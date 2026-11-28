# The host protocol (`hostwire/1`)

How the app talks to a machine, what runs there, and what it can and cannot do.
Written for two readers: someone deciding whether to trust the helper the app puts
on their machine, and a developer adding to it. Every claim names the file it comes
from; paths are relative to the repository root. The catalog of services and
methods is `docs/host-api.json`, printed by `herdr-host api` and checked by a test,
so this file does not repeat it.

## What it replaces and why

The app used to send four small python programs to each machine (a request relay
for herdr's socket, an event relay, a fallback relay, and the keeper) and used SFTP
and one SSH channel per command for everything else. Each of those was a channel on
the SSH connection (sshd counts them against `MaxSessions`), needed `python3`, and
spoke its own framing.

Now one program, `herdr-host` (`rust/crates/host`), runs as `herdr-host serve` on
**one** exec channel per machine and carries everything on it: herdr's requests and
events, agent sessions, log following, file reading and watching, inbox uploads,
port listing, and Made verification. There is no python on the machine and none in
the app.

## Process model

- `serve` lives exactly as long as its SSH channel. It is not a service, opens no
  port and installs nothing resident. When stdin ends it exits; it never signals a
  keeper. Per-session keeper daemons are the only background processes, as before
  (`docs/AGENT_SESSIONS.md`).
- The app starts it with a fixed command (`hostServeCommand()`,
  `app/lib/data/services/keeper_command.dart`) that execs
  `~/.herdr-mobile/bin/herdr-host-<app version>` and exits 65 when that file is
  missing. Exit codes of `serve`: 0 the client ended, 64 usage, 70 a protocol
  failure (the reason is on stderr).
- **Installed per version.** On 65 the app runs the installer once
  (`tool/install-host.sh`, embedded verbatim and checked by a test): the host
  downloads the release of the app's exact version from GitHub, checks it against
  the release's `herdr-host-SHA256SUMS`, runs it for its `--version`, and renames it
  to `herdr-host-<version>`. Two apps of different versions on one machine each find
  their own build. `serve` removes all but the three most recently modified
  versions at start (`rust/crates/host/src/install.rs`).
- A machine without the helper (no build for its CPU, offline, download blocked)
  degrades, never silently: herdr requests use one bridge channel each (herdr's own
  `remote-api-bridge`, else `socat`), files are read-only over SFTP, and there are no
  agent sessions, uploads, ports or Made checks. Each shows why.

## The wire

Crate `rust/crates/wire` (Rust) and `app/lib/data/host/wire.dart` (Dart); the golden
vectors in `rust/crates/wire/tests/vectors.json` are decoded by both
(`app/test/host_wire_vectors_test.dart`).

**Start.** `serve` writes the 14 bytes `\xFFHERDR-HOST/1\n` before anything else and
moves its real stdout to a private close-on-exec descriptor, pointing fd 1 at
`/dev/null`, so a stray print cannot corrupt a frame and a keeper it starts cannot
inherit the wire. The client discards what comes before the magic (a login shell's
noise, up to 64 KiB, then fails showing the first 200 bytes).

**Frame.** `len:u32le` (the bytes after it: 1 + 4 + payload) · `kind:u8` ·
`stream:u32le` · payload. The two high bits of `kind` are flags.

| kind | type | direction | payload |
| --- | --- | --- | --- |
| 01 | HELLO | both, stream 0, once, first | JSON |
| 02 | OPEN | client to host | `{"svc","method","args","zctx"}`; stream ids are odd and increase |
| 03 | MSG | both | one JSON value |
| 04 | DATA | both | raw bytes |
| 05 | CREDIT | both | `u32le` bytes of flow-control credit |
| 06 | END | both | `{}`, a result object, or `{"error":{"code","message","retryable"}}`; ends the sender's side |
| 07 | RESET | both | `{"code","message"}`; aborts both directions |

Flag `0x80`: the payload is one complete zlib stream. Flag `0x40`: it is the next
sync-flushed piece of the stream's continuous zlib stream, allowed only on a stream
opened with `zctx` (each direction has its own zlib stream). A sender deflates a
payload of at least 512 bytes when that is smaller; on a `zctx` stream every payload
of at least 64 bytes goes through the continuous stream (a request that repeats the
shape of the last costs about 16 bytes, an event about 30). `zctx` DATA is cut into
16 KiB frames, because compressing incompressible bytes adds a few. Limits: 1 MiB
for any payload but DATA, 32 KiB for DATA, at most 64 open streams.

**Handshake.** The client's HELLO carries `proto` (1), its name and version, and the
herdr session and socket it wants looked for. The host's carries `proto`, the host
(version, OS, CPU, home, hostname, user), the limits, and each service's availability
with the reason when it is not available. An unknown `proto` is answered with an
`END` error `proto_mismatch` on stream 0 and exit 70. A service's availability is
checked again at every OPEN, so a herdr that starts after the connection is used.

**Pipelined start.** The client does not wait for the host's HELLO. `HostLink.start`
(`app/lib/data/host/host_link.dart`) writes its HELLO and then the OPEN of the
stream it needs (the herdr mux, say) and that stream's first request in the same
burst; the host reads frames in order and answers each after its own HELLO. This is
allowed because the host's window is a fixed 1 MiB (`limits.window`), which is also
what a stream is opened with before the HELLO has said otherwise. Why: the HELLO,
the OPEN and the first request used to cost three round trips in a row, and over a
mobile link a round trip is 80 ms or more. Modelled on an 80 ms link the first herdr
request leaves 560 ms to 400 ms sooner (`cold_first_request_ms` in
`app/benchmark/background_bench_test.dart`; desktop, modelled, not measured on a
phone). `HostLink.connect` is `start` plus waiting for the HELLO, for callers that
decide by what the host offers.

**Helper missing, or link lost.** When the `serve` command exits 65 the helper is
not installed. That fails the link, and every stream opened before the HELLO, with
`HostMissing` (code `helper_missing`); the app installs the helper once and starts
again (`host_install.dart`). A connection that drops or a `serve` that exits is
`HostLinkLost` (`link_lost`, retryable) and is never a reason to install. Why two
errors: reinstalling on a flaky radio would download the helper on every drop.

**Streams.** A *call* is OPEN, one MSG, END. A *stream* runs until it ends: a watch,
an attach, a download. The host's END closes a stream at once; a client that is
still sending is ignored. A call that is not answered in time is reset by the client.

**Flow control.** Every stream direction starts with a 1 MiB window of credit,
counted in wire bytes (after compression). A sender never exceeds it; the receiver
grants more as its consumer takes data (half a window at a time). More data than
credit granted resets the stream; a send blocked on credit for 60 s resets it with
`stalled`. The host's writer thread drains an *interactive* queue first and lets one
frame of the *bulk* queue through after every eight interactive ones, so a download
cannot starve a permission answer. A method's class is fixed by the catalog.

**Write batching.** The host's writer thread normally writes each frame as it is
queued. A stream can ask it to batch (`set_batch(BATCH_HOLD)`, 30 ms,
`rust/crates/host/src/session.rs`): `herdr.events`, `keeper.attach` and
`keeper.follow` do. The first frame after a quiet period leaves at once, the frames
that follow inside the window are buffered (a 64 KiB `BufWriter`) and leave in one
`write`, and any frame of an unbatched stream, or the batched stream's own END,
flushes everything first, so a permission answer is never held behind a burst. Why
30 ms: a pane redraws at 60 Hz (one frame per 16 ms), so the delay is under two
frames, and behind SSH one `write` is one packet where one per frame was many. On a
throwaway bench (5 panes at 10 events per second for 5 s, in process, desktop) socket
writes went from 251 to 64 (-75%) and MSG frames from 251 to 106 (with `coalesce_ms`,
below); not measured over a real radio.

**Errors.** A closed set (`rust/crates/wire/src/error.rs`): `bad_request`,
`unknown_service`, `unknown_method`, `unavailable`, `not_found`, `permission`,
`not_a_file`, `not_a_directory`, `exists`, `changed`, `too_large`, `agent_exited`,
`agent_missing`, `failed`, `busy`, `stalled`, `cancelled`, `proto_mismatch`,
`internal`. `retryable` is set by the host. An unknown code reads as `internal`.

## Services

One module per service in `rust/crates/host/src/svc/` and `src/mux.rs`, each a
`Service` (`src/service.rs`): a name, a table of methods with their class and
examples, an availability check, and a handler that runs on the stream's own thread
(2 MiB stack, so zlib's state fits in a debug build).

| service | what it does | trust |
| --- | --- | --- |
| `herdr` | `mux`: herdr's API with pipelining, answers cut to the fields the app reads, and row deltas for repeated screen reads; `events`: the subscription, cut the same way, with optional `coalesce_ms` (below) | the client sends the projections; the host knows no field names |
| `keeper` | `probe`, `list`, `start`, `history`, `kill`, `attach`, `follow`, `blob`: agent sessions and the log reader | every client string is validated (agent is a route id, folder exists, keeper id shape, log path absolute, `.jsonl`, under the home folder) |
| `fs` | `stat`, `list`, `real_path`, `read`, `watch`, `thumb`, `search` | **read-only**; reads what the SSH user can read, as SFTP did; `thumb` decodes a picture and `search` walks folders, both bounded (below) |
| `transfer` | `reserve`, `put`, `sweep` | the **only writes** the helper makes: inside `~/.herdr-mobile/inbox/<12 hex>/`, with names and sizes decided on the host (sanitised name, 0700 folders, 0600 files, 2 GiB cap, sha256 verified, resumable); link rules below |
| `ports` | `list`, `watch`, `probe` | lists TCP listeners (Linux: `/proc/net/tcp*` and the user's own `/proc/<pid>/fd`; macOS: `lsof`); `watch` remembers which process owns each socket, so a tick in which nothing changed reads only `/proc/net/tcp{,6}` and walks no `/proc/<pid>/fd`; `probe` connects to loopback only |
| `made` | `verify`: one batch of path and port checks | metadata and listener state only |

What the helper deliberately does **not** do: proxy TCP. Port forwarding stays SSH
`direct-tcpip`, so a host's `AllowTcpForwarding no` still decides. It runs as the SSH
user, never asks for root, and keeps no state besides the keepers' own files and the
inbox.

**`herdr.events` and `coalesce_ms`.** Open args may carry `coalesce_ms` (an integer,
default 0 = off, capped at 5000; the app sends 250). With it the host drops a
`pane_updated` whose pruned `data.pane` equals the last one it sent for that pane,
sends the first one after a quiet period at once and holds those that follow inside
the window, sending only the latest when the window ends. Every other event is sent
at once, after the held update of the pane it names, and is never dropped. Why: an
agent that streams makes herdr announce the pane many times a second, and the app
only needs its newest state; the rest is radio. The coalescing is on the host so the
bytes never cross the link (`docs/host-api.json` has the exact wording).

**`fs.thumb`.** A bulk stream: `{path, max_px, quality, if_match?}` answers one MSG
`{width,height,size,mtime_ms,format:"jpeg",source_size}`, the JPEG as DATA, then END
`{}`. The longest edge is `max_px` (default 256, clamped to 32..1024), never
enlarged; `quality` defaults to 70 (30..90); the EXIF orientation is applied. JPEG,
PNG, WebP and GIF (first frame) are read; HEIC, SVG, RAW and CMYK JPEG are not, and
end with `failed` and a message that starts `unsupported image`. A source over 64 MiB
or 64 megapixels is `too_large` (the pixel count is read from the header, before any
decoding); an `if_match` that no longer fits the file is `changed`. Nothing is cached
or written on the host. Why it exists: a tile used to be the whole file over the
radio (up to 2 MiB) or, for a bigger photo, a glyph. It is pure Rust
(`jpeg-decoder`, which decodes a JPEG at a fraction of its size by scaling in the
DCT, `png`, `image-webp`, `gif`, `jpeg-encoder`; `rust/crates/host/src/svc/thumb.rs`).

*What a decode may cost.* Pixels alone say little: a 2 KB file can describe a picture
whose decode needs 0.4-0.8 GB (a progressive JPEG keeps every coefficient, 6 bytes a
pixel at 4:4:4; a GIF holds a frame and a canvas, 8 bytes a pixel; a lossless WebP
holds its output and an RGBA buffer, 7). So the header gives a byte estimate per
format (`jpeg_decode_bytes` and its siblings in `thumb.rs`, worst case where the
header says no more: the chroma subsampling of a JPEG is not in it, so 4:2:0 counts
as 4:4:4) and over 256 MiB is `too_large`, the 64 MP and 64 MiB limits staying. At
most two pictures decode at once in the whole `serve` process; a third waits (the
stream stays cancellable, and holds no buffer) and ends with `busy` (retryable) after
10 s, so one host's peak is two estimates, not one per open stream. An interlaced
(Adam7) PNG cannot be fed row by row, because `next_row` yields the narrow rows of one
pass: it is decoded whole into one buffer of at most 4 bytes a pixel (the estimate
counts it) and resized, while other PNGs still stream row by row. A WebP's EXIF, ICC
and XMP chunks are sized by the file itself (a 100-byte file can announce 4 GiB, and
`image-webp` allocates what it is told), so the decoder is given a 1 MiB limit for
them: a block over it is not read and the picture comes out upright.

Measured on a desktop, release
build, warm file cache, not a phone: a 4000x3000 3.3 MB JPEG takes 44.6 ms (median)
and gives 9,401 bytes at 256 px, 66.8 ms and 87,756 bytes at 1024 px; a 12 MP PNG
takes 85.6 ms at 256 px. `serve` stayed at 3.8 MB resident idle, 5.3 MB after a
256 px JPEG and peaked at 24 MB at 1024 px.

**`fs.search`.** An interactive stream: `{root, query?, kind, modified_within_s?,
max_results, max_depth, hidden, ignore}`. It walks breadth first (shallow matches
first), matching `query` as a case-insensitive part of the *name*; an empty query
matches everything, which is what the time filters use. Defaults: 500 results (cap
2000), depth 12 (cap 32, the entries of `root` are depth 1), no hidden names,
`ignore` = `.git node_modules target .cache __pycache__ .venv build` (an ignored
folder is skipped and not reported; `[]` searches everything). A symlink is reported
as kind `link` and never followed. Entries leave in MSGs of at most 100, the first as
soon as there is an entry, then when full or every 150 ms; END is
`{scanned,truncated,elapsed_ms,skipped_dirs}`. `truncated` is true when
`max_results` or a scan cap (200,000 entries, 20 s) stopped the walk, so the app can
say the search was cut instead of implying there is nothing more. Cancelling resets
the stream and the walk stops within 256 entries
(`rust/crates/host/src/svc/search.rs`). A desktop measurement, not a phone: 51,000
entries scanned in 10-13 ms on the host. Without the helper (or when it answers
`unknown_method`) the app walks over SFTP instead, capped at 3,000 entries and 4 s,
and says when that cut it short (`app/lib/data/services/file_walk_search.dart`).

**`transfer`: links and names.** `~/.herdr-mobile` and `inbox` may be symlinks, and
are followed: people keep their dotfiles with stow or chezmoi or on a data disk, and
when the helper refused the link they could never upload and the inbox never
shrank (`sweep` returned 0). Both are resolved once per call and every operation
works under the real path, so a `put` takes the path `reserve` gave (under the home)
or the real path of the same inbox, and nothing else: exactly
`<inbox>/<12 hex>/<stamp>-<name>`, no `..`. Below the inbox nothing is followed: the
session folder is made by `reserve`, so a link there was planted and is `bad_request`,
and so is a link as the file's own name; `sweep` skips a linked session folder and
never removes or follows a linked file. A link to a file, or to nothing, where a
folder belongs is `not_a_directory` / `not_found`. `put` keeps leaves ending in
`.part` and `.meta` for its own companion files, so `reserve` puts a `_` after a name
that ends that way (`weights.ckpt.meta` becomes `...-weights.ckpt.meta_`): it used to
hand the name out and then refuse the upload of it. Names carry the UTC time, not the
phone's.

## Backends: adding another multiplexer

herdr is a backend, not a special case. `Backend` (`rust/crates/host/src/backend/mod.rs`)
carries a backend's own JSON vocabulary: its service name, discovery (is it here, and
where), `call` (one native request, one native response) and `subscribe` (an ack and
an event source). `MuxService<B: Backend>` (`src/mux.rs`) serves `mux` and `events`
for any `B`: pipelining, projection pruning, the delta cache and compression are
generic. Adding rex means one module implementing `Backend` (its socket, its
control-plane client), one line in `registry()` (`rust/crates/host/src/lib.rs`), and a
Dart adapter that maps the app's neutral board model onto it
(`docs/research/rex/rex-protocol.md` sketches that model); nothing in `serve`, the
wire, or the other services changes.

## Changing the protocol

1. A new method or service: add its `MethodSpec` (a real example for args and result;
   a test parses the example into the typed args), regenerate the catalog
   (`cd rust && cargo run -q -p host -- api > ../docs/host-api.json`; a test fails
   until you do), add the Dart client, and a test that drives the real binary
   (`app/test/host_serve_herdr_test.dart` is the pattern, `ProcessHostProcess`).
2. A change to frames or flags: edit `rust/crates/wire`, regenerate the vectors
   (`cargo test -p wire --test vectors -- --ignored regenerate`), update
   `wire.dart`; its test fails until it agrees. Bump `proto` only for an
   incompatible change; the app pins the helper to its own version, so the two sides
   of one release always match.
3. Tests that need a herdr, an agent or an ACP peer use Rust fakes
   (`rust/crates/testkit`), never the owner's machine.

## Footprint (measured on a desktop Linux machine, release build)

The binary is 1.87 MB stripped (1,872,648 bytes; 1,434,016 before the picture
decoders and encoder, +423 KiB). After the handshake `serve` holds 3.8 MB resident
when idle (`VmRSS`). Each open stream adds a thread, which costs address space for
its 2 MiB stack and only the pages it touches in memory; a 1024 px thumbnail is the
largest single cost seen (24 MB peak). All of this was measured on a desktop Linux
machine, release build. Not measured on a phone: the helper runs on the host, but
its cost to the radio (frames per request, bytes per event) is modelled in
`app/benchmark/background_bench_test.dart`, not measured.
