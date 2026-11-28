//! The session's tab in herdr on this computer (`docs/AGENT_SESSIONS.md`,
//! "Shared sessions"). After the agent has answered `initialize`, the keeper
//! shows the session at the desk: a tab in the workspace herdr has open for the
//! linked worktree that holds the session's folder, else in `Phone sessions`
//! (made when missing, never focused), running `herdr-tui attach <id>`.
//!
//! A chain of `herdr` CLI commands, one in flight at a time, each started
//! without waiting and polled on the daemon's tick ([`Pane::poll`]); a command
//! that hangs is killed after its timeout. No herdr, no `herdr-tui`, no server
//! or any failure is logged and nothing else changes. Ported from the python
//! `open_pane` family (`keeper_script.dart` 2349-2532); unlike the python the
//! pane runs only `herdr-tui` (the python `view` is gone), so without one on
//! this host no tab is opened.

use crate::fds;
use crate::search;
use crate::spawn;
use serde_json::Value;
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// The workspace sessions without a worktree of their own go to.
pub const WORKSPACE: &str = "Phone sessions";
/// Seconds a herdr command may take.
const HERDR_TIMEOUT: Duration = Duration::from_secs(10);
/// The first command doubles as "is a herdr server running": it fails at once.
const PROBE_TIMEOUT: Duration = Duration::from_secs(3);
/// The tab close, which a `kill` waits for.
const CLOSE_TIMEOUT: Duration = Duration::from_secs(3);
const OUT_MAX: usize = 4 * 1024 * 1024;

/// Where the pane's programs are, and whether the person wants a pane.
#[derive(Clone, Copy, Debug)]
pub struct Locate<'a> {
    pub home: &'a Path,
    /// `$PATH`; the usual extra bins are searched too ([`search::dirs`]).
    pub path_env: &'a str,
    /// `$HERDR_MOBILE_NO_PANE`: `1` keeps herdr out (a terminal client that is
    /// itself the pane sets it).
    pub no_pane: Option<&'a str>,
    /// `$HERDR_MOBILE_HERDR`: the herdr to run, instead of looking for one.
    pub herdr: Option<&'a str>,
}

/// The programs the chain runs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Programs {
    pub herdr: PathBuf,
    pub tui: PathBuf,
}

/// Why no pane is opened.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Skip {
    /// `HERDR_MOBILE_NO_PANE=1`, or `~/.herdr-mobile/no-panes` exists.
    Disabled,
    NoHerdr,
    /// herdr is here but `herdr-tui` is not (nothing else can show the session).
    NoTui,
    /// The `herdr-tui` path cannot be typed into a shell as one word.
    Untypable(String),
}

impl Skip {
    /// The sentence for the diagnostic log.
    #[must_use]
    pub fn reason(&self) -> String {
        match self {
            Skip::Disabled => {
                "no herdr pane: switched off (HERDR_MOBILE_NO_PANE or no-panes)".into()
            }
            Skip::NoHerdr => "no herdr pane: herdr is not installed on this host".into(),
            Skip::NoTui => "no herdr pane: herdr-tui is not installed on this host".into(),
            Skip::Untypable(p) => {
                format!("no herdr pane: the herdr-tui path cannot be typed into a shell: {p:?}")
            }
        }
    }
}

/// Which programs open the pane, or why none does.
///
/// # Errors
/// The [`Skip`] reason.
pub fn locate(cx: &Locate<'_>) -> Result<Programs, Skip> {
    if cx.no_pane == Some("1") || cx.home.join(".herdr-mobile").join("no-panes").exists() {
        return Err(Skip::Disabled);
    }
    let mut dirs = search::dirs(cx.path_env, cx.home);
    let herdr = match cx.herdr.filter(|h| !h.is_empty()) {
        Some(h) => PathBuf::from(h),
        None => search::which("herdr", &dirs).ok_or(Skip::NoHerdr)?,
    };
    dirs.push(cx.home.join(".herdr-mobile").join("bin"));
    let tui = search::which("herdr-tui", &dirs).ok_or(Skip::NoTui)?;
    if !typable(&tui) {
        return Err(Skip::Untypable(tui.to_string_lossy().into_owned()));
    }
    Ok(Programs { herdr, tui })
}

/// Whether `'<path>'` is one shell word: absolute, no quote, no control
/// character.
fn typable(path: &Path) -> bool {
    let s = path.to_string_lossy();
    path.is_absolute()
        && !s.contains('\'')
        && !s.chars().any(|c| u32::from(c) < 0x20 || c == '\x7f')
}

