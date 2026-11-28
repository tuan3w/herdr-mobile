//! `testkit::bin_dir()` / `testkit::bin()` find the binaries cargo built for this package.

#[test]
fn bin_finds_what_cargo_built_for_this_package() {
    for (name, built) in [
        ("fake-acp-agent", env!("CARGO_BIN_EXE_fake-acp-agent")),
        ("fake-herdr", env!("CARGO_BIN_EXE_fake-herdr")),
        ("bench-acp-agent", env!("CARGO_BIN_EXE_bench-acp-agent")),
    ] {
        let found = testkit::bin(name);
        assert_eq!(
            std::fs::canonicalize(&found).expect("the binary exists"),
            std::fs::canonicalize(built).expect("cargo built it"),
            "{name}"
        );
        assert_eq!(found.parent().expect("a dir"), testkit::bin_dir());
    }
}
