//! The daemon: the event loop that owns the agent and its clients. One thread
//! for the logic, one reader thread per source (the agent's pipes, each
//! client) feeding one channel — the workspace's `mpsc` pattern, no async.
//! Each tick drains the channel, reaps the child, accepts new clients, and
//! naps for the rest of the 250 ms window (the python `run`/`tick`,
//! `keeper_script.dart` 2639-2678). The [`Router`] does the ACP logic; this
//! does the bytes.

use crate::alerts::{Alert, Fired, Hooks, HOOK_LIMIT};
use crate::launchd::{self, JobEnv};
use crate::linebuf::Lines;
use crate::pane::{self, Pane};
use crate::records::StateDir;
use crate::router::{AlertEvent, Out, Router};
use crate::routes::Route;
use crate::spawn::{self, Listener, MAX_AGENT_LINE, MAX_CLIENT_LINE, TICK};
use std::io::{self, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// One line of input, or a source going away.
enum Ev {
    AgentOut(String),
    AgentErr(String),
    Client(u64, String),
    ClientGone(u64),
    AgentGone,
}

/// The write end of a client's socket, kept so it lives with the conn.
struct Conn {
    id: u64,
    write: UnixStream,
    /// When it connected.
    born: Instant,
    /// Set by its first valid JSON-RPC line (python `conn.active`).
    active: bool,
}

/// The connections to close for being idle: those that connected more than `limit` ago and have
/// not sent one valid line. Active ones are never idle (python `tick` `:2644`), however long they
/// have been quiet.
fn never_active(conns: &[Conn], now: Instant, limit: Duration) -> Vec<u64> {
    conns
        .iter()
        .filter(|c| !c.active && now.duration_since(c.born) > limit)
        .map(|c| c.id)
        .collect()
}

/// What the daemon runs beside the agent: the alert hook, the herdr pane, and
/// the launchd job it may itself be. All of it is started and polled from the
/// loop's tick; nothing here blocks it.
struct Extras {
    home: PathBuf,
    hooks: Hooks,
    pane: Option<Pane>,
    job: Option<JobEnv>,
}

impl Extras {
    /// After the agent has answered `initialize`: opens the herdr pane, or logs
    /// why none is opened.
    fn open(
        home: &Path,
        job: Option<JobEnv>,
        route: &Route,
        id: &str,
        cwd: &Path,
        agent: &mut Router,
    ) -> Extras {
        let path_env = std::env::var("PATH").unwrap_or_default();
        let no_pane = std::env::var("HERDR_MOBILE_NO_PANE").ok();
        let herdr = std::env::var("HERDR_MOBILE_HERDR").ok();
        let located = pane::locate(&pane::Locate {
            home,
            path_env: &path_env,
            no_pane: no_pane.as_deref(),
            herdr: herdr.as_deref(),
        });
        let pane = match located {
            Ok(programs) => {
                let (pane, log) = Pane::open(programs, id, &cwd.to_string_lossy(), &route.label);
                for line in log {
                    agent.dlog(&line);
                }
                Some(pane)
            }
            Err(skip) => {
                agent.dlog(&skip.reason());
                None
            }
        };
        Extras {
            home: home.to_path_buf(),
            hooks: Hooks::new(HOOK_LIMIT),
            pane,
            job,
        }
    }

    /// One tick: starts the hook for each alert, reaps the hooks that ended
    /// (and kills the overdue), and advances the pane chain. True when the
    /// record changed (the chain learned the session's pane).
    fn tick(&mut self, agent: &mut Router, alerts: Vec<AlertEvent>) -> bool {
        if !alerts.is_empty() {
            let hook = Hooks::hook_path(
                &self.home,
                std::env::var_os("HERDR_KEEPER_ON_BLOCKED").as_deref(),
            );
            for event in alerts {
                let fired = self.hooks.fire(
                    hook.as_deref(),
                    &Alert {
                        id: &agent.id,
                        agent: &agent.agent,
                        cwd: &agent.cwd,
                        title: agent.title(),
                        event: event.event,
                        summary: &event.summary,
                    },
                );
                match fired {
                    Fired::Started | Fired::NoHook => {}
                    Fired::TooMany => agent.dlog("alert hook skipped: four are still running"),
                    Fired::Failed(e) => agent.dlog(&format!("alert hook failed to start: {e}")),
                }
            }
        }
        for line in self.hooks.reap() {
            agent.dlog(&line);
        }
        let mut changed = false;
        if let Some(pane) = self.pane.as_mut() {
            for line in pane.poll() {
                agent.dlog(&line);
            }
            if let Some(pid) = pane.take_pane_id() {
                if agent.info.pane_id.is_none() {
                    agent.info.pane_id = Some(pid);
                    changed = true;
                }
            }
        }
        changed
    }
}

/// A launchd job's process is not a group leader of its own making, and the
/// agent joins the daemon's group ([`spawn::spawn_agent`]): be one. The job
/// also starts with launchd's umask, not the login's; the agent gets the
/// login's back.
fn become_job(job: &JobEnv) {
    // Already a leader is fine: that is the answer when launchd made it one.
    let _ = rustix::process::setsid();
    if let Some(mask) = job.umask {
        let _ = rustix::process::umask(rustix::fs::Mode::from_bits_truncate(
            mask as rustix::fs::RawMode,
        ));
    }
}

/// A file only the person can read, for what the agent printed on its way out.
fn write_private(path: &Path, data: &[u8]) -> io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(data)
}