/// What a finished herdr command leads to.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Then {
    /// `workspace list` answered.
    Workspaces,
    /// `tab list` of the worktree's workspace answered.
    Tabs { wid: String },
    /// `pane list` of the worktree's workspace answered.
    Panes { wid: String, tid: String },
    /// `pane read` of the worktree's empty shell answered.
    Read {
        wid: String,
        tid: String,
        pid: String,
    },
    /// `workspace create` / `tab create` answered; the new tab takes the
    /// session, and a new workspace's tab is renamed.
    Made { rename: bool },
    /// `pane run` answered; the tab is renamed after it.
    Rename { tid: String },
    /// The last command of a chain.
    End,
}

/// The command in flight.
struct Job {
    child: Child,
    args: Vec<String>,
    then: Then,
    /// Where to go when it fails or hangs: a tab of its own in this workspace.
    fail_tab: Option<String>,
    out: Vec<u8>,
    err: Vec<u8>,
    deadline: Instant,
}

/// The chain, owned by the daemon.
pub struct Pane {
    programs: Programs,
    id: String,
    cwd: String,
    label: String,
    job: Option<Job>,
    /// The tab this chain made: closed when the session is ended on request.
    /// (A worktree's own empty shell is the person's, never closed.)
    tab: Option<String>,
    /// The pane the session was put in, until the daemon has recorded it.
    new_pane: Option<String>,
}

