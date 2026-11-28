//! Golden vectors: the byte layout both the Rust host and the Dart client
//! (`app/test/host_wire_vectors_test.dart`) must decode the same way.
//!
//! `tests/vectors.json` is checked in. After a deliberate format change,
//! regenerate it with
//! `cargo test -p wire --test vectors -- --ignored regenerate`
//! and update the Dart codec to match; the Dart test fails until it does.

use serde_json::{json, Value};
use std::io::Read;
use wire::{
    deflate, encode_frame, read_frame, ClientHello, ContinuousDeflater, Flags, Frame, Inflater,
    Kind, MAGIC,
};

const FILE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/vectors.json");

fn to_hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes.iter().fold(String::new(), |mut s, b| {
        let _ = write!(s, "{b:02x}");
        s
    })
}

fn from_hex(text: &str) -> Vec<u8> {
    (0..text.len() / 2)
        .map(|i| u8::from_str_radix(&text[i * 2..i * 2 + 2], 16).expect("hex"))
        .collect()
}

/// A reader that hands out at most `step` bytes per `read`, to prove a frame
/// split across reads decodes the same.
struct Chunked<'a> {
    data: &'a [u8],
    step: usize,
}

impl Read for Chunked<'_> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.step.min(buf.len()).min(self.data.len());
        buf[..n].copy_from_slice(&self.data[..n]);
        self.data = &self.data[n..];
        Ok(n)
    }
}

struct Built {
    name: &'static str,
    frames: Vec<(Frame, Option<Vec<u8>>)>,
}

fn plain(name: &'static str, frames: Vec<Frame>) -> Built {
    Built {
        name,
        frames: frames.into_iter().map(|f| (f, None)).collect(),
    }
}

fn builds() -> Vec<Built> {
    let client_hello = serde_json::to_value(ClientHello {
        proto: 1,
        client: wire::ClientInfo {
            name: "herdr-mobile".into(),
            version: "0.1.68".into(),
        },
        herdr: wire::HerdrHello::default(),
    })
    .expect("hello serializes");
    let big_json = json!({"result": {"text": "row of a pane screen ".repeat(200)}});
    let big_bytes = big_json.to_string().into_bytes();
    let event =
        br#"{"event":"pane.updated","data":{"pane":{"id":"p1","agent":"omp","status":"working"}}}"#;
    let mut tx = ContinuousDeflater::new();
    let ctx: Vec<(Frame, Option<Vec<u8>>)> = (0..3)
        .map(|_| {
            (
                Frame::compressed(Kind::Msg, Flags::DeflateCtx, 5, tx.piece(event)),
                Some(event.to_vec()),
            )
        })
        .collect();
    let text: Vec<u8> = (0..32_768u32).map(|i| b'a' + (i % 26) as u8).collect();
    vec![
        plain(
            "hello_client",
            vec![Frame::json(Kind::Hello, 0, &client_hello)],
        ),
        plain(
            "open_call",
            vec![Frame::json(
                Kind::Open,
                1,
                &json!({"svc":"fs","method":"stat","args":{"path":"/home/u"},"zctx":false}),
            )],
        ),
        plain(
            "msg_end_pair",
            vec![
                Frame::json(Kind::Msg, 1, &json!({"kind":"dir","size":4096})),
                Frame::json(Kind::End, 1, &json!({})),
            ],
        ),
        plain(
            "end_error",
            vec![Frame::json(
                Kind::End,
                3,
                &json!({"error":{"code":"not_found","message":"no such keeper","retryable":false}}),
            )],
        ),
        plain(
            "data_credit_reset",
            vec![
                Frame::new(Kind::Data, 7, b"line one\nline two\n".to_vec()),
                Frame::credit(7, 524_288),
                Frame::json(Kind::Reset, 7, &json!({"code":"cancelled","message":""})),
            ],
        ),
        plain("data_at_the_limit", vec![Frame::new(Kind::Data, 9, text)]),
        Built {
            name: "msg_deflate",
            frames: vec![(
                Frame::compressed(Kind::Msg, Flags::Deflate, 11, deflate(&big_bytes)),
                Some(big_bytes),
            )],
        },
        Built {
            name: "msg_deflate_ctx_stream",
            frames: ctx,
        },
    ]
}

