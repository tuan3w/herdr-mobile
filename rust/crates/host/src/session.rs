//! The `serve` session: one reader (this thread) that routes frames to
//! streams, one writer thread that owns the output, and one thread per open
//! stream running its service's handler.
//!
//! Flow control is credit based per stream and direction (`wire::Limits::window`
//! to start): a sender never exceeds its credit, the receiver grants more as the
//! handler consumes. The writer drains an interactive queue first and a bulk
//! queue after every eighth interactive frame. No async runtime, no shared
//! state beyond the maps and queues below.

use crate::service::{Class, MethodKind, MethodSpec, Registry};
use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use std::io::{BufWriter, Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};
use wire::{
    deflate_if_smaller, read_frame, write_frame, ClientHello, ContinuousDeflater, ErrorCode, Flags,
    Frame, HostHello, HostInfo, Inflater, Kind, Limits, Open, WireError, MAX_DATA, MAX_PAYLOAD,
    PROTO,
};

/// How long a send may wait for credit before the stream is aborted.
pub const STALL: Duration = Duration::from_secs(60);

/// A stream thread's stack. Handlers are small, but zlib's compressor state
/// (`flate2::Compress`, miniz) is ~300 KB and in a debug build is built on the
/// stack: 256 KiB overflowed. Only the pages a thread touches are resident, so
/// 2 MiB for each of up to 64 streams costs address space, not memory.
const STACK: usize = 2 * 1024 * 1024;

/// Interactive frames sent before one bulk frame is let through.
const BULK_EVERY: u32 = 8;

/// Compression thresholds (wire payload bytes).
const DEFLATE_MIN: usize = 512;
const CTX_MIN: usize = 64;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// What the session needs to know that is not in the registry.
pub struct SessionOptions {
    pub host: HostInfo,
    pub home: PathBuf,
    pub limits: Limits,
    /// How long a send waits for credit before `stalled`.
    pub stall: Duration,
    /// Leave the process when the output cannot be written (the real `serve`
    /// does; tests do not).
    pub exit_on_write_error: bool,
}

/// What a handler receives from the client.
#[derive(Debug, PartialEq)]
pub enum Incoming {
    Msg(Value),
    Data(Vec<u8>),
}

/// Why a send did not go out.
#[derive(Debug, PartialEq, Eq)]
pub enum SendError {
    /// The stream was reset or the session is ending.
    Closed,
    /// A `MSG` over 1 MiB on the wire.
    TooLarge,
    /// No credit for [`STALL`]: the stream has been reset.
    Stalled,
}

impl From<SendError> for WireError {
    fn from(e: SendError) -> Self {
        match e {
            SendError::Closed => WireError::new(ErrorCode::Cancelled, "the stream was closed"),
            SendError::TooLarge => {
                WireError::new(ErrorCode::TooLarge, "a message is over 1 MiB on the wire")
            }
            SendError::Stalled => {
                WireError::new(ErrorCode::Stalled, "the client stopped reading this stream")
            }
        }
    }
}

/// Whether sends may be compressed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Compress {
    /// Deflate frames of 512 B or more when that is smaller (or continuous
    /// compression on a `zctx` stream).
    Auto,
    Never,
}

// ---- the writer ----

/// How long a batched stream's frames may wait for company before they are
/// flushed (see [`StreamCtx::set_batch`]). A pane redraws at 60 Hz, one frame
/// per 16 ms, so 30 ms is under two frames: a person cannot tell, while a burst
/// of events or agent chunks becomes one `write` and, behind SSH, one packet
/// instead of one per frame. Used by the churn-carrying streams: `herdr.events`
/// and the keeper's `attach` and `follow`.
pub const BATCH_HOLD: Duration = Duration::from_millis(30);

/// The writer's buffer: a whole batch leaves in one `write`.
const WRITE_BUFFER: usize = 64 * 1024;

/// A frame in a queue, with the batching its stream asked for.
struct Queued {
    frame: Frame,
    /// `Some` for a `MSG`/`DATA` of a batched stream.
    hold: Option<Duration>,
}

#[derive(Default)]
struct Queues {
    interactive: VecDeque<Queued>,
    bulk: VecDeque<Queued>,
    since_bulk: u32,
    closed: bool,
    /// Set by a client `RESET`: whatever is held goes out now.
    flush_requested: bool,
}

