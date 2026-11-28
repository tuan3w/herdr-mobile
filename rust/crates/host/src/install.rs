//! Housekeeping of `~/.herdr-mobile/bin/`: the app installs one binary per app
//! version (`herdr-host-<version>`), so old ones pile up. `serve` keeps the
//! newest few and removes the rest. A running keeper keeps its own copy open,
//! so removing a file never stops one.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// How many installed versions stay: the one running, and the ones a second
/// phone with another app version may still want.
pub const KEEP: usize = 3;

/// Removes all but the [`KEEP`] most recently modified `herdr-host-*` files of
/// `<home>/.herdr-mobile/bin`, never the running binary. Best effort: errors
/// are ignored, because failing to tidy must not fail a session.
pub fn prune_old_versions(home: &Path) {
    let me = std::env::current_exe().ok();
    prune_dir(&home.join(".herdr-mobile/bin"), me.as_deref(), KEEP);
}

pub(crate) fn prune_dir(dir: &Path, running: Option<&Path>, keep: usize) {
    // `current_exe()` is canonical; `dir` is reached through `$HOME`, which may
    // be a link. Compare canonical paths, or the running binary is not
    // recognised and gets deleted.
    let Ok(dir) = dir.canonicalize() else {
        return;
    };
    let running = running.and_then(|p| p.canonicalize().ok());
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return;
    };
    let mut found: Vec<(SystemTime, PathBuf)> = entries
        .filter_map(Result::ok)
        .filter(|e| e.file_name().to_string_lossy().starts_with("herdr-host-"))
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
        .collect();
    found.sort_by_key(|(modified, _)| std::cmp::Reverse(*modified));
    for (_, path) in found.into_iter().skip(keep) {
        if running.as_deref().is_some_and(|me| me == path) {
            continue;
        }
        let _ = std::fs::remove_file(path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn touch(dir: &Path, name: &str, age_secs: u64) {
        let path = dir.join(name);
        std::fs::write(&path, "x").expect("write");
        let when = SystemTime::now() - Duration::from_secs(age_secs);
        std::fs::File::options()
            .write(true)
            .open(&path)
            .expect("open")
            .set_modified(when)
            .expect("set mtime");
    }

    #[test]
    fn the_newest_few_stay_and_nothing_else_is_touched() {
        let dir = tempfile::tempdir().expect("tempdir");
        for (i, v) in ["0.1.60", "0.1.61", "0.1.62", "0.1.63", "0.1.64"]
            .iter()
            .enumerate()
        {
            touch(
                dir.path(),
                &format!("herdr-host-{v}"),
                1000 - (i as u64) * 100,
            );
        }
        touch(dir.path(), "herdr-tui", 5000);
        prune_dir(dir.path(), None, 3);
        let mut left: Vec<String> = std::fs::read_dir(dir.path())
            .expect("read")
            .map(|e| e.expect("entry").file_name().to_string_lossy().into_owned())
            .collect();
        left.sort();
        assert_eq!(
            left,
            [
                "herdr-host-0.1.62",
                "herdr-host-0.1.63",
                "herdr-host-0.1.64",
                "herdr-tui"
            ]
        );
    }

    #[test]
    fn the_running_binary_is_never_removed_even_when_it_is_the_oldest() {
        let dir = tempfile::tempdir().expect("tempdir");
        touch(dir.path(), "herdr-host-0.1.1", 9000);
        for (i, v) in ["0.1.2", "0.1.3", "0.1.4"].iter().enumerate() {
            touch(
                dir.path(),
                &format!("herdr-host-{v}"),
                100 - (i as u64) * 10,
            );
        }
        let me = dir.path().join("herdr-host-0.1.1");
        prune_dir(dir.path(), Some(&me), 3);
        assert!(me.exists());
    }

    /// `current_exe()` is canonical, but the folder is reached through `$HOME`,
    /// which may be a link (a home on another disk): the comparison used to
    /// miss, and every start deleted the binary it was running.
    #[test]
    fn the_running_binary_survives_when_home_is_reached_through_a_link() {
        let root = tempfile::tempdir().expect("tempdir");
        let real = root.path().join("real-home");
        std::fs::create_dir(&real).expect("real home");
        let fake = root.path().join("fake-home");
        std::os::unix::fs::symlink(&real, &fake).expect("link");
        touch(&real, "herdr-host-0.1.1", 9000);
        for (i, v) in ["0.1.2", "0.1.3", "0.1.4"].iter().enumerate() {
            touch(&real, &format!("herdr-host-{v}"), 100 - (i as u64) * 10);
        }
        let running = real
            .canonicalize()
            .expect("canonical")
            .join("herdr-host-0.1.1");
        prune_dir(&fake, Some(&running), 3);
        assert!(running.exists(), "the running binary was removed");
        assert!(real.join("herdr-host-0.1.4").exists());
    }

    #[test]
    fn a_missing_folder_is_not_an_error() {
        prune_dir(Path::new("/nonexistent/herdr-mobile-test"), None, 3);
    }
}
