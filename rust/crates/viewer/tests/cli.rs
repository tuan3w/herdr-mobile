//! `herdr-tui ls` and `kill` against an empty, private HOME, and the keeper the program carries:
//! a session started by `herdr-tui` runs as `herdr-tui keeper-daemon`, and nothing in its path
//! reaches for python.

use std::process::{Command, Output};

fn run(home: &std::path::Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_herdr-tui"))
        .args(args)
        .env_clear()
        .env("HOME", home)
        .env("PATH", "/usr/bin:/bin")
        .env("HERDR_MOBILE_NO_PANE", "1")
        .output()
        .expect("run herdr-tui")
}

#[test]
fn ls_on_a_machine_with_no_sessions_says_how_to_start() {
    let home = tempfile::tempdir().expect("tempdir");
    let out = run(home.path(), &["ls"]);
    assert!(out.status.success(), "{out:?}");
    assert!(String::from_utf8_lossy(&out.stdout).contains("Start one with `herdr-tui`"));
}

#[test]
fn killing_a_session_that_does_not_exist_fails_and_says_which() {
    let home = tempfile::tempdir().expect("tempdir");
    let out = run(home.path(), &["kill", "zzz999"]);
    assert!(!out.status.success(), "{out:?}");
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("zzz999"),
        "{out:?}"
    );
}

#[test]
fn kill_without_an_id_is_a_usage_error_not_a_bulk_kill() {
    let home = tempfile::tempdir().expect("tempdir");
    let out = run(home.path(), &["kill"]);
    assert_eq!(out.status.code(), Some(64), "{out:?}");
}

