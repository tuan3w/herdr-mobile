//! The keeper's commands as library calls: what `herdr-host start/list/kill/
//! probe/attach` do, without printing or exiting. The command line
//! (`herdr-host`'s `main.rs`) prints their results; `herdr-host serve` answers
//! the app with them.
//!
//! Every failure carries the exit code the command line ends with
//! ([`crate::exit`]) and the sentence it prints, so both callers say the same
//! thing.

use crate::records::{is_valid_id, random_id, Info, Liveness, State, StateDir, System};
use crate::{exit, launchd, routes, search, spawn};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// The grace a `kill` gives the keeper's process group before SIGKILL.
const KILL_GRACE: Duration = Duration::from_secs(2);

/// The machine the commands run on: whose home holds `.herdr-mobile`, and
/// where agents are looked for.
#[derive(Clone, Debug, Default)]
pub struct Env {
    pub home: PathBuf,
    /// The `PATH` agents are searched in (the usual extra bins are added).
    pub path: String,
}

impl Env {
    /// `$HOME` and `$PATH` of this process; empty when unset.
    #[must_use]
    pub fn from_process() -> Env {
        Env {
            home: std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_default(),
            path: std::env::var("PATH").unwrap_or_default(),
        }
    }

    fn state_dir(&self, command: &str) -> Result<StateDir, CtlError> {
        if self.home.as_os_str().is_empty() {
            return Err(CtlError::new(exit::USAGE, format!("{command} needs $HOME")));
        }
        StateDir::create(&self.home).map_err(|e| CtlError::new(exit::USAGE, e.to_string()))
    }

    /// `~` and `~/x` expanded to the home folder.
    fn expand_tilde(&self, p: &str) -> PathBuf {
        if !self.home.as_os_str().is_empty() {
            if p == "~" {
                return self.home.clone();
            }
            if let Some(rest) = p.strip_prefix("~/") {
                return self.home.join(rest);
            }
        }
        PathBuf::from(p)
    }
}

/// Why a command failed: the exit code the command line ends with and the
/// sentence it prints after `herdr-mobile: `.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CtlError {
    /// One of [`crate::exit`].
    pub code: i32,
    pub message: String,
}