impl Queues {
    fn take(&mut self) -> Option<Queued> {
        let take_bulk = self.interactive.is_empty() || self.since_bulk >= BULK_EVERY;
        if take_bulk {
            if let Some(f) = self.bulk.pop_front() {
                self.since_bulk = 0;
                return Some(f);
            }
        }
        let f = self.interactive.pop_front()?;
        self.since_bulk = self.since_bulk.saturating_add(1);
        Some(f)
    }

    fn idle(&self) -> bool {
        self.interactive.is_empty() && self.bulk.is_empty()
    }
}

/// What the writer does next.
enum Next {
    /// A frame, and whether the queues are empty after taking it.
    Frame(Queued, bool),
    /// Flush the output: a hold ran out or a flush was requested.
    Flush,
    Closed,
}

struct Writer {
    q: Mutex<Queues>,
    cv: Condvar,
}

impl Writer {
    fn new() -> Self {
        Self {
            q: Mutex::new(Queues::default()),
            cv: Condvar::new(),
        }
    }

    fn push(&self, class: Class, frame: Frame) {
        self.push_held(class, frame, None);
    }

    fn push_held(&self, class: Class, frame: Frame, hold: Option<Duration>) {
        let mut q = lock(&self.q);
        if q.closed {
            return;
        }
        let queued = Queued { frame, hold };
        match class {
            Class::Interactive => q.interactive.push_back(queued),
            Class::Bulk => q.bulk.push_back(queued),
        }
        self.cv.notify_one();
    }

    /// The next thing to do. Frames first; with nothing queued, waits for one
    /// until `deadline` (a held batch's flush time), without polling.
    fn next(&self, deadline: Option<Instant>) -> Next {
        let mut q = lock(&self.q);
        loop {
            if let Some(f) = q.take() {
                let idle = q.idle();
                return Next::Frame(f, idle);
            }
            if q.flush_requested {
                q.flush_requested = false;
                return Next::Flush;
            }
            if q.closed {
                return Next::Closed;
            }
            q = match deadline {
                None => self.cv.wait(q).unwrap_or_else(PoisonError::into_inner),
                Some(d) => {
                    let left = d.saturating_duration_since(Instant::now());
                    if left.is_zero() {
                        return Next::Flush;
                    }
                    self.cv
                        .wait_timeout(q, left)
                        .unwrap_or_else(PoisonError::into_inner)
                        .0
                }
            };
        }
    }

    fn request_flush(&self) {
        lock(&self.q).flush_requested = true;
        self.cv.notify_one();
    }

    fn close(&self) {
        lock(&self.q).closed = true;
        self.cv.notify_all();
    }
}

/// The output with batching: frames of a batched stream are written into the
/// buffer and flushed together.
///
/// Rule: a batched frame is flushed at once (leading edge) when its stream has
/// not been flushed within its `hold`; a later one inside that window waits,
/// and everything pending is flushed when `hold` has passed since the first
/// held frame. Any frame without a hold (interactive traffic, `CREDIT`, `END`,
/// `RESET`) makes the output due and flushes the whole buffer, held frames
/// included, so nothing waits behind a batch. Frames are written in queue
/// order throughout, so batching never reorders.
struct Batcher<W: Write> {
    out: BufWriter<W>,
    /// When each batched stream was last flushed.
    last_flush: HashMap<u32, Instant>,
    /// Batched streams with frames in the buffer.
    pending: Vec<u32>,
    /// When the first held frame must be flushed at the latest.
    deadline: Option<Instant>,
    /// Something in the buffer must not wait for a hold.
    urgent: bool,
}

impl<W: Write> Batcher<W> {
    fn new(out: W) -> Self {
        Self {
            out: BufWriter::with_capacity(WRITE_BUFFER, out),
            last_flush: HashMap::new(),
            pending: Vec::new(),
            deadline: None,
            urgent: false,
        }
    }

