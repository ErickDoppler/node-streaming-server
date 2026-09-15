#!/usr/bin/env node
'use strict';

/*
 * Streaming Server — relays H.264 video from F16 HUD publishers to viewers.
 *
 * ONE TCP port serves everything, so a single open/forwarded port is enough
 * to cross firewalls. Standard ports are preferred (80, then 8080, 8000);
 * if all are taken, the previously used port (persisted in .ports.json) and
 * finally a random port from 6500..7500 are tried. Connections are told
 * apart by their first bytes:
 *
 *   Publishers (raw TCP):
 *     Handshake:  "STREAM <key> [token]\n" -> "OK <token>\n" | "BUSY\n" | "BAD\n"
 *                 "CHECK <key>\n"          -> "FREE\n" | "BUSY\n" | "BAD\n"
 *     The token is a server-issued device validation key (never shown to
 *     users): a publisher reconnecting with the right token takes its key
 *     back from a stale session instead of getting BUSY — the fuse for
 *     "closed the app, reopened it, key still in use". Viewers only ever
 *     need the stream key.
 *     After OK the publisher sends frames:
 *       u32be payloadLength, u8 flags (bit0 = keyframe), u64be ptsMillis,
 *       payload = H.264 Annex-B (SPS/PPS prepended to every keyframe).
 *
 *   Browsers (HTTP):
 *     GET /          the viewer page
 *     GET /info      JSON: version, IPs, ports, live stream keys
 *     GET /ws?key=K  WebSocket; every binary message is one frame:
 *                    u8 flags, u64be ptsMillis, payload (Annex-B).
 *     A viewer may subscribe before its stream goes live; it simply waits.
 *     Forwarding to a fresh viewer starts at the next keyframe.
 */

const http = require('http');
const net = require('net');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const os = require('os');

const VERSION = '1.4';
// Most-probably-open ports first; the 6500..7500 range is the last resort.
const STANDARD_PORTS = [80, 8080, 8000];
const PORT_MIN = 6500;
const PORT_MAX = 7500;
const PORTS_FILE = path.join(__dirname, '.ports.json');
const PUBLIC_DIR = path.join(__dirname, 'public');
const KEY_RE = /^[A-Za-z0-9_-]{1,64}$/;
const MAX_FRAME = 4 * 1024 * 1024;

// key -> { publisher: net.Socket|null, viewers: Set<Viewer>, token: string }
// Viewer = { socket: net.Socket, started: boolean }
const streams = new Map();

function stream(key) {
  let s = streams.get(key);
  if (!s) {
    s = { publisher: null, viewers: new Set(), token: '' };
    streams.set(key, s);
  }
  return s;
}

function gcStream(key) {
  const s = streams.get(key);
  if (s && !s.publisher && s.viewers.size === 0) streams.delete(key);
}

function localIps() {
  const out = [];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const it of list || []) {
      if (it.family === 'IPv4' && !it.internal) out.push(it.address);
    }
  }
  return out;
}

// ------------------------------------------------------------ sticky ports

function loadPorts() {
  try {
    const p = JSON.parse(fs.readFileSync(PORTS_FILE, 'utf8'));
    const port = p.port || p.viewer; // `viewer` = pre-V1.1 two-port files
    if (Number.isInteger(port)) return { port };
  } catch (_) {}
  return {};
}

function randPort() {
  return PORT_MIN + Math.floor(Math.random() * (PORT_MAX - PORT_MIN + 1));
}

/** Standard ports first, then the sticky one, then randoms in range. */
function listenPreferred(server, sticky) {
  return new Promise((resolve, reject) => {
    const candidates = [...STANDARD_PORTS];
    if (Number.isInteger(sticky) && sticky > 0 && !candidates.includes(sticky)) {
      candidates.push(sticky);
    }
    for (let i = 0; i < 200; i++) candidates.push(randPort());
    let i = 0;
    const tryNext = () => {
      if (i >= candidates.length) return reject(new Error('no free port'));
      const port = candidates[i++];
      server.once('error', (e) => {
        if (e.code === 'EADDRINUSE' || e.code === 'EACCES') tryNext();
        else reject(e);
      });
      server.listen(port, () => {
        server.removeAllListeners('error');
        resolve(port);
      });
    };
    tryNext();
  });
}

// -------------------------------------------------------------- publishers

