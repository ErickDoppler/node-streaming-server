#!/usr/bin/env node
'use strict';

/*
 * Smoke test for a built Streaming Server.
 *
 * The project has no compile step, so "did it build" can only mean "does it
 * actually run". This starts the built server and drives every path a real
 * deployment uses: the viewer page, /info, the publisher handshake on the
 * same port, the device-token takeover, and an end-to-end frame relay to a
 * WebSocket viewer. The first failure exits non-zero so build.cmd and
 * build.sh can fail the build.
 *
 *   usage: node scripts/smoke-test.js <dir-containing-server.js>
 */

const { spawn } = require('child_process');
const http = require('http');
const net = require('net');
const path = require('path');
const crypto = require('crypto');

const WS_MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const KEY = 'smoketest_' + crypto.randomBytes(3).toString('hex');
const START_TIMEOUT = 20000;

const serverDir = path.resolve(process.argv[2] || '.');
const serverJs = path.join(serverDir, 'server.js');

let passed = 0;

function ok(what) {
  passed++;
  console.log('  [pass] ' + what);
}

function fail(what, detail) {
  throw new Error(what + (detail ? ' -- ' + detail : ''));
}

function check(cond, what, detail) {
  if (cond) ok(what);
  else fail(what, detail);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------------- server boot

/** Starts server.js and resolves with the port it reports in its log. */
function startServer() {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['server.js'], {
      cwd: serverDir,
      stdio: ['ignore', 'pipe', 'pipe']
    });
    let out = '';
    let done = false;
    const timer = setTimeout(() => {
      if (done) return;
      done = true;
      child.kill();
      reject(new Error('server reported no port within ' + START_TIMEOUT +
        'ms; output was:\n' + out));
    }, START_TIMEOUT);

    const scan = (buf) => {
      out += buf;
      const m = /single port (\d+)/.exec(out);
      if (m && !done) {
        done = true;
        clearTimeout(timer);
        resolve({ child, port: Number(m[1]), log: () => out });
      }
    };
    child.stdout.on('data', scan);
    child.stderr.on('data', scan);
    child.on('error', (e) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      reject(e);
    });
    child.on('exit', (code) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      reject(new Error('server exited early with code ' + code + ':\n' + out));
    });
  });
}

// ------------------------------------------------------------- http helper

function get(port, urlPath) {
  return new Promise((resolve, reject) => {
    const req = http.get(
      { host: '127.0.0.1', port: port, path: urlPath, timeout: 5000 },
      (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (d) => { body += d; });
        res.on('end', () => resolve({ status: res.statusCode, body: body }));
      }
    );
    req.on('timeout', () => req.destroy(new Error('timeout on ' + urlPath)));
    req.on('error', reject);
  });
}

// -------------------------------------------------------- publisher helper

/** Opens a raw TCP publisher link with a line reader and a frame writer. */
function publisher(port) {
  const sock = net.connect({ host: '127.0.0.1', port: port });
  const lines = [];
  const waiters = [];
  let buf = '';

  sock.on('data', (chunk) => {
    buf += chunk.toString('latin1');
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      if (waiters.length) waiters.shift()(line);
      else lines.push(line);
    }
  });
  sock.on('error', () => {});

  return {
    sock: sock,
    ready: new Promise((res, rej) => {
      sock.once('connect', res);
      sock.once('error', rej);
    }),
    send: (s) => sock.write(s),
    /** Resolves with the next newline-terminated reply, or null on timeout. */
    line: (ms) => new Promise((res) => {
      if (lines.length) return res(lines.shift());
      const w = (l) => { clearTimeout(t); res(l); };
      const t = setTimeout(() => {
        const i = waiters.indexOf(w);
        if (i >= 0) waiters.splice(i, 1);
        res(null);
      }, ms || 5000);
      waiters.push(w);
    }),
    /** One wire frame: u32be length, u8 flags, u64be pts, payload. */
    frame: (isKey, pts, payload) => {
      const head = Buffer.alloc(13);
      head.writeUInt32BE(payload.length, 0);
      head[4] = isKey ? 1 : 0;
      head.writeBigUInt64BE(BigInt(pts), 5);
      sock.write(Buffer.concat([head, payload]));
    },
    close: () => sock.destroy()
  };
}

// ----------------------------------------------------------- viewer helper

/** Opens a WebSocket viewer and collects the binary messages it receives. */
function viewer(port, key) {
  const sock = net.connect({ host: '127.0.0.1', port: port });
  const nonce = crypto.randomBytes(16).toString('base64');
  const expect = crypto.createHash('sha1')
    .update(nonce + WS_MAGIC).digest('base64');
  const messages = [];
  let buf = Buffer.alloc(0);
  let upgraded = false;

  const opened = new Promise((resolve, reject) => {
    sock.once('connect', () => {
      sock.write(
        'GET /ws?key=' + encodeURIComponent(key) + ' HTTP/1.1\r\n' +
        'Host: 127.0.0.1\r\n' +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        'Sec-WebSocket-Key: ' + nonce + '\r\n' +
        'Sec-WebSocket-Version: 13\r\n\r\n'
      );
    });
    sock.once('error', reject);
    sock.on('data', (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      if (!upgraded) {
        const end = buf.indexOf('\r\n\r\n');
        if (end < 0) return;
        const head = buf.subarray(0, end).toString('latin1');
        buf = buf.subarray(end + 4);
        upgraded = true;
        if (!/^HTTP\/1\.1 101/.test(head)) {
          return reject(new Error('no 101 upgrade:\n' + head));
        }
        if (head.indexOf('Sec-WebSocket-Accept: ' + expect) < 0) {
          return reject(new Error('wrong Sec-WebSocket-Accept:\n' + head));
        }
        resolve();
      }
      // Server frames are unmasked; each one carries a relayed video frame.
      while (buf.length >= 2) {
        const opcode = buf[0] & 0x0f;
        let len = buf[1] & 0x7f;
        let off = 2;
        if (len === 126) {
          if (buf.length < 4) return;
          len = buf.readUInt16BE(2);
          off = 4;
        } else if (len === 127) {
          if (buf.length < 10) return;
          len = Number(buf.readBigUInt64BE(2));
          off = 10;
        }
        if (buf.length < off + len) return;
        const payload = Buffer.from(buf.subarray(off, off + len));
        buf = buf.subarray(off + len);
        if (opcode === 2) messages.push(payload);
      }
    });
  });

  return { opened: opened, messages: messages, close: () => sock.destroy() };
}

