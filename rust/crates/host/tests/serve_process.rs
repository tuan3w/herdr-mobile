//! The real `herdr-host serve` binary on pipes, the way the app starts it, plus
//! the checked-in service catalog.

use serde_json::json;
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use wire::{
    read_frame, write_frame, ClientHello, ClientInfo, ErrorCode, Frame, HerdrHello, HostHello,
    Kind, WireError, MAGIC,
};

fn serve(home: &std::path::Path) -> std::process::Child {
    Command::new(env!("CARGO_BIN_EXE_herdr-host"))
        .arg("serve")
        .env("HOME", home)
        .env_remove("HERDR_SOCKET_PATH")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn herdr-host serve")
}

fn hello_frame() -> Frame {
    let hello = ClientHello {
        proto: 1,
        client: ClientInfo {
            name: "test".into(),
            version: "0".into(),
        },
        herdr: HerdrHello::default(),
    };
    Frame::json(Kind::Hello, 0, &serde_json::to_value(hello).expect("hello"))
}

#[test]
fn serve_greets_with_the_magic_then_a_hello_that_carries_the_release_version() {
    let home = tempfile::tempdir().expect("home");
    let mut child = serve(home.path());
    let mut stdin = child.stdin.take().expect("stdin");
    let mut stdout = child.stdout.take().expect("stdout");
    let mut magic = [0u8; 14];
    stdout.read_exact(&mut magic).expect("magic first");
    assert_eq!(&magic, MAGIC);
    write_frame(&mut stdin, &hello_frame()).expect("send hello");
    let f = read_frame(&mut stdout).expect("frame").expect("a hello");
    assert_eq!(f.kind, Kind::Hello);
    let hello: HostHello = serde_json::from_slice(&f.payload).expect("host hello");
    assert_eq!(hello.proto, 1);
    assert_eq!(hello.host.version, host::VERSION);
    assert_eq!(hello.host.home, home.path().to_string_lossy());
    assert_eq!(hello.host.os, std::env::consts::OS);
    // An OPEN for something that does not exist is refused, not fatal.
    write_frame(
        &mut stdin,
        &Frame::json(Kind::Open, 1, &json!({"svc": "nope", "method": "x"})),
    )
    .expect("send open");
    let f = read_frame(&mut stdout).expect("frame").expect("an end");
    let err =
        WireError::from_end(&serde_json::from_slice(&f.payload).expect("json")).expect("error");
    assert_eq!(err.code, ErrorCode::UnknownService);
    drop(stdin);
    assert_eq!(child.wait().expect("exit").code(), Some(0));
}

#[test]
fn bytes_that_are_not_frames_end_serve_with_70_and_a_reason_on_stderr() {
    let home = tempfile::tempdir().expect("home");
    let mut child = serve(home.path());
    let mut stdin = child.stdin.take().expect("stdin");
    stdin.write_all(&[0xFF; 32]).expect("garbage");
    drop(stdin);
    let out = child.wait_with_output().expect("exit");
    assert_eq!(out.status.code(), Some(keeper::exit::FAILED));
    assert!(String::from_utf8_lossy(&out.stderr).starts_with("herdr-host:"));
    assert!(
        out.stdout.starts_with(MAGIC),
        "the magic is still first on stdout"
    );
}

#[test]
fn the_catalog_checked_in_at_docs_host_api_json_is_what_api_prints() {
    let out = Command::new(env!("CARGO_BIN_EXE_herdr-host"))
        .arg("api")
        .output()
        .expect("run api");
    assert!(out.status.success());
    let checked_in = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../docs/host-api.json");
    let expected = std::fs::read_to_string(checked_in).unwrap_or_default();
    assert_eq!(
        String::from_utf8_lossy(&out.stdout).trim_end(),
        expected.trim_end(),
        "regenerate with: cd rust && cargo run -q -p host -- api > ../docs/host-api.json"
    );
}
