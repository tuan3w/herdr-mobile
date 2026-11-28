//! What the keeper does beyond the agent's wire, checked
//! against the built `herdr-host` binary run with a scripted agent: the alert
//! hook, the herdr pane tab, the agent's file descriptors, the login umask and
//! a keeper that runs as a launchd job (the part of it that does not need
//! macOS). The pure parts (hook limits, the plist, `launchctl` command lines,
//! the keeper command-line check) are unit tests in the `keeper` crate.
//!
//! Hermetic: its own HOME and a PATH with only a scripted `omp`; the `herdr` it
//! talks to is a shell script of the test's own that logs its arguments and
//! answers like herdr's CLI; every process it starts is stopped by pid. The
//! scripted agent is testkit's `fake-acp-agent`.

use acp::{Id, Message};
use keeper::records::{State, StateDir};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

const WAIT: Duration = Duration::from_secs(30);

/// A `herdr` that logs every call (a JSON array per line in
/// `$HERDR_FAKE_DIR/calls.jsonl`) and answers the calls the pane chain makes
/// like herdr's CLI does (`{"id":"cli","result":{…}}`). What it knows is in
/// `$HERDR_FAKE_DIR`: `workspaces.items`, `tabs-<workspace>.items`,
/// `panes-<workspace>.items` (JSON elements, comma-separated, no brackets) and
/// `screen-<pane>.txt`; `workspace create` makes `Phone sessions` (`w1`) and
/// the tab and pane counter runs from there.
const FAKE_HERDR: &str = r#"#!/bin/sh
D="$HERDR_FAKE_DIR"
line='['; sep=''
for a in "$@"; do
  e=$(printf '%s' "$a" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  line="$line$sep\"$e\""; sep=','
done
echo "$line]" >> "$D/calls.jsonl"
arg() { while [ $# -gt 1 ]; do if [ "$1" = "$NAME" ]; then echo "$2"; return; fi; shift; done; }
next() { n=$(cat "$D/counter" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$D/counter"; echo "$n"; }
items() { cat "$D/$1" 2>/dev/null; }
case "$1 $2" in
  "workspace list")
    list=$(items workspaces.items)
    if [ -f "$D/created" ]; then
      phone='{"workspace_id":"w1","label":"Phone sessions"}'
      if [ -n "$list" ]; then list="$list,$phone"; else list="$phone"; fi
    fi
    printf '{"id":"cli","result":{"type":"workspace_list","workspaces":[%s]}}\n' "$list" ;;
  "workspace create")
    touch "$D/created"; n=$(next)
    printf '{"id":"cli","result":{"type":"workspace_created","workspace":{"workspace_id":"w1","label":"Phone sessions"},"tab":{"tab_id":"w1:t%s"},"root_pane":{"pane_id":"w1:p%s"}}}\n' "$n" "$n" ;;
  "tab create")
    NAME=--workspace; w=$(arg "$@"); n=$(next)
    printf '{"id":"cli","result":{"type":"tab_created","tab":{"tab_id":"%s:t%s"},"root_pane":{"pane_id":"%s:p%s"}}}\n' "$w" "$n" "$w" "$n" ;;
  "tab list")
    NAME=--workspace; w=$(arg "$@")
    printf '{"id":"cli","result":{"type":"tab_list","tabs":[%s]}}\n' "$(items "tabs-$w.items")" ;;
  "pane list")
    NAME=--workspace; w=$(arg "$@")
    printf '{"id":"cli","result":{"type":"pane_list","panes":[%s]}}\n' "$(items "panes-$w.items")" ;;
  "pane read")
    cat "$D/screen-$3.txt" 2>/dev/null ;;
esac
exit 0
"#;

/// An isolated machine: a home, a `bin` with the scripted `omp`, the built
/// `herdr-host`, and a fake `herdr`.
struct Machine {
    dir: tempfile::TempDir,
    home: PathBuf,
    bin: PathBuf,
    work: PathBuf,
    fake: PathBuf,
    keeper: PathBuf,
    started: Vec<i64>,
}

