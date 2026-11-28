//! The alert hook: a program the person provides, run when a session needs
//! them (a request is waiting) or has finished a turn nobody watched. Ported
//! from the python `hook`/`reap_hooks` (`keeper_script.dart` 2262-2300).
//!
//! The hook is `$HERDR_KEEPER_ON_BLOCKED`, else the executable
//! `~/.herdr-mobile/on-blocked`; none configured means nothing runs. It gets
//! `KEEPER_ID`, `KEEPER_AGENT`, `KEEPER_CWD`, `KEEPER_TITLE`, `KEEPER_EVENT`
//! (`blocked` or `done`) and `KEEPER_SUMMARY` on top of the keeper's
//! environment; the title and the summary are redacted
//! ([`crate::redact::redact_line`]). It runs in its own process group with no
//! terminal and no stdio, at most four at a time, and a hook still running
//! after five seconds is killed with its group. The daemon only starts it and
//! polls it on its tick, so a hook that hangs never holds the loop.

use crate::redact::redact_line;
use crate::spawn;
use std::ffi::OsStr;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// Hooks running at once; a fifth alert is dropped.
pub const MAX_RUNNING: usize = 4;
/// How long a hook may run before it is killed.
pub const HOOK_LIMIT: Duration = Duration::from_secs(5);

/// What an alert says, before redaction.
#[derive(Clone, Copy, Debug)]
pub struct Alert<'a> {
    pub id: &'a str,
    pub agent: &'a str,
    pub cwd: &'a str,
    pub title: &'a str,
    /// `blocked` or `done`.
    pub event: &'a str,
    pub summary: &'a str,
}

/// What [`Hooks::fire`] did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Fired {
    /// No hook is configured: nothing was started.
    NoHook,
    Started,
    /// Four are still running: this alert is dropped.
    TooMany,
    /// The hook could not be started; the reason, for the diagnostic log.
    Failed(String),
}

/// The hooks in flight.
#[derive(Debug)]
pub struct Hooks {
    running: Vec<Running>,
    limit: Duration,
}

#[derive(Debug)]
struct Running {
    child: Child,
    started: Instant,
    /// Already sent the SIGKILL: waiting for the process to be collected.
    killed: bool,
}

impl Hooks {
    /// `limit` is how long a hook may run ([`HOOK_LIMIT`] in the daemon).
    #[must_use]
    pub fn new(limit: Duration) -> Hooks {
        Hooks {
            running: Vec::new(),
            limit,
        }
    }

    /// Hooks started and not yet seen to have ended.
    #[must_use]
    pub fn running(&self) -> usize {
        self.running.len()
    }

    /// The hook to run: `configured` (`$HERDR_KEEPER_ON_BLOCKED`) when it is
    /// not empty, else `<home>/.herdr-mobile/on-blocked`; `None` unless that is
    /// a file the person can execute.
    #[must_use]
    pub fn hook_path(home: &Path, configured: Option<&OsStr>) -> Option<PathBuf> {
        let path = match configured {
            Some(p) if !p.is_empty() => PathBuf::from(p),
            _ => home.join(".herdr-mobile").join("on-blocked"),
        };
        let is_file = std::fs::metadata(&path).is_ok_and(|m| m.is_file());
        let executable = rustix::fs::access(&path, rustix::fs::Access::EXEC_OK).is_ok();
        (is_file && executable).then_some(path)
    }

    /// Starts the hook at `path` for `alert`; `None` is "no hook configured".
    pub fn fire(&mut self, path: Option<&Path>, alert: &Alert<'_>) -> Fired {
        let Some(path) = path else {
            return Fired::NoHook;
        };
        if self.running.len() >= MAX_RUNNING {
            return Fired::TooMany;
        }
        let mut cmd = Command::new(path);
        cmd.stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .env("KEEPER_ID", alert.id)
            .env("KEEPER_AGENT", alert.agent)
            .env("KEEPER_CWD", alert.cwd)
            .env("KEEPER_TITLE", redact_line(alert.title))
            .env("KEEPER_EVENT", alert.event)
            .env("KEEPER_SUMMARY", redact_line(alert.summary))
            // Its own group: the kill after the limit takes what it started.
            .process_group(0);
        crate::fds::close_inherited(&mut cmd, crate::fds::Strategy::from_env());
        match cmd.spawn() {
            Ok(child) => {
                self.running.push(Running {
                    child,
                    started: Instant::now(),
                    killed: false,
                });
                Fired::Started
            }
            Err(e) => Fired::Failed(e.to_string()),
        }
    }