/// `update` against a folder standing in for a release: the installed file is a copy of the real
/// binary in a private folder, the "release" is a script that says its version.
mod update {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};

    /// The SHA-256 of `file` by `sha256sum`, else `shasum -a 256` (macOS has only the latter), the
    /// same order as `tool/install-host.sh`. Neither: the test fails.
    fn sha(file: &Path) -> String {
        let attempts: [(&str, &[&str]); 2] = [("sha256sum", &[]), ("shasum", &["-a", "256"])];
        for (program, args) in attempts {
            let Ok(out) = Command::new(program).args(args).arg(file).output() else {
                continue;
            };
            if !out.status.success() {
                continue;
            }
            if let Some(sum) = String::from_utf8_lossy(&out.stdout)
                .split_whitespace()
                .next()
            {
                return sum.to_string();
            }
        }
        panic!(
            "these tests need `sha256sum` or `shasum` on PATH to write the mirror's checksum file"
        );
    }

    struct Rig {
        _dir: tempfile::TempDir,
        installed: PathBuf,
        mirror: PathBuf,
        home: PathBuf,
    }

    /// `None` only where this platform has no release asset to stand in for. A missing `curl` or
    /// checksum tool FAILS: the update command needs them (as the installer does), and a test that
    /// returned early would pass without checking anything.
    fn rig(release_says: &str) -> Option<Rig> {
        assert!(
            Command::new("curl").arg("--version").output().is_ok(),
            "these tests need `curl` on PATH: the update command downloads from a file:// mirror with it"
        );
        let dir = tempfile::tempdir().expect("tempdir");
        let (bin, mirror, home) = (
            dir.path().join("bin"),
            dir.path().join("mirror"),
            dir.path().join("home"),
        );
        for d in [&bin, &mirror, &home] {
            std::fs::create_dir_all(d).expect("mkdir");
        }
        let installed = bin.join("herdr-tui");
        std::fs::copy(env!("CARGO_BIN_EXE_herdr-tui"), &installed).expect("copy");
        let asset = herdr_tui::update::asset()?;
        let file = mirror.join(asset);
        std::fs::write(
            &file,
            format!("#!/bin/sh\necho 'herdr-tui {release_says}' >&2\n"),
        )
        .expect("asset");
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        std::fs::write(
            mirror.join("herdr-tui-SHA256SUMS"),
            format!("{}  {asset}\n", sha(&file)),
        )
        .expect("sums");
        Some(Rig {
            _dir: dir,
            installed,
            mirror,
            home,
        })
    }

    fn update(r: &Rig, args: &[&str]) -> Output {
        Command::new(&r.installed)
            .arg("update")
            .args(args)
            .env_clear()
            .env("HOME", &r.home)
            .env("PATH", "/usr/bin:/bin")
            .env(
                "HERDR_TUI_BASE_URL",
                format!("file://{}", r.mirror.display()),
            )
            .output()
            .expect("run update")
    }

    fn version(file: &Path) -> String {
        let out = Command::new(file).arg("--version").output().expect("run");
        String::from_utf8_lossy(&out.stderr).trim().to_string()
    }

    #[test]
    fn a_newer_release_replaces_the_file_and_an_open_copy_is_not_needed() {
        let Some(r) = rig("99.0.0") else { return };
        let out = update(&r, &[]);
        assert!(out.status.success(), "{out:?}");
        assert_eq!(version(&r.installed), "herdr-tui 99.0.0");
        assert!(
            std::fs::read_dir(r.installed.parent().expect("a folder"))
                .expect("readable")
                .all(|e| {
                    let n = e.expect("an entry").file_name();
                    !n.to_string_lossy().starts_with(".herdr-tui-update")
                }),
            "nothing is left beside it"
        );
    }

    #[test]
    fn check_says_so_and_changes_nothing() {
        let Some(r) = rig("99.0.0") else { return };
        let before = version(&r.installed);
        let out = update(&r, &["--check"]);
        assert!(out.status.success(), "{out:?}");
        assert!(
            String::from_utf8_lossy(&out.stdout).contains("differs"),
            "{out:?}"
        );
        assert_eq!(version(&r.installed), before);
    }

    #[test]
    fn a_download_that_does_not_match_its_checksum_is_never_installed() {
        let Some(r) = rig("99.0.0") else { return };
        let before = version(&r.installed);
        let asset = herdr_tui::update::asset().expect("asset");
        std::fs::write(
            r.mirror.join(asset),
            "#!/bin/sh\necho 'herdr-tui 98.0.0' >&2\n",
        )
        .expect("tamper");
        let out = update(&r, &[]);
        assert!(!out.status.success(), "{out:?}");
        assert!(
            String::from_utf8_lossy(&out.stderr).contains("checksum mismatch"),
            "{out:?}"
        );
        assert_eq!(version(&r.installed), before);
    }

    #[test]
    fn the_latest_is_never_a_downgrade_but_a_named_version_is_installed_even_if_older() {
        let Some(r) = rig("0.0.1") else { return };
        let before = version(&r.installed);
        let out = update(&r, &[]);
        assert!(!out.status.success(), "{out:?}");
        assert!(
            String::from_utf8_lossy(&out.stderr).contains("older"),
            "{out:?}"
        );
        assert_eq!(version(&r.installed), before);
        // Asked for by name: the mirror stands in for that release.
        let out = update(&r, &["0.0.1"]);
        assert!(out.status.success(), "{out:?}");
        assert_eq!(version(&r.installed), "herdr-tui 0.0.1");
    }

    #[test]
    fn a_release_that_is_not_there_says_so_and_leaves_the_file_and_the_folder_alone() {
        let Some(r) = rig("99.0.0") else { return };
        let before = version(&r.installed);
        std::fs::remove_file(r.mirror.join("herdr-tui-SHA256SUMS")).expect("remove sums");
        let out = update(&r, &[]);
        assert!(!out.status.success(), "{out:?}");
        assert!(
            String::from_utf8_lossy(&out.stderr).contains("no such file"),
            "{out:?}"
        );
        assert_eq!(version(&r.installed), before);
        assert!(
            std::fs::read_dir(r.installed.parent().expect("a folder"))
                .expect("readable")
                .all(|e| !e
                    .expect("an entry")
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".herdr-tui-update")),
            "the scratch folder is removed on failure"
        );
    }
}

/// A real session, started by `herdr-tui` itself. The keeper is this binary (`keeper-daemon`) and
/// the agent is testkit's `fake-acp-agent`; a `python3` first on PATH that records itself and fails
/// guards the whole run: it stands in for "something reached for python".
mod session {
    use super::*;
    use keeper::records::{Liveness, State, StateDir};
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::process::Stdio;
    use std::time::{Duration, Instant};

    fn executable(path: &Path, text: &str) {
        std::fs::write(path, text).expect("write script");
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    }

    struct Machine {
        dir: tempfile::TempDir,
        home: PathBuf,
        cwd: PathBuf,
        path: String,
    }

