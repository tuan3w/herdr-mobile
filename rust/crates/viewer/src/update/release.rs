//! What is known about a release without touching the machine: which file is for this computer,
//! what the sums say, which version is newer, and where releases are downloaded from. Pure
//! functions, so the decisions are tested without a network.

/// Where releases are downloaded from: the latest one, unless `HERDR_TUI_BASE_URL` names a mirror
/// (or a folder, as `file:///path`, which is what the tests use).
const LATEST: &str = "https://github.com/tuan3w/herdr-mobile/releases/latest/download";
const RELEASES: &str = "https://github.com/tuan3w/herdr-mobile/releases/download";

/// The checksums file every release carries (`sha256sum herdr-tui-*`). Every `herdr-tui` already
/// out there fetches it by this name, so renaming it strands them (docs/TUI.md, "Updating").
pub(super) const SUMS: &str = "herdr-tui-SHA256SUMS";

/// The release file for a platform, as `std::env::consts` names it, or `None` where there is none.
#[must_use]
fn asset_for(os: &str, arch: &str) -> Option<&'static str> {
    match (os, arch) {
        ("linux", "x86_64") => Some("herdr-tui-linux-x86_64"),
        ("linux", "aarch64") => Some("herdr-tui-linux-aarch64"),
        ("macos", "aarch64") => Some("herdr-tui-macos-arm64"),
        ("macos", "x86_64") => Some("herdr-tui-macos-x86_64"),
        _ => None,
    }
}

/// The release file for this computer.
#[must_use]
pub fn asset() -> Option<&'static str> {
    asset_for(std::env::consts::OS, std::env::consts::ARCH)
}

/// The checksum a `SHA256SUMS` text lists for `asset` (`<hex>  <name>`, or `<hex> *<name>`).
#[must_use]
pub(super) fn wanted_sum(sums: &str, asset: &str) -> Option<String> {
    sums.lines().find_map(|l| {
        let mut parts = l.split_whitespace();
        let (sum, name) = (parts.next()?, parts.next()?);
        let ok = sum.len() == 64 && sum.bytes().all(|b| b.is_ascii_hexdigit());
        (ok && name.trim_start_matches('*') == asset).then(|| sum.to_ascii_lowercase())
    })
}

/// A release number, ordered the way releases are (`0.1.9` comes before `0.1.10`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version {
    major: u64,
    minor: u64,
    patch: u64,
}

impl Version {
    #[must_use]
    pub const fn new(major: u64, minor: u64, patch: u64) -> Version {
        Version {
            major,
            minor,
            patch,
        }
    }
}

/// `x.y.z` out of `herdr-tui 0.1.37` (what `--version` prints) or a bare `0.1.37`.
#[must_use]
pub fn version_of(text: &str) -> Option<Version> {
    let v = text.split_whitespace().last()?.trim_start_matches('v');
    let mut n = v.split('.').map(str::parse::<u64>);
    Some(Version::new(
        n.next()?.ok()?,
        n.next()?.ok()?,
        n.next()?.ok()?,
    ))
}

/// Which release is wanted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    /// The latest one, which is never a downgrade.
    Latest,
    /// One the person named: going back to it, or to an older one, is what they asked for.
    Pinned,
}

/// What to do about a downloaded, checked release.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Step {
    /// Put it in place.
    Install,
    /// It is older than this program: never a downgrade.
    Older,
}

/// `have` is this program's version and `got` what the release says it is. A release that will
/// not say is still installed: it was checked against the sums.
#[must_use]
pub(super) fn decide(have: Version, got: Option<Version>, target: Target) -> Step {
    match got {
        Some(g) if g < have && target == Target::Latest => Step::Older,
        _ => Step::Install,
    }
}

/// The `0.1.37` in what `--version` printed, when it says one.
pub(super) fn named_version(said: &str) -> Option<&str> {
    let said = said.trim();
    version_of(said)?;
    Some(said.strip_prefix("herdr-tui ").unwrap_or(said))
}

