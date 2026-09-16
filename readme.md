# node-streaming-server

A tiny H.264 relay server. A phone (or any other encoder) pushes video to it
over a plain TCP socket; anyone with a browser and the stream key watches it
live, with roughly a frame of latency and no plugins, no apps and no accounts.

It is **one file, zero npm dependencies, one TCP port**. The only thing it needs
is a Node.js runtime, and `download-tools` will fetch a portable one for you.

Built as the video backend for the F16 HUD / Matrix Cam family of Android apps,
but the wire protocol is simple enough for anything that can emit Annex-B H.264.

---

## Run it

Three steps on either platform: **get the toolchain**, **build**, **start**.
Nothing is installed system-wide, nothing is added to your PATH, and nothing
touches the registry — everything lives inside this folder.

### Windows

**1. Get the toolchain.** Double-click `download-tools.cmd`, or run it from a
terminal in this folder. It downloads a portable Node.js into `tools\node\`
(~33 MB, verified against nodejs.org's SHA-256 checksums), and skips the
download entirely if you already have Node.js 18 or newer.

```bat
download-tools.cmd
```

**2. Build.** Parse-checks the sources, stages a self-contained `dist\` folder,
then actually starts that server and relays a real video frame through it — 20
checks — before it reports success.

```bat
build.cmd
```

**3. Start it.** Launches the server and opens the viewer page in your browser.

```bat
dist\run.cmd
```

### Linux / macOS

**1. Get the toolchain.** Downloads a portable Node.js into `tools/node/`
(~50 MB, verified against nodejs.org's SHA-256 checksums), and skips the
download entirely if you already have Node.js 18 or newer. No sudo, no package
manager.

```bash
./download-tools.sh
```

**2. Build.** Parse-checks the sources, stages a self-contained `dist/` folder,
then actually starts that server and relays a real video frame through it — 20
checks — before it reports success.

```bash
./build.sh
```

**3. Start it.** Launches the server and opens the viewer page in your browser.

```bash
./dist/run.sh
```

*(The `.sh` files are committed executable, so a `git clone` needs no `chmod`.
If you downloaded a ZIP instead, run `chmod +x *.sh` once.)*

### Then what

The server prints the port it bound on startup — it prefers **80**, then 8080,
then 8000. Open `http://<server-ip>:<port>/` from any browser on the network,
type a stream key, and press **CONNECT**. Point your encoder at that same
`<server-ip>:<port>` with the same key, and the picture appears.

### Deploying it elsewhere

Build with the Node.js runtime baked in, then copy the whole `dist/` folder to
the target machine — it needs nothing installed at all, not even Node.js:

```bat
build.cmd --bundle-node
```

```bash
./build.sh --bundle-node
```

Then run `run.cmd` or `run.sh` inside the copied folder.

---

## Contents

