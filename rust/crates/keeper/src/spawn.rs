//! The host-side plumbing the daemon and the commands share: spawning the
//! agent in its own process group (so a `kill` takes the tree), the daemon's
//! socket, and the group `kill`. Ported from the python `spawn`/`claim`/`kill`
//! (`keeper_script.dart` 1412-1434, 1389-1409, 3049-3076).
//!
//! No `unsafe` here: the one module that has it is [`crate::fds`], which the
//! agent's spawn calls to close the descriptors it must not inherit. The
//! daemon is detached by spawning it as its own process group (a reparented
//! child), not by `fork`.

use crate::records::StateDir;
use crate::routes::Route;
use crate::search;
use std::io::{self, Read};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

/// The agent's line cap (python `MAX_AGENT_LINE` `:66`).
pub const MAX_AGENT_LINE: usize = 64 * 1024 * 1024;
/// A client's line cap (python `MAX_CLIENT_LINE` `:65`).
pub const MAX_CLIENT_LINE: usize = 32 * 1024 * 1024;
/// How long a connection may go without a first valid line before the daemon closes it (python
/// `tick` `:2644`). A client that has sent one valid line is never idle-closed: an attached phone
/// is silent for a whole agent turn and still wants the update when it lands.
pub const IDLE_CLIENT: Duration = Duration::from_secs(30);

/// The environment variable that overrides [`IDLE_CLIENT`] with milliseconds. Tests set it so the
/// sweep can be observed without waiting 30 s; nothing in the product sets it.
pub const IDLE_CLIENT_ENV: &str = "HERDR_KEEPER_IDLE_MS";

/// [`IDLE_CLIENT`], or the override in [`IDLE_CLIENT_ENV`] when it holds a number of milliseconds.
#[must_use]
pub fn idle_client() -> Duration {
    std::env::var(IDLE_CLIENT_ENV)
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .map_or(IDLE_CLIENT, Duration::from_millis)
}

/// The event loop's nap when nothing is ready.
pub const TICK: Duration = Duration::from_millis(250);
/// The unix socket's backlog (python `claim` `:1401`).
pub const SOCKET_BACKLOG: u32 = 16;

/// Reap a finished child without blocking. The starter spawns the daemon as
/// its own child; when the daemon dies on a failed start it becomes a zombie,
/// and a zombie still answers `kill -0` (so it reads as "alive" and the
/// starter would poll forever). Waiting on it removes the zombie.
pub fn reap(pid: u32) {
    let Ok(raw) = i32::try_from(pid) else {
        return;
    };
    let Some(p) = rustix::process::Pid::from_raw(raw) else {
        return;
    };
    let _ = rustix::process::waitpid(Some(p), rustix::process::WaitOptions::NOHANG);
}