// -------------------------------------------------------------------- run

async function run() {
  console.log('smoke test: ' + serverJs);
  const started = await startServer();
  const child = started.child;
  const port = started.port;
  ok('server started on port ' + port);

  try {
    // --- HTTP surface ----------------------------------------------------
    const info = await get(port, '/info');
    check(info.status === 200, 'GET /info -> 200', 'got ' + info.status);
    const j = JSON.parse(info.body);
    check(typeof j.version === 'string' && j.version.length > 0,
      'GET /info reports a version (V' + j.version + ')');
    check(j.viewerPort === port && j.streamPort === port,
      'GET /info reports one port for viewers and publishers');
    check(Array.isArray(j.ips) && Array.isArray(j.live),
      'GET /info reports ips[] and live[]');

    const page = await get(port, '/');
    check(page.status === 200 && /STREAMING SERVER/.test(page.body),
      'GET / serves the viewer page (' + page.body.length + ' bytes)');

    const missing = await get(port, '/nope');
    check(missing.status === 404, 'GET /nope -> 404', 'got ' + missing.status);

    // --- publisher handshake, on that very same port ---------------------
    const probe = publisher(port);
    await probe.ready;
    probe.send('CHECK ' + KEY + '\n');
    check((await probe.line()) === 'FREE', 'CHECK on a free key -> FREE');
    probe.close();

    const pub = publisher(port);
    await pub.ready;
    pub.send('STREAM ' + KEY + '\n');
    const okLine = await pub.line();
    check(/^OK [0-9a-f]{32}$/.test(okLine || ''),
      'STREAM handshake -> OK <token>', 'got ' + okLine);
    const token = okLine.slice(3);

    const busy = publisher(port);
    await busy.ready;
    busy.send('CHECK ' + KEY + '\n');
    check((await busy.line()) === 'BUSY', 'CHECK on a taken key -> BUSY');
    busy.close();

    const liveNow = JSON.parse((await get(port, '/info')).body).live;
    check(liveNow.indexOf(KEY) >= 0, 'GET /info lists the live key');

    // --- end-to-end relay ------------------------------------------------
    const view = viewer(port, KEY);
    await view.opened;
    ok('WebSocket viewer upgraded on /ws?key=' + KEY);

    pub.frame(false, 1000, Buffer.from([0, 0, 0, 1, 0x41, 0xaa, 0xbb]));
    await sleep(300);
    check(view.messages.length === 0,
      'a fresh viewer is not fed a mid-GOP frame before its first keyframe',
      'got ' + view.messages.length + ' message(s)');

    const payload = Buffer.from([0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x65, 9]);
    pub.frame(true, 2000, payload);
    for (let i = 0; i < 50 && view.messages.length === 0; i++) await sleep(20);
    check(view.messages.length === 1, 'the keyframe reached the viewer',
      'got ' + view.messages.length + ' message(s)');
    const got = view.messages[0];
    check(got[0] === 1 && Number(got.readBigUInt64BE(1)) === 2000,
      'the relayed frame keeps its keyframe flag and its pts');
    check(got.subarray(9).equals(payload),
      'the relayed payload is byte-identical to what was published');

    pub.frame(false, 2033, Buffer.from([0, 0, 0, 1, 0x41, 7]));
    for (let i = 0; i < 50 && view.messages.length < 2; i++) await sleep(20);
    check(view.messages.length === 2,
      'the next mid-GOP frame is relayed as well');

    // --- key ownership ---------------------------------------------------
    const intruder = publisher(port);
    await intruder.ready;
    intruder.send('STREAM ' + KEY + '\n');
    check((await intruder.line()) === 'BUSY',
      'a second publisher without the token is refused');
    intruder.close();

    const rejoin = publisher(port);
    await rejoin.ready;
    rejoin.send('STREAM ' + KEY + ' ' + token + '\n');
    check(/^OK /.test((await rejoin.line()) || ''),
      'the same publisher retakes its key with its device token');
    rejoin.close();

    view.close();
    pub.close();
    await sleep(300);

    const after = JSON.parse((await get(port, '/info')).body).live;
    check(after.indexOf(KEY) < 0,
      'the key is released once every publisher is gone');

    console.log('\nsmoke test OK - ' + passed + ' checks passed');
  } catch (e) {
    console.error('\nsmoke test FAILED: ' + (e && e.message || e));
    console.error('\n--- server output ---\n' + started.log());
    process.exitCode = 1;
  } finally {
    child.kill();
  }
}

run().catch((e) => {
  console.error('smoke test FAILED: ' + (e && e.stack || e));
  process.exitCode = 1;
});