impl CtlError {
    #[must_use]
    pub fn new(code: i32, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

impl std::fmt::Display for CtlError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for CtlError {}

/// What `start` needs: an agent id and the folder it runs in (`~` allowed).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StartRequest {
    pub agent: String,
    pub cwd: String,
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

/// The ids of the routes whose binary (or npx) this host can run.
#[must_use]
pub fn probe(env: &Env) -> Vec<String> {
    let dirs = search::dirs(&env.path, &env.home);
    routes::all()
        .into_iter()
        .filter(|r| search::resolve(r, &dirs).is_some())
        .map(|r| r.id)
        .collect()
}

/// Every keeper on disk, newest first; stale ones are marked exited.
///
/// # Errors
/// Exit 64 when there is no home or the state folder cannot be made.
pub fn list(env: &Env) -> Result<Vec<Info>, CtlError> {
    let dir = env.state_dir("list")?;
    Ok(dir.scan(now_ms(), &System))
}

/// [`start_with`] for a daemon that may open its own herdr pane.
///
/// # Errors
/// As [`start_with`].
pub fn start(env: &Env, req: &StartRequest) -> Result<Info, CtlError> {
    start_with(env, req, false)
}

/// Spawns a detached daemon and waits for its record to say `running`.
/// `no_pane` is for a client that is itself the pane (the terminal client):
/// the daemon gets `HERDR_MOBILE_NO_PANE=1` and never opens a herdr tab.
///
/// # Errors
/// Exit 64 for an unknown agent, 66 when the folder is missing, 69 when the
/// agent is not installed, 70 when the keeper could not start (the sentence
/// holds the agent's own stderr when it wrote any).
pub fn start_with(env: &Env, req: &StartRequest, no_pane: bool) -> Result<Info, CtlError> {
    if env.home.as_os_str().is_empty() {
        return Err(CtlError::new(exit::USAGE, "start needs $HOME"));
    }
    let Some(route) = routes::by_id(&req.agent) else {
        return Err(CtlError::new(
            exit::USAGE,
            format!("unknown agent {}", req.agent),
        ));
    };
    let cwd = env.expand_tilde(&req.cwd);
    if !cwd.is_dir() {
        return Err(CtlError::new(
            exit::GONE,
            format!("the folder does not exist on this host: {}", cwd.display()),
        ));
    }
    let dirs = search::dirs(&env.path, &env.home);
    if search::resolve(&route, &dirs).is_none() {
        return Err(CtlError::new(
            exit::MISSING,
            format!("{} is not installed on this host", route.label),
        ));
    }
    let dir = env.state_dir("start")?;
    let id = random_id().map_err(|e| CtlError::new(exit::FAILED, e.to_string()))?;
    let self_path = std::env::current_exe().unwrap_or_default();
    // Claude Code on macOS is started as a job of the desktop session, which
    // can open the login Keychain; nothing else is (and off macOS nothing is).
    let mut job = launchd::try_start(dir.root(), &self_path, &id, &req.agent, &cwd, no_pane);
    let pid = if job.is_some() {
        // Not this process's child: there is no pid to reap.
        0
    } else {
        spawn::spawn_daemon(&self_path, &id, &req.agent, &cwd, no_pane)
            .map_err(|e| CtlError::new(exit::FAILED, e.to_string()))?
    };
    let started = wait_for_running(&dir, &id, pid, job.as_mut());
    if started.is_err() {
        if let Some(job) = &job {
            job.abandon();
        }
    }
    started
}

/// The daemon writes <id>.json (state=starting, pid) at once, then flips it
/// to running when the agent's `initialize` is answered. Polls for the record,
/// then for the ready state. `job` is the launchd job that runs the daemon, if
/// it is one: its end without a record is a failed start too.
fn wait_for_running(
    dir: &StateDir,
    id: &str,
    pid: u32,
    mut job: Option<&mut launchd::Job>,
) -> Result<Info, CtlError> {
    let deadline = Instant::now() + crate::records::INIT_TIMEOUT;
    while Instant::now() < deadline {
        if let Some(info) = dir.read(id) {
            if info.state == State::Running {
                reap_on_exit(pid);
                return Ok(info);
            }
            if info.state == State::Exited {
                // The agent refused `initialize`: report the reason and leave
                // nothing behind.
                return Err(fail_start(dir, id, pid, "the agent failed to start"));
            }
            // Still starting: is the daemon alive? It is our child; a dead one
            // is a zombie that still answers `kill -0`, so reap it first
            // (`NOHANG` is a no-op while it runs).
            spawn::reap(pid);
            if info
                .pid
                .is_none_or(|p| !crate::records::System.pid_alive(p))
            {
                return Err(fail_start(dir, id, pid, "the agent failed to start"));
            }
        } else if job.as_mut().is_some_and(|j| j.ended()) {
            return Err(fail_start(
                dir,
                id,
                pid,
                "the keeper did not start (its job ended without an answer)",
            ));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Err(fail_start(dir, id, pid, "the keeper did not start in time"))
}

/// A failed start: the reason (the agent's stderr, when the daemon wrote it),
/// nothing left on disk, exit 70. The daemon is already dead; reaping it
/// removes the zombie so a later `list` does not see it.
fn fail_start(dir: &StateDir, id: &str, pid: u32, base: &str) -> CtlError {
    spawn::reap(pid);
    let reason = std::fs::read_to_string(dir.path(id, "err")).unwrap_or_default();
    let text = if reason.trim().is_empty() {
        base.to_string()
    } else {
        format!("{base}\n{reason}")
    };
    dir.remove(id);
    CtlError::new(exit::FAILED, text)
}

/// The daemon is this process's child: when it ends later (the agent exited,
/// a `kill`), nobody waits for it, and in a long-lived process (`serve`) it
/// would stay a zombie. A thread that waits for it costs nothing; in the
/// command line the process is gone by then.
fn reap_on_exit(pid: u32) {
    let Some(pid) = i32::try_from(pid)
        .ok()
        .and_then(rustix::process::Pid::from_raw)
    else {
        return;
    };
    let _ = std::thread::Builder::new()
        .name("reap-keeper".into())
        .stack_size(64 * 1024)
        .spawn(move || {
            let _ = rustix::process::waitpid(Some(pid), rustix::process::WaitOptions::empty());
        });
}

/// SIGTERM the daemon (its group takes the agent), then clean up. Takes the
/// 2 s grace before SIGKILL, whether or not the group is already gone.
///
/// # Errors
/// Exit 64 for an id that is not one, 66 when no such keeper exists.
pub fn kill(env: &Env, id: &str) -> Result<(), CtlError> {
    if !is_valid_id(id) {
        return Err(CtlError::new(
            exit::USAGE,
            format!("{id} is not a keeper id"),
        ));
    }
    let dir = env.state_dir("kill")?;
    let Some(info) = dir.read(id) else {
        return Err(no_such_keeper(id));
    };
    if let Some(pid) = info.pid {
        if crate::records::is_keeper_pid(pid) {
            spawn::kill_group(pid as i32);
            // Grace, then hard.
            std::thread::sleep(KILL_GRACE);
            spawn::kill_group_hard(pid as i32);
        }
    }
    dir.remove(id);
    Ok(())
}

/// The keeper's socket: lines of ACP both ways.
///
/// # Errors
/// Exit 66 when no such keeper exists, 70 while it is still starting, 67 when
/// its agent has exited (the sentence says why).
pub fn connect(env: &Env, id: &str) -> Result<UnixStream, CtlError> {
    let dir = env.state_dir("attach")?;
    // An id that cannot name a keeper is never joined onto a path.
    let info = if is_valid_id(id) { dir.read(id) } else { None };
    let Some(info) = info else {
        return Err(no_such_keeper(id));
    };
    dir.connect(id).map_err(|_| {
        // The socket is gone. A starting keeper has no socket yet; a dead
        // one's record is marked stale.
        if info.state == State::Starting
            && info
                .pid
                .is_some_and(|p| crate::records::System.pid_alive(p))
        {
            return CtlError::new(exit::FAILED, "the keeper is still starting");
        }
        let why = info
            .exit_reason
            .clone()
            .unwrap_or_else(|| "the agent has exited.".to_string());
        CtlError::new(exit::EXITED, format!("keeper {id}: {why}"))
    })
}

fn no_such_keeper(id: &str) -> CtlError {
    CtlError::new(exit::GONE, format!("no such keeper: {id}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env_in(home: &std::path::Path) -> Env {
        Env {
            home: home.to_path_buf(),
            path: String::new(),
        }
    }

    #[test]
    fn a_keeper_id_that_could_climb_out_of_the_state_folder_is_no_keeper() {
        let home = tempfile::tempdir().expect("home");
        let env = env_in(home.path());
        for id in ["../x", "a/b", "", "UPPER", "..", "x y"] {
            assert_eq!(
                connect(&env, id).err().map(|e| e.code),
                Some(exit::GONE),
                "{id:?}"
            );
        }
        assert_eq!(
            kill(&env, "../x").err().map(|e| e.code),
            Some(exit::USAGE),
            "kill refuses it before touching a file"
        );
    }

    #[test]
    fn nothing_is_asked_of_a_host_without_a_home() {
        let env = Env::default();
        assert_eq!(list(&env).err().map(|e| e.code), Some(exit::USAGE));
        let start_err = start(
            &env,
            &StartRequest {
                agent: "omp".into(),
                cwd: "/".into(),
            },
        )
        .err();
        assert_eq!(start_err.map(|e| e.code), Some(exit::USAGE));
    }

    #[test]
    fn start_says_which_of_its_preconditions_failed() {
        let home = tempfile::tempdir().expect("home");
        let env = env_in(home.path());
        let code = |agent: &str, cwd: &str| {
            start(
                &env,
                &StartRequest {
                    agent: agent.into(),
                    cwd: cwd.into(),
                },
            )
            .err()
            .map(|e| e.code)
        };
        assert_eq!(code("nope", "/tmp"), Some(exit::USAGE));
        assert_eq!(code("omp", "/definitely/not/here"), Some(exit::GONE));
        // `~` is expanded to the host's home: the folder it names is missing
        // there, so the answer is about the folder, not about the agent.
        assert_eq!(code("omp", "~/missing"), Some(exit::GONE));
    }

    #[test]
    fn a_stale_record_connects_as_an_exited_agent_with_its_reason() {
        let home = tempfile::tempdir().expect("home");
        let env = env_in(home.path());
        let dir = StateDir::create(home.path()).expect("dir");
        dir.write(&Info {
            id: "abc123".into(),
            state: State::Exited,
            exit_reason: Some("the agent ended.".into()),
            ..Info::default()
        })
        .expect("record");
        let err = connect(&env, "abc123").expect_err("an error");
        assert_eq!(err.code, exit::EXITED);
        assert!(err.message.contains("the agent ended."), "{err}");
    }
}
