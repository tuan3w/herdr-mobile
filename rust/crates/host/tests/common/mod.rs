//! Shared by `mux_golden.rs` and `serve_herdr.rs`: a hostwire client with
//! timeouts on every read, and a fake herdr socket that answers from the
//! exchanges recorded in `fixtures/mux_golden.json`.
#![allow(dead_code)]

use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use wire::{
    read_frame, write_frame, ClientHello, ClientInfo, Flags, Frame, HerdrHello, HostHello,
    Inflater, Kind, WireError, MAGIC,
};

pub const WAIT: Duration = Duration::from_secs(10);

pub fn golden() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/mux_golden.json"
    );
    let text = std::fs::read_to_string(path).expect("read the golden fixture");
    serde_json::from_str(&text).expect("golden fixture is JSON")
}

pub fn client_hello(socket: Option<&Path>) -> ClientHello {
    ClientHello {
        proto: 1,
        client: ClientInfo {
            name: "test".into(),
            version: "0".into(),
        },
        herdr: HerdrHello {
            session: "default".into(),
            socket: socket.map(|p| p.to_string_lossy().into_owned()),
        },
    }
}

/// What arrived on a stream.
#[derive(Debug)]
pub enum Item {
    Msg(Value),
    Data(Vec<u8>),
    End(Value),
    Reset(Value),
}

pub struct Client<W: Write> {
    pub out: W,
    frames: Receiver<Option<Frame>>,
    pending: HashMap<u32, VecDeque<Item>>,
    inflaters: HashMap<u32, Inflater>,
    next_stream: u32,
    pub hello: HostHello,
}

impl<W: Write> Client<W> {
    /// Reads the magic and the HELLO from `input` after sending `hello`.
    pub fn connect<R: Read + Send + 'static>(
        mut input: R,
        mut out: W,
        hello: &ClientHello,
    ) -> Self {
        let (tx, frames) = channel();
        std::thread::spawn(move || {
            let mut magic = vec![0u8; MAGIC.len()];
            if input.read_exact(&mut magic).is_err() || magic != MAGIC {
                let _ = tx.send(None);
                return;
            }
            while let Ok(Some(f)) = read_frame(&mut input) {
                if tx.send(Some(f)).is_err() {
                    return;
                }
            }
            let _ = tx.send(None);
        });
        write_frame(
            &mut out,
            &Frame::json(Kind::Hello, 0, &serde_json::to_value(hello).expect("hello")),
        )
        .expect("send hello");
        let first = match frames.recv_timeout(WAIT) {
            Ok(Some(f)) => f,
            other => panic!("no HELLO from the host: {other:?}"),
        };
        assert_eq!(first.kind, Kind::Hello);
        let hello: HostHello = serde_json::from_slice(&first.payload).expect("host hello");
        Self {
            out,
            frames,
            pending: HashMap::new(),
            inflaters: HashMap::new(),
            next_stream: 1,
            hello,
        }
    }

    pub fn open(&mut self, svc: &str, method: &str, args: &Value, zctx: bool) -> u32 {
        let id = self.next_stream;
        self.next_stream += 2;
        write_frame(
            &mut self.out,
            &Frame::json(
                Kind::Open,
                id,
                &json!({"svc": svc, "method": method, "args": args, "zctx": zctx}),
            ),
        )
        .expect("send open");
        id
    }

    pub fn send_msg(&mut self, stream: u32, value: &Value) {
        write_frame(&mut self.out, &Frame::json(Kind::Msg, stream, value)).expect("send msg");
    }

    pub fn end(&mut self, stream: u32) {
        write_frame(&mut self.out, &Frame::json(Kind::End, stream, &json!({}))).expect("send end");
    }

    fn ingest(&mut self, f: Frame) {
        let item = match f.kind {
            Kind::Msg | Kind::Data | Kind::End | Kind::Reset => {
                let payload = match f.flags {
                    Flags::None => f.payload,
                    Flags::Deflate => Inflater::once(&f.payload).expect("inflates"),
                    Flags::DeflateCtx => self
                        .inflaters
                        .entry(f.stream)
                        .or_default()
                        .piece(&f.payload)
                        .expect("inflates"),
                };
                match f.kind {
                    Kind::Data => Item::Data(payload),
                    Kind::Msg => Item::Msg(serde_json::from_slice(&payload).expect("MSG is JSON")),
                    Kind::End => Item::End(serde_json::from_slice(&payload).expect("END is JSON")),
                    _ => Item::Reset(serde_json::from_slice(&payload).expect("RESET is JSON")),
                }
            }
            _ => return,
        };
        self.pending.entry(f.stream).or_default().push_back(item);
    }

    /// The next item of `stream`, or `None` when nothing arrives in `wait`.
    pub fn try_item(&mut self, stream: u32, wait: Duration) -> Option<Item> {
        loop {
            if let Some(item) = self.pending.get_mut(&stream).and_then(VecDeque::pop_front) {
                return Some(item);
            }
            match self.frames.recv_timeout(wait) {
                Ok(Some(f)) => self.ingest(f),
                Ok(None) | Err(RecvTimeoutError::Disconnected) => return None,
                Err(RecvTimeoutError::Timeout) => return None,
            }
        }
    }

    pub fn item(&mut self, stream: u32) -> Item {
        self.try_item(stream, WAIT)
            .unwrap_or_else(|| panic!("nothing arrived on stream {stream} in {WAIT:?}"))
    }

    /// The next MSG of `stream`; anything else fails the test.
    pub fn msg(&mut self, stream: u32) -> Value {
        match self.item(stream) {
            Item::Msg(v) => v,
            other => panic!("expected a MSG on stream {stream}, got {other:?}"),
        }
    }

    /// The END of `stream`, as an error when it carries one.
    pub fn ended(&mut self, stream: u32) -> Result<Value, WireError> {
        match self.item(stream) {
            Item::End(v) => match WireError::from_end(&v) {
                Some(e) => Err(e),
                None => Ok(v),
            },
            other => panic!("expected END on stream {stream}, got {other:?}"),
        }
    }
}