function handlePublisher(socket) {
  socket.setNoDelay(true);
  // A live publisher pushes ~30 frames a second; a long-silent socket is a
  // dead one (crashed app, vanished network) and must free its key.
  socket.setTimeout(60000, () => socket.destroy());
  let buf = Buffer.alloc(0);
  let key = null;          // set after a successful STREAM handshake
  let handshaken = false;

  const drop = (reply) => {
    try { if (reply) socket.write(reply); } catch (_) {}
    socket.destroy();
  };

  socket.on('data', (chunk) => {
    buf = buf.length ? Buffer.concat([buf, chunk]) : chunk;

    if (!handshaken) {
      const nl = buf.indexOf(0x0a);
      if (nl < 0) {
        if (buf.length > 512) drop('BAD\n');
        return;
      }
      const line = buf.subarray(0, nl).toString('utf8').trim();
      buf = buf.subarray(nl + 1);
      const m = /^(STREAM|CHECK)\s+(\S+)(?:\s+(\S+))?$/.exec(line);
      if (!m || !KEY_RE.test(m[2])) return drop('BAD\n');
      const k = m[2];
      const clientToken = m[3] || '';
      if (clientToken && !/^[0-9a-fA-F]{16,64}$/.test(clientToken)) {
        return drop('BAD\n');
      }
      const busy = !!streams.get(k)?.publisher;
      if (m[1] === 'CHECK') return drop(busy ? 'BUSY\n' : 'FREE\n');
      const s = stream(k);
      if (busy) {
        // The device validation token: the same publisher returning after
        // an app restart or a dropped link replaces its stale session; a
        // different device stays BUSY.
        if (!clientToken || clientToken !== s.token) return drop('BUSY\n');
        try { s.publisher.destroy(); } catch (_) {}
        log(`publisher takeover: key=${k}`);
      }
      if (!s.token) s.token = crypto.randomBytes(16).toString('hex');
      s.publisher = socket;
      // A (re)starting encoder means new parameters: resync every viewer.
      for (const v of s.viewers) v.started = false;
      key = k;
      handshaken = true;
      try { socket.write(`OK ${s.token}\n`); } catch (_) {}
      log(`publisher connected: key=${key} from ${socket.remoteAddress}`);
    }

    // Frame loop: forward every complete frame to the key's viewers.
    while (true) {
      if (buf.length < 13) return;
      const len = buf.readUInt32BE(0);
      if (len === 0 || len > MAX_FRAME) return drop(null);
      if (buf.length < 13 + len) return;
      const flags = buf[4];
      const header = buf.subarray(4, 13);      // flags + pts, reused for WS
      const payload = buf.subarray(13, 13 + len);
      buf = buf.subarray(13 + len);
      const s = streams.get(key);
      if (!s) return drop(null);
      const msg = Buffer.concat([header, payload]);
      for (const v of s.viewers) {
        if (!v.started) {
          if (!(flags & 1)) continue;          // wait for a keyframe
          v.started = true;
        }
        wsSend(v.socket, msg);
      }
    }
  });

  const bye = () => {
    if (key) {
      const s = streams.get(key);
      if (s && s.publisher === socket) {
        s.publisher = null;
        // Viewers stay subscribed and resume at the next keyframe.
        for (const v of s.viewers) v.started = false;
        gcStream(key);
        log(`publisher disconnected: key=${key}`);
      }
    }
  };
  socket.on('close', bye);
  socket.on('error', () => {});
}

// ------------------------------------------------------------- WebSockets