impl Pane {
    /// Starts the chain with `workspace list`. Returns the log lines of a first
    /// command that could not start.
    #[must_use]
    pub fn open(programs: Programs, id: &str, cwd: &str, route_label: &str) -> (Pane, Vec<String>) {
        let base = cwd.trim_end_matches('/');
        let folder = Path::new(base)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| cwd.to_string());
        let mut pane = Pane {
            programs,
            id: id.to_string(),
            cwd: cwd.to_string(),
            label: format!("{route_label} \u{b7} {folder}"),
            job: None,
            tab: None,
            new_pane: None,
        };
        let mut log = Vec::new();
        pane.call(
            &["workspace", "list"],
            Then::Workspaces,
            None,
            PROBE_TIMEOUT,
            &mut log,
        );
        (pane, log)
    }

    /// The pane the chain put the session in, once.
    pub fn take_pane_id(&mut self) -> Option<String> {
        self.new_pane.take()
    }

    /// Whether a herdr command is in flight.
    #[must_use]
    pub fn busy(&self) -> bool {
        self.job.is_some()
    }

    /// The command line typed into the pane.
    fn command(&self) -> String {
        format!("'{}' attach {}", self.programs.tui.display(), self.id)
    }

    fn call(
        &mut self,
        args: &[&str],
        then: Then,
        fail_tab: Option<String>,
        timeout: Duration,
        log: &mut Vec<String>,
    ) {
        let mut cmd = Command::new(&self.programs.herdr);
        cmd.args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0);
        fds::close_inherited(&mut cmd, fds::Strategy::from_env());
        let child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                log.push(format!(
                    "herdr {} did not start: {e}",
                    args[..args.len().min(2)].join(" ")
                ));
                return;
            }
        };
        for fd in [
            child.stdout.as_ref().map(rustix::fd::AsFd::as_fd),
            child.stderr.as_ref().map(rustix::fd::AsFd::as_fd),
        ]
        .into_iter()
        .flatten()
        {
            let _ = rustix::fs::fcntl_setfl(fd, rustix::fs::OFlags::NONBLOCK);
        }
        // The job owns the child and its (nonblocking) pipes.
        self.job = Some(Job {
            child,
            args: args.iter().map(|a| (*a).to_string()).collect(),
            then,
            fail_tab,
            out: Vec::new(),
            err: Vec::new(),
            deadline: Instant::now() + timeout,
        });
    }

    /// Advances the chain: reads what the command in flight has printed and,
    /// when it has ended (or is overdue), takes the next step. Never blocks.
    /// Returns the sentences for the diagnostic log.
    pub fn poll(&mut self) -> Vec<String> {
        let mut log = Vec::new();
        let Some(job) = self.job.as_mut() else {
            return log;
        };
        drain(job);
        let rc = match job.child.try_wait() {
            Ok(None) if Instant::now() < job.deadline => return log,
            Ok(None) => None,
            Ok(Some(status)) => {
                // The command is done: whatever it printed is in the pipes.
                drain(job);
                Some(status.code().unwrap_or(-1))
            }
            Err(_) => Some(-1),
        };
        let Some(mut job) = self.job.take() else {
            return log;
        };
        if rc.is_none() {
            kill_job(&mut job);
        }
        let name = format!("herdr {}", job.args[..job.args.len().min(2)].join(" "));
        let failed = rc != Some(0);
        match rc {
            None => log.push(format!("{name} did not answer in time")),
            Some(0) => self.next(&job, &mut log),
            Some(code) => log.push(format!(
                "{name} failed ({code}): {}",
                crate::router::trunc(String::from_utf8_lossy(&job.err).trim(), 300)
            )),
        }
        if failed {
            if let Some(wid) = job.fail_tab {
                self.new_tab(&wid, &mut log);
            }
        }
        log
    }

    /// The step after a command that exited 0.
    fn next(&mut self, job: &Job, log: &mut Vec<String>) {
        match job.then.clone() {
            Then::Workspaces => self.on_workspaces(&job.out, log),
            Then::Tabs { wid } => self.on_tabs(&job.out, &wid, log),
            Then::Panes { wid, tid } => self.on_panes(&job.out, &wid, &tid, log),
            Then::Read { wid, tid, pid } => self.on_read(&job.out, &wid, &tid, &pid, log),
            Then::Made { rename } => self.on_made(&job.out, rename, log),
            Then::Rename { tid } => {
                let label = self.label.clone();
                self.call(
                    &["tab", "rename", &tid, &label],
                    Then::End,
                    None,
                    HERDR_TIMEOUT,
                    log,
                );
            }
            Then::End => {}
        }
    }

    fn on_workspaces(&mut self, out: &[u8], log: &mut Vec<String>) {
        let result = herdr_result(out);
        let spaces: Vec<Value> = result
            .get("workspaces")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        // A session in a worktree belongs in that worktree's workspace: at the
        // desk the person opens the worktree and finds its agent there, not an
        // empty shell beside a tab in `Phone sessions`.
        if let Some(wid) = checkout_workspace(&spaces, &self.cwd) {
            // A worktree herdr just made has one tab: an empty shell. The
            // session takes that one rather than sit in a second tab beside it
            // (`on_tabs`), else a tab of its own.
            self.call(
                &["tab", "list", "--workspace", &wid],
                Then::Tabs { wid: wid.clone() },
                Some(wid.clone()),
                HERDR_TIMEOUT,
                log,
            );
            return;
        }
        for w in &spaces {
            if w.get("label").and_then(Value::as_str) == Some(WORKSPACE) {
                if let Some(wid) = w.get("workspace_id").and_then(Value::as_str) {
                    self.new_tab(wid, log);
                    return;
                }
            }
        }
        // A new workspace comes with a tab and a pane: this session takes them.
        let cwd = self.cwd.clone();
        self.call(
            &[
                "workspace",
                "create",
                "--label",
                WORKSPACE,
                "--cwd",
                &cwd,
                "--no-focus",
            ],
            Then::Made { rename: true },
            None,
            HERDR_TIMEOUT,
            log,
        );
    }

    fn new_tab(&mut self, wid: &str, log: &mut Vec<String>) {
        let (cwd, label) = (self.cwd.clone(), self.label.clone());
        self.call(
            &[
                "tab",
                "create",
                "--workspace",
                wid,
                "--cwd",
                &cwd,
                "--label",
                &label,
                "--no-focus",
            ],
            Then::Made { rename: false },
            None,
            HERDR_TIMEOUT,
            log,
        );
    }

    fn on_tabs(&mut self, out: &[u8], wid: &str, log: &mut Vec<String>) {
        let result = herdr_result(out);
        let tabs = result.get("tabs").and_then(Value::as_array);
        let tab = match tabs {
            Some(t) if t.len() == 1 && t[0].is_object() => &t[0],
            _ => return self.new_tab(wid, log),
        };
        let tid = tab.get("tab_id").and_then(Value::as_str);
        let Some(tid) = tid.filter(|_| tab.get("pane_count").and_then(Value::as_i64) == Some(1))
        else {
            return self.new_tab(wid, log);
        };
        self.call(
            &["pane", "list", "--workspace", wid],
            Then::Panes {
                wid: wid.to_string(),
                tid: tid.to_string(),
            },
            Some(wid.to_string()),
            HERDR_TIMEOUT,
            log,
        );
    }

    fn on_panes(&mut self, out: &[u8], wid: &str, tid: &str, log: &mut Vec<String>) {
        let result = herdr_result(out);
        let mine: Vec<&Value> = result
            .get("panes")
            .and_then(Value::as_array)
            .map(|panes| {
                panes
                    .iter()
                    .filter(|p| p.get("tab_id").and_then(Value::as_str) == Some(tid))
                    .collect()
            })
            .unwrap_or_default();
        let pid = (mine.len() == 1)
            .then(|| mine[0].get("pane_id").and_then(Value::as_str))
            .flatten();
        // A pane with an agent in it is somebody's.
        let Some(pid) = pid.filter(|_| mine[0].get("agent").is_none_or(Value::is_null)) else {
            return self.new_tab(wid, log);
        };
        self.call(
            &["pane", "read", pid, "--lines", "30"],
            Then::Read {
                wid: wid.to_string(),
                tid: tid.to_string(),
                pid: pid.to_string(),
            },
            Some(wid.to_string()),
            HERDR_TIMEOUT,
            log,
        );
    }

    fn on_read(&mut self, out: &[u8], wid: &str, tid: &str, pid: &str, log: &mut Vec<String>) {
        if !untouched_shell(&String::from_utf8_lossy(out)) {
            return self.new_tab(wid, log);
        }
        // The tab is the person's own, so it is never closed with the session:
        // only the rename and the command are ours.
        let command = self.command();
        self.call(
            &["pane", "run", pid, &command],
            Then::Rename {
                tid: tid.to_string(),
            },
            None,
            HERDR_TIMEOUT,
            log,
        );
        self.new_pane = Some(pid.to_string());
        log.push(format!(
            "herdr pane {pid} (tab {tid}, the worktree's empty shell) shows the session"
        ));
    }

    fn on_made(&mut self, out: &[u8], rename: bool, log: &mut Vec<String>) {
        let result = herdr_result(out);
        let name = |key: &str, id: &str| {
            result
                .get(key)
                .and_then(|v| v.get(id))
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        };
        let (Some(tid), Some(pid)) = (name("tab", "tab_id"), name("root_pane", "pane_id")) else {
            log.push(format!(
                "no herdr pane: herdr named no tab and pane: {}",
                crate::router::trunc(&String::from_utf8_lossy(out), 300)
            ));
            return;
        };
        self.tab = Some(tid.clone());
        let command = self.command();
        let then = if rename {
            Then::Rename { tid: tid.clone() }
        } else {
            Then::End
        };
        self.call(
            &["pane", "run", &pid, &command],
            then,
            None,
            HERDR_TIMEOUT,
            log,
        );
        log.push(format!("herdr pane {pid} (tab {tid}) shows the session"));
        self.new_pane = Some(pid);
    }

    /// The agent ended by itself (or the keeper is going away): the command in
    /// flight stops; the tab stays, the terminal says why the session ended.
    pub fn stop(&mut self) {
        if let Some(mut job) = self.job.take() {
            kill_job(&mut job);
        }
    }

    /// The session was ended on request: its tab goes too. Waits for herdr, at
    /// most three seconds. Returns the sentences for the diagnostic log.
    pub fn close(&mut self) -> Vec<String> {
        self.stop();
        let Some(tab) = self.tab.take() else {
            return Vec::new();
        };
        let mut cmd = Command::new(&self.programs.herdr);
        cmd.args(["tab", "close", &tab])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0);
        fds::close_inherited(&mut cmd, fds::Strategy::from_env());
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => return vec![format!("herdr tab close failed: {e}")],
        };
        let end = Instant::now() + CLOSE_TIMEOUT;
        loop {
            match child.try_wait() {
                Ok(Some(_)) | Err(_) => return Vec::new(),
                Ok(None) if Instant::now() >= end => {
                    if let Ok(pid) = i32::try_from(child.id()) {
                        spawn::kill_group_hard(pid);
                    }
                    let _ = child.wait();
                    return vec!["herdr tab close failed: timed out".to_string()];
                }
                Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            }
        }
    }
}