    fn write(&mut self, queued: &Queued, now: Instant) -> std::io::Result<()> {
        let frame = &queued.frame;
        write_frame(&mut self.out, frame)?;
        let id = frame.stream;
        match queued.hold {
            None => self.urgent = true,
            Some(hold) => {
                // Leading edge: nothing of this stream is waiting in the
                // buffer and its last flush is older than `hold`.
                let waiting = self.pending.contains(&id);
                if !waiting {
                    self.pending.push(id);
                }
                let recent = self
                    .last_flush
                    .get(&id)
                    .is_some_and(|t| now.saturating_duration_since(*t) < hold);
                if waiting || recent {
                    let due = now + hold;
                    self.deadline = Some(self.deadline.map_or(due, |d| d.min(due)));
                } else {
                    self.urgent = true;
                }
            }
        }
        if matches!(frame.kind, Kind::End | Kind::Reset) {
            self.last_flush.remove(&id);
            self.pending.retain(|p| *p != id);
        }
        Ok(())
    }

    /// Whether to flush now: `idle` is whether the queues are empty.
    fn due(&self, idle: bool, now: Instant) -> bool {
        (idle && self.urgent) || self.deadline.is_some_and(|d| now >= d)
    }

    fn flush(&mut self, now: Instant) -> std::io::Result<()> {
        self.out.flush()?;
        for id in self.pending.drain(..) {
            self.last_flush.insert(id, now);
        }
        // A stream that ended without a frame of ours (client reset) leaves an
        // entry: drop the stale ones.
        if self.last_flush.len() > 128 {
            self.last_flush
                .retain(|_, t| now.saturating_duration_since(*t) < STALL);
        }
        self.deadline = None;
        self.urgent = false;
        Ok(())
    }
}

// ---- streams ----

#[derive(Default)]
struct Inbox {
    q: VecDeque<(Kind, Vec<u8>, usize)>,
    /// Bytes received and not yet credited back.
    inflight: usize,
    /// Bytes consumed since the last credit frame.
    consumed: usize,
    ended: bool,
}

struct Stream {
    id: u32,
    class: Class,
    inbox: Mutex<Inbox>,
    inbox_cv: Condvar,
    credit: Mutex<i64>,
    credit_cv: Condvar,
    cancelled: AtomicBool,
    compress: AtomicU8,
    /// Nanoseconds of batching hold; 0 = none.
    batch: AtomicU64,
    /// Held across compress, credit wait and enqueue so a continuous stream's
    /// pieces are queued in the order they were compressed.
    sender: Mutex<Option<ContinuousDeflater>>,
    /// The client's continuous zlib stream, on a `zctx` stream: its frames
    /// flagged `deflate_ctx` are pieces of it, inflated in arrival order (only
    /// the reader thread touches it).
    receiver: Mutex<Option<Inflater>>,
}

impl Stream {
    fn new(id: u32, class: Class, zctx: bool, window: usize) -> Self {
        Self {
            id,
            class,
            inbox: Mutex::new(Inbox::default()),
            inbox_cv: Condvar::new(),
            credit: Mutex::new(i64::try_from(window).unwrap_or(i64::MAX)),
            credit_cv: Condvar::new(),
            cancelled: AtomicBool::new(false),
            compress: AtomicU8::new(0),
            batch: AtomicU64::new(0),
            sender: Mutex::new(zctx.then(ContinuousDeflater::new)),
            receiver: Mutex::new(zctx.then(Inflater::new)),
        }
    }

    fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        // Take each lock once so a waiter between its check and its wait wakes.
        drop(lock(&self.inbox));
        self.inbox_cv.notify_all();
        drop(lock(&self.credit));
        self.credit_cv.notify_all();
    }

    fn cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }
}

struct Shared {
    writer: Writer,
    streams: Mutex<Streams>,
    limits: Limits,
    stall: Duration,
    hello: ClientHello,
    home: PathBuf,
    registry: Arc<Registry>,
}

#[derive(Default)]
struct Streams {
    map: HashMap<u32, Arc<Stream>>,
    last_id: u32,
}

impl Shared {
    fn window(&self) -> usize {
        self.limits.window as usize
    }

    fn get(&self, id: u32) -> Option<Arc<Stream>> {
        lock(&self.streams).map.get(&id).cloned()
    }

    fn remove(&self, id: u32) {
        lock(&self.streams).map.remove(&id);
    }

    fn refuse(&self, id: u32, e: &WireError) {
        self.writer
            .push(Class::Interactive, Frame::json(Kind::End, id, &e.to_end()));
    }

    fn reset(&self, stream: &Stream, e: &WireError) {
        stream.cancel();
        self.remove(stream.id);
        self.writer.push(
            stream.class,
            Frame::json(Kind::Reset, stream.id, &e.to_body()),
        );
    }