impl Machine {
    fn new() -> Machine {
        let dir = tempfile::tempdir().expect("a temp dir");
        let root = dir.path();
        let (home, bin, work) = (root.join("home"), root.join("bin"), root.join("work"));
        for d in [&home, &bin, &work, &root.join("fake")] {
            std::fs::create_dir_all(d).expect("a folder");
        }
        script(
            &bin.join("omp"),
            &format!(
                "#!/bin/sh\nexec '{}' \"$@\"\n",
                testkit::bin("fake-acp-agent").display()
            ),
        );
        let fake = root.join("fake-herdr");
        script(&fake, FAKE_HERDR);
        Machine {
            home,
            bin,
            work,
            fake,
            keeper: PathBuf::from(env!("CARGO_BIN_EXE_herdr-host")),
            started: Vec::new(),
            dir,
        }
    }

    fn root(&self) -> &Path {
        self.dir.path()
    }

    /// Where the fake herdr keeps its log and what it knows.
    fn fake_dir(&self) -> PathBuf {
        self.root().join("fake")
    }

    /// A keeper command as the phone's `serve` or a terminal would run it: only
    /// the scripted bin and the system, no herdr of the real machine.
    fn command(&self, args: &[&str], env: &[(&str, &str)]) -> Command {
        let path = format!("{}:/usr/bin:/bin", self.bin.display());
        let mut cmd = Command::new(&self.keeper);
        cmd.args(args)
            .stdin(Stdio::null())
            .env("HOME", &self.home)
            .env("PATH", path)
            .env("HERDR_FAKE_DIR", self.fake_dir())
            .env("FAKE_ACP_GATE", self.root().join("gate"))
            .env("FAKE_ACP_TITLE_ON_NEW", "1")
            .env("FAKE_ACP_ENV_KEYS", "HERDR_KEEPER_LABEL,HERDR_KEEPER_UMASK")
            .env_remove("HERDR_MOBILE_NO_PANE")
            .env_remove("HERDR_MOBILE_HERDR")
            .env_remove("HERDR_KEEPER_ON_BLOCKED")
            .env_remove("HERDR_KEEPER_FD_SWEEP");
        for k in [
            "HERDR_SOCKET_PATH",
            "HERDR_ENV",
            "HERDR_PANE_ID",
            "HERDR_TAB_ID",
            "HERDR_WORKSPACE_ID",
            "HERDR_BIN_PATH",
        ] {
            cmd.env_remove(k);
        }
        for (k, v) in env {
            cmd.env(k, v);
        }
        cmd
    }

    /// `start` for the scripted `omp` in `cwd`; `prelude` is shell run first in
    /// the same process (a `umask`, a leaked descriptor).
    fn start_with(&mut self, cwd: &Path, env: &[(&str, &str)], prelude: Option<&str>) -> Value {
        let cwd = cwd.to_string_lossy().into_owned();
        let args = ["start", "--agent", "omp", "--cwd", cwd.as_str()];
        let out = match prelude {
            None => self.command(&args, env).output(),
            Some(prelude) => {
                let inner = self.command(&args, env);
                let mut sh = Command::new("sh");
                sh.arg("-c")
                    .arg(format!("{prelude}; exec \"$0\" \"$@\""))
                    .arg(&self.keeper)
                    .args(args)
                    .stdin(Stdio::null());
                for (k, v) in inner.get_envs() {
                    match v {
                        Some(v) => sh.env(k, v),
                        None => sh.env_remove(k),
                    };
                }
                sh.output()
            }
        }
        .expect("herdr-host runs");
        assert!(
            out.status.success(),
            "start failed ({:?}): {}",
            out.status.code(),
            String::from_utf8_lossy(&out.stderr)
        );
        let info: Value =
            serde_json::from_slice(first_line(&out)).expect("start prints one JSON line");
        self.started.extend(
            ["pid", "agent_pid"]
                .iter()
                .filter_map(|k| info[*k].as_i64()),
        );
        info
    }

    fn start(&mut self, cwd: &Path, env: &[(&str, &str)]) -> Value {
        self.start_with(cwd, env, None)
    }

    fn state_dir(&self) -> StateDir {
        StateDir::create(&self.home).expect("the state dir")
    }