/// Reads what is there, up to [`OUT_MAX`] each; the pipes are nonblocking.
fn drain(job: &mut Job) {
    fn pull<R: Read>(from: Option<&mut R>, into: &mut Vec<u8>) {
        let Some(from) = from else { return };
        let mut buf = [0u8; 16 * 1024];
        while into.len() < OUT_MAX {
            match from.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => into.extend_from_slice(&buf[..n]),
            }
        }
    }
    pull(job.child.stdout.as_mut(), &mut job.out);
    pull(job.child.stderr.as_mut(), &mut job.err);
}

/// SIGKILL the command's group and collect it.
fn kill_job(job: &mut Job) {
    if let Ok(pid) = i32::try_from(job.child.id()) {
        spawn::kill_group_hard(pid);
    }
    let _ = job.child.wait();
}

/// `.result` of what a herdr CLI command printed (`{}` when it is not that).
fn herdr_result(out: &[u8]) -> Value {
    serde_json::from_slice::<Value>(out)
        .ok()
        .and_then(|mut v| v.get_mut("result").map(Value::take))
        .filter(Value::is_object)
        .unwrap_or_else(|| Value::Object(serde_json::Map::new()))
}

/// The workspace id herdr has open for the linked worktree that holds `cwd`
/// (the folder itself or one below it; the deepest checkout wins), else `None`.
/// `workspace list` carries `worktree.checkout_path` on herdr 0.9.3; an older
/// herdr has none, and then the session goes where it always did. Only linked
/// worktrees: the main checkout's workspace is the person's own.
#[must_use]
pub fn checkout_workspace(workspaces: &[Value], cwd: &str) -> Option<String> {
    let here = normpath(cwd);
    let mut best: Option<(&str, usize)> = None;
    for w in workspaces {
        let Some(wt) = w.get("worktree").filter(|wt| wt.is_object()) else {
            continue;
        };
        if wt.get("is_linked_worktree").and_then(Value::as_bool) != Some(true) {
            continue;
        }
        let (Some(path), Some(wid)) = (
            wt.get("checkout_path")
                .and_then(Value::as_str)
                .filter(|p| !p.is_empty()),
            w.get("workspace_id")
                .and_then(Value::as_str)
                .filter(|p| !p.is_empty()),
        ) else {
            continue;
        };
        let path = normpath(path);
        let inside = here == path || here.starts_with(&format!("{}/", path.trim_end_matches('/')));
        if inside && best.is_none_or(|(_, len)| path.len() > len) {
            best = Some((wid, path.len()));
        }
    }
    best.map(|(wid, _)| wid.to_string())
}