/// The daemon's whole life, in one process. Its return is the exit code.
pub fn run() -> i32 {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut agent = None;
    let mut cwd = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--agent" => {
                i += 1;
                agent = args.get(i).cloned();
            }
            "--cwd" => {
                i += 1;
                cwd = args.get(i).cloned();
            }
            _ => {}
        }
        i += 1;
    }
    let Some(agent_name) = agent else {
        eprintln!("herdr-host: the daemon needs --agent");
        return crate::exit::USAGE;
    };
    let Some(cwd_s) = cwd else {
        eprintln!("herdr-host: the daemon needs --cwd");
        return crate::exit::USAGE;
    };
    let Some(route) = crate::routes::by_id(&agent_name) else {
        eprintln!("herdr-host: unknown agent {agent_name}");
        return crate::exit::USAGE;
    };
    let cwd = PathBuf::from(cwd_s);
    let Some(id) = std::env::var("HERDR_KEEPER_ID")
        .ok()
        .filter(|s| crate::records::is_valid_id(s))
    else {
        eprintln!("herdr-host: the daemon needs HERDR_KEEPER_ID");
        return crate::exit::USAGE;
    };
    let Some(home) = std::env::var_os("HOME") else {
        eprintln!("herdr-host: the daemon needs $HOME");
        return crate::exit::USAGE;
    };
    let home = PathBuf::from(home);
    // A keeper that runs as a launchd job says so in its environment; the
    // variables are taken out of it so the agent never sees them.
    let job = launchd::take_job_env();
    if let Some(job) = &job {
        become_job(job);
    }
    let mut dir = match StateDir::create(&home) {
        Ok(d) => d,
        Err(e) => {
            return fail(
                crate::exit::FAILED,
                &format!("the keeper's folder cannot be made: {e}"),
            )
        }
    };
    if let Err(e) = dir.enter() {
        return fail(
            crate::exit::FAILED,
            &format!("the keeper's folder cannot be entered: {e}"),
        );
    }
    let listener = match Listener::bind(&dir, &id) {
        Ok(l) => l,
        Err(e) => {
            return fail(
                crate::exit::FAILED,
                &format!("the socket cannot be bound: {e}"),
            )
        }
    };
    // The diagnostic log is opened after the router exists (it is handed over).
    let mut child = match spawn::spawn_agent(&route, &cwd) {
        Ok(c) => c,
        Err(e) => return fail(crate::exit::MISSING, &e.to_string()),
    };
    let agent_pid = child.id();
    let mut agent_in = child.stdin.take().expect("the agent's stdin is piped");
    let agent_out_raw = child.stdout.take().expect("the agent's stdout is piped");
    let agent_err_raw = child.stderr.take().expect("the agent's stderr is piped");
    let (tx, rx) = mpsc::channel::<Ev>();
    // The agent's pipes are read from the very start: the handshake and the
    // loop both take their lines from this one channel.
    reader_threads(agent_out_raw, agent_err_raw, &tx);
    let mut conns: Vec<Conn> = Vec::new();
    let mut agent = Router::new(
        id.clone(),
        route.id.clone(),
        cwd.to_string_lossy().into_owned(),
        spawn::epoch(),
    );
    if let Some(w) = spawn::open_log(&dir, &id) {
        agent.set_diag(w);
    }
    agent
        .info
        .extra
        .insert("agent_pid".to_string(), serde_json::json!(agent_pid));
    if let Some(job) = &job {
        agent
            .info
            .extra
            .insert("launchd".to_string(), serde_json::json!(job.label));
    }
    if launchd::keychain_login(
        cfg!(target_os = "macos"),
        &route.id,
        job.is_some(),
        launchd::has_env_login(|k| std::env::var(k).ok()),
    ) {
        agent
            .info
            .extra
            .insert("login".to_string(), serde_json::json!("keychain"));
    }
    if let Err(e) = dir.write(&agent.info) {
        eprintln!("herdr-host: the record cannot be written: {e}");
    }

    // The agent's stderr, kept so a failed `initialize` can report the reason
    // (the python keeper's `err_tail`). Bounded: the last 20 lines.
    let err_tail: std::sync::Arc<std::sync::Mutex<Vec<String>>> =
        std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    if let Err(code) = handshake(&mut agent, &mut agent_in, &rx, &dir, &route, &err_tail) {
        // The agent refused `initialize`/`authenticate` (or left before
        // answering): the record must say so, and the formatted reason must
        // reach the starter — a separate process that only reads files — so it
        // goes to a sidecar next to the record.
        let death_code = child
            .try_wait()
            .ok()
            .flatten()
            .and_then(|s| s.code())
            .unwrap_or(0);
        let stage = if agent.auth_stage {
            "authenticate (sign-in)"
        } else {
            "initialize"
        };
        let reason = if let Some(r) = &agent.auth_reason {
            r.clone()
        } else if let Some(r) = &agent.init_reason {
            format!("the agent refused initialize: {r}")
        } else {
            format!("the agent exited (code {death_code}) before it answered {stage}")
        };
        {
            let tail = err_tail.lock().expect("the stderr tail is not poisoned");
            let text = tail.join("\n");
            let text = if text.is_empty() {
                reason
            } else {
                format!("{reason}\n{text}")
            };
            let _ = write_private(&dir.path(&agent.id, "err"), text.as_bytes());
        }
        let mut out = Out::default();
        agent.agent_exited(death_code, "the agent refused to start", &mut out);
        spawn::kill_group(i32::try_from(std::process::id()).unwrap_or(0));
        let _ = std::fs::remove_file(dir.path(&agent.id, "sock"));
        if let Err(e) = dir.write(&agent.info) {
            eprintln!("herdr-host: the record cannot be written: {e}");
        }
        if let Some(job) = &job {
            launchd::bootout(&job.label, false);
        }
        return code;
    }
    let sig = signal_flag();
    let idle_limit = spawn::idle_client();
    let mut extras = Extras::open(&home, job, &route, &id, &cwd, &mut agent);
    loop {
        // Wakes early when a line arrives; the event it returns is kept
        // (`first_event`), not dropped, and is drained with the rest below.
        let first_event = rx.recv_timeout(TICK).ok();
        // New clients.
        while let Some(stream) = listener.accept() {
            if conns.len() >= 16 {
                break;
            }
            // The listener is nonblocking (so `accept` never stalls the loop);
            // the socket it hands back inherits that flag, so set it blocking
            // — the reader thread and the writes block on it.
            if let Err(e) = stream.set_nonblocking(false) {
                eprintln!("herdr-host: a client socket cannot be made blocking: {e}");
                continue;
            }
            let read = stream.try_clone().expect("a socket can be cloned");
            let id = {
                let mut out = Out::default();
                let id = agent.add_client(&mut out);
                flush(&agent, &conns, &mut out, &mut agent_in, &dir);
                id
            };
            client_reader(read, id, &tx);
            conns.push(Conn {
                id,
                write: stream,
                born: Instant::now(),
                active: false,
            });
        }
        // The channel: the event that woke the nap (if any) first, then every
        // line that arrived since the last tick. `recv_timeout` returns the
        // first event early, so it is kept (`first_event`), not dropped. The
        // rest drain non-blocking (`try_recv`), so the loop never stalls on a
        // live channel.
        let mut out = Out::default();
        let mut agent_gone = false;
        let mut gone: Vec<u64> = Vec::new();
        for ev in first_event
            .into_iter()
            .chain(std::iter::from_fn(|| rx.try_recv().ok()))
        {
            match ev {
                Ev::AgentOut(line) => agent.on_agent_line(&line, &mut out),
                Ev::AgentErr(line) => {
                    let text = line.trim_end().to_string();
                    if !text.is_empty() {
                        let mut tail = err_tail.lock().expect("the stderr tail is not poisoned");
                        tail.push(crate::router::trunc(&text, 300));
                        if tail.len() > 20 {
                            tail.remove(0);
                        }
                        agent.dlog(&format!("agent: {text}"));
                    }
                }
                Ev::Client(id, line) => {
                    if agent.on_client_line(id, &line, &mut out) {
                        if let Some(c) = conns.iter_mut().find(|c| c.id == id) {
                            c.active = true;
                        }
                    }
                }
                Ev::ClientGone(id) => gone.push(id),
                Ev::AgentGone => agent_gone = true,
            }
        }
        for id in &gone {
            agent.drop_client(*id, &mut out);
        }
        // Connections that never sent a valid line within the limit go; an attached client that is
        // merely quiet (a long agent turn) stays until it closes.
        let idle = never_active(&conns, Instant::now(), idle_limit);
        for id in &idle {
            agent.drop_client(*id, &mut out);
        }
        for c in conns
            .iter()
            .filter(|c| idle.contains(&c.id) && !gone.contains(&c.id))
        {
            // Closing our handle is not enough: the reader thread holds a clone of the socket,
            // so the peer would see no EOF and the thread would block until the peer left.
            let _ = c.write.shutdown(std::net::Shutdown::Both);
        }
        conns.retain(|c| !idle.contains(&c.id) && !gone.contains(&c.id));
        let alerts = std::mem::take(&mut out.alerts);
        flush(&agent, &conns, &mut out, &mut agent_in, &dir);
        if extras.tick(&mut agent, alerts) {
            if let Err(e) = dir.write(&agent.info) {
                eprintln!("herdr-host: the record cannot be written: {e}");
            }
        }

        // A `kill` (SIGTERM/SIGINT) ends the daemon cleanly.
        if sig.load(std::sync::atomic::Ordering::Relaxed) {
            return finish(
                agent,
                &dir,
                &mut child,
                &mut conns,
                true,
                &err_tail,
                &mut extras,
            );
        }
        // The child. `agent_gone` is its stdout hitting EOF; `try_wait` would
        // reap it here, and then `finish`'s wait would see nothing — so the
        // exit status is read once, in `finish`.
        if agent_gone {
            return finish(
                agent,
                &dir,
                &mut child,
                &mut conns,
                false,
                &err_tail,
                &mut extras,
            );
        }
    }
}

