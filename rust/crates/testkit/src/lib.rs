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
/// test executable, which is where cargo puts a package's binaries.
pub fn bin_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("HERDR_TESTKIT_DIR").filter(|d| !d.is_empty()) {
        return PathBuf::from(dir);
    }
    profile_dir_of(&std::env::current_exe().expect("the path of the running test"))
}

/// The profile directory (`<target>/debug`, `<target>/release`, ...) a test
/// executable was built under.
///
/// The executable sits in `<profile>/deps/` with cargo's classic layout, but in
/// `<profile>/build/<package>/<hash>/out/` with the newer one (a runner with a
/// recent cargo: the old rule took `out` for the profile and the fallback build
/// failed with "profile `out` is not defined"). So walk up to the first
/// directory that holds cargo's `.fingerprint` folder, which only a profile
/// directory does, and only then fall back to the name rule.
fn profile_dir_of(exe: &Path) -> PathBuf {
    let mut dirs = exe.ancestors().skip(1);
    if let Some(dir) = dirs.clone().find(|d| d.join(".fingerprint").is_dir()) {
        return dir.to_path_buf();
    }
    if let Some(dir) = dirs.find(|d| {
        d.file_name()
            .is_some_and(|n| n == "debug" || n == "release")
    }) {
        return dir.to_path_buf();
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(tag: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("testkit-profile-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("make the scratch folder");
        dir
    }

    #[test]
    fn a_test_built_in_the_newer_layout_belongs_to_the_profile_above_its_build_folder() {
        // `<target>/debug/build/<package>/<hash>/out/<test>`: the folder that
        // holds it is called `out`, which is not a profile.
        let target = scratch("new");
        let profile = target.join("debug");
        std::fs::create_dir_all(profile.join(".fingerprint")).expect("make the profile folder");
        let exe = profile.join("build/herdr-tui/0123abcd/out/cli-0123abcd");
        assert_eq!(profile_dir_of(&exe), profile);
        let _ = std::fs::remove_dir_all(&target);
    }

    #[test]
    fn a_test_built_in_the_classic_layout_belongs_to_the_profile_above_deps() {
        let target = scratch("classic");
        let profile = target.join("release");
        std::fs::create_dir_all(profile.join(".fingerprint")).expect("make the profile folder");
        assert_eq!(profile_dir_of(&profile.join("deps/cli-0123abcd")), profile);
        let _ = std::fs::remove_dir_all(&target);
    }

    #[test]
    fn a_custom_profile_is_found_by_its_fingerprint_folder_not_its_name() {
        let target = scratch("custom");
        let profile = target.join("ci-fast");
        std::fs::create_dir_all(profile.join(".fingerprint")).expect("make the profile folder");
        assert_eq!(profile_dir_of(&profile.join("deps/cli-0123abcd")), profile);
        let _ = std::fs::remove_dir_all(&target);
    }

    #[test]
    fn without_a_fingerprint_folder_the_usual_names_still_decide() {
        assert_eq!(
            profile_dir_of(Path::new("/nowhere/target/debug/build/pkg/h/out/cli-h")),
            PathBuf::from("/nowhere/target/debug")
        );
        assert_eq!(
            profile_dir_of(Path::new("/nowhere/target/release/deps/cli-h")),
            PathBuf::from("/nowhere/target/release")
        );
    }
}