    /// The calls the fake herdr has logged, in order.
    fn herdr_calls(&self) -> Vec<Vec<String>> {
        let Ok(text) = std::fs::read_to_string(self.fake_dir().join("calls.jsonl")) else {
            return Vec::new();
        };
        text.lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| serde_json::from_str(l).expect("a logged call is a JSON array"))
            .collect()
    }

    /// Tells the fake herdr what it knows.
    fn seed(&self, file: &str, text: &str) {
        std::fs::write(self.fake_dir().join(file), text).expect("seed the fake herdr");
    }

    /// A `herdr-tui` where the keeper looks for it (`~/.herdr-mobile/bin`).
    fn install_tui(&self) -> PathBuf {
        let dir = self.home.join(".herdr-mobile").join("bin");
        std::fs::create_dir_all(&dir).expect("bin");
        let tui = dir.join("herdr-tui");
        script(&tui, "#!/bin/sh\nexit 0\n");
        tui
    }

    /// The keeper's diagnostic log.
    fn log_of(&self, id: &str) -> String {
        std::fs::read_to_string(self.state_dir().path(id, "log")).unwrap_or_default()
    }
}

impl Drop for Machine {
    fn drop(&mut self) {
        for pid in &self.started {
            let _ = Command::new("kill")
                .arg(pid.to_string())
                .stderr(Stdio::null())
                .status();
        }
        // Wait for each to be gone: a condition, not a guess at how long it takes.
        let end = Instant::now() + Duration::from_secs(5);
        for pid in &self.started {
            while Command::new("kill")
                .args(["-0", &pid.to_string()])
                .stderr(Stdio::null())
                .status()
                .is_ok_and(|s| s.success())
                && Instant::now() < end
            {
                std::thread::sleep(Duration::from_millis(5));
            }
        }
    }
}

fn script(path: &Path, text: &str) {
    std::fs::write(path, text).expect("write a script");
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
}

fn first_line(out: &Output) -> &[u8] {
    out.stdout.split(|b| *b == b'\n').next().unwrap_or_default()
}