/// A herdr socket that answers from recorded exchanges: the requests of the
/// golden file by `(method, params)` in the order they were recorded, and an
/// `events.subscribe` with the recorded ack and events.
pub struct FakeHerdr {
    pub path: PathBuf,
    pub requests: Arc<Mutex<Vec<Value>>>,
}

/// What identifies a request to the canned answers.
fn key_of(request: &Value) -> Value {
    if request.is_object() {
        json!([request.get("method"), request.get("params")])
    } else {
        request.clone()
    }
}

pub fn start_fake(path: &Path, golden: &Value) -> FakeHerdr {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).expect("socket dir");
    }
    let mut canned: Vec<(Value, VecDeque<Option<String>>)> = Vec::new();
    for exchange in golden["exchanges"].as_array().expect("exchanges") {
        let key = key_of(&exchange["request"]);
        let answer = exchange["response"].as_str().map(str::to_string);
        match canned.iter_mut().find(|(k, _)| *k == key) {
            Some((_, queue)) => queue.push_back(answer),
            None => canned.push((key, VecDeque::from([answer]))),
        }
    }
    let events = &golden["events"];
    let ack = events["ack_line"].as_str().expect("ack").to_string();
    let lines: Vec<String> = events["event_lines"]
        .as_array()
        .expect("event lines")
        .iter()
        .map(|l| l.as_str().expect("line").to_string())
        .collect();
    let canned = Arc::new(Mutex::new(canned));
    let requests = Arc::new(Mutex::new(Vec::new()));
    let listener = UnixListener::bind(path).expect("bind the fake herdr socket");
    let seen = Arc::clone(&requests);
    std::thread::spawn(move || {
        for conn in listener.incoming() {
            let Ok(conn) = conn else { return };
            let canned = Arc::clone(&canned);
            let seen = Arc::clone(&seen);
            let (ack, lines) = (ack.clone(), lines.clone());
            std::thread::spawn(move || serve_one(conn, &canned, &seen, &ack, &lines));
        }
    });
    FakeHerdr {
        path: path.to_path_buf(),
        requests,
    }
}

type Canned = Mutex<Vec<(Value, VecDeque<Option<String>>)>>;

fn serve_one(
    conn: UnixStream,
    canned: &Canned,
    seen: &Mutex<Vec<Value>>,
    ack: &str,
    events: &[String],
) {
    let mut reader = BufReader::new(&conn);
    let mut line = String::new();
    if reader.read_line(&mut line).unwrap_or(0) == 0 {
        return;
    }
    let Ok(request) = serde_json::from_str::<Value>(&line) else {
        return;
    };
    seen.lock().expect("seen").push(request.clone());
    let mut out = &conn;
    if request.get("method").and_then(Value::as_str) == Some("events.subscribe") {
        let _ = out.write_all(format!("{ack}\n").as_bytes());
        for event in events {
            let _ = out.write_all(format!("{event}\n").as_bytes());
        }
        // The subscription stays open until the client hangs up.
        let mut rest = String::new();
        while reader.read_line(&mut rest).unwrap_or(0) > 0 {
            rest.clear();
        }
        return;
    }
    let key = key_of(&request);
    let answer = canned
        .lock()
        .expect("canned")
        .iter_mut()
        .find(|(k, _)| *k == key)
        .and_then(|(_, queue)| queue.pop_front())
        .flatten();
    if let Some(answer) = answer {
        let _ = out.write_all(format!("{answer}\n").as_bytes());
    }
}
