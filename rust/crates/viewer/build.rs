//! The binary reports the release's version (the app's `version:` in pubspec.yaml), because a
//! release is one number for the app and for herdr-tui; the crate's own 0.1.0 means nothing to
//! the person running `herdr-tui --version`.

use std::{env, fs, path::PathBuf};

fn main() {
    let pubspec =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"))
            .join("../../../app/pubspec.yaml");
    println!("cargo:rerun-if-changed={}", pubspec.display());
    let text =
        fs::read_to_string(&pubspec).unwrap_or_else(|e| panic!("{}: {e}", pubspec.display()));
    let version = text
        .lines()
        .find_map(|l| l.strip_prefix("version: "))
        .and_then(|v| v.split('+').next())
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .expect("pubspec.yaml has a `version: x.y.z+n` line");
    println!("cargo:rustc-env=HERDR_TUI_VERSION={version}");
}