    impl Machine {
        fn new() -> Machine {
            let dir = tempfile::tempdir().expect("tempdir");
            let (home, cwd) = (dir.path().join("home"), dir.path().join("proj"));
            let (stub, bin) = (dir.path().join("stub"), dir.path().join("bin"));
            for d in [&home, &cwd, &stub, &bin] {
                std::fs::create_dir_all(d).expect("mkdir");
            }
            executable(
                &bin.join("omp"),
                &format!(
                    "#!/bin/sh\nexec '{}' \"$@\"\n",
                    testkit::bin("fake-acp-agent").display()
                ),
            );
            executable(
                &stub.join("python3"),
                &format!(
                    "#!/bin/sh\necho \"$0 $*\" >> {}/python-used\nexit 99\n",
                    dir.path().display()
                ),
            );
            // Only the stub, the scripted agent and the system: the real PATH holds real agents.
            let path = format!("{}:{}:/usr/bin:/bin", stub.display(), bin.display());
            Machine {
                dir,
                home,
                cwd,
                path,
            }
        }

        fn command(&self, args: &[&str]) -> Command {
            let mut cmd = Command::new(env!("CARGO_BIN_EXE_herdr-tui"));
            cmd.args(args)
                .env_clear()
                .env("HOME", &self.home)
                .env("PATH", &self.path)
                .env("HERDR_MOBILE_NO_PANE", "1")
                .stdin(Stdio::null());
            cmd
        }

        fn python_was_used(&self) -> bool {
            self.dir.path().join("python-used").exists()
        }
    }

    /// Stops every keeper still recorded, by the pid its record holds, so a failing test leaves
    /// nothing running.
    impl Drop for Machine {
        fn drop(&mut self) {
            let Ok(dir) = StateDir::create(&self.home) else {
                return;
            };
            for info in dir.scan(0, &keeper::records::System) {
                if let Some(pid) = info.pid {
                    let _ = Command::new("kill").arg(pid.to_string()).status();
                }
            }
        }
    }

    /// Waits for `condition`, polling; a failed wait names what it waited for.
    fn wait_for(what: &str, mut condition: impl FnMut() -> bool) {
        let end = Instant::now() + Duration::from_secs(20);
        while !condition() {
            assert!(Instant::now() < end, "timed out waiting for {what}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    #[test]
    fn a_session_started_by_herdr_tui_is_its_own_keeper_daemon_and_python_is_never_run() {
        let m = Machine::new();
        // No terminal here: the screen cannot open, but the session was started first and
        // outlives the client.
        let cwd = m.cwd.to_string_lossy().into_owned();
        let _ = m
            .command(&["--agent", "omp", "--cwd", &cwd])
            .output()
            .expect("run herdr-tui");

        let dir = StateDir::create(&m.home).expect("state dir");
        let infos = dir.scan(0, &keeper::records::System);
        assert_eq!(infos.len(), 1, "one session was started: {infos:?}");
        let info = &infos[0];
        assert_eq!((info.agent.as_str(), info.state), ("omp", State::Running));

        // The daemon is this program, run as `herdr-tui keeper-daemon …`.
        let pid = info.pid.expect("a running keeper has a pid");
        // `/proc` where there is one, `ps` where there is not (macOS): the same two
        // ways the keeper's own pid check reads it.
        let cmdline = std::fs::read(format!("/proc/{pid}/cmdline"))
            .ok()
            .or_else(|| {
                Command::new("ps")
                    .args(["-o", "command=", "-p", &pid.to_string()])
                    .output()
                    .ok()
                    .map(|o| o.stdout)
            })
            .expect("the daemon is alive");
        let text = String::from_utf8_lossy(&cmdline).into_owned();
        let words: Vec<&str> = text
            .split(|c: char| c == '\0' || c.is_whitespace())
            .filter(|w| !w.is_empty())
            .collect();
        assert!(
            words.first().is_some_and(|w| w.ends_with("herdr-tui"))
                && words.get(1) == Some(&"keeper-daemon"),
            "{text:?}"
        );

        let ls = m.command(&["ls"]).output().expect("run ls");
        assert!(ls.status.success(), "{ls:?}");
        assert!(
            String::from_utf8_lossy(&ls.stdout).contains(&info.id),
            "{ls:?}"
        );

        let kill = m.command(&["kill", &info.id]).output().expect("run kill");
        assert!(kill.status.success(), "{kill:?}");
        assert_eq!(
            String::from_utf8_lossy(&kill.stdout).trim(),
            format!("ended {}", info.id)
        );
        wait_for("the keeper to be gone", || {
            !keeper::records::System.pid_alive(pid)
        });
        assert!(!m.python_was_used(), "something ran python3");
    }
}