    fn shutdown(&self) {
        let all: Vec<Arc<Stream>> = lock(&self.streams).map.values().cloned().collect();
        for s in all {
            s.cancel();
        }
        self.writer.close();
    }

    fn on_open(self: &Arc<Self>, frame: &Frame) {
        let id = frame.stream;
        let mut streams = lock(&self.streams);
        if id == 0 || id.is_multiple_of(2) || id <= streams.last_id {
            drop(streams);
            self.refuse(
                id,
                &WireError::new(
                    ErrorCode::BadRequest,
                    "stream ids are odd and increase with every OPEN",
                ),
            );
            return;
        }
        streams.last_id = id;
        let open: Open = match serde_json::from_slice(&frame.payload) {
            Ok(o) => o,
            Err(e) => {
                drop(streams);
                self.refuse(
                    id,
                    &WireError::new(ErrorCode::BadRequest, format!("OPEN is not valid: {e}")),
                );
                return;
            }
        };
        let (service, spec) = match self.registry.find(&open.svc, &open.method) {
            Ok(found) => found,
            Err(e) => {
                drop(streams);
                self.refuse(id, &e);
                return;
            }
        };
        // Live, not the HELLO's snapshot: herdr may start after the connection.
        let status = service.availability(&self.hello);
        if !status.available {
            let reason = status
                .reason
                .unwrap_or_else(|| format!("{} is not available on this machine", open.svc));
            drop(streams);
            self.refuse(
                id,
                &WireError::new(ErrorCode::Unavailable, reason).retryable(),
            );
            return;
        }
        if streams.map.len() >= self.limits.max_streams as usize {
            drop(streams);
            self.refuse(
                id,
                &WireError::new(ErrorCode::Busy, "too many open streams").retryable(),
            );
            return;
        }
        let stream = Arc::new(Stream::new(id, spec.class, open.zctx, self.window()));
        streams.map.insert(id, Arc::clone(&stream));
        drop(streams);
        let ctx = StreamCtx {
            shared: Arc::clone(self),
            stream: Arc::clone(&stream),
            args: Arc::new(open.args),
            service: open.svc,
        };
        let spawned = std::thread::Builder::new()
            .name(format!("stream-{id}"))
            .stack_size(STACK)
            .spawn(move || run_stream(&ctx, &*service, spec));
        if spawned.is_err() {
            self.remove(id);
            self.refuse(
                id,
                &WireError::new(ErrorCode::Busy, "no thread for the stream").retryable(),
            );
        }
    }

    fn on_payload(&self, frame: Frame) {
        let Some(stream) = self.get(frame.stream) else {
            return; // a late frame for a stream that has ended: ignored
        };
        let wire_len = frame.payload.len();
        let bytes = match frame.flags {
            Flags::None => frame.payload,
            Flags::Deflate => match Inflater::once(&frame.payload) {
                Ok(b) => b,
                Err(e) => {
                    self.reset(
                        &stream,
                        &WireError::new(ErrorCode::BadRequest, e.to_string()),
                    );
                    return;
                }
            },
            Flags::DeflateCtx => {
                let inflated = match lock(&stream.receiver).as_mut() {
                    Some(z) => z.piece(&frame.payload).map_err(|e| e.to_string()),
                    None => {
                        Err("continuous compression needs a stream opened with zctx".to_string())
                    }
                };
                match inflated {
                    Ok(b) => b,
                    Err(why) => {
                        self.reset(&stream, &WireError::new(ErrorCode::BadRequest, why));
                        return;
                    }
                }
            }
        };
        let mut inbox = lock(&stream.inbox);
        inbox.inflight += wire_len;
        if inbox.inflight > self.window() {
            drop(inbox);
            self.reset(
                &stream,
                &WireError::new(ErrorCode::BadRequest, "more data sent than credit granted"),
            );
            return;
        }
        inbox.q.push_back((frame.kind, bytes, wire_len));
        drop(inbox);
        stream.inbox_cv.notify_all();
    }

    fn on_credit(&self, frame: &Frame) {
        let (Some(stream), Some(n)) = (self.get(frame.stream), frame.credit_bytes()) else {
            return;
        };
        *lock(&stream.credit) += i64::from(n);
        stream.credit_cv.notify_all();
    }