/// The base URL releases are fetched from: a mirror, else the release named (`0.1.30` or
/// `v0.1.30`), else the latest.
#[must_use]
pub fn base_url(env: impl Fn(&str) -> Option<String>, version: Option<&str>) -> String {
    if let Some(b) = env("HERDR_TUI_BASE_URL")
        .map(|b| b.trim_end_matches('/').to_string())
        .filter(|b| !b.is_empty())
    {
        return b;
    }
    match version {
        Some(v) => format!("{RELEASES}/v{}", v.trim_start_matches('v')),
        None => LATEST.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SUM_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const SUM_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    #[test]
    fn every_platform_the_release_builds_has_its_file_and_the_rest_none() {
        assert_eq!(asset_for("linux", "x86_64"), Some("herdr-tui-linux-x86_64"));
        assert_eq!(
            asset_for("linux", "aarch64"),
            Some("herdr-tui-linux-aarch64")
        );
        assert_eq!(asset_for("macos", "aarch64"), Some("herdr-tui-macos-arm64"));
        assert_eq!(asset_for("macos", "x86_64"), Some("herdr-tui-macos-x86_64"));
        assert_eq!(asset_for("windows", "x86_64"), None);
        assert_eq!(asset_for("linux", "riscv64"), None);
    }

    /// The file names in the lines of `text` that carry `marker` (`asset: herdr-tui-linux-x86_64 }`
    /// in the workflow, `asset=herdr-tui-linux-x86_64 ;;` in the script), sorted.
    fn names_after(text: &str, marker: &str) -> Vec<String> {
        let mut names: Vec<String> = text
            .lines()
            .filter_map(|l| l.split_once(marker))
            .filter_map(|(_, rest)| {
                rest.split(|c: char| c.is_whitespace() || matches!(c, ',' | '}' | ';' | '"'))
                    .next()
            })
            .filter(|n| n.starts_with("herdr-tui-"))
            .map(str::to_string)
            .collect();
        names.sort();
        names.dedup();
        names
    }

    /// Every `herdr-tui` out there asks for these files by name and can only update itself while
    /// they exist, so the three places that name them must agree.
    #[test]
    fn the_files_this_client_asks_for_are_the_ones_the_release_builds_and_the_script_installs() {
        let mut ours: Vec<String> = [
            ("linux", "x86_64"),
            ("linux", "aarch64"),
            ("macos", "aarch64"),
            ("macos", "x86_64"),
        ]
        .iter()
        .map(|(os, arch)| {
            asset_for(os, arch)
                .expect("a platform the release builds")
                .to_string()
        })
        .collect();
        ours.sort();
        let workflow = include_str!("../../../../../.github/workflows/release.yml");
        let script = include_str!("../../../../../tool/install-tui.sh");
        assert_eq!(
            names_after(workflow, "asset: "),
            ours,
            "release.yml builds other files than this client asks for"
        );
        assert_eq!(
            names_after(script, "asset="),
            ours,
            "tool/install-tui.sh installs other files than this client asks for"
        );
        for (what, text) in [("release.yml", workflow), ("tool/install-tui.sh", script)] {
            assert!(
                text.contains(SUMS),
                "{what} does not use the checksums file {SUMS}"
            );
        }
    }

    #[test]
    fn the_sum_of_a_file_is_found_by_its_exact_name_in_either_format() {
        let sums = format!("{SUM_A}  herdr-tui-linux-x86_64\n{SUM_B} *herdr-tui-macos-arm64\nnot a sum  herdr-tui-linux-aarch64\n");
        assert_eq!(
            wanted_sum(&sums, "herdr-tui-linux-x86_64").as_deref(),
            Some(SUM_A)
        );
        assert_eq!(
            wanted_sum(&sums, "herdr-tui-macos-arm64").as_deref(),
            Some(SUM_B)
        );
        assert_eq!(wanted_sum(&sums, "herdr-tui-linux-aarch64"), None);
        assert_eq!(wanted_sum(&sums, "herdr-tui-linux"), None);
    }

    #[test]
    fn a_version_is_read_from_what_the_program_prints() {
        assert_eq!(
            version_of("herdr-tui 0.1.37\n"),
            Some(Version::new(0, 1, 37))
        );
        assert_eq!(version_of("0.1.9"), Some(Version::new(0, 1, 9)));
        assert_eq!(version_of("herdr-tui nightly"), None);
        assert!(version_of("herdr-tui 0.1.10") > version_of("herdr-tui 0.1.9"));
    }

    #[test]
    fn a_newer_release_installs_and_an_older_one_never_does_unless_it_was_named() {
        let have = Version::new(0, 1, 37);
        assert_eq!(
            decide(have, Some(Version::new(0, 1, 38)), Target::Latest),
            Step::Install
        );
        assert_eq!(
            decide(have, Some(Version::new(0, 1, 30)), Target::Latest),
            Step::Older
        );
        // Asked for by name, an older release is installed: that is how a person goes back.
        assert_eq!(
            decide(have, Some(Version::new(0, 1, 30)), Target::Pinned),
            Step::Install
        );
        // A local build of this very version is replaced by the release's.
        assert_eq!(decide(have, Some(have), Target::Latest), Step::Install);
        // A download that will not say its version is still checked and installed.
        assert_eq!(decide(have, None, Target::Latest), Step::Install);
    }

    #[test]
    fn a_mirror_replaces_the_release_and_a_blank_one_does_not() {
        assert_eq!(base_url(|_| None, None), LATEST);
        assert_eq!(base_url(|_| Some(String::new()), None), LATEST);
        assert_eq!(base_url(|_| Some("file:///r/".into()), None), "file:///r");
        assert_eq!(
            base_url(|_| Some("file:///r/".into()), Some("0.1.30")),
            "file:///r"
        );
        assert_eq!(
            base_url(|_| None, Some("0.1.30")),
            format!("{RELEASES}/v0.1.30")
        );
        assert_eq!(
            base_url(|_| None, Some("v0.1.30")),
            base_url(|_| None, Some("0.1.30"))
        );
    }
}