/// The agent, in its own process group (so a `kill` takes the tree), with the
/// host's PATH plus the usual extra bins. It inherits the daemon's default
/// signal handling, so it dies on a terminal close like a typed program would.
///
/// # Errors
/// When the agent is not installed, or cannot be spawned.
pub fn spawn_agent(route: &Route, cwd: &Path) -> io::Result<Child> {
    let home = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_default();
    let path_env = std::env::var("PATH").unwrap_or_default();
    let dirs = search::dirs(&path_env, &home);
    let Some(argv) = search::resolve(route, &dirs) else {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("{} is not installed on this host", route.label),
        ));
    };
    let (path, rest) = argv.split_first().expect("resolve gives at least a binary");
    let mut env_path = dirs
        .iter()
        .map(|p| p.to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join(":");
    if let Some(existing) = std::env::var_os("PATH") {
        env_path = format!("{env_path}:{}", existing.to_string_lossy());
    }
    let mut cmd = Command::new(path);
    cmd.args(rest)
        .current_dir(cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("PATH", env_path)
        // The daemon is a group leader; the agent joins its group so a
        // `kill` of the daemon's group takes the agent too.
        .process_group(i32::try_from(std::process::id()).unwrap_or(0));
    // Nothing the keeper's starter left open reaches the agent.
    crate::fds::close_inherited(&mut cmd, crate::fds::Strategy::from_env());
    cmd.spawn()
}

/// The agent for a `history` list: its own process group (so
/// [`kill_group`] takes the whole tree), no terminal, `stderr` to the void —
/// a brief conversation, torn down by the caller.
pub fn spawn_history_agent(route: &Route, cwd: &Path) -> io::Result<Child> {
    let home = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_default();
    let path_env = std::env::var("PATH").unwrap_or_default();
    let dirs = search::dirs(&path_env, &home);
    let Some(argv) = search::resolve(route, &dirs) else {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!(
                "{} is not installed on this host (looked for {}{})",
                route.id,
                route.binary,
                if route.npx.is_some() { " or npx" } else { "" }
            ),
        ));
    };
    let (path, rest) = argv.split_first().expect("resolve gives at least a binary");
    let mut env_path = dirs
        .iter()
        .map(|p| p.to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join(":");
    if let Some(existing) = std::env::var_os("PATH") {
        env_path = format!("{env_path}:{}", existing.to_string_lossy());
    }
    let mut cmd = Command::new(path);
    cmd.args(rest)
        .current_dir(cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .env("PATH", &env_path)
        .process_group(0);
    crate::fds::close_inherited(&mut cmd, crate::fds::Strategy::from_env());
    cmd.spawn()
}

/// The daemon's socket: bound before the agent spawns (so `list` sees a
/// starting keeper), nonblocking, private. The daemon accepts on it only once
/// `initialize` is answered.
pub struct Listener {
    inner: UnixListener,
}

impl Listener {
    ///
    /// # Errors
    /// When the socket cannot be bound.
    pub fn bind(dir: &StateDir, id: &str) -> io::Result<Listener> {
        let path = dir.path(id, "sock");
        let _ = std::fs::remove_file(&path);
        let inner = UnixListener::bind(&path)?;
        inner.set_nonblocking(true)?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        Ok(Listener { inner })
    }

    /// One new client, or `None` when none is ready (the loop naps).
    #[must_use]
    pub fn accept(&self) -> Option<std::os::unix::net::UnixStream> {
        match self.inner.accept() {
            Ok((s, _)) => Some(s),
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                ) =>
            {
                None
            }
            Err(_) => None,
        }
    }
}

/// The keeper's diagnostic log file: created at start, private (python `:330`
/// opens `.json`, `.sock` and `.log` all 0600). The daemon's `dlog` writes to
/// it; `session/load` reads the in-memory log, never this file.
pub fn open_log(dir: &StateDir, id: &str) -> Option<std::io::BufWriter<std::fs::File>> {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.path(id, "log");
    let file = std::fs::File::options()
        .create(true)
        .append(true)
        .open(&path)
        .ok()?;
    let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    Some(std::io::BufWriter::new(file))
}
/// A `kill`: SIGTERM the process group (the daemon's, which reaps the agent).
pub fn kill_group(pid: i32) {
    group_signal(pid, rustix::process::Signal::Term);
}

/// SIGKILL the group: what a `kill` does after the grace.
pub fn kill_group_hard(pid: i32) {
    group_signal(pid, rustix::process::Signal::Kill);
}

fn group_signal(pid: i32, sig: rustix::process::Signal) {
    if pid <= 0 {
        return;
    }
    // The `kill` binary on some hosts (procps-ng 4.0.4) refuses the negative
    // process-group form and exits 1 without signalling; the syscall always
    // works. `kill_process_group` negates the pid for us.
    let Some(p) = rustix::process::Pid::from_raw(pid) else {
        return;
    };
    let _ = rustix::process::kill_process_group(p, sig);
}

/// 6 random bytes, hex: the log's generation tag (python `epoch` `:1337`).
#[must_use]
pub fn epoch() -> String {
    let mut b = [0u8; 6];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut b);
    }
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Spawn the daemon as a detached child in its own process group. Returns
/// the child's PID. The daemon writes its record to disk; the caller polls
/// for it. `no_pane` sets `HERDR_MOBILE_NO_PANE=1` for the daemon: the
/// client that started it is itself the pane, so no second herdr tab opens.
pub fn spawn_daemon(
    self_path: &std::path::Path,
    id: &str,
    agent: &str,
    cwd: &std::path::Path,
    no_pane: bool,
) -> io::Result<u32> {
    let mut command = Command::new(self_path);
    command
        .args(["keeper-daemon", "--agent", agent, "--cwd"])
        .arg(cwd)
        .env("HERDR_KEEPER_ID", id);
    if no_pane {
        command.env("HERDR_MOBILE_NO_PANE", "1");
    }
    let child = command
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    Ok(child.id())
}