- [Run it](#run-it)
- [Why one port](#why-one-port)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [The scripts](#the-scripts)
- [Using the viewer page](#using-the-viewer-page)
- [Publishing a stream](#publishing-a-stream)
- [Wire protocol](#wire-protocol)
- [HTTP endpoints](#http-endpoints)
- [Ports, routers and firewalls](#ports-routers-and-firewalls)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Project layout](#project-layout)
- [Contributing](#contributing)

---

## Why one port

Most streaming stacks want several ports open — one for ingest, one for the web
UI, one for signalling. Behind a home router, a corporate firewall or a mobile
carrier NAT, that is the whole battle.

This server multiplexes everything onto a **single TCP port**. It peeks at the
first bytes of each incoming connection and decides what it is:

| First bytes         | Treated as                                   |
| ------------------- | -------------------------------------------- |
| `STREAM ` / `CHECK ` | a publisher pushing video (raw TCP)          |
| anything else        | HTTP — the viewer page, `/info`, or a WebSocket upgrade |

So forwarding one port is enough to serve both the people watching and the
device streaming.

The server prefers the ports most likely to already be open outbound —
**80**, then **8080**, then **8000** — then the port it used last time
(remembered in `.ports.json`), then a random one in 6500–7500. Whichever it
picks, it prints it on startup and reports it at `/info`.

## How it works

```
  Android / encoder                  node-streaming-server                browser
  ─────────────────                  ─────────────────────                ───────
   STREAM <key> ─────────────► ┌──────────────────────────┐
   OK <token>   ◄───────────── │  first-byte demultiplexer │
                               │                          │
   H.264 frames ─────────────► │  key ──► viewer set      │ ──WebSocket──►  fMP4
   (Annex-B, u32 length        │         (starts each new │   binary frames  in
    + flags + pts)             │          viewer at the   │                 MSE
                               │          next keyframe)  │
                               └──────────────────────────┘
```

The server itself never decodes, transcodes or re-containers anything — it is a
pure fan-out relay, which is why it stays this small and this fast. All of the
clever work happens in the browser: `public/index.html` contains a hand-written
fragmented-MP4 muxer that wraps the incoming Annex-B H.264 (and ADTS AAC, if the
publisher sends sound) into fMP4 segments and feeds them to Media Source
Extensions. That is why the viewer page needs no JavaScript libraries at all.

A few details that matter in practice:

- **Viewers may arrive first.** Subscribing to a key that has no publisher yet
  just waits; the picture appears when the stream starts.
- **New viewers start at the next keyframe**, never mid-GOP, so nobody ever sees
  a screen of green mush.
- **A publisher that restarts keeps its key.** On its first `STREAM` the server
  issues a device token; reconnecting with that token takes the key back from
  the stale session instead of being told `BUSY`. Users never see the token —
  they only ever need the stream key.
- **A silent publisher is dropped after 60 s**, so a crashed app cannot sit on a
  key forever.

## Requirements

- **Node.js 18 or newer** — that is the entire dependency list. `download-tools`
  will fetch a portable copy if you do not have one.
- A modern browser for the viewer page (anything with Media Source Extensions:
  Chrome, Edge, Firefox, Safari 13+, Android WebView).

No npm install, no build toolchain, no native modules.

## The scripts

| Script | What it does |
| ------ | ------------ |
| `download-tools.cmd` / `.sh` | Downloads a portable Node.js into `tools/node/`, verified against the SHA-256 checksums published by nodejs.org. Skips the download if a new-enough Node.js is already on PATH — `--force` downloads anyway. Override the version with `NODE_VERSION=v20.18.1`. |
| `build.cmd` / `.sh` | Finds Node.js, parses every source file, stages `dist/`, and smoke-tests the result. `--no-test` skips the smoke test; `--bundle-node` copies the runtime into `dist/node/`. |
| `dist/run.cmd` / `run.sh` | Starts the built server and opens the viewer page. Generated by `build` from `scripts/run-template.*`. |
| `start-server.bat` / `.sh` | The original no-build launcher: runs `server.js` straight from the source folder, downloading Node.js itself if it has to. Handy when you just want the thing up and do not care about `dist/`. |
| `scripts/smoke-test.js` | The build's proof of life. Boots the server, then checks the viewer page, `/info`, the publisher handshake, key ownership and the device-token takeover, and relays a real frame to a real WebSocket viewer — 20 assertions in about a second. Run it by hand with `node scripts/smoke-test.js dist`. |

`build` fails loudly and returns a non-zero exit code on any problem, so it
drops straight into CI.

## Using the viewer page

Open `http://<server-ip>:<port>/` — the port is printed on startup.

1. Type the **stream key** and press **CONNECT** (or Enter).
2. Keys you have used are remembered in a **streaming catalog** below the box;
   click one to reconnect. **CLEAR** forgets them.

While a stream is playing:

| Gesture | Effect |
| ------- | ------ |
| Double click / double tap on the video | Fullscreen on, and off again (Esc also exits) |
| Long press on the video | Rotate the picture 90°, for awkwardly mounted cameras. Remembered. |
| Double click / double tap on the **STREAMING SERVER** title | Cycle the colour scheme: white, grey, green, yellow, red, sky blue. Remembered. |

Audio starts muted — browsers insist — so unmute with the video controls if the
publisher is sending sound.

The status line tells you where you stand: `CONNECTING`, `WAITING FOR STREAM`
(subscribed, publisher not live yet), `LIVE`, or `SERVER LOST — RETRYING`, which
reconnects by itself.

## Publishing a stream

Point your encoder at `<server-ip>:<port>` — the **same** port as the viewer
page — and speak the protocol below. On Android, that is what the F16 HUD /
Matrix Cam apps do; anywhere else, roughly 30 lines of socket code.

Stream keys are `[A-Za-z0-9_-]`, 1–64 characters.

## Wire protocol

### Handshake (publisher, plain text, `\n`-terminated)

```
STREAM <key> [token]   ->  OK <token>     the key is yours; remember the token
                       ->  BUSY           someone else is on that key
                       ->  BAD            malformed request or illegal key

CHECK <key>            ->  FREE | BUSY | BAD
```

`CHECK` lets an app grey out a key that is already taken before the user
commits to it.

The token is 32 hex characters, issued by the server on the first `STREAM` for a
key. Store it on the device and send it back on every later `STREAM`: that is
what lets the same device reclaim its key after a crash or a dropped link. A
different device, without the token, gets `BUSY`.

### Frames (publisher, binary, after `OK`)

```
┌──────────────┬───────┬───────────────┬───────────────────────┐
│ length  u32be│ flags │  pts   u64be  │  payload (length bytes)│
│  (4 bytes)   │  u8   │   (8 bytes)   │   H.264 Annex-B        │
└──────────────┴───────┴───────────────┴───────────────────────┘
```

- `length` — payload size in bytes; max 4 MiB.
- `flags` — bit 0 = keyframe, bit 1 = this payload is ADTS AAC audio, not video.
- `pts` — presentation timestamp in milliseconds.
- `payload` — Annex-B H.264 (`00 00 00 01` start codes). **Prepend SPS and PPS
  to every keyframe** — new viewers join at a keyframe and have nothing else to
  configure the decoder with.

Send ~30 frames a second and keep the socket alive; 60 seconds of silence closes
it and frees the key.

### Frames (viewer, WebSocket binary)

Connect to `ws://<host>:<port>/ws?key=<key>`. Every binary message is one frame,
the publisher's own bytes minus the length prefix:

```
┌───────┬───────────────┬────────────────────────┐
│ flags │  pts   u64be  │  payload               │
│  u8   │   (8 bytes)   │  H.264 Annex-B / ADTS  │
└───────┴───────────────┴────────────────────────┘
```

## HTTP endpoints

| Route | Response |
| ----- | -------- |
| `GET /` | The viewer page. |
| `GET /info` | `{"version","ips","viewerPort","streamPort","live"}` — `ips` are the server's LAN addresses, `live` the keys currently being published. Handy for a "what is streaming right now" dashboard. |
| `GET /ws?key=<key>` | WebSocket upgrade; see above. |

## Ports, routers and firewalls

To watch from outside the LAN, forward **one** TCP port on your router to the
machine running the server. Port 80 is the friendliest choice — it is the one
port that is open outbound almost everywhere, including on hotel Wi-Fi and
mobile networks.

- **Windows** — binding port 80 needs nothing special, but IIS, Skype or another
  web server may already hold it. The server will quietly move to 8080.
- **Linux / macOS** — ports below 1024 need privileges. Either run the server
  with them, or grant the capability once:
  `sudo setcap 'cap_net_bind_service=+ep' tools/node/bin/node`. Without that it
  simply falls through to 8080, which is fine on a LAN.

`.ports.json` remembers the last port that worked, so the address stays stable
across restarts. Delete it to start the search from scratch.

## Security

Be clear-eyed about what this is: a **LAN and hobby-grade relay**, not a
hardened public service.

- **No TLS.** Traffic is plain HTTP and plain TCP. Anyone on the path can watch
  the video.
- **The stream key is the only secret.** Anyone who knows it can view the
  stream; there are no viewer accounts or passwords. Treat a key like a
  password — long and unguessable — if the server is reachable from the
  internet.
- **The device token only protects publishing**, not viewing. It stops a
  stranger from hijacking your key to push their own video.
- **No rate limiting and no viewer cap.** Every viewer gets a full copy of the
  stream, so bandwidth is `bitrate × viewers`.

If you expose this to the internet, put it behind a reverse proxy that
terminates TLS and adds authentication.

## Troubleshooting

**`build` says no Node.js found** — run `download-tools` first, or install
Node.js 18+ from [nodejs.org](https://nodejs.org).

**The viewer page loads but stays on `WAITING FOR STREAM`** — nothing is
publishing on that key. Check `/info`: the `live` array lists the keys actually
being pushed right now. Keys are case-sensitive.

**The publisher gets `BUSY` after a crash** — it reconnected without its device
token, so the server cannot tell it apart from a stranger. Make sure the app
stores the token from `OK <token>` and sends it back. The stale session is
dropped after 60 seconds of silence in any case.

**Black picture, or the player never starts** — the publisher is probably not
prepending SPS/PPS to its keyframes. The viewer needs them to configure the
decoder, and it ignores everything before the first usable keyframe.

**Video drifts behind live** — the page nudges itself back to the live edge once
a second, but it will not fight you if you deliberately paused. Press play, or
reconnect.

**The port keeps changing** — something else is taking 80/8080/8000 first.
Delete `.ports.json` and restart, or free the port you want.

## Project layout

```
node-streaming-server/
├── server.js                 the whole server (~400 lines, no dependencies)
├── public/
│   └── index.html            viewer page: fMP4 muxer + MSE player, no libraries
├── scripts/
│   ├── smoke-test.js         end-to-end test run by build
│   ├── run-template.cmd      copied into dist/ as run.cmd
│   └── run-template.sh       copied into dist/ as run.sh
├── download-tools.cmd/.sh    fetch the portable Node.js toolchain
├── build.cmd/.sh             check, stage dist/, smoke-test
├── start-server.bat/.sh      no-build launcher, straight from source
├── package.json
├── tools/                    downloaded toolchain        (git-ignored)
└── dist/                     build output                (git-ignored)
```

## Contributing

`main` is protected: it takes a pull request, and a pull request takes an
approving review from [@ErickDoppler](https://github.com/ErickDoppler), who owns
every path in the repository. Nothing lands on `main` any other way.

If you have push access to this repository:

```bash
git switch -c my-change
# ...work...
git push -u origin my-change
gh pr create            # or open it on github.com
```

If you do not, fork the repository, push the branch to your fork, and open the
pull request from there. Either way the review path is the same.

Before you push, make sure the build still passes — it is the whole test suite:

```bash
./build.sh              # build.cmd on Windows
```

Pushing new commits to an open pull request dismisses the existing approval, so
expect another round of review after a fixup.