/// Polls `cond` until it holds.
fn wait_for(what: &str, mut cond: impl FnMut() -> bool) {
    let end = Instant::now() + WAIT;
    while !cond() {
        assert!(Instant::now() < end, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn id_of(info: &Value) -> String {
    info["id"].as_str().expect("an id").to_string()
}

fn strings(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|s| (*s).to_string()).collect()
}

/// A phone: a client of the keeper's socket that has not said it is a terminal.
struct Phone {
    write: UnixStream,
    read: BufReader<UnixStream>,
    next_id: i64,
}

impl Phone {
    fn connect(dir: &StateDir, id: &str) -> Phone {
        let stream = dir.connect(id).expect("the keeper listens on <id>.sock");
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .expect("a timeout guards the test");
        Phone {
            write: stream.try_clone().expect("clone"),
            read: BufReader::new(stream),
            next_id: 1,
        }
    }

    fn send_line(&mut self, line: &str) {
        writeln!(self.write, "{line}").expect("write");
    }

    fn next_message(&mut self) -> Message {
        let mut line = String::new();
        assert!(
            self.read.read_line(&mut line).expect("the keeper answers") > 0,
            "the keeper closed the connection"
        );
        Message::parse(line.trim()).expect("the keeper speaks JSON-RPC")
    }

    /// A request, and everything up to its answer.
    fn request(&mut self, method: &str, params: Value) -> (Value, Vec<Message>) {
        let id = self.next_id;
        self.next_id += 1;
        self.send_line(&Message::request(id, method, params).to_line());
        let mut notes = Vec::new();
        loop {
            match self.next_message() {
                Message::Response {
                    id: Id::Num(n),
                    outcome,
                } if n == id => return (outcome.expect("no error"), notes),
                other => notes.push(other),
            }
        }
    }

    /// Opens a session; returns once the agent has named it (the title reached
    /// the keeper, so the hook will know it).
    fn open_session(&mut self, cwd: &Path) {
        let (init, _) = self.request(
            "initialize",
            json!({"protocolVersion": 1, "clientCapabilities": {},
                   "clientInfo": {"name": "herdr-mobile", "title": "Phone", "version": "0"}}),
        );
        assert_eq!(init["protocolVersion"], 1, "{init}");
        let (made, mut notes) = self.request(
            "session/new",
            json!({"cwd": cwd.to_string_lossy(), "mcpServers": []}),
        );
        assert_eq!(made["sessionId"], "sess-1", "{made}");
        let titled = |m: &Message| {
            matches!(m, Message::Notification { params, .. }
                if params["update"]["title"] == "Fake title")
        };
        while !notes.iter().any(titled) {
            notes.push(self.next_message());
        }
    }

    fn prompt(&mut self, text: &str) -> i64 {
        let id = self.next_id;
        self.next_id += 1;
        self.send_line(
            &Message::request(
                id,
                "session/prompt",
                json!({"sessionId": "sess-1", "prompt": [{"type": "text", "text": text}]}),
            )
            .to_line(),
        );
        id
    }

    /// Reads to the request the agent is blocked on and answers it.
    fn allow_next_permission(&mut self) {
        loop {
            if let Message::Request { id, method, .. } = self.next_message() {
                if method == "session/request_permission" {
                    let reply = json!({"jsonrpc": "2.0", "id": id,
                        "result": {"outcome": {"outcome": "selected", "optionId": "allow"}}});
                    self.send_line(&reply.to_string());
                    return;
                }
            }
        }
    }

    /// Reads to the answer of the prompt `id`.
    fn finish_turn(&mut self, id: i64) -> Value {
        loop {
            if let Message::Response {
                id: Id::Num(n),
                outcome,
            } = self.next_message()
            {
                if n == id {
                    return outcome.expect("the prompt is answered");
                }
            }
        }
    }
}

// -- the alert hook ------------------------------------------------------------

/// A hook that appends what it was told to `$HOME/hook.out`.
const RECORD_HOOK: &str = "#!/bin/sh\nprintf '%s|%s|%s|%s|%s|%s\\n' \"$KEEPER_EVENT\" \"$KEEPER_ID\" \"$KEEPER_AGENT\" \"$KEEPER_CWD\" \"$KEEPER_TITLE\" \"$KEEPER_SUMMARY\" >> \"$HOME/hook.out\"\n";

fn hook_events(m: &Machine) -> Vec<Vec<String>> {
    std::fs::read_to_string(m.home.join("hook.out"))
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| l.split('|').map(str::to_string).collect())
        .collect()
}

#[test]
fn the_hook_runs_on_blocked_and_on_done_with_the_keeper_environment() {
    let mut m = Machine::new();
    let hook = m.root().join("hook");
    script(&hook, RECORD_HOOK);
    let info = m.start(
        &m.work.clone(),
        &[
            ("HERDR_MOBILE_NO_PANE", "1"),
            ("HERDR_KEEPER_ON_BLOCKED", hook.to_str().expect("utf-8")),
        ],
    );
    let id = id_of(&info);
    let mut phone = Phone::connect(&m.state_dir(), &id);
    phone.open_session(&m.work);

    // A request is held: the hook runs, with a summary that has lost its secrets.
    let turn = phone.prompt(
        "perm:curl -H \"Authorization: Bearer abcdef1234567890\" https://u:pw@x.io?token=zzz1234 sk-abcdefghijklmnop12",
    );
    wait_for("the blocked hook", || !hook_events(&m).is_empty());
    let events = hook_events(&m);
    assert_eq!(events.len(), 1, "{events:?}");
    let e = &events[0];
    assert_eq!(
        e[..5],
        strings(&[
            "blocked",
            &id,
            "omp",
            &m.work.to_string_lossy(),
            "Fake title"
        ])[..],
        "{e:?}"
    );
    assert!(e[5].starts_with("curl"), "{}", e[5]);
    for secret in [
        "abcdef1234567890",
        "pw@",
        "zzz1234",
        "sk-abcdefghijklmnop12",
    ] {
        assert!(!e[5].contains(secret), "{secret} in {}", e[5]);
    }
    assert!(e[5].chars().count() <= 120, "{}", e[5]);

    // The phone answers and is looking: the turn ending is not news.
    phone.allow_next_permission();
    assert_eq!(phone.finish_turn(turn)["stopReason"], "end_turn");

    // The phone goes away mid-turn; the turn ends unseen: "done".
    phone.prompt("gate");
    drop(phone);
    let dir = m.state_dir();
    wait_for("the keeper to notice the phone left", || {
        dir.read(&id).is_some_and(|i| i.clients == 0)
    });
    std::fs::write(m.root().join("gate"), "").expect("open the gate");
    wait_for("the done hook", || hook_events(&m).len() >= 2);
    let events = hook_events(&m);
    assert_eq!(events.len(), 2, "no other alert: {events:?}");
    assert_eq!(
        events[1],
        strings(&[
            "done",
            &id,
            "omp",
            &m.work.to_string_lossy(),
            "Fake title",
            "Turn finished (end_turn)"
        ])
    );
}

// -- the herdr pane --------------------------------------------------------------

/// The command typed into the pane.
fn pane_command(tui: &Path, id: &str) -> String {
    format!("'{}' attach {id}", tui.display())
}

fn fake_env(m: &Machine) -> Vec<(&'static str, String)> {
    vec![("HERDR_MOBILE_HERDR", m.fake.to_string_lossy().into_owned())]
}

fn as_pairs<'a>(env: &'a [(&'static str, String)]) -> Vec<(&'static str, &'a str)> {
    env.iter().map(|(k, v)| (*k, v.as_str())).collect()
}

#[test]
fn a_plain_folder_gets_phone_sessions_once_and_the_next_session_a_tab_in_it() {
    let mut m = Machine::new();
    let tui = m.install_tui();
    let env = fake_env(&m);
    let (one, two) = (m.work.join("one"), m.work.join("two"));
    std::fs::create_dir_all(&one).expect("one");
    std::fs::create_dir_all(&two).expect("two");

    // No `Phone sessions` yet: the first session makes it and takes its pane.
    let first = m.start(&one, &as_pairs(&env));
    let first_id = id_of(&first);
    wait_for("the first tab to be renamed", || m.herdr_calls().len() >= 4);
    assert_eq!(
        m.herdr_calls(),
        vec![
            strings(&["workspace", "list"]),
            strings(&[
                "workspace",
                "create",
                "--label",
                "Phone sessions",
                "--cwd",
                &one.to_string_lossy(),
                "--no-focus"
            ]),
            strings(&["pane", "run", "w1:p1", &pane_command(&tui, &first_id)]),
            strings(&["tab", "rename", "w1:t1", "omp \u{b7} one"]),
        ]
    );
    // The record says where the session is shown.
    let dir = m.state_dir();
    wait_for("pane_id in the record", || {
        dir.read(&first_id)
            .is_some_and(|i| i.pane_id.as_deref() == Some("w1:p1"))
    });

    // The next one gets a tab of its own in that workspace.
    let second = m.start(&two, &as_pairs(&env));
    let second_id = id_of(&second);
    wait_for("the second pane command", || m.herdr_calls().len() >= 7);
    assert_eq!(
        m.herdr_calls()[4..],
        [
            strings(&["workspace", "list"]),
            strings(&[
                "tab",
                "create",
                "--workspace",
                "w1",
                "--cwd",
                &two.to_string_lossy(),
                "--label",
                "omp \u{b7} two",
                "--no-focus"
            ]),
            strings(&["pane", "run", "w1:p2", &pane_command(&tui, &second_id)]),
        ]
    );
    wait_for("pane_id of the second session", || {
        dir.read(&second_id)
            .is_some_and(|i| i.pane_id.as_deref() == Some("w1:p2"))
    });
    assert_eq!(
        m.herdr_calls()
            .iter()
            .filter(|c| c[..2] == ["workspace", "create"])
            .count(),
        1,
        "`Phone sessions` is made once"
    );

    // Ended on request: the tab the keeper made goes with the session.
    let killed = m
        .command(&["kill", second_id.as_str()], &as_pairs(&env))
        .output()
        .expect("kill runs");
    assert!(
        killed.status.success(),
        "{}",
        String::from_utf8_lossy(&killed.stderr)
    );
    wait_for("the tab to be closed", || {
        m.herdr_calls().last() == Some(&strings(&["tab", "close", "w1:t2"]))
    });
}

/// A linked worktree `<work>/wt` herdr has open as workspace `w2`, next to the
/// main checkout's workspace `w3`.
fn seed_worktree(m: &Machine, wt: &Path) {
    let space = |id: &str, path: &Path, linked: bool| {
        format!(
            r#"{{"workspace_id":"{id}","label":"{id}","worktree":{{"checkout_path":"{}","is_linked_worktree":{linked}}}}}"#,
            path.display()
        )
    };
    m.seed(
        "workspaces.items",
        &format!("{},{}", space("w2", wt, true), space("w3", &m.work, false)),
    );
}

#[test]
fn a_folder_inside_a_linked_worktree_opens_its_tab_in_that_worktrees_workspace() {
    let mut m = Machine::new();
    let tui = m.install_tui();
    let env = fake_env(&m);
    let wt = m.work.join("wt");
    let inside = wt.join("app");
    std::fs::create_dir_all(&inside).expect("inside");
    seed_worktree(&m, &wt);

    let info = m.start(&inside, &as_pairs(&env));
    let id = id_of(&info);
    wait_for("the pane command", || m.herdr_calls().len() >= 4);
    assert_eq!(
        m.herdr_calls(),
        vec![
            strings(&["workspace", "list"]),
            // The worktree has no tab the keeper could take over: a tab of its own.
            strings(&["tab", "list", "--workspace", "w2"]),
            strings(&[
                "tab",
                "create",
                "--workspace",
                "w2",
                "--cwd",
                &inside.to_string_lossy(),
                "--label",
                "omp \u{b7} app",
                "--no-focus"
            ]),
            strings(&["pane", "run", "w2:p1", &pane_command(&tui, &id)]),
        ]
    );

    // The main checkout's workspace is the person's own: Phone sessions, as before.
    let other = m.work.join("main");
    std::fs::create_dir_all(&other).expect("main");
    let second = m.start(&other, &as_pairs(&env));
    wait_for("the second chain", || m.herdr_calls().len() >= 7);
    let _ = second;
    let calls = m.herdr_calls();
    assert_eq!(calls[4], strings(&["workspace", "list"]));
    assert_eq!(calls[5][..2], ["workspace", "create"], "{:?}", calls[5]);
}

#[test]
fn a_worktrees_untouched_shell_is_taken_and_anything_else_is_left_alone() {
    let mut m = Machine::new();
    let tui = m.install_tui();
    let env = fake_env(&m);
    let wt = m.work.join("wt");
    std::fs::create_dir_all(&wt).expect("wt");
    seed_worktree(&m, &wt);
    m.seed("tabs-w2.items", r#"{"tab_id":"w2:t1","pane_count":1}"#);
    m.seed(
        "panes-w2.items",
        r#"{"pane_id":"w2:p1","tab_id":"w2:t1","agent":null}"#,
    );

    // A shell that was just opened: the session takes it; no second tab.
    m.seed(
        "screen-w2:p1.txt",
        "tuan@host ~/wt$                          worktree/x\n\n\n",
    );
    let info = m.start(&wt, &as_pairs(&env));
    let id = id_of(&info);
    wait_for("the tab to be renamed", || m.herdr_calls().len() >= 6);
    assert_eq!(
        m.herdr_calls(),
        vec![
            strings(&["workspace", "list"]),
            strings(&["tab", "list", "--workspace", "w2"]),
            strings(&["pane", "list", "--workspace", "w2"]),
            strings(&["pane", "read", "w2:p1", "--lines", "30"]),
            strings(&["pane", "run", "w2:p1", &pane_command(&tui, &id)]),
            strings(&["tab", "rename", "w2:t1", "omp \u{b7} wt"]),
        ]
    );
    let dir = m.state_dir();
    wait_for("pane_id in the record", || {
        dir.read(&id)
            .is_some_and(|i| i.pane_id.as_deref() == Some("w2:p1"))
    });

    // A shell with a command typed half way is somebody's: a tab of its own
    // (the fake numbers new tabs from 10, so the two panes cannot be mixed up).
    m.seed("screen-w2:p1.txt", "tuan@host ~/wt$ git commi\n");
    m.seed("counter", "10");
    let before = m.herdr_calls().len();
    let info = m.start(&wt, &as_pairs(&env));
    let id = id_of(&info);
    wait_for("a tab of its own", || m.herdr_calls().len() >= before + 6);
    let calls = m.herdr_calls();
    assert_eq!(calls[before + 4][..2], ["tab", "create"], "{calls:?}");
    assert_eq!(
        calls[before + 5],
        strings(&["pane", "run", "w2:p11", &pane_command(&tui, &id)]),
        "nothing is typed into the shell that was left alone: {calls:?}"
    );
}

/// A start that opens no pane says why in its log, and herdr is never run.
fn assert_no_pane(m: &Machine, id: &str) {
    wait_for("the keeper to say it opens no pane", || {
        m.log_of(id).contains("no herdr pane")
    });
    assert!(m.herdr_calls().is_empty(), "{:?}", m.herdr_calls());
}

#[test]
fn no_pane_is_opened_when_the_person_or_the_machine_says_no() {
    let mut m = Machine::new();
    let tui = m.install_tui();
    let env = fake_env(&m);

    // `HERDR_MOBILE_NO_PANE=1` (a terminal client that is itself the pane).
    let mut off = as_pairs(&env);
    off.push(("HERDR_MOBILE_NO_PANE", "1"));
    let info = m.start(&m.work.clone(), &off);
    assert_no_pane(&m, &id_of(&info));

    // `~/.herdr-mobile/no-panes`.
    let no_panes = m.home.join(".herdr-mobile").join("no-panes");
    std::fs::write(&no_panes, "").expect("no-panes");
    let info = m.start(&m.work.clone(), &as_pairs(&env));
    assert_no_pane(&m, &id_of(&info));
    std::fs::remove_file(&no_panes).expect("remove no-panes");

    // Without `herdr-tui` nothing can show the session: no tab, even with herdr.
    std::fs::remove_file(&tui).expect("remove the tui");
    let info = m.start(&m.work.clone(), &as_pairs(&env));
    let id = id_of(&info);
    wait_for("the keeper to say there is no herdr-tui", || {
        m.log_of(&id).contains("herdr-tui is not installed")
    });
    assert!(m.herdr_calls().is_empty(), "{:?}", m.herdr_calls());

    // The control: with `herdr-tui` back, and only `1` switching it off, herdr is run.
    m.install_tui();
    let mut zero = as_pairs(&env);
    zero.push(("HERDR_MOBILE_NO_PANE", "0"));
    m.start(&m.work.clone(), &zero);
    wait_for("a pane with NO_PANE=0", || m.herdr_calls().len() >= 3);
}

// -- file descriptors and the umask ------------------------------------------------

#[cfg(target_os = "linux")]
fn fds_the_agent_saw(m: &Machine) -> Vec<i64> {
    let path = m.root().join("fds.json");
    wait_for("the agent to report its descriptors", || path.exists());
    // The agent writes it whole at `initialize`, before the keeper says "running".
    serde_json::from_str(&std::fs::read_to_string(&path).expect("read")).expect("a JSON list")
}

#[cfg(target_os = "linux")]
fn open_fds_of(pid: i64) -> Vec<i64> {
    let mut fds: Vec<i64> = std::fs::read_dir(format!("/proc/{pid}/fd"))
        .expect("the process is alive")
        .filter_map(|e| e.ok()?.file_name().to_str()?.parse().ok())
        .collect();
    fds.sort_unstable();
    fds
}

// Linux only: it reads `/proc/<pid>/fd`, which macOS does not have. The macOS
// descriptor closing is therefore not run by any test (launchd and the Mac
// paths are unverified, as the docs say).
#[cfg(target_os = "linux")]
#[test]
fn the_agent_gets_only_stdin_stdout_and_stderr_by_either_path() {
    let mut m = Machine::new();
    let fds_file = m.root().join("fds.json");
    let fds_path = fds_file.to_string_lossy().into_owned();
    // `close_range`, then the fallback loop (`HERDR_KEEPER_FD_SWEEP`).
    for sweep in [false, true] {
        let _ = std::fs::remove_file(&fds_file);
        let mut env = vec![
            ("HERDR_MOBILE_NO_PANE", "1"),
            ("FAKE_ACP_FDS_FILE", fds_path.as_str()),
        ];
        if sweep {
            env.push(("HERDR_KEEPER_FD_SWEEP", "1"));
        }
        // The starter leaves descriptor 7 open: it reaches the keeper, as the
        // phone's SSH channel would, and must stop there.
        let info = m.start_with(&m.work.clone(), &env, Some("exec 7</dev/null"));
        let daemon = info["pid"].as_i64().expect("the keeper's pid");
        assert!(
            open_fds_of(daemon).contains(&7),
            "the leak reached the keeper (else this proves nothing): {:?}",
            open_fds_of(daemon)
        );
        assert_eq!(fds_the_agent_saw(&m), vec![0, 1, 2], "sweep={sweep}");
        let agent = info["agent_pid"].as_i64().expect("the agent's pid");
        assert_eq!(open_fds_of(agent), vec![0, 1, 2], "sweep={sweep}");
    }
}

fn mode_of(path: &Path) -> u32 {
    std::fs::metadata(path).expect("stat").permissions().mode() & 0o777
}

#[test]
fn the_agent_gets_the_login_umask_and_the_keepers_own_files_stay_private() {
    let mut m = Machine::new();
    let written = m.root().join("agent-wrote-this");
    let env = [
        ("HERDR_MOBILE_NO_PANE", "1"),
        ("FAKE_ACP_UMASK_FILE", written.to_str().expect("utf-8")),
    ];
    let info = m.start_with(&m.work.clone(), &env, Some("umask 027"));
    let id = id_of(&info);
    // 0666 under umask 027 is 0640: the agent is not stuck with the keeper's 077.
    assert_eq!(mode_of(&written), 0o640);
    let dir = m.state_dir();
    for ext in ["sock", "json", "log"] {
        assert_eq!(mode_of(&dir.path(&id, ext)), 0o600, "{ext}");
    }
}

// -- a keeper that runs as a launchd job ---------------------------------------------

#[test]
fn a_launchd_job_keeper_says_so_in_its_record_gets_the_login_umask_and_hides_its_variables() {
    let mut m = Machine::new();
    let label = "dev.herdrmobile.keeper.0123456789ab";
    let id = "jobabc";
    let written = m.root().join("agent-wrote-this");
    let seen = m.root().join("agent-env.json");
    let mut daemon = m
        .command(
            &[
                "keeper-daemon",
                "--agent",
                "omp",
                "--cwd",
                &m.work.to_string_lossy(),
            ],
            &[
                ("HERDR_MOBILE_NO_PANE", "1"),
                ("HERDR_KEEPER_ID", id),
                ("HERDR_KEEPER_LABEL", label),
                // A job starts with launchd's umask; the one `start` read comes in here.
                ("HERDR_KEEPER_UMASK", "27"),
                ("FAKE_ACP_UMASK_FILE", written.to_str().expect("utf-8")),
                ("FAKE_ACP_ENV_FILE", seen.to_str().expect("utf-8")),
            ],
        )
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("the daemon starts");
    let pid = i64::from(daemon.id());
    m.started.push(pid);
    let dir = m.state_dir();
    wait_for("the job's keeper to be running", || {
        dir.read(id).is_some_and(|i| i.state == State::Running)
    });
    let record = dir.read(id).expect("the record");
    assert_eq!(record.extra["launchd"], label, "the record names the job");
    assert!(
        record.extra.get("login").is_none(),
        "no Keychain note off macOS"
    );
    assert_eq!(
        mode_of(&written),
        0o640,
        "the login's umask reached the agent"
    );
    let agent_env: Value =
        serde_json::from_str(&std::fs::read_to_string(&seen).expect("read")).expect("json");
    assert_eq!(
        agent_env,
        json!({"HERDR_KEEPER_LABEL": null, "HERDR_KEEPER_UMASK": null}),
        "the agent never sees the job's variables"
    );
    for ext in ["sock", "json", "log"] {
        assert_eq!(mode_of(&dir.path(id, ext)), 0o600, "{ext}");
    }
    // `kill` ends it like any keeper (the daemon is a `keeper-daemon` of this binary).
    let killed = m
        .command(&["kill", id], &[("HERDR_MOBILE_NO_PANE", "1")])
        .output()
        .expect("kill runs");
    assert!(
        killed.status.success(),
        "{}",
        String::from_utf8_lossy(&killed.stderr)
    );
    // The daemon is this test's child: collect it.
    daemon.wait().expect("the daemon ends");
}