/// One reader thread per pipe: it reads lines and sends them, then signals the
/// source is gone. The stdout reader also sends `AgentGone` when it ends.
fn reader_threads(
    out: std::process::ChildStdout,
    err: std::process::ChildStderr,
    tx: &mpsc::Sender<Ev>,
) {
    agent_reader(out, tx, true);
    agent_reader(err, tx, false);
}

fn agent_reader<R: io::Read + Send + 'static>(r: R, tx: &mpsc::Sender<Ev>, is_stdout: bool) {
    let tx = tx.clone();
    std::thread::spawn(move || {
        for line in Lines::new(io::BufReader::new(r), MAX_AGENT_LINE) {
            match line {
                Ok(l) => {
                    let ev = if is_stdout {
                        Ev::AgentOut(l)
                    } else {
                        Ev::AgentErr(l)
                    };
                    if tx.send(ev).is_err() {
                        return;
                    }
                }
                Err(_) => break,
            }
        }
        if is_stdout {
            let _ = tx.send(Ev::AgentGone);
        }
    });
}

/// The reader thread for one client's socket.
fn client_reader(stream: UnixStream, id: u64, tx: &mpsc::Sender<Ev>) {
    let tx = tx.clone();
    std::thread::spawn(move || {
        for line in Lines::new(io::BufReader::new(stream), MAX_CLIENT_LINE) {
            match line {
                Ok(l) => {
                    if tx.send(Ev::Client(id, l)).is_err() {
                        return;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = tx.send(Ev::ClientGone(id));
    });
}

/// The handshake: send `initialize`, read to the answer, and `authenticate`
/// when the route names a method the agent offers (python `run` +
/// `on_init_response` `:2304-2348`). Lines come from the agent's reader
/// thread, so nothing is lost between the handshake and the loop.
fn handshake(
    agent: &mut Router,
    agent_in: &mut ChildStdin,
    rx: &mpsc::Receiver<Ev>,
    dir: &StateDir,
    route: &Route,
    err_tail: &std::sync::Arc<std::sync::Mutex<Vec<String>>>,
) -> Result<(), i32> {
    if send(agent_in, &Router::init_request(Some(route))).is_err() {
        return Err(crate::exit::FAILED);
    }
    let deadline = Instant::now() + crate::records::INIT_TIMEOUT;
    let mut out = Out::default();
    while !out.ready && !out.failed {
        let Some(line) = next_agent_line(rx, deadline, err_tail) else {
            return Err(crate::exit::FAILED);
        };
        agent.on_agent_line(&line, &mut out);
    }
    if out.failed {
        return Err(crate::exit::FAILED);
    }
    if let (Some(auth), Some(init)) = (&route.auth, agent.init_result.as_ref()) {
        if offers_auth(init, auth) {
            if send(agent_in, &Router::auth_request(auth)).is_err() {
                return Err(crate::exit::FAILED);
            }
            agent.auth_stage = true;
            let mut out2 = Out::default();
            while !out2.ready && !out2.failed {
                let Some(line) = next_agent_line(rx, deadline, err_tail) else {
                    return Err(crate::exit::FAILED);
                };
                agent.on_agent_line(&line, &mut out2);
            }
            if out2.failed {
                return Err(crate::exit::FAILED);
            }
        }
    }
    if let Err(e) = dir.write(&agent.info) {
        eprintln!("herdr-host: the record cannot be written: {e}");
    }
    Ok(())
}

/// The next line from the agent, up to `deadline` (the init timeout).
/// `AgentErr` lines (stderr) are kept in `err_tail` (bounded) so a failed
/// `initialize` can report the reason; everything else stays in the queue
/// for the loop.
fn next_agent_line(
    rx: &mpsc::Receiver<Ev>,
    deadline: Instant,
    err_tail: &std::sync::Arc<std::sync::Mutex<Vec<String>>>,
) -> Option<String> {
    loop {
        let now = Instant::now();
        if now > deadline {
            return None;
        }
        let wait = deadline
            .saturating_duration_since(now)
            .min(Duration::from_millis(50));
        match rx.recv_timeout(wait) {
            Ok(Ev::AgentOut(line)) => return Some(line),
            Ok(Ev::AgentErr(line)) => {
                let mut tail = err_tail.lock().expect("the stderr tail is not poisoned");
                tail.push(line);
                if tail.len() > 20 {
                    tail.remove(0);
                }
            }
            Ok(Ev::AgentGone) => return None,
            // A client event before init is impossible (no client is attached
            // yet); keep it in the queue.
            Ok(_) => {}
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return None,
        }
    }
}

/// Write the router's output: the agent's stdin, the clients' sockets, and the
/// record when it changed.
fn flush(agent: &Router, conns: &[Conn], out: &mut Out, agent_in: &mut ChildStdin, dir: &StateDir) {
    for line in std::mem::take(&mut out.agent) {
        let _ = send(agent_in, &line);
    }
    for (id, lines) in out.clients.drain() {
        let Some(conn) = conns.iter().find(|c| c.id == id) else {
            continue;
        };
        let Ok(mut write) = conn.write.try_clone() else {
            continue;
        };
        for line in lines {
            let mut data = line.into_bytes();
            data.push(b'\n');
            let _ = write.write_all(&data);
        }
    }
    if out.dirty {
        if let Err(e) = dir.write(&agent.info) {
            eprintln!("herdr-host: the record cannot be written: {e}");
        }
    }
}

/// The agent is gone (it exited, or a `kill` arrived): record it, tell the
/// clients, clean up.
fn finish(
    mut agent: Router,
    dir: &StateDir,
    child: &mut Child,
    conns: &mut Vec<Conn>,
    terminating: bool,
    err_tail: &std::sync::Arc<std::sync::Mutex<Vec<String>>>,
    extras: &mut Extras,
) -> i32 {
    // The agent's death is known (`agent_gone`): `wait` returns at once. A `kill`
    // may find it alive: `try_wait`, then the group signal below takes it.
    let status = if terminating {
        child.try_wait().ok().flatten()
    } else {
        child.wait().ok()
    };
    let code = status.as_ref().and_then(|s| s.code()).unwrap_or(0);
    #[cfg(unix)]
    use std::os::unix::process::ExitStatusExt;
    #[cfg(unix)]
    let signal = status.as_ref().and_then(|s| s.signal());
    #[cfg(not(unix))]
    let signal: Option<i32> = None;
    // The reason, in the person's words (python `run` `:2597-2606`).
    let mut reason = if terminating {
        "Ended on request.".to_string()
    } else if let Some(sig) = signal {
        format!("The agent was killed by signal {sig}.")
    } else if code == 0 {
        "The agent exited.".to_string()
    } else {
        format!("The agent exited with code {code}.")
    };
    // A nonzero exit carries the agent's last stderr line (python `:2605`).
    if code > 0 {
        if let Some(last) = err_tail
            .lock()
            .expect("the stderr tail is not poisoned")
            .last()
        {
            reason.push(' ');
            reason.push_str(last);
        }
    }
    let mut out = Out::default();
    agent.agent_exited(code, &reason, &mut out);
    for (id, lines) in out.clients.drain() {
        let Some(conn) = conns.iter().find(|c| c.id == id) else {
            continue;
        };
        if let Ok(mut write) = conn.write.try_clone() {
            for line in lines {
                let mut data = line.into_bytes();
                data.push(b'\n');
                let _ = write.write_all(&data);
            }
        }
    }
    // Close every client socket's write side: the client reads EOF (its attach
    // bridge exits) and the reader threads' `read()` unblocks — the daemon
    // cannot exit while a reader is blocked in `read()`.
    for c in &mut *conns {
        let _ = c.write.shutdown(std::net::Shutdown::Write);
    }
    conns.clear();
    // The session was ended on request: its herdr tab goes too. An agent that
    // exits on its own leaves it (the terminal says why); a command still in
    // flight just stops. (A hook the person's program is running is left to
    // finish: it is in its own group, so the signal below does not reach it.)
    if let Some(p) = extras.pane.as_mut() {
        if terminating {
            for line in p.close() {
                agent.dlog(&line);
            }
        } else {
            p.stop();
        }
    }
    // The daemon is the group leader; the agent is in its group. A signal to
    // the group takes the agent too.
    spawn::kill_group(i32::try_from(std::process::id()).unwrap_or(0));
    let _ = std::fs::remove_file(dir.path(&agent.id, "sock"));
    if let Err(e) = dir.write(&agent.info) {
        eprintln!("herdr-host: the record cannot be written: {e}");
    }
    // The agent may ignore SIGTERM (it is SIGKILLed by the `kill` command's
    // ladder): never block on it, or the daemon outlives the `kill`.
    let _ = child.try_wait();
    // A keeper that runs as a launchd job unloads the job, or launchd would
    // keep listing it. The unload ends this process: it is the last thing.
    if let Some(job) = &extras.job {
        launchd::bootout(&job.label, false);
    }
    0
}

/// A failed start: the code is the exit, the text goes to stderr.
fn fail(code: i32, text: &str) -> i32 {
    eprintln!("herdr-mobile: {text}");
    code
}

fn send(w: &mut ChildStdin, line: &str) -> io::Result<()> {
    let mut data = line.as_bytes().to_vec();
    data.push(b'\n');
    w.write_all(&data)
}

/// The agent's `authMethods` names the method the route wants.
fn offers_auth(init: &serde_json::Value, method: &str) -> bool {
    init.get("authMethods")
        .and_then(serde_json::Value::as_array)
        .is_some_and(|m| {
            m.iter()
                .any(|x| x.get("id").and_then(serde_json::Value::as_str) == Some(method))
        })
}

/// A flag a signal sets: the loop reads it each tick and ends cleanly.
fn signal_flag() -> std::sync::Arc<std::sync::atomic::AtomicBool> {
    let flag = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    for sig in [signal_hook::consts::SIGTERM, signal_hook::consts::SIGINT] {
        let _ = signal_hook::flag::register(sig, std::sync::Arc::clone(&flag));
    }
    // SIGHUP is ignored: it is the phone's SSH channel closing (the starter's
    // pgroup gets it), and the keeper must outlive that — a `kill` arrives as
    // SIGTERM. The python keeper does the same (`signal.SIGHUP -> SIG_IGN`).
    // It is caught into a flag the loop never reads, so it changes nothing.
    let hup = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let _ = signal_hook::flag::register(signal_hook::consts::SIGHUP, hup);
    flag
}

#[cfg(test)]
mod tests {
    use super::*;

    fn conn(id: u64, born: Instant, active: bool) -> Conn {
        let (write, _peer) = UnixStream::pair().expect("a socket pair");
        Conn {
            id,
            write,
            born,
            active,
        }
    }

    #[test]
    fn only_a_connection_that_never_spoke_is_idle() {
        let limit = Duration::from_secs(30);
        let t0 = Instant::now();
        let conns = [
            conn(1, t0, false),
            conn(2, t0, true),
            conn(3, t0 + Duration::from_secs(20), false),
        ];
        // Inside the limit nobody goes.
        assert!(never_active(&conns, t0 + Duration::from_secs(30), limit).is_empty());
        // Past it only the silent newcomer that never spoke (1) goes; the attached client (2)
        // stays however long it has been quiet, and 3 is still young.
        assert_eq!(
            never_active(&conns, t0 + Duration::from_secs(31), limit),
            vec![1]
        );
        assert_eq!(
            never_active(&conns, t0 + Duration::from_secs(10_000), limit),
            vec![1, 3]
        );
    }
}