fn rejects() -> Vec<(&'static str, &'static str, Vec<u8>)> {
    let mut cut = Vec::new();
    encode_frame(&Frame::new(Kind::Msg, 1, b"{\"a\":1}".to_vec()), &mut cut);
    cut.truncate(cut.len() - 2);
    let len_too_big = u32::try_from(5 + (1 << 20) + 1).expect("fits");
    vec![
        (
            "oversize_payload",
            "too_large",
            len_too_big.to_le_bytes().to_vec(),
        ),
        (
            "length_below_header",
            "bad_length",
            4u32.to_le_bytes().to_vec(),
        ),
        (
            "unknown_kind",
            "unknown_kind",
            vec![5, 0, 0, 0, 0x2A, 0, 0, 0, 0],
        ),
        (
            "both_flags",
            "bad_flags",
            vec![5, 0, 0, 0, 0xC3, 0, 0, 0, 0],
        ),
        (
            "flag_on_open",
            "bad_flags",
            vec![5, 0, 0, 0, 0x82, 0, 0, 0, 0],
        ),
        ("cut_frame", "truncated", cut),
    ]
}

fn frame_json(f: &Frame, inflated: Option<&Vec<u8>>) -> Value {
    let mut o = json!({
        "kind": f.kind.name(),
        "flags": f.flags.name(),
        "stream": f.stream,
        "payload_hex": to_hex(&f.payload),
    });
    if let Some(bytes) = inflated {
        o["inflated_hex"] = json!(to_hex(bytes));
    }
    o
}

fn document() -> Value {
    let vectors: Vec<Value> = builds()
        .into_iter()
        .map(|b| {
            let mut bytes = Vec::new();
            for (f, _) in &b.frames {
                encode_frame(f, &mut bytes);
            }
            json!({
                "name": b.name,
                "hex": to_hex(&bytes),
                "frames": b.frames.iter().map(|(f, i)| frame_json(f, i.as_ref())).collect::<Vec<_>>(),
            })
        })
        .collect();
    let rejects: Vec<Value> = rejects()
        .into_iter()
        .map(|(name, error, bytes)| json!({"name": name, "hex": to_hex(&bytes), "error": error}))
        .collect();
    json!({"magic_hex": to_hex(MAGIC), "vectors": vectors, "rejects": rejects})
}

#[test]
#[ignore = "writes tests/vectors.json after a deliberate format change"]
fn regenerate() {
    let text = serde_json::to_string_pretty(&document()).expect("serializes") + "\n";
    std::fs::write(FILE, text).expect("write vectors.json");
}

#[test]
fn the_checked_in_vectors_decode_and_the_plain_ones_re_encode_byte_for_byte() {
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(FILE).expect("vectors.json"))
        .expect("vectors.json is JSON");
    assert_eq!(from_hex(doc["magic_hex"].as_str().expect("magic")), MAGIC);
    let vectors = doc["vectors"].as_array().expect("vectors");
    assert!(vectors.len() >= 8);
    for v in vectors {
        let name = v["name"].as_str().expect("name");
        let bytes = from_hex(v["hex"].as_str().expect("hex"));
        let expected = v["frames"].as_array().expect("frames");
        for step in [1, 3, 4096, usize::MAX] {
            let mut r = Chunked { data: &bytes, step };
            let mut inflater = Inflater::new();
            let mut got = Vec::new();
            while let Some(f) = read_frame(&mut r).unwrap_or_else(|e| panic!("{name}: {e}")) {
                got.push(f);
            }
            assert_eq!(got.len(), expected.len(), "{name} step {step}");
            let mut again = Vec::new();
            for (f, e) in got.iter().zip(expected) {
                assert_eq!(f.kind.name(), e["kind"], "{name}");
                assert_eq!(f.flags.name(), e["flags"], "{name}");
                assert_eq!(f.stream, e["stream"], "{name}");
                assert_eq!(
                    to_hex(&f.payload),
                    e["payload_hex"].as_str().expect("payload"),
                    "{name}"
                );
                match f.flags {
                    Flags::None => {}
                    Flags::Deflate => assert_eq!(
                        to_hex(&Inflater::once(&f.payload).expect("inflates")),
                        e["inflated_hex"].as_str().expect("inflated"),
                        "{name}"
                    ),
                    Flags::DeflateCtx => assert_eq!(
                        to_hex(&inflater.piece(&f.payload).expect("inflates")),
                        e["inflated_hex"].as_str().expect("inflated"),
                        "{name}"
                    ),
                }
                encode_frame(f, &mut again);
            }
            assert_eq!(again, bytes, "{name}: re-encoding changes the bytes");
        }
    }
    for r in doc["rejects"].as_array().expect("rejects") {
        let name = r["name"].as_str().expect("name");
        let bytes = from_hex(r["hex"].as_str().expect("hex"));
        let err = read_frame(&mut bytes.as_slice()).expect_err(name);
        assert_eq!(err.name(), r["error"].as_str().expect("error"), "{name}");
    }
}
