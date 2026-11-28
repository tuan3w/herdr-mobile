//! The `serve` session over an in-memory socket pair, with a service made for
//! the test. Every read has a timeout, so a bug fails the test instead of
//! hanging it.

use host::{
    Class, Compress, Incoming, MethodKind, MethodSpec, Registry, Service, SessionOptions, StreamCtx,
};
use serde_json::{json, Value};
use std::io::Read;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use wire::{
    read_frame, write_frame, ClientHello, ClientInfo, ContinuousDeflater, ErrorCode, Flags, Frame,
    HerdrHello, HostHello, Inflater, Kind, Limits, ServiceStatus, WireError, MAGIC,
};

const WAIT: Duration = Duration::from_secs(10);

#[derive(Default)]
struct Probe {
    reset_seen: AtomicBool,
    handlers_running: AtomicUsize,
}

struct TestService(Arc<Probe>);

static METHODS: &[MethodSpec] = &[
    MethodSpec {
        name: "echo",
        kind: MethodKind::Call,
        class: Class::Interactive,
        summary: "returns its args",
        args_example: "{\"a\":1}",
        result_example: "{\"a\":1}",
    },
    MethodSpec {
        name: "count",
        kind: MethodKind::Stream,
        class: Class::Interactive,
        summary: "sends args.n messages",
        args_example: "{\"n\":3}",
        result_example: "{\"done\":3}",
    },
    MethodSpec {
        name: "upload",
        kind: MethodKind::Stream,
        class: Class::Bulk,
        summary: "counts the DATA bytes the client sends",
        args_example: "{}",
        result_example: "{\"bytes\":0}",
    },
    MethodSpec {
        name: "download",
        kind: MethodKind::Stream,
        class: Class::Bulk,
        summary: "sends args.bytes bytes",
        args_example: "{\"bytes\":1}",
        result_example: "{}",
    },
    MethodSpec {
        name: "wait",
        kind: MethodKind::Stream,
        class: Class::Interactive,
        summary: "runs until the stream is done",
        args_example: "{}",
        result_example: "{}",
    },
    MethodSpec {
        name: "fail",
        kind: MethodKind::Call,
        class: Class::Interactive,
        summary: "fails with not_found",
        args_example: "{}",
        result_example: "{}",
    },
];

impl Service for TestService {
    fn name(&self) -> &'static str {
        "test"
    }

    fn methods(&self) -> &'static [MethodSpec] {
        METHODS
    }

    fn availability(&self, _: &ClientHello) -> ServiceStatus {
        ServiceStatus::available().with("flavour", json!("test"))
    }

    fn open(&self, method: &str, ctx: &StreamCtx) -> Result<Value, WireError> {
        self.0.handlers_running.fetch_add(1, Ordering::SeqCst);
        let result = self.run(method, ctx);
        self.0.handlers_running.fetch_sub(1, Ordering::SeqCst);
        result
    }
}

impl TestService {
    fn run(&self, method: &str, ctx: &StreamCtx) -> Result<Value, WireError> {
        match method {
            "echo" => Ok(ctx.args().clone()),
            "count" => {
                let n = ctx.args()["n"].as_u64().unwrap_or(0);
                for i in 0..n {
                    ctx.send_msg(&json!({"i": i, "pad": "x".repeat(200)}))?;
                }
                Ok(json!({"done": n}))
            }
            "upload" => {
                let mut bytes = 0usize;
                while let Some(item) = ctx.recv() {
                    if let Incoming::Data(d) = item {
                        bytes += d.len();
                    }
                }
                Ok(json!({"bytes": bytes}))
            }
            "download" => {
                ctx.set_compress(Compress::Never);
                let n = ctx.args()["bytes"].as_u64().unwrap_or(0) as usize;
                ctx.send_data(&vec![7u8; n])?;
                Ok(json!({}))
            }
            "wait" => {
                while ctx.sleep(Duration::from_secs(5)) {}
                if ctx.cancelled() {
                    self.0.reset_seen.store(true, Ordering::SeqCst);
                }
                Ok(json!({}))
            }
            "fail" => Err(WireError::new(ErrorCode::NotFound, "nothing here")),
            _ => Err(WireError::new(ErrorCode::UnknownMethod, method)),
        }
    }
}

struct Gone;