    fn on_end(&self, frame: &Frame) {
        if let Some(stream) = self.get(frame.stream) {
            lock(&stream.inbox).ended = true;
            stream.inbox_cv.notify_all();
        }
    }

    fn on_reset(&self, frame: &Frame) {
        if let Some(stream) = self.get(frame.stream) {
            stream.cancel();
            self.remove(stream.id);
            // Whatever is held for a batched stream goes out now.
            self.writer.request_flush();
        }
    }
}

/// The handle a handler uses to talk to its stream. Cheap to clone: helper
/// threads of one handler share it.
#[derive(Clone)]
pub struct StreamCtx {
    shared: Arc<Shared>,
    stream: Arc<Stream>,
    args: Arc<Value>,
    service: String,
}

impl StreamCtx {
    /// The `args` of the `OPEN`.
    #[must_use]
    pub fn args(&self) -> &Value {
        &self.args
    }

    /// The client's HELLO.
    #[must_use]
    pub fn hello(&self) -> &ClientHello {
        &self.shared.hello
    }

    /// The home folder of the user `serve` runs as.
    #[must_use]
    pub fn home(&self) -> &std::path::Path {
        &self.shared.home
    }

    /// The service this stream was opened on.
    #[must_use]
    pub fn service(&self) -> &str {
        &self.service
    }

    /// Whether the stream was reset or the session is ending.
    #[must_use]
    pub fn cancelled(&self) -> bool {
        self.stream.cancelled()
    }

    /// Whether the client ended its side or the stream was cancelled: a watcher
    /// stops when this is true.
    #[must_use]
    pub fn done(&self) -> bool {
        self.cancelled() || lock(&self.stream.inbox).ended
    }

