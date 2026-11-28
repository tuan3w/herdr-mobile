//! `fs.thumb` and `fs.search` through the real `herdr-host serve` binary on
//! pipes, the way the app runs it, with a temporary home. Every wait is
//! bounded by the client's timeout, so a bug fails the test instead of hanging
//! it.

mod common;

use common::{client_hello, Client, Item};
use serde_json::{json, Value};
use std::fs;
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use wire::{ErrorCode, WireError};

struct Serve {
    client: Client<ChildStdin>,
    child: Child,
    home: tempfile::TempDir,
}

impl Drop for Serve {
    fn drop(&mut self) {
        // This test started the child; this is the only process it ends.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn serve() -> Serve {
    let home = tempfile::tempdir().expect("home");
    let mut child = Command::new(env!("CARGO_BIN_EXE_herdr-host"))
        .arg("serve")
        .env("HOME", home.path())
        .env_remove("HERDR_SOCKET_PATH")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn herdr-host serve");
    let stdin = child.stdin.take().expect("stdin");
    let stdout = child.stdout.take().expect("stdout");
    let client = Client::connect(stdout, stdin, &client_hello(None));
    Serve {
        client,
        child,
        home,
    }
}

impl Serve {
    fn path(&self) -> &Path {
        self.home.path()
    }