/// Python's `os.path.normpath` for a POSIX path: no filesystem access.
fn normpath(path: &str) -> String {
    let absolute = path.starts_with('/');
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if parts.last().is_some_and(|p| *p != "..") {
                    parts.pop();
                } else if !absolute {
                    parts.push("..");
                }
            }
            p => parts.push(p),
        }
    }
    let joined = parts.join("/");
    match (absolute, joined.is_empty()) {
        (true, _) => format!("/{joined}"),
        (false, true) => ".".to_string(),
        (false, false) => joined,
    }
}

/// Whether `screen` (what `herdr pane read` printed) is a shell that was just
/// opened and left alone: one non-blank line, and that line is a prompt (ends
/// with `$`, `%`, `#`, `>`, `❯` or `➜`, ignoring a right-hand prompt after a
/// gap of spaces). Anything else (output, a command half typed, a program
/// running) is somebody's and nothing may be typed into it.
#[must_use]
pub fn untouched_shell(screen: &str) -> bool {
    let mut lines = screen.lines().filter(|l| !l.trim().is_empty());
    let (Some(line), None) = (lines.next(), lines.next()) else {
        return false;
    };
    let line = line.trim();
    // `re.split(r"\s{2,}")[0]`: up to the first run of two whitespace characters.
    let mut left = line;
    let mut prev_space = None;
    for (i, c) in line.char_indices() {
        if c.is_whitespace() {
            if let Some(start) = prev_space {
                left = &line[..start];
                break;
            }
            prev_space = Some(i);
        } else {
            prev_space = None;
        }
    }
    left.ends_with(['$', '%', '#', '>', '\u{276f}', '\u{279c}'])
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn space(id: &str, path: Option<&str>, linked: bool) -> Value {
        let mut w = json!({"workspace_id": id, "label": id});
        if let Some(p) = path {
            w["worktree"] = json!({"checkout_path": p, "is_linked_worktree": linked});
        }
        w
    }

    #[test]
    fn the_deepest_linked_worktree_that_holds_the_folder_wins() {
        let spaces = vec![
            space("w1", None, false),
            space("w2", Some("/r/wt"), true),
            space("w3", Some("/r"), false),
            space("w4", Some("/r/wt/app"), true),
            space("w5", Some("/other"), true),
        ];
        assert_eq!(checkout_workspace(&spaces, "/r/wt"), Some("w2".into()));
        assert_eq!(checkout_workspace(&spaces, "/r/wt/x/y"), Some("w2".into()));
        assert_eq!(
            checkout_workspace(&spaces, "/r/wt/app/src"),
            Some("w4".into())
        );
        assert_eq!(
            checkout_workspace(&spaces, "/r/wt/../elsewhere"),
            None,
            "normalised first"
        );
        assert_eq!(
            checkout_workspace(&spaces, "/r/wtx"),
            None,
            "a sibling is not inside"
        );
        assert_eq!(
            checkout_workspace(&spaces, "/r"),
            None,
            "the main checkout is the person's own"
        );
    }

    #[test]
    fn paths_are_normalised_like_python() {
        for (raw, want) in [
            ("/a/b/../c/./d//e", "/a/c/d/e"),
            ("/", "/"),
            ("/..", "/"),
            ("a/../..", ".."),
            ("", "."),
            ("/a/b/", "/a/b"),
        ] {
            assert_eq!(normpath(raw), want, "{raw:?}");
        }
    }

    #[test]
    fn only_a_lone_prompt_is_an_untouched_shell() {
        assert!(untouched_shell(
            "tuan@host ~/wt$                          worktree/x\n\n\n"
        ));
        assert!(untouched_shell("~ \u{276f}\n"));
        assert!(untouched_shell("\n  root# \n\n"));
        assert!(!untouched_shell(
            "tuan@host ~/wt$ git status\nOn branch x\ntuan@host ~/wt$\n"
        ));
        assert!(!untouched_shell("tuan@host ~/wt$ git commi\n"));
        assert!(!untouched_shell("vim"));
        assert!(!untouched_shell(""));
        assert!(!untouched_shell("a$\nb$\n"));
    }

    #[test]
    fn the_pane_needs_herdr_and_herdr_tui_and_the_persons_consent() {
        let home = tempfile::tempdir().expect("home");
        let bin = home.path().join("bin");
        std::fs::create_dir_all(&bin).expect("bin");
        let make = |dir: &Path, name: &str| {
            use std::os::unix::fs::PermissionsExt;
            std::fs::create_dir_all(dir).expect("dir");
            let p = dir.join(name);
            std::fs::write(&p, "#!/bin/sh\n").expect("write");
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).expect("chmod");
            p
        };
        let path = bin.to_string_lossy().into_owned();
        let cx = |no_pane, herdr| Locate {
            home: home.path(),
            path_env: &path,
            no_pane,
            herdr,
        };
        assert_eq!(locate(&cx(None, None)), Err(Skip::NoHerdr));
        let herdr = make(&bin, "herdr");
        assert_eq!(locate(&cx(None, None)), Err(Skip::NoTui));
        // `herdr-tui` is found in the usual places: the private bin folder here.
        let tui = make(&home.path().join(".herdr-mobile").join("bin"), "herdr-tui");
        assert_eq!(
            locate(&cx(None, None)),
            Ok(Programs {
                herdr: herdr.clone(),
                tui: tui.clone()
            })
        );
        assert_eq!(locate(&cx(Some("1"), None)), Err(Skip::Disabled));
        assert!(
            locate(&cx(Some("0"), None)).is_ok(),
            "only 1 switches it off"
        );
        // The herdr to run can be named; it need not be on the PATH.
        std::fs::remove_file(&herdr).expect("remove");
        let named = herdr.to_string_lossy().into_owned();
        assert!(locate(&cx(None, Some(&named))).is_ok());
        assert_eq!(locate(&cx(None, None)), Err(Skip::NoHerdr));
        // `no-panes` wins over everything.
        std::fs::write(home.path().join(".herdr-mobile").join("no-panes"), "").expect("no-panes");
        assert_eq!(locate(&cx(None, Some(&named))), Err(Skip::Disabled));
    }

    #[test]
    fn a_tui_path_that_is_not_one_shell_word_is_never_typed() {
        assert!(typable(Path::new("/home/me/.local/bin/herdr-tui")));
        assert!(!typable(Path::new("/home/o'brien/herdr-tui")));
        assert!(!typable(Path::new("/home/a\nb/herdr-tui")));
        assert!(!typable(Path::new("relative/herdr-tui")));
    }
}
