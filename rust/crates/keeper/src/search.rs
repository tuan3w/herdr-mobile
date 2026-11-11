//! Finding an agent on the host. A non-interactive SSH session has a poor
//! PATH, so the search also looks where agents are usually installed.

use crate::routes::Route;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// Directories to look in, in order, without duplicates: `$PATH`, then the usual
/// install places under `home`.
#[must_use]
pub fn dirs(path_env: &str, home: &Path) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = Vec::new();
    let mut add = |d: PathBuf| {
        if !d.as_os_str().is_empty() && d.is_dir() && !found.contains(&d) {
            found.push(d);
        }
    };
    for d in path_env.split(':') {
        add(PathBuf::from(d));
    }
    for d in [
        home.join(".local/bin"),
        home.join(".local/share/herdr-mobile/acp-adapters/node_modules/.bin"),
        home.join(".bun/bin"),
        home.join(".cargo/bin"),
        home.join(".npm-global/bin"),
        // Where the OpenCode and Kimi installers put their binary.
        home.join(".opencode/bin"),
        home.join(".kimi-code/bin"),
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/opt/homebrew/bin"),
    ] {
        add(d);
    }
    // Newest node first: `read_dir` order is not sorted.
    let mut nodes: Vec<PathBuf> = std::fs::read_dir(home.join(".nvm/versions/node"))
        .map(|rd| {
            rd.filter_map(Result::ok)
                .map(|e| e.path().join("bin"))
                .collect()
        })
        .unwrap_or_default();
    nodes.sort();
    nodes.reverse();
    for d in nodes {
        add(d);
    }
    found
}

/// The first executable file called `name` in `dirs`.
#[must_use]
pub fn which(name: &str, dirs: &[PathBuf]) -> Option<PathBuf> {
    dirs.iter().map(|d| d.join(name)).find(|p| {
        std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    })
}

/// The command that runs `route`: its binary with its arguments, else
/// `npx -y <package>` with the same arguments (`@github/copilot --acp --stdio`
/// needs them). `None` when the host has neither.
#[must_use]
pub fn resolve(route: &Route, dirs: &[PathBuf]) -> Option<Vec<String>> {
    if let Some(bin) = which(&route.binary, dirs) {
        let mut argv = vec![bin.to_string_lossy().into_owned()];
        argv.extend(route.args.iter().cloned());
        return Some(argv);
    }
    let pkg = route.npx.as_ref()?;
    let npx = which("npx", dirs)?;
    let mut argv = vec![
        npx.to_string_lossy().into_owned(),
        "-y".to_string(),
        pkg.clone(),
    ];
    argv.extend(route.args.iter().cloned());
    Some(argv)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::routes;

    fn executable(dir: &Path, name: &str) {
        let p = dir.join(name);
        std::fs::write(&p, "#!/bin/sh\n").expect("write a script");
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    }

    #[test]
    fn a_binary_wins_over_npx_and_keeps_its_arguments() {
        let bin = tempfile::tempdir().expect("tempdir");
        executable(bin.path(), "omp");
        executable(bin.path(), "npx");
        let dirs = vec![bin.path().to_path_buf()];
        let omp = resolve(&routes::by_id("omp").expect("omp"), &dirs).expect("found");
        assert!(omp[0].ends_with("/omp") && omp[1] == "acp");
        // codex-acp is not installed: npx runs its package.
        let codex = resolve(&routes::by_id("codex").expect("codex"), &dirs).expect("npx");
        assert_eq!(&codex[1..], ["-y", "@agentclientprotocol/codex-acp"]);
        // A route with arguments keeps them behind the package.
        let copilot = resolve(&routes::by_id("copilot").expect("copilot"), &dirs).expect("npx");
        assert_eq!(&copilot[1..], ["-y", "@github/copilot", "--acp", "--stdio"]);
    }

    #[test]
    fn nothing_found_is_none_and_a_plain_file_is_not_executable() {
        let bin = tempfile::tempdir().expect("tempdir");
        std::fs::write(bin.path().join("omp"), "x").expect("write");
        let dirs = vec![bin.path().to_path_buf()];
        assert_eq!(resolve(&routes::by_id("omp").expect("omp"), &dirs), None);
    }

    #[test]
    fn dirs_skips_missing_places_and_duplicates() {
        let home = tempfile::tempdir().expect("tempdir");
        std::fs::create_dir_all(home.path().join(".local/bin")).expect("mkdir");
        let found = dirs(
            &format!(
                "{0}/.local/bin:{0}/nope:{0}/.local/bin",
                home.path().display()
            ),
            home.path(),
        );
        // First, once; the missing directory is absent. (System places such as
        // /usr/local/bin may follow on a real host.)
        assert_eq!(found[0], home.path().join(".local/bin"));
        assert_eq!(
            found
                .iter()
                .filter(|d| **d == home.path().join(".local/bin"))
                .count(),
            1
        );
        assert!(!found.contains(&home.path().join("nope")));
    }
}
