//! Test fixtures for herdr-mobile (never shipped): the binaries `fake-acp-agent`,
//! `fake-herdr` and `bench-acp-agent`, and this library, which finds them.
//!
//! Rust tests ask [`bin`] for a path; Dart tests read `HERDR_TESTKIT_DIR`.

use std::path::{Path, PathBuf};
use std::process::Command;

pub mod pyjson;
pub mod pyrandom;

/// The directory holding the fixture binaries.
///
/// `HERDR_TESTKIT_DIR` when set; otherwise the profile directory of the running
/// test executable (`<target>/<profile>/deps/<test>` -> `<target>/<profile>`),
/// which is where cargo puts a package's binaries.
pub fn bin_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("HERDR_TESTKIT_DIR").filter(|d| !d.is_empty()) {
        return PathBuf::from(dir);
    }
    let exe = std::env::current_exe().expect("the path of the running test");
    let parent = exe.parent().expect("a test lives in a directory");
    if parent.file_name().is_some_and(|n| n == "deps") {
        parent.parent().unwrap_or(parent).to_path_buf()
    } else {
        parent.to_path_buf()
    }
}

/// The path of the fixture binary `name` (`"fake-acp-agent"`, ...).
///
/// `cargo test --workspace` has built it already (testkit's own tests need it).
/// When only another crate's tests were built (`cargo test -p host`), this
/// runs `cargo build -p testkit --bins` once, in the same target directory and
/// profile as the running test. Cargo's build lock makes concurrent callers
/// wait for each other. With `HERDR_TESTKIT_DIR` set nothing is built: the
/// binary must be there.
pub fn bin(name: &str) -> PathBuf {
    let dir = bin_dir();
    let path = dir.join(format!("{name}{}", std::env::consts::EXE_SUFFIX));
    if path.exists() {
        return path;
    }
    if std::env::var_os("HERDR_TESTKIT_DIR").is_none_or(|d| d.is_empty()) {
        build(&dir);
    }
    assert!(
        path.exists(),
        "{} is missing: run `cargo build -p testkit --bins` (or set HERDR_TESTKIT_DIR)",
        path.display()
    );
    path
}

fn build(profile_dir: &Path) {
    let cargo = std::env::var_os("CARGO").unwrap_or_else(|| "cargo".into());
    let mut cmd = Command::new(cargo);
    cmd.args(["build", "--offline", "-p", "testkit", "--bins"])
        .current_dir(env!("CARGO_MANIFEST_DIR"));
    match profile_dir.file_name().and_then(|n| n.to_str()) {
        Some("debug") | None => {}
        Some("release") => {
            cmd.arg("--release");
        }
        Some(other) => {
            cmd.args(["--profile", other]);
        }
    }
    match cmd.status() {
        Ok(status) if status.success() => {}
        Ok(status) => panic!("cargo build -p testkit --bins failed: {status}"),
        Err(e) => panic!("cannot run cargo to build the testkit binaries: {e}"),
    }
}