impl Service for Gone {
    fn name(&self) -> &'static str {
        "gone"
    }
    fn methods(&self) -> &'static [MethodSpec] {
        METHODS
    }
    fn availability(&self, _: &ClientHello) -> ServiceStatus {
        ServiceStatus::unavailable("no such thing on this host")
    }
    fn open(&self, _: &str, _: &StreamCtx) -> Result<Value, WireError> {
        unreachable!("an unavailable service is never opened")
    }
}

struct Client {
    out: UnixStream,
    frames: Receiver<Option<Frame>>,
    server: Option<JoinHandle<i32>>,
    hello: Option<HostHello>,
    next_stream: u32,
}

fn client_hello(proto: u32) -> Frame {
    let hello = ClientHello {
        proto,
        client: ClientInfo {
            name: "test".into(),
            version: "0".into(),
        },
        herdr: HerdrHello::default(),
    };
    Frame::json(Kind::Hello, 0, &serde_json::to_value(hello).expect("hello"))
}

fn options(limits: Limits, stall: Duration) -> SessionOptions {
    SessionOptions {
        host: wire::HostInfo {
            version: "9.9.9".into(),
            os: "linux".into(),
            arch: "x86_64".into(),
            home: "/home/test".into(),
            hostname: "box".into(),
            user: "tester".into(),
        },
        home: "/home/test".into(),
        limits,
        stall,
        exit_on_write_error: false,
    }
}

