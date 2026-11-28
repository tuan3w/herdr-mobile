//! The writer's batching (`StreamCtx::set_batch`) over an in-memory socket
//! pair whose server end counts `write` and `flush` calls. The hold in these
//! tests is a minute, so a frame that is not flushed by the leading edge or by
//! another frame is not flushed at all: the tests prove the rule without
//! sleeping for the hold.

use host::{Class, Incoming, MethodKind, MethodSpec, Registry, Service, SessionOptions, StreamCtx};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{channel, Receiver};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use wire::{
    read_frame, write_frame, ClientHello, ClientInfo, Frame, HerdrHello, Kind, Limits,
    ServiceStatus, WireError, MAGIC,
};

const WAIT: Duration = Duration::from_secs(10);
/// Long enough to notice a frame that should have been held, short enough for
/// a test; absence is only ever asserted for frames the host was told to hold
/// for a minute, so a slow machine cannot make it fail.
const QUIET: Duration = Duration::from_millis(300);

/// The server's output: counts the calls that reach the socket.
struct Counting {
    inner: UnixStream,
    writes: Arc<AtomicUsize>,
    flushes: Arc<AtomicUsize>,
}

impl Write for Counting {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.writes.fetch_add(1, Ordering::SeqCst);
        self.inner.write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.flushes.fetch_add(1, Ordering::SeqCst);
        self.inner.flush()
    }
}

#[derive(Default)]
struct Probe {
    /// DATA frames the `batched` handler has handed to the session.
    sent: AtomicUsize,
}

struct BatchService(Arc<Probe>);

static METHODS: &[MethodSpec] = &[
    MethodSpec {
        name: "echo",
        kind: MethodKind::Call,
        class: Class::Interactive,
        summary: "returns its args",
        args_example: "{}",
        result_example: "{}",
    },
    MethodSpec {
        name: "batched",
        kind: MethodKind::Stream,
        class: Class::Interactive,
        summary: "batches; sends what the client's MSGs say: {data}, {burst}, {end}",
        args_example: "{}",
        result_example: "{}",
    },
    MethodSpec {
        name: "unbatched",
        kind: MethodKind::Stream,
        class: Class::Interactive,
        summary: "like batched, without batching",
        args_example: "{}",
        result_example: "{}",
    },
];

impl Service for BatchService {
    fn name(&self) -> &'static str {
        "test"
    }

    fn methods(&self) -> &'static [MethodSpec] {
        METHODS
    }

    fn availability(&self, _: &ClientHello) -> ServiceStatus {
        ServiceStatus::available()
    }

    fn open(&self, method: &str, ctx: &StreamCtx) -> Result<Value, WireError> {
        match method {
            "echo" => Ok(ctx.args().clone()),
            "batched" | "unbatched" => {
                if method == "batched" {
                    ctx.set_batch(Duration::from_secs(60));
                }
                while let Some(item) = ctx.recv() {
                    let Incoming::Msg(m) = item else { continue };
                    if let Some(text) = m["data"].as_str() {
                        ctx.send_data(text.as_bytes())?;
                        self.0.sent.fetch_add(1, Ordering::SeqCst);
                    } else if let Some(n) = m["burst"].as_u64() {
                        for i in 0..n {
                            ctx.send_data(format!("{i:05}|{}", "x".repeat(90)).as_bytes())?;
                            self.0.sent.fetch_add(1, Ordering::SeqCst);
                        }
                    } else if m["end"].as_bool() == Some(true) {
                        break;
                    }
                }
                Ok(json!({}))
            }
            other => Err(WireError::new(wire::ErrorCode::UnknownMethod, other)),
        }
    }
}

struct Client {
    out: UnixStream,
    frames: Receiver<Option<Frame>>,
    server: Option<JoinHandle<i32>>,
    next_stream: u32,
    probe: Arc<Probe>,
    writes: Arc<AtomicUsize>,
    flushes: Arc<AtomicUsize>,
}

