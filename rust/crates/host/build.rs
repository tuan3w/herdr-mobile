//! The binary reports the release's version (the app's `version:` in
//! `app/pubspec.yaml`): the app pins the host helper to its own version, so
//! `herdr-host --version` and the install path `herdr-host-<version>` must be
//! that number, not the crate's 0.1.0. (Same extraction as
//! `rust/crates/viewer/build.rs`; two small scripts beat a build-dependency
//! crate for ten lines.)

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
    println!("cargo:rustc-env=HERDR_HOST_VERSION={version}");
}