    /// Every MSG, all DATA bytes and the END of one stream.
    fn run(
        &mut self,
        method: &str,
        args: &Value,
    ) -> (Vec<Value>, Vec<u8>, Result<Value, WireError>) {
        let id = self.client.open("fs", method, args, false);
        let (mut msgs, mut data) = (Vec::new(), Vec::new());
        loop {
            match self.client.item(id) {
                Item::Msg(v) => msgs.push(v),
                Item::Data(d) => data.extend(d),
                Item::End(v) => return (msgs, data, WireError::from_end(&v).map_or(Ok(v), Err)),
                Item::Reset(v) => panic!("reset: {v}"),
            }
        }
    }
}

fn gradient(w: u32, h: u32) -> Vec<u8> {
    let mut v = Vec::new();
    for y in 0..h {
        for x in 0..w {
            v.extend([(x * 255 / w) as u8, (y * 255 / h) as u8, 90]);
        }
    }
    v
}

fn jpeg(w: u32, h: u32) -> Vec<u8> {
    let mut out = Vec::new();
    jpeg_encoder::Encoder::new(&mut out, 85)
        .encode(
            &gradient(w, h),
            w as u16,
            h as u16,
            jpeg_encoder::ColorType::Rgb,
        )
        .expect("encode");
    out
}

fn dims(jpeg: &[u8]) -> (u32, u32) {
    assert_eq!(&jpeg[..3], &[0xFF, 0xD8, 0xFF]);
    let mut d = jpeg_decoder::Decoder::new(jpeg);
    d.decode().expect("decodes");
    let i = d.info().expect("info");
    (u32::from(i.width), u32::from(i.height))
}

#[test]
fn the_hello_and_the_catalog_list_both_methods_under_fs() {
    let s = serve();
    assert!(s.client.hello.services["fs"].available);
    let out = Command::new(env!("CARGO_BIN_EXE_herdr-host"))
        .arg("api")
        .output()
        .expect("api");
    let api: Value = serde_json::from_slice(&out.stdout).expect("catalog JSON");
    let fs = api["services"]
        .as_array()
        .expect("services")
        .iter()
        .find(|s| s["name"] == "fs")
        .expect("fs service");
    let methods: Vec<(&str, &str, &str)> = fs["methods"]
        .as_array()
        .expect("methods")
        .iter()
        .map(|m| {
            (
                m["name"].as_str().expect("name"),
                m["kind"].as_str().expect("kind"),
                m["class"].as_str().expect("class"),
            )
        })
        .collect();
    assert!(
        methods.contains(&("thumb", "stream", "bulk")),
        "{methods:?}"
    );
    assert!(
        methods.contains(&("search", "stream", "interactive")),
        "{methods:?}"
    );
}

#[test]
fn thumb_over_the_real_binary_returns_msg_jpeg_end_and_the_typed_errors() {
    let mut s = serve();
    let source = jpeg(1200, 800);
    fs::write(s.path().join("pic.jpg"), &source).expect("write");
    fs::write(s.path().join("notes.txt"), b"text").expect("text");
    fs::create_dir(s.path().join("folder")).expect("dir");

    let (msgs, data, end) = s.run("thumb", &json!({"path": "~/pic.jpg", "max_px": 300}));
    end.expect("ends well");
    assert_eq!(msgs.len(), 1);
    assert_eq!(
        (msgs[0]["width"].clone(), msgs[0]["height"].clone()),
        (json!(300), json!(200))
    );
    assert_eq!(msgs[0]["format"], "jpeg");
    assert_eq!(msgs[0]["source_size"], source.len());
    assert_eq!(dims(&data), (300, 200));

    let (msgs, data, end) = s.run(
        "thumb",
        &json!({"path": "~/pic.jpg", "if_match": {"size": 1, "mtime_ms": 1}}),
    );
    assert_eq!(end.expect_err("changed").code, ErrorCode::Changed);
    assert!(msgs.is_empty() && data.is_empty());

    let err = s
        .run("thumb", &json!({"path": "~/notes.txt"}))
        .2
        .expect_err("not a picture");
    assert_eq!(err.code, ErrorCode::Failed);
    assert!(
        err.message.starts_with("unsupported image"),
        "{}",
        err.message
    );
    assert_eq!(
        s.run("thumb", &json!({"path": "~/folder"}))
            .2
            .expect_err("dir")
            .code,
        ErrorCode::NotAFile
    );
    assert_eq!(
        s.run("thumb", &json!({"path": "~/missing.png"}))
            .2
            .expect_err("missing")
            .code,
        ErrorCode::NotFound
    );
    let huge = fs::File::create(s.path().join("huge.jpg")).expect("huge");
    huge.set_len(65 * 1024 * 1024).expect("sparse");
    assert_eq!(
        s.run("thumb", &json!({"path": "~/huge.jpg"}))
            .2
            .expect_err("too large")
            .code,
        ErrorCode::TooLarge
    );
}

/// A lossless WebP in a VP8X container whose EXIF flag is set and whose EXIF
/// chunk announces about 4 GiB but holds no bytes (a 100-byte file).
fn webp_announcing_4_gib_of_exif(w: u32, h: u32) -> Vec<u8> {
    let mut plain = Vec::new();
    image_webp::WebPEncoder::new(&mut plain)
        .encode(&gradient(w, h), w, h, image_webp::ColorType::Rgb8)
        .expect("webp");
    let u24 = |n: u32| n.to_le_bytes()[..3].to_vec();
    let mut body = b"WEBPVP8X".to_vec();
    body.extend(10u32.to_le_bytes());
    body.push(0x08); // the EXIF flag
    body.extend([0, 0, 0]);
    body.extend(u24(w - 1));
    body.extend(u24(h - 1));
    body.extend(&plain[12..]); // the VP8L chunk
    body.extend(b"EXIF");
    body.extend(0xFFFF_FF00u32.to_le_bytes());
    let mut out = b"RIFF".to_vec();
    out.extend(u32::try_from(body.len()).expect("fits").to_le_bytes());
    out.extend(body);
    out
}

/// `image-webp` allocates a metadata chunk as long as its header says, so
/// that file used to abort `serve` (a release build aborts on a failed
/// allocation). The address space is capped at 2 GiB, so the 4 GiB request
/// fails on any machine, whatever its overcommit setting: the old code died
/// here, the stream now ends with the picture, upright, and the process lives.
#[cfg(target_os = "linux")]
#[test]
fn a_webp_announcing_4_gib_of_exif_neither_aborts_the_host_nor_allocates_it() {
    let home = tempfile::tempdir().expect("home");
    let mut child = Command::new("sh")
        .args(["-c", "ulimit -v 2097152 && exec \"$0\" serve"])
        .arg(env!("CARGO_BIN_EXE_herdr-host"))
        .env("HOME", home.path())
        .env_remove("HERDR_SOCKET_PATH")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn");
    let stdin = child.stdin.take().expect("stdin");
    let stdout = child.stdout.take().expect("stdout");
    let client = Client::connect(stdout, stdin, &client_hello(None));
    let mut s = Serve {
        client,
        child,
        home,
    };
    fs::write(
        s.path().join("crafted.webp"),
        webp_announcing_4_gib_of_exif(300, 200),
    )
    .expect("write");
    fs::write(s.path().join("pic.jpg"), jpeg(300, 200)).expect("write");

    let (msgs, data, end) = s.run("thumb", &json!({"path": "~/crafted.webp", "max_px": 100}));
    end.expect("the picture still comes, the EXIF block is not read");
    assert_eq!(
        (msgs[0]["width"].clone(), msgs[0]["height"].clone()),
        (json!(100), json!(67))
    );
    assert_eq!(dims(&data), (100, 67));

    // The process is alive and serves the next request.
    let (_, data, end) = s.run("thumb", &json!({"path": "~/pic.jpg", "max_px": 100}));
    end.expect("still serving");
    assert_eq!(dims(&data), (100, 67));
}

#[test]
fn search_over_the_real_binary_finds_breadth_first_and_ends_with_the_summary() {
    let mut s = serve();
    for p in [
        "w/notes/TODO.md",
        "w/a/b/todo-later.txt",
        "w/todo.txt",
        "w/target/todo.o",
    ] {
        let full = s.path().join(p);
        fs::create_dir_all(full.parent().expect("parent")).expect("dirs");
        fs::write(full, b"x").expect("file");
    }
    let (msgs, _, end) = s.run("search", &json!({"root": "~/w", "query": "TODO"}));
    let names: Vec<String> = msgs
        .iter()
        .flat_map(|m| m["entries"].as_array().expect("entries").clone())
        .map(|e| e["name"].as_str().expect("name").to_string())
        .collect();
    assert_eq!(names[0], "todo.txt", "the shallowest first: {names:?}");
    assert_eq!(names.len(), 3, "the ignored `target` is skipped: {names:?}");
    let end = end.expect("ends well");
    assert_eq!(end["truncated"], false);
    assert_eq!(end["skipped_dirs"], 0);
    assert!(end["scanned"].as_u64().expect("scanned") >= 5);

    let err = s
        .run("search", &json!({"root": "~/nope"}))
        .2
        .expect_err("root");
    assert_eq!(err.code, ErrorCode::NotFound);
    let err = s
        .run("search", &json!({"root": "~/w/todo.txt"}))
        .2
        .expect_err("root");
    assert_eq!(err.code, ErrorCode::NotADirectory);
}