fn start_with(probe: &Arc<Probe>, limits: Limits, stall: Duration, proto: u32) -> Client {
    let (client_end, server_end) = UnixStream::pair().expect("pair");
    let server_in = server_end.try_clone().expect("clone");
    let registry = Arc::new(Registry::new(vec![
        Arc::new(TestService(Arc::clone(probe))),
        Arc::new(Gone),
    ]));
    let server = std::thread::spawn(move || {
        host::session::run(server_in, server_end, registry, options(limits, stall))
    });
    let mut reader = client_end.try_clone().expect("clone");
    reader.set_read_timeout(Some(WAIT)).expect("timeout");
    let (tx, frames) = channel();
    std::thread::spawn(move || {
        let mut magic = [0u8; 14];
        if reader.read_exact(&mut magic).is_err() || &magic != MAGIC {
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
        hello: None,
        next_stream: 1,
    };
    c.send(&client_hello(proto));
    if proto == 1 {
        let hello = c.next();
        assert_eq!(hello.kind, Kind::Hello);
        c.hello = Some(serde_json::from_slice(&hello.payload).expect("host hello"));
    }
    c
}

fn start() -> Client {
    start_with(
        &Arc::new(Probe::default()),
        Limits::default(),
        Duration::from_secs(60),
        1,
    )
}

impl Client {
    fn send(&mut self, f: &Frame) {
        write_frame(&mut self.out, f).expect("client write");
    }

    fn try_next(&self, d: Duration) -> Option<Frame> {
        match self.frames.recv_timeout(d) {
            Ok(f) => f,
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => None,
        }
    }

    fn next(&self) -> Frame {
        self.try_next(WAIT).expect("a frame before the timeout")
    }

    fn open(&mut self, svc: &str, method: &str, args: Value, zctx: bool) -> u32 {
        let id = self.next_stream;
        self.next_stream += 2;
        self.send(&Frame::json(
            Kind::Open,
            id,
            &json!({"svc": svc, "method": method, "args": args, "zctx": zctx}),
        ));
        id
    }

    /// Frames of `stream` up to and including its END or RESET.
    fn until_end(&self, stream: u32) -> Vec<Frame> {
        let mut got = Vec::new();
        loop {
            let f = self.next();
            let last = matches!(f.kind, Kind::End | Kind::Reset) && f.stream == stream;
            if f.stream == stream || f.kind == Kind::End {
                got.push(f);
            }
            if last {
                return got;
            }
        }
    }

    /// Ends the client's side (a half-close, because the reader thread still
    /// holds the socket) and returns the server's exit code.
    fn finish(mut self) -> i32 {
        let _ = self.out.shutdown(std::net::Shutdown::Write);
        self.server.take().expect("server").join().expect("joins")
    }
}

fn json_of(f: &Frame) -> Value {
    serde_json::from_slice(&f.payload).expect("json payload")
}

#[test]
fn the_handshake_announces_the_host_its_limits_and_each_services_availability() {
    let c = start();
    let hello = c.hello.as_ref().expect("hello");
    assert_eq!(hello.proto, 1);
    assert_eq!(hello.host.version, "9.9.9");
    assert_eq!(hello.limits, Limits::default());
    assert!(hello.services["test"].available);
    assert_eq!(hello.services["test"].extra["flavour"], "test");
    assert!(!hello.services["gone"].available);
    assert_eq!(
        hello.services["gone"].reason.as_deref(),
        Some("no such thing on this host")
    );
    assert_eq!(c.finish(), 0, "a client that leaves cleanly is exit 0");
}

#[test]
fn a_call_answers_with_one_message_then_ends() {
    let mut c = start();
    let id = c.open("test", "echo", json!({"a": [1, 2]}), false);
    let frames = c.until_end(id);
    assert_eq!(frames.len(), 2);
    assert_eq!(
        (frames[0].kind, json_of(&frames[0])),
        (Kind::Msg, json!({"a": [1, 2]}))
    );
    assert_eq!(
        (frames[1].kind, json_of(&frames[1])),
        (Kind::End, json!({}))
    );
    assert_eq!(c.finish(), 0);
}

#[test]
fn a_failing_handler_ends_its_stream_with_the_error_and_leaves_the_session_up() {
    let mut c = start();
    let id = c.open("test", "fail", json!({}), false);
    let frames = c.until_end(id);
    let err = WireError::from_end(&json_of(frames.last().expect("end"))).expect("an error");
    assert_eq!(
        (err.code, err.message.as_str()),
        (ErrorCode::NotFound, "nothing here")
    );
    let id = c.open("test", "echo", json!({}), false);
    assert_eq!(c.until_end(id).len(), 2, "the session still serves");
    assert_eq!(c.finish(), 0);
}

#[test]
fn unknown_and_unavailable_opens_are_refused_with_their_reasons() {
    let mut c = start();
    for (svc, method, code) in [
        ("nope", "x", ErrorCode::UnknownService),
        ("test", "nope", ErrorCode::UnknownMethod),
        ("gone", "echo", ErrorCode::Unavailable),
    ] {
        let id = c.open(svc, method, json!({}), false);
        let f = c.until_end(id).pop().expect("end");
        let err = WireError::from_end(&json_of(&f)).expect("an error");
        assert_eq!(err.code, code, "{svc}.{method}");
        if code == ErrorCode::Unavailable {
            assert_eq!(err.message, "no such thing on this host");
        }
    }
    assert_eq!(c.finish(), 0);
}

#[test]
fn stream_ids_must_be_odd_and_increasing() {
    let mut c = start();
    let a = c.open("test", "echo", json!({}), false);
    assert_eq!(c.until_end(a).len(), 2);
    for bad in [a, 2, 0] {
        c.send(&Frame::json(
            Kind::Open,
            bad,
            &json!({"svc":"test","method":"echo"}),
        ));
        let f = c.next();
        assert_eq!((f.kind, f.stream), (Kind::End, bad));
        let err = WireError::from_end(&json_of(&f)).expect("an error");
        assert_eq!(err.code, ErrorCode::BadRequest, "id {bad}");
    }
    assert_eq!(c.finish(), 0);
}

#[test]
fn a_stream_cap_refuses_the_extra_open_as_retryable_busy() {
    let limits = Limits {
        max_streams: 2,
        ..Limits::default()
    };
    let mut c = start_with(
        &Arc::new(Probe::default()),
        limits,
        Duration::from_secs(60),
        1,
    );
    c.open("test", "wait", json!({}), false);
    c.open("test", "wait", json!({}), false);
    let third = c.open("test", "wait", json!({}), false);
    let f = c.until_end(third).pop().expect("end");
    let err = WireError::from_end(&json_of(&f)).expect("an error");
    assert_eq!((err.code, err.retryable), (ErrorCode::Busy, true));
    assert_eq!(c.finish(), 0);
}

#[test]
fn a_reset_cancels_the_handler_and_nothing_more_is_sent_on_that_stream() {
    let probe = Arc::new(Probe::default());
    let mut c = start_with(&probe, Limits::default(), Duration::from_secs(60), 1);
    let id = c.open("test", "wait", json!({}), false);
    let deadline = Instant::now() + WAIT;
    while probe.handlers_running.load(Ordering::SeqCst) == 0 {
        assert!(Instant::now() < deadline, "the handler never started");
        std::thread::sleep(Duration::from_millis(5));
    }
    c.send(&Frame::json(
        Kind::Reset,
        id,
        &json!({"code":"cancelled","message":""}),
    ));
    while probe.handlers_running.load(Ordering::SeqCst) != 0 {
        assert!(Instant::now() < deadline, "the handler never stopped");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(probe.reset_seen.load(Ordering::SeqCst));
    let other = c.open("test", "echo", json!({}), false);
    let frames = c.until_end(other);
    assert!(frames.iter().all(|f| f.stream == other), "{frames:?}");
    assert_eq!(c.finish(), 0);
}

#[test]
fn a_client_that_ends_its_side_lets_an_upload_finish_with_what_it_sent() {
    let mut c = start();
    let id = c.open("test", "upload", json!({}), false);
    c.send(&Frame::new(Kind::Data, id, vec![1; 1000]));
    c.send(&Frame::new(Kind::Data, id, vec![2; 24]));
    c.send(&Frame::json(Kind::End, id, &json!({})));
    let end = c.until_end(id).pop().expect("end");
    assert_eq!(json_of(&end), json!({"bytes": 1024}));
    assert_eq!(c.finish(), 0);
}

#[test]
fn an_upload_larger_than_the_window_flows_as_the_host_grants_credit() {
    let mut c = start();
    let window = Limits::default().window as usize;
    let id = c.open("test", "upload", json!({}), false);
    let total = 3 * window + 5;
    let (mut sent, mut credit) = (0usize, window);
    while sent < total {
        if credit == 0 {
            let f = c.next();
            assert_eq!(
                f.kind,
                Kind::Credit,
                "only credit is expected while sending"
            );
            credit += f.credit_bytes().expect("credit") as usize;
            continue;
        }
        let n = credit.min(total - sent).min(32 * 1024);
        c.send(&Frame::new(Kind::Data, id, vec![9; n]));
        sent += n;
        credit -= n;
    }
    c.send(&Frame::json(Kind::End, id, &json!({})));
    let end = loop {
        let f = c.next();
        if f.kind == Kind::End {
            break f;
        }
        assert_eq!(f.kind, Kind::Credit);
    };
    assert_eq!(json_of(&end), json!({"bytes": total}));
    assert_eq!(c.finish(), 0);
}

#[test]
fn more_data_than_the_credit_granted_resets_the_stream() {
    let mut c = start();
    // `wait` never reads its input, so nothing is credited back.
    let id = c.open("test", "wait", json!({}), false);
    let window = Limits::default().window as usize;
    // One frame past the window, in frames the codec accepts.
    let mut sent = 0;
    while sent <= window {
        c.send(&Frame::new(Kind::Data, id, vec![0; 32 * 1024]));
        sent += 32 * 1024;
    }
    let reset = loop {
        let f = c.next();
        if f.kind == Kind::Reset {
            break f;
        }
    };
    assert_eq!(
        WireError::from_body(&json_of(&reset)).code,
        ErrorCode::BadRequest
    );
    assert_eq!(c.finish(), 0);
}

#[test]
fn a_download_stops_at_the_window_until_the_client_grants_more() {
    let mut c = start();
    let window = Limits::default().window as usize;
    let id = c.open("test", "download", json!({"bytes": 2 * window}), false);
    // Wait until the whole window has arrived (`next` fails after `WAIT`, far
    // longer than a busy machine needs), instead of counting what arrives in
    // one fixed look: a slow runner delivered fewer bytes in 500 ms.
    let mut got = 0usize;
    while got < window {
        let f = c.next();
        if f.kind == Kind::Data {
            got += f.payload.len();
        }
    }
    assert_eq!(got, window, "the host must stop at the granted window");
    // Nothing more comes without credit (a negative check: a short look can
    // only miss a violation, never report a false one).
    assert!(c.try_next(Duration::from_millis(200)).is_none());
    c.send(&Frame::credit(id, u32::try_from(window).expect("fits")));
    let mut ended = false;
    while !ended {
        let f = c.next();
        match f.kind {
            Kind::Data => got += f.payload.len(),
            Kind::End => ended = true,
            _ => {}
        }
    }
    assert_eq!(got, 2 * window);
    assert_eq!(c.finish(), 0);
}

#[test]
fn a_client_that_never_reads_gets_the_stream_reset_as_stalled() {
    let mut c = start_with(
        &Arc::new(Probe::default()),
        Limits::default(),
        Duration::from_millis(300),
        1,
    );
    let window = Limits::default().window as usize;
    let id = c.open("test", "download", json!({"bytes": 2 * window}), false);
    let reset = loop {
        let f = c.next();
        if f.kind == Kind::Reset && f.stream == id {
            break f;
        }
    };
    assert_eq!(
        WireError::from_body(&json_of(&reset)).code,
        ErrorCode::Stalled
    );
    // The session itself is fine.
    let other = c.open("test", "echo", json!({}), false);
    assert_eq!(c.until_end(other).len(), 2);
    assert_eq!(c.finish(), 0);
}

#[test]
fn a_zctx_stream_arrives_as_pieces_of_one_zlib_stream() {
    let mut c = start();
    let id = c.open("test", "count", json!({"n": 5}), true);
    let frames = c.until_end(id);
    let mut inflater = Inflater::new();
    let mut seen = 0;
    for f in &frames {
        if f.kind != Kind::Msg {
            continue;
        }
        assert_eq!(
            f.flags,
            Flags::DeflateCtx,
            "messages over 64 bytes use the stream"
        );
        let plain = inflater.piece(&f.payload).expect("inflates");
        let v: Value = serde_json::from_slice(&plain).expect("json");
        assert_eq!(v["i"], seen);
        seen += 1;
    }
    assert_eq!(seen, 5);
    assert_eq!(c.finish(), 0);
}

#[test]
fn a_hello_for_another_protocol_is_refused_and_exits_70() {
    let c = start_with(
        &Arc::new(Probe::default()),
        Limits::default(),
        Duration::from_secs(60),
        2,
    );
    let f = c.next();
    assert_eq!((f.kind, f.stream), (Kind::End, 0));
    let err = WireError::from_end(&json_of(&f)).expect("an error");
    assert_eq!(err.code, ErrorCode::ProtoMismatch);
    assert_eq!(c.finish(), keeper::exit::FAILED);
}

#[test]
fn bytes_that_are_not_frames_end_the_session_with_exit_70() {
    let mut c = start();
    std::io::Write::write_all(&mut c.out, &[0xFF; 16]).expect("write");
    assert_eq!(c.finish(), keeper::exit::FAILED);
}

#[test]
fn a_second_hello_is_a_protocol_error() {
    let mut c = start();
    c.send(&client_hello(1));
    assert_eq!(c.finish(), keeper::exit::FAILED);
}

#[test]
fn a_client_may_send_pieces_of_one_zlib_stream_on_a_zctx_stream() {
    let mut c = start();
    let id = c.open("test", "upload", json!({}), true);
    let mut tx = ContinuousDeflater::new();
    // The same text three times: later pieces refer back to earlier ones, so
    // they only inflate when the host keeps the stream's state between frames.
    let text =
        "{\"id\":\"m1\",\"method\":\"pane.read\",\"params\":{\"pane_id\":\"w1:p1\"}}\n".repeat(40);
    for _ in 0..3 {
        let piece = tx.piece(text.as_bytes());
        assert!(piece.len() < text.len());
        c.send(&Frame::compressed(Kind::Data, Flags::DeflateCtx, id, piece));
    }
    c.send(&Frame::json(Kind::End, id, &json!({})));
    let end = loop {
        let f = c.next();
        if f.kind == Kind::End {
            break f;
        }
    };
    assert_eq!(json_of(&end), json!({"bytes": 3 * text.len()}));
    assert_eq!(c.finish(), 0);
}

#[test]
fn continuous_compression_without_zctx_resets_the_stream() {
    let mut c = start();
    let id = c.open("test", "wait", json!({}), false);
    let piece = ContinuousDeflater::new().piece(b"{\"a\":1}");
    c.send(&Frame::compressed(Kind::Msg, Flags::DeflateCtx, id, piece));
    let reset = loop {
        let f = c.next();
        if f.kind == Kind::Reset {
            break f;
        }
    };
    assert_eq!(
        WireError::from_body(&json_of(&reset)).code,
        ErrorCode::BadRequest
    );
    assert_eq!(c.finish(), 0);
}