fn start() -> Client {
    let probe = Arc::new(Probe::default());
    let (client_end, server_end) = UnixStream::pair().expect("pair");
    let server_in = server_end.try_clone().expect("clone");
    let writes = Arc::new(AtomicUsize::new(0));
    let flushes = Arc::new(AtomicUsize::new(0));
    let output = Counting {
        inner: server_end,
        writes: Arc::clone(&writes),
        flushes: Arc::clone(&flushes),
    };
    let registry = Arc::new(Registry::new(vec![Arc::new(BatchService(Arc::clone(
        &probe,
    )))]));
    let options = SessionOptions {
        host: wire::HostInfo {
            version: "9.9.9".into(),
            os: "linux".into(),
            arch: "x86_64".into(),
            home: "/home/test".into(),
            hostname: "box".into(),
            user: "tester".into(),
        },
        home: "/home/test".into(),
        limits: Limits::default(),
        stall: Duration::from_secs(60),
        exit_on_write_error: false,
    };
    let server =
        std::thread::spawn(move || host::session::run(server_in, output, registry, options));
    let mut reader = client_end.try_clone().expect("clone");
    reader.set_read_timeout(Some(WAIT)).expect("timeout");
    let (tx, frames) = channel();
    std::thread::spawn(move || {
        let mut magic = vec![0u8; MAGIC.len()];
        if reader.read_exact(&mut magic).is_err() || magic != MAGIC {
            let _ = tx.send(None);
            return;
        }
        loop {
            match read_frame(&mut reader) {
                Ok(Some(f)) => {
                    if tx.send(Some(f)).is_err() {
                        return;
                    }
                }
                _ => {
                    let _ = tx.send(None);
                    return;
                }
            }
        }
    });
    let mut c = Client {
        out: client_end,
        frames,
        server: Some(server),
        next_stream: 1,
        probe,
        writes,
        flushes,
    };
    let hello = ClientHello {
        proto: 1,
        client: ClientInfo {
            name: "test".into(),
            version: "0".into(),
        },
        herdr: HerdrHello::default(),
    };
    c.send(&Frame::json(
        Kind::Hello,
        0,
        &serde_json::to_value(hello).expect("hello"),
    ));
    assert_eq!(c.next().kind, Kind::Hello);
    c
}

impl Client {
    fn send(&mut self, f: &Frame) {
        write_frame(&mut self.out, f).expect("client write");
    }

    fn next(&self) -> Frame {
        self.try_next(WAIT).expect("a frame before the timeout")
    }

    fn try_next(&self, d: Duration) -> Option<Frame> {
        self.frames.recv_timeout(d).unwrap_or_default()
    }

    fn open(&mut self, method: &str) -> u32 {
        let id = self.next_stream;
        self.next_stream += 2;
        self.send(&Frame::json(
            Kind::Open,
            id,
            &json!({"svc": "test", "method": method, "args": {}, "zctx": false}),
        ));
        id
    }

    fn say(&mut self, stream: u32, msg: &Value) {
        self.send(&Frame::json(Kind::Msg, stream, msg));
    }