    /// Reaps the hooks that ended and kills the ones past the limit. Returns
    /// the sentences for the diagnostic log. Never blocks.
    pub fn reap(&mut self) -> Vec<String> {
        let mut log = Vec::new();
        let limit = self.limit;
        self.running.retain_mut(|hook| {
            if hook.child.try_wait().ok().flatten().is_some() {
                return false;
            }
            if !hook.killed && hook.started.elapsed() > limit {
                // The group's SIGKILL: a later reap collects the child.
                if let Ok(pid) = i32::try_from(hook.child.id()) {
                    spawn::kill_group_hard(pid);
                }
                hook.killed = true;
                log.push(format!("alert hook killed after {} s", limit.as_secs()));
            }
            true
        });
        log
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn script(dir: &Path, name: &str, body: &str) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).expect("write the hook");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        path
    }

    fn alert<'a>(event: &'a str, summary: &'a str) -> Alert<'a> {
        Alert {
            id: "abc123",
            agent: "omp",
            cwd: "/work",
            title: "Fake title",
            event,
            summary,
        }
    }

    /// Reaps until nothing runs. Polls a condition; no fixed sleep stands in for work.
    fn drain(hooks: &mut Hooks) -> Vec<String> {
        let mut log = Vec::new();
        let end = Instant::now() + Duration::from_secs(20);
        while hooks.running() > 0 {
            assert!(Instant::now() < end, "hooks did not end");
            log.extend(hooks.reap());
            std::thread::sleep(Duration::from_millis(5));
        }
        log
    }

    #[test]
    fn no_hook_means_nothing_runs() {
        let home = tempfile::tempdir().expect("home");
        let mut hooks = Hooks::new(HOOK_LIMIT);
        assert_eq!(Hooks::hook_path(home.path(), None), None);
        assert_eq!(
            Hooks::hook_path(home.path(), Some(OsStr::new(""))),
            None,
            "an empty variable is no variable"
        );
        assert_eq!(hooks.fire(None, &alert("blocked", "x")), Fired::NoHook);
        assert_eq!(hooks.running(), 0);
    }

    #[test]
    fn the_default_hook_must_be_an_executable_file() {
        let home = tempfile::tempdir().expect("home");
        let base = home.path().join(".herdr-mobile");
        std::fs::create_dir_all(&base).expect("base");
        let path = base.join("on-blocked");
        std::fs::write(&path, "#!/bin/sh\n").expect("write");
        assert_eq!(
            Hooks::hook_path(home.path(), None),
            None,
            "not executable yet"
        );
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        assert_eq!(Hooks::hook_path(home.path(), None), Some(path.clone()));
        let other = script(home.path(), "mine", "");
        assert_eq!(
            Hooks::hook_path(home.path(), Some(other.as_os_str())),
            Some(other),
            "the variable wins over the default"
        );
        assert_eq!(
            Hooks::hook_path(home.path(), Some(OsStr::new("/definitely/not/here"))),
            None
        );
        assert_eq!(
            Hooks::hook_path(home.path(), Some(base.as_os_str())),
            None,
            "a folder is not a hook"
        );
    }

    #[test]
    fn the_hook_gets_the_keeper_environment_with_a_redacted_summary() {
        let dir = tempfile::tempdir().expect("dir");
        let out = dir.path().join("out");
        let hook = script(
            dir.path(),
            "hook",
            &format!(
                "printf '%s|%s|%s|%s|%s|%s' \"$KEEPER_EVENT\" \"$KEEPER_ID\" \"$KEEPER_AGENT\" \"$KEEPER_CWD\" \"$KEEPER_TITLE\" \"$KEEPER_SUMMARY\" > '{}'",
                out.display()
            ),
        );
        let mut hooks = Hooks::new(HOOK_LIMIT);
        let fired = hooks.fire(
            Some(&hook),
            &alert("blocked", "curl -H 'x' https://u:pw@x.io\nsecond line"),
        );
        assert_eq!(fired, Fired::Started);
        drain(&mut hooks);
        let text = std::fs::read_to_string(&out).expect("the hook ran");
        assert_eq!(
            text,
            "blocked|abc123|omp|/work|Fake title|curl -H 'x' https://***@x.io"
        );
    }

    #[test]
    fn four_run_at_once_and_a_fifth_is_dropped() {
        let dir = tempfile::tempdir().expect("dir");
        let hook = script(dir.path(), "slow", "exec sleep 30");
        // A long limit: the four stay up while the fifth is offered.
        let mut hooks = Hooks::new(Duration::from_secs(600));
        for n in 0..MAX_RUNNING {
            assert_eq!(
                hooks.fire(Some(&hook), &alert("blocked", "x")),
                Fired::Started,
                "hook {n}"
            );
        }
        assert_eq!(hooks.running(), MAX_RUNNING);
        assert_eq!(hooks.fire(Some(&hook), &alert("done", "x")), Fired::TooMany);
        assert_eq!(hooks.running(), MAX_RUNNING, "the fifth was not started");
        // Stop them: the same hooks under a short limit.
        hooks.limit = Duration::from_millis(1);
        let log = drain(&mut hooks);
        assert_eq!(log.len(), MAX_RUNNING, "{log:?}");
    }

    #[test]
    fn a_hook_that_hangs_is_killed_with_its_group_after_the_limit() {
        let dir = tempfile::tempdir().expect("dir");
        let pid_file = dir.path().join("pid");
        let hook = script(
            dir.path(),
            "hang",
            &format!("echo $$ > '{}'\nsleep 30 &\nwait", pid_file.display()),
        );
        let mut hooks = Hooks::new(Duration::from_millis(200));
        assert_eq!(
            hooks.fire(Some(&hook), &alert("blocked", "x")),
            Fired::Started
        );
        let log = drain(&mut hooks);
        assert_eq!(log.len(), 1, "{log:?}");
        assert!(log[0].starts_with("alert hook killed after"), "{log:?}");
        // The shell is gone (it was collected, so this is no zombie).
        let pid: i64 = std::fs::read_to_string(&pid_file)
            .expect("the hook wrote its pid")
            .trim()
            .parse()
            .expect("a pid");
        assert!(
            !crate::records::Liveness::pid_alive(&crate::records::System, pid),
            "the hook's process is gone"
        );
    }

    #[test]
    fn a_hook_that_cannot_be_started_says_why() {
        let dir = tempfile::tempdir().expect("dir");
        // Executable, but not a program the system can run (no interpreter).
        let path = dir.path().join("broken");
        std::fs::write(&path, "#!/definitely/not/an/interpreter\n").expect("write");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        let mut hooks = Hooks::new(HOOK_LIMIT);
        assert!(matches!(
            hooks.fire(Some(&path), &alert("done", "x")),
            Fired::Failed(_)
        ));
        assert_eq!(hooks.running(), 0);
    }
}