    /// Sleeps up to `d`; returns early with `false` when the stream is done.
    pub fn sleep(&self, d: Duration) -> bool {
        let deadline = Instant::now() + d;
        let mut inbox = lock(&self.stream.inbox);
        loop {
            if self.cancelled() || inbox.ended {
                return false;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return true;
            }
            inbox = self
                .stream
                .inbox_cv
                .wait_timeout(inbox, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }

    /// Asks the writer to batch this stream's `MSG`/`DATA` frames (default: no
    /// batching). The first frame after `hold` of quiet goes out at once; those
    /// that follow inside `hold` are buffered and leave together when `hold`
    /// has passed since the first of them, or sooner if any other frame (other
    /// streams' interactive traffic, this stream's `END`) is written. Use it
    /// for streams that carry churn, with [`BATCH_HOLD`].
    pub fn set_batch(&self, hold: Duration) {
        let nanos = u64::try_from(hold.as_nanos()).unwrap_or(u64::MAX);
        self.stream.batch.store(nanos, Ordering::SeqCst);
    }

    /// Chooses whether this stream's sends may be compressed.
    pub fn set_compress(&self, c: Compress) {
        self.stream.compress.store(
            match c {
                Compress::Auto => 0,
                Compress::Never => 1,
            },
            Ordering::SeqCst,
        );
    }

    /// The next message or chunk from the client; `None` when the client ended
    /// its side or the stream was cancelled. A `MSG` that is not JSON resets
    /// the stream.
    #[must_use]
    pub fn recv(&self) -> Option<Incoming> {
        let mut inbox = lock(&self.stream.inbox);
        loop {
            if self.cancelled() {
                return None;
            }
            if let Some((kind, bytes, wire_len)) = inbox.q.pop_front() {
                inbox.inflight = inbox.inflight.saturating_sub(wire_len);
                inbox.consumed += wire_len;
                if inbox.consumed >= self.shared.window() / 2 {
                    let grant = u32::try_from(inbox.consumed).unwrap_or(u32::MAX);
                    inbox.consumed = 0;
                    self.shared
                        .writer
                        .push(Class::Interactive, Frame::credit(self.stream.id, grant));
                }
                drop(inbox);
                if kind == Kind::Data {
                    return Some(Incoming::Data(bytes));
                }
                return match serde_json::from_slice(&bytes) {
                    Ok(v) => Some(Incoming::Msg(v)),
                    Err(e) => {
                        self.shared.reset(
                            &self.stream,
                            &WireError::new(ErrorCode::BadRequest, format!("MSG is not JSON: {e}")),
                        );
                        None
                    }
                };
            }
            if inbox.ended {
                return None;
            }
            inbox = self
                .stream
                .inbox_cv
                .wait(inbox)
                .unwrap_or_else(PoisonError::into_inner);
        }
    }

    /// Sends one JSON message.
    ///
    /// # Errors
    /// [`SendError`].
    pub fn send_msg(&self, value: &Value) -> Result<(), SendError> {
        let bytes = serde_json::to_vec(value).map_err(|_| SendError::Closed)?;
        self.send(Kind::Msg, bytes)
    }

    /// Sends bytes, split into frames of at most 32 KiB (16 KiB on a `zctx`
    /// stream: compressing incompressible data adds a few bytes, and a frame
    /// over the limit cannot be taken back once the stream's zlib state has
    /// advanced).
    ///
    /// # Errors
    /// [`SendError`].
    pub fn send_data(&self, bytes: &[u8]) -> Result<(), SendError> {
        let step = if lock(&self.stream.sender).is_some() {
            MAX_DATA / 2
        } else {
            MAX_DATA
        };
        for chunk in bytes.chunks(step) {
            self.send(Kind::Data, chunk.to_vec())?;
        }
        Ok(())
    }

    fn send(&self, kind: Kind, bytes: Vec<u8>) -> Result<(), SendError> {
        let mut deflater = lock(&self.stream.sender);
        if self.cancelled() {
            return Err(SendError::Closed);
        }
        let auto = self.stream.compress.load(Ordering::SeqCst) == 0;
        let (flags, payload) = match deflater.as_mut() {
            Some(z) if auto && bytes.len() >= CTX_MIN => (Flags::DeflateCtx, z.piece(&bytes)),
            Some(_) | None => match auto
                .then(|| deflate_if_smaller(&bytes, DEFLATE_MIN))
                .flatten()
            {
                Some(packed) => (Flags::Deflate, packed),
                None => (Flags::None, bytes),
            },
        };
        let limit = if kind == Kind::Data {
            MAX_DATA
        } else {
            MAX_PAYLOAD
        };
        if payload.len() > limit {
            // The continuous stream already took this piece in; the stream
            // cannot go on, and the handler is about to end it.
            return Err(SendError::TooLarge);
        }
        self.wait_credit(payload.len())?;
        let hold = match self.stream.batch.load(Ordering::SeqCst) {
            0 => None,
            nanos if matches!(kind, Kind::Msg | Kind::Data) => Some(Duration::from_nanos(nanos)),
            _ => None,
        };
        self.shared.writer.push_held(
            self.stream.class,
            Frame::compressed(kind, flags, self.stream.id, payload),
            hold,
        );
        Ok(())
    }

    fn wait_credit(&self, n: usize) -> Result<(), SendError> {
        let need = i64::try_from(n).unwrap_or(i64::MAX);
        let deadline = Instant::now() + self.shared.stall;
        let mut avail = lock(&self.stream.credit);
        loop {
            if self.cancelled() {
                return Err(SendError::Closed);
            }
            if *avail >= need {
                *avail -= need;
                return Ok(());
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                drop(avail);
                self.shared.reset(
                    &self.stream,
                    &WireError::new(ErrorCode::Stalled, "the client stopped reading this stream"),
                );
                return Err(SendError::Stalled);
            }
            avail = self
                .stream
                .credit_cv
                .wait_timeout(avail, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }

    fn finish(&self, end: &Value) {
        if self.cancelled() {
            return;
        }
        self.shared.writer.push(
            self.stream.class,
            Frame::json(Kind::End, self.stream.id, end),
        );
        self.shared.remove(self.stream.id);
        // A helper thread of this handler may be blocked in `recv`: the stream is
        // over, so it gets `None` instead of waiting for a client that will not
        // be heard again.
        lock(&self.stream.inbox).ended = true;
        self.stream.inbox_cv.notify_all();
    }
}

fn run_stream(ctx: &StreamCtx, service: &dyn crate::service::Service, spec: &'static MethodSpec) {
    let result = service.open(spec.name, ctx);
    match result {
        Ok(value) => match spec.kind {
            MethodKind::Call => match ctx.send_msg(&value) {
                Ok(()) => ctx.finish(&Value::Object(serde_json::Map::new())),
                Err(e) => ctx.finish(&WireError::from(e).to_end()),
            },
            MethodKind::Stream => ctx.finish(&value),
        },
        Err(e) => ctx.finish(&e.to_end()),
    }
}

/// Answers a HELLO the host cannot accept and returns the exit code.
fn refuse<W: Write>(out: &mut W, code: ErrorCode, why: &str) -> i32 {
    eprintln!("herdr-host: {why}");
    let _ = write_frame(
        out,
        &Frame::json(Kind::End, 0, &WireError::new(code, why).to_end()),
    );
    let _ = out.flush();
    keeper::exit::FAILED
}

/// Runs one session to its end: the exit code of `serve`.
pub fn run<R: Read, W: Write + Send + 'static>(
    mut input: R,
    mut output: W,
    registry: Arc<Registry>,
    options: SessionOptions,
) -> i32 {
    if output
        .write_all(wire::MAGIC)
        .and_then(|()| output.flush())
        .is_err()
    {
        return keeper::exit::FAILED;
    }
    let first = match read_frame(&mut input) {
        Ok(Some(f)) if f.kind == Kind::Hello && f.stream == 0 => f,
        Ok(Some(_)) => {
            return refuse(
                &mut output,
                ErrorCode::BadRequest,
                "the first frame must be HELLO",
            );
        }
        Ok(None) => return 0,
        Err(e) => {
            eprintln!("herdr-host: {e}");
            return keeper::exit::FAILED;
        }
    };
    let hello: ClientHello = match serde_json::from_slice(&first.payload) {
        Ok(h) => h,
        Err(e) => {
            return refuse(
                &mut output,
                ErrorCode::BadRequest,
                &format!("HELLO is not valid: {e}"),
            );
        }
    };
    if hello.proto != PROTO {
        return refuse(
            &mut output,
            ErrorCode::ProtoMismatch,
            &format!(
                "this host speaks hostwire/{PROTO}, the client {}",
                hello.proto
            ),
        );
    }
    let host_hello = HostHello {
        proto: PROTO,
        host: options.host,
        limits: options.limits,
        services: registry.status(&hello),
    };
    let shared = Arc::new(Shared {
        writer: Writer::new(),
        streams: Mutex::new(Streams::default()),
        limits: options.limits,
        stall: options.stall,
        hello,
        home: options.home,
        registry,
    });
    shared.writer.push(
        Class::Interactive,
        Frame::json(
            Kind::Hello,
            0,
            &serde_json::to_value(&host_hello).unwrap_or(Value::Null),
        ),
    );
    let writer_shared = Arc::clone(&shared);
    let exit_on_write_error = options.exit_on_write_error;
    let writer = std::thread::Builder::new()
        .name("writer".to_string())
        .spawn(move || {
            let mut batcher = Batcher::new(output);
            let failed = |writer_shared: &Shared| {
                writer_shared.shutdown();
                if exit_on_write_error {
                    std::process::exit(0);
                }
            };
            loop {
                match writer_shared.writer.next(batcher.deadline) {
                    Next::Frame(queued, idle) => {
                        let now = Instant::now();
                        if batcher.write(&queued, now).is_err() {
                            failed(&writer_shared);
                            return;
                        }
                        if batcher.due(idle, now) && batcher.flush(now).is_err() {
                            failed(&writer_shared);
                            return;
                        }
                    }
                    Next::Flush => {
                        if batcher.flush(Instant::now()).is_err() {
                            failed(&writer_shared);
                            return;
                        }
                    }
                    Next::Closed => break,
                }
            }
            let _ = batcher.flush(Instant::now());
        });
    let Ok(writer) = writer else {
        return keeper::exit::FAILED;
    };

    let mut code = 0;
    loop {
        match read_frame(&mut input) {
            Ok(Some(frame)) => match frame.kind {
                Kind::Hello => {
                    eprintln!("herdr-host: a second HELLO");
                    code = keeper::exit::FAILED;
                    break;
                }
                Kind::Open => shared.on_open(&frame),
                Kind::Msg | Kind::Data => shared.on_payload(frame),
                Kind::Credit => shared.on_credit(&frame),
                Kind::End => shared.on_end(&frame),
                Kind::Reset => shared.on_reset(&frame),
            },
            Ok(None) => break,
            Err(e) => {
                eprintln!("herdr-host: {e}");
                code = keeper::exit::FAILED;
                break;
            }
        }
    }
    shared.shutdown();
    let _ = writer.join();
    code
}