    /// Waits until the handler has handed `n` frames to the session.
    fn sent(&self, n: usize) {
        let deadline = Instant::now() + WAIT;
        while self.probe.sent.load(Ordering::SeqCst) < n {
            assert!(Instant::now() < deadline, "the handler never sent {n}");
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    fn finish(mut self) -> i32 {
        let _ = self.out.shutdown(std::net::Shutdown::Write);
        self.server.take().expect("server").join().expect("joins")
    }
}

fn data(f: &Frame) -> &str {
    assert_eq!(f.kind, Kind::Data);
    std::str::from_utf8(&f.payload).expect("text")
}

#[test]
fn the_first_frame_after_quiet_leaves_at_once_and_the_next_waits_for_another_frame() {
    let mut c = start();
    let b = c.open("batched");
    c.say(b, &json!({"data": "one"}));
    // Leading edge: readable now, though the hold is a minute.
    let f = c.next();
    assert_eq!((f.stream, data(&f)), (b, "one"));

    c.say(b, &json!({"data": "two"}));
    c.sent(2);
    assert!(
        c.try_next(QUIET).is_none(),
        "a frame inside the hold waits for company"
    );

    // An interactive frame is never delayed behind the batch, and writing it
    // flushes the held frame first (queue order).
    let e = c.open("echo");
    let f = c.next();
    assert_eq!((f.stream, data(&f)), (b, "two"));
    let f = c.next();
    assert_eq!((f.stream, f.kind), (e, Kind::Msg));
    assert_eq!(c.next().kind, Kind::End);
    c.say(b, &json!({"end": true}));
    assert_eq!(c.finish(), 0);
}

#[test]
fn an_unbatched_stream_is_never_held() {
    let mut c = start();
    let u = c.open("unbatched");
    for text in ["a", "b", "c"] {
        c.say(u, &json!({"data": text}));
        let f = c.next();
        assert_eq!((f.stream, data(&f)), (u, text));
    }
    c.say(u, &json!({"end": true}));
    assert_eq!(c.next().kind, Kind::End);
    assert_eq!(c.finish(), 0);
}

#[test]
fn a_burst_is_a_few_writes_arrives_complete_and_in_order_and_the_end_comes_last() {
    let mut c = start();
    let (writes0, flushes0) = (
        c.writes.load(Ordering::SeqCst),
        c.flushes.load(Ordering::SeqCst),
    );
    let b = c.open("batched");
    c.say(b, &json!({"burst": 200}));
    c.sent(200);
    // The END is interactive: it flushes the held frames and follows them.
    c.say(b, &json!({"end": true}));
    let mut seen = Vec::new();
    loop {
        let f = c.next();
        assert_eq!(f.stream, b);
        if f.kind == Kind::End {
            break;
        }
        seen.push(data(&f).to_string());
    }
    assert_eq!(seen.len(), 200);
    for (i, text) in seen.iter().enumerate() {
        assert!(text.starts_with(&format!("{i:05}|")), "frame {i}: {text}");
    }
    let writes = c.writes.load(Ordering::SeqCst) - writes0;
    let flushes = c.flushes.load(Ordering::SeqCst) - flushes0;
    // 200 frames of ~110 bytes are one buffer: the leading frame, the batch
    // with the END, at most a stray one for the stream's OPEN bookkeeping.
    assert!(writes <= 4, "{writes} writes for 200 frames");
    assert!(flushes <= 4, "{flushes} flushes for 200 frames");
    assert_eq!(c.finish(), 0);
}

#[test]
fn a_client_reset_flushes_what_is_held() {
    let mut c = start();
    let b = c.open("batched");
    c.say(b, &json!({"data": "first"}));
    assert_eq!(data(&c.next()), "first");
    c.say(b, &json!({"data": "held"}));
    c.sent(2);
    assert!(c.try_next(QUIET).is_none());
    c.send(&Frame::json(
        Kind::Reset,
        b,
        &json!({"code": "cancelled", "message": "test"}),
    ));
    let f = c.next();
    assert_eq!((f.stream, data(&f)), (b, "held"));
    assert_eq!(c.finish(), 0);
}

#[test]
fn the_end_of_the_session_flushes_what_is_held() {
    let mut c = start();
    let b = c.open("batched");
    c.say(b, &json!({"data": "first"}));
    assert_eq!(data(&c.next()), "first");
    c.say(b, &json!({"data": "held"}));
    c.sent(2);
    assert!(c.try_next(QUIET).is_none());
    // The client leaves: the writer drains, flushes and the session exits.
    let _ = c.out.shutdown(std::net::Shutdown::Write);
    let f = c.next();
    assert_eq!((f.stream, data(&f)), (b, "held"));
    assert_eq!(c.finish(), 0);
}