const WS_MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/** Sends one binary WS frame (server frames are unmasked). */
function wsSend(socket, payload) {
  if (socket.destroyed) return;
  const n = payload.length;
  let header;
  if (n < 126) {
    header = Buffer.from([0x82, n]);
  } else if (n < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x82; header[1] = 126;
    header.writeUInt16BE(n, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x82; header[1] = 127;
    header.writeBigUInt64BE(BigInt(n), 2);
  }
  try {
    socket.write(header);
    socket.write(payload);
  } catch (_) {}
}

/** Minimal client-frame reader: answers pings, honors close. */
function wsListen(socket, onClose) {
  let buf = Buffer.alloc(0);
  socket.on('data', (chunk) => {
    buf = buf.length ? Buffer.concat([buf, chunk]) : chunk;
    while (buf.length >= 2) {
      const opcode = buf[0] & 0x0f;
      const masked = (buf[1] & 0x80) !== 0;
      let len = buf[1] & 0x7f;
      let off = 2;
      if (len === 126) {
        if (buf.length < 4) return;
        len = buf.readUInt16BE(2); off = 4;
      } else if (len === 127) {
        if (buf.length < 10) return;
        len = Number(buf.readBigUInt64BE(2)); off = 10;
      }
      const maskOff = off;
      if (masked) off += 4;
      if (buf.length < off + len) return;
      const payload = Buffer.from(buf.subarray(off, off + len));
      if (masked) {
        for (let i = 0; i < len; i++) payload[i] ^= buf[maskOff + (i % 4)];
      }
      buf = buf.subarray(off + len);
      if (opcode === 8) {           // close
        try { socket.end(Buffer.from([0x88, 0x00])); } catch (_) {}
        onClose();
        return;
      }
      if (opcode === 9) {           // ping -> pong
        const pong = Buffer.alloc(2 + payload.length);
        pong[0] = 0x8a; pong[1] = payload.length;
        payload.copy(pong, 2);
        try { socket.write(pong); } catch (_) {}
      }
      // Text/binary from viewers is ignored.
    }
  });
  socket.on('close', onClose);
  socket.on('error', () => {});
}

// ------------------------------------------------------------ HTTP viewer

function serveFile(res, file, type) {
  fs.readFile(path.join(PUBLIC_DIR, file), (err, data) => {
    if (err) {
      res.writeHead(404); res.end('not found');
      return;
    }
    res.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-cache' });
    res.end(data);
  });
}

function makeHttpServer(getPorts) {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    if (url.pathname === '/' || url.pathname === '/index.html') {
      return serveFile(res, 'index.html', 'text/html; charset=utf-8');
    }
    if (url.pathname === '/info') {
      const ports = getPorts();
      const live = [...streams.entries()]
        .filter(([, s]) => s.publisher).map(([k]) => k);
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Cache-Control': 'no-cache'
      });
      return res.end(JSON.stringify({
        version: VERSION,
        ips: localIps(),
        viewerPort: ports.viewer,
        streamPort: ports.stream,
        live
      }));
    }
    res.writeHead(404); res.end('not found');
  });

  server.on('upgrade', (req, socket) => {
    const url = new URL(req.url, 'http://x');
    const key = url.searchParams.get('key') || '';
    const wsKey = req.headers['sec-websocket-key'];
    if (url.pathname !== '/ws' || !KEY_RE.test(key) || !wsKey) {
      socket.destroy();
      return;
    }
    const accept = crypto.createHash('sha1')
      .update(wsKey + WS_MAGIC).digest('base64');
    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
    );
    socket.setNoDelay(true);
    const s = stream(key);
    const viewer = { socket, started: false };
    s.viewers.add(viewer);
    log(`viewer joined: key=${key} from ${socket.remoteAddress} ` +
        `(${s.viewers.size} viewing)`);
    wsListen(socket, () => {
      if (s.viewers.delete(viewer)) {
        gcStream(key);
        log(`viewer left: key=${key}`);
      }
    });
  });

  return server;
}

// ------------------------------------------------------------------- main

function log(msg) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

async function main() {
  const saved = loadPorts();
  const ports = {};

  // HTTP handling exists as an internal server; connections reach it only
  // through the multiplexer below, which sniffs the first bytes: publisher
  // handshakes ("STREAM ", "CHECK ") go to the relay, everything else is
  // parsed as HTTP. One open port covers viewers AND stream clients.
  const httpServer = makeHttpServer(() => ports);
  const server = net.createServer((socket) => {
    socket.once('data', (first) => {
      socket.pause();
      socket.unshift(first);
      const head = first.toString('latin1', 0, Math.min(first.length, 7));
      if (head.startsWith('STREAM') || head.startsWith('CHECK')) {
        handlePublisher(socket);
      } else {
        httpServer.emit('connection', socket);
      }
      socket.resume();
    });
    socket.on('error', () => {});
  });

  const port = await listenPreferred(server, saved.port);
  ports.viewer = port;
  ports.stream = port;

  if (saved.port !== port) {
    try {
      // `viewer`/`stream` kept for older launcher scripts and tools.
      fs.writeFileSync(PORTS_FILE,
        JSON.stringify({ port, viewer: port, stream: port }));
    } catch (_) {}
  }

  log(`Streaming Server V${VERSION}`);
  const ips = localIps();
  log(`single port ${port} serves the viewer page AND stream clients`);
  log(`viewer page:      ${ips.map((ip) => `http://${ip}:${port}`).join('  ') || `http://localhost:${port}`}`);
  log(`stream endpoint:  ${ips.map((ip) => `${ip}:${port}`).join('  ') || `localhost:${port}`}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
