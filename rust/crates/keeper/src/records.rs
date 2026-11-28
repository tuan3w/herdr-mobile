//! The keeper's files: `~/.herdr-mobile/keepers/<id>.json` (its record),
//! `<id>.sock` (its socket) and `<id>.log`. A record keeps every field this
//! version does not know, so a newer or older keeper's files survive a rewrite.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// Ids avoid characters that look alike.
const ID_ALPHABET: &[u8] = b"abcdefghjkmnpqrstuvwxyz23456789";
const ID_LEN: usize = 6;
/// An exited keeper's record is kept this long, so the phone can still show why.
const KEEP_EXITED: Duration = Duration::from_secs(24 * 3600);
/// A keeper has this long to get its agent through `initialize`.
pub const INIT_TIMEOUT: Duration = Duration::from_secs(120);
/// Files of a keeper that has no record yet are not stale before this.
const ORPHAN_AFTER: Duration = Duration::from_secs(INIT_TIMEOUT.as_secs() + 30);

/// Where a keeper is in its life.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    /// Its agent has not answered `initialize` yet.
    Starting,
    #[default]
    Running,
    Exited,
}

/// A keeper's record. Fields this version does not know are kept in `extra`
/// and written back, so two versions can share a directory.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Info {
    pub id: String,
    #[serde(default)]
    pub agent: String,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    pub state: State,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<i64>,
    #[serde(default)]
    pub pending: u32,
    #[serde(default)]
    pub turn_active: bool,
    #[serde(default)]
    pub unseen_done: bool,
    #[serde(default)]
    pub clients: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exited_at: Option<i64>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

/// Whether `id` can name a keeper: lower case letters and digits, 3 to 32.
#[must_use]
pub fn is_valid_id(id: &str) -> bool {
    (3..=32).contains(&id.len())
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
}

/// A fresh id from the system's random source.
///
/// # Errors
/// When `/dev/urandom` cannot be read.
pub fn random_id() -> io::Result<String> {
    let mut urandom = fs::File::open("/dev/urandom")?;
    let mut id = String::with_capacity(ID_LEN);
    let mut byte = [0u8; 1];
    // Reject bytes past the last whole multiple of the alphabet: no modulo bias.
    let limit = 256 - 256 % ID_ALPHABET.len();
    while id.len() < ID_LEN {
        urandom.read_exact(&mut byte)?;
        if usize::from(byte[0]) < limit {
            id.push(char::from(
                ID_ALPHABET[usize::from(byte[0]) % ID_ALPHABET.len()],
            ));
        }
    }
    Ok(id)
}

/// What the host can say about a keeper's process and socket. A trait so the
/// scan can be tested without real processes.
pub trait Liveness {
    fn pid_alive(&self, pid: i64) -> bool;
    fn sock_alive(&self, dir: &StateDir, id: &str) -> bool;
}

/// The real thing: signal 0 and a connect.
#[derive(Clone, Copy, Debug)]
pub struct System;

impl Liveness for System {
    fn pid_alive(&self, pid: i64) -> bool {
        let Some(pid) = i32::try_from(pid)
            .ok()
            .and_then(rustix::process::Pid::from_raw)
        else {
            return false;
        };
        match rustix::process::test_kill_process(pid) {
            Ok(()) => true,
            Err(e) => e == rustix::io::Errno::PERM,
        }
    }

    fn sock_alive(&self, dir: &StateDir, id: &str) -> bool {
        dir.connect(id).is_ok()
    }
}

/// The directory holding keeper files.
#[derive(Clone, Debug)]
pub struct StateDir {
    root: PathBuf,
    /// The process has changed into [`root`](Self::root), so sockets can be
    /// reached by a short relative name.
    entered: bool,
}

impl StateDir {
    /// `~/.herdr-mobile/keepers`, made private (0700) when missing.
    ///
    /// # Errors
    /// When the directories cannot be made.
    pub fn create(home: &Path) -> io::Result<StateDir> {
        let base = home.join(".herdr-mobile");
        let root = base.join("keepers");
        for p in [&base, &root] {
            match fs::DirBuilder::new().mode(0o700).create(p) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
                Err(e) => return Err(e),
            }
        }
        // Both private, even when an earlier keeper (or the installer) left the
        // base 0755: the records are the phone's sessions, not world-readable.
        fs::set_permissions(&base, fs::Permissions::from_mode(0o700))?;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700))?;
        Ok(StateDir {
            root,
            entered: false,
        })
    }

    /// Changes the process into the directory. A unix socket path is limited to
    /// about 104 bytes and a long `$HOME` exceeds it, so sockets are reached by
    /// `<id>.sock` from inside. Process-wide: call it once, from a binary.
    ///
    /// # Errors
    /// When the directory cannot be entered.
    pub fn enter(&mut self) -> io::Result<()> {
        std::env::set_current_dir(&self.root)?;
        self.entered = true;
        Ok(())
    }

    /// The folder the records are in.
    #[must_use]
    pub fn root(&self) -> &Path {
        &self.root
    }

    #[must_use]
    pub fn path(&self, id: &str, ext: &str) -> PathBuf {
        let name = format!("{id}.{ext}");
        if self.entered {
            PathBuf::from(name)
        } else {
            self.root.join(name)
        }
    }

    /// Connects to a keeper's socket.
    ///
    /// # Errors
    /// When nothing listens there.
    pub fn connect(&self, id: &str) -> io::Result<UnixStream> {
        UnixStream::connect(self.path(id, "sock"))
    }

    /// The record of keeper `id`; `None` when missing or unreadable.
    #[must_use]
    pub fn read(&self, id: &str) -> Option<Info> {
        let raw = fs::read(self.path(id, "json")).ok()?;
        serde_json::from_slice(&raw).ok()
    }

    /// Writes the record atomically (temp file, then rename), private to the user.
    ///
    /// # Errors
    /// When the file cannot be written.
    pub fn write(&self, info: &Info) -> io::Result<()> {
        let target = self.path(&info.id, "json");
        let tmp = self.path(&info.id, &format!("json.tmp{}", std::process::id()));
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(&serde_json::to_vec(info).map_err(io::Error::other)?)?;
        drop(f);
        fs::rename(tmp, target)
    }

    /// Deletes a keeper's files; missing ones are fine. A keeper that ran as a
    /// macOS launchd job has that job unloaded too (best effort, no wait).
    pub fn remove(&self, id: &str) {
        let label = self.read(id).and_then(|i| {
            i.extra
                .get("launchd")
                .and_then(Value::as_str)
                .map(str::to_string)
        });
        if let Some(label) = label {
            crate::launchd::bootout(&label, false);
        }
        for ext in ["json", "sock", "log", "err"] {
            let _ = fs::remove_file(self.path(id, ext));
        }
    }

    /// All keepers on disk, newest first. A keeper whose process or socket is
    /// gone is recorded as exited; one that has been exited for a day is removed,
    /// as are leftover socket, log and temp files of keepers that never got a record.
    pub fn scan(&self, now_ms: i64, live: &dyn Liveness) -> Vec<Info> {
        let Ok(rd) = fs::read_dir(if self.entered {
            Path::new(".")
        } else {
            &self.root
        }) else {
            return Vec::new();
        };
        let names: Vec<String> = rd
            .filter_map(Result::ok)
            .filter_map(|e| e.file_name().into_string().ok())
            .collect();
        let mut out = Vec::new();
        for name in &names {
            let Some(id) = name.strip_suffix(".json") else {
                continue;
            };
            if !is_valid_id(id) {
                continue;
            }
            let Some(mut info) = self.read(id).filter(|i| i.id == id) else {
                continue;
            };
            if info.state != State::Exited && !self.is_alive(&info, now_ms, live) {
                mark_stale(&mut info, now_ms);
                let _ = self.write(&info);
                let _ = fs::remove_file(self.path(id, "sock"));
            }
            if info.state == State::Exited {
                let at = info.exited_at.or(info.started_at).unwrap_or(0);
                let keep = i64::try_from(KEEP_EXITED.as_millis()).unwrap_or(i64::MAX);
                if now_ms.saturating_sub(at) > keep {
                    self.remove(id);
                    continue;
                }
            }
            out.push(info);
        }
        self.clean_orphans(&names, &out);
        out.sort_by_key(|i| std::cmp::Reverse(i.started_at.unwrap_or(0)));
        out
    }

    fn is_alive(&self, info: &Info, now_ms: i64, live: &dyn Liveness) -> bool {
        if info.state == State::Starting && info.pid.is_some_and(|p| live.pid_alive(p)) {
            // It accepts no connections yet, so a probe cannot tell it from a dead
            // one: only its process says, until it is older than it may be.
            let limit = i64::try_from((INIT_TIMEOUT + Duration::from_secs(30)).as_millis())
                .unwrap_or(i64::MAX);
            if info
                .started_at
                .is_none_or(|t| now_ms.saturating_sub(t) < limit)
            {
                return true;
            }
        }
        info.pid.is_some_and(|p| live.pid_alive(p)) && live.sock_alive(self, &info.id)
    }

    fn clean_orphans(&self, names: &[String], known: &[Info]) {
        let old = |name: &str| {
            let path = if self.entered {
                PathBuf::from(name)
            } else {
                self.root.join(name)
            };
            fs::metadata(path)
                .and_then(|m| m.modified())
                .is_ok_and(|t| {
                    SystemTime::now()
                        .duration_since(t)
                        .is_ok_and(|age| age > ORPHAN_AFTER)
                })
        };
        for name in names {
            let orphan = match name.rsplit_once('.') {
                Some((stem, "sock" | "log")) => {
                    !known.iter().any(|i| i.id == stem) && !self.path(stem, "json").exists()
                }
                _ => name.contains(".json.tmp"),
            };
            if orphan && old(name) {
                let _ = fs::remove_file(if self.entered {
                    PathBuf::from(name)
                } else {
                    self.root.join(name)
                });
            }
        }
    }
}

/// A keeper whose process or socket is gone: record it as exited.
fn mark_stale(info: &mut Info, now_ms: i64) {
    info.state = State::Exited;
    info.pending = 0;
    info.turn_active = false;
    info.clients = 0;
    info.exit_reason.get_or_insert_with(|| {
        "The keeper process is gone (killed, or the host restarted).".to_string()
    });
    info.exited_at = Some(now_ms);
}

/// Whether `pid` runs a keeper. Never signal a recycled pid.
#[must_use]
pub fn is_keeper_pid(pid: i64) -> bool {
    if pid <= 1 {
        return false;
    }
    let cmd = fs::read(format!("/proc/{pid}/cmdline")).ok().or_else(|| {
        std::process::Command::new("ps")
            .args(["-o", "command=", "-p", &pid.to_string()])
            .output()
            .ok()
            .map(|o| o.stdout)
    });
    cmd.is_some_and(|cmd| is_keeper_command(&String::from_utf8_lossy(&cmd)))
}

/// Whether a command line (the arguments NUL-separated, as `/proc` has them,
/// or space-separated, as `ps` prints them) is a keeper's: a daemon started as
/// `herdr-host keeper-daemon …` or, from the terminal client,
/// `herdr-tui keeper-daemon …`. A bare `herdr-host serve` or `herdr-tui` is not
/// one. The python keeper of earlier versions (`herdr-keeper`, `keeper-*.py`)
/// still is, so a `kill` reaches the ones that may still be running.
#[must_use]
pub fn is_keeper_command(cmdline: &str) -> bool {
    let daemon = cmdline
        .split(|c: char| c == '\0' || c.is_whitespace())
        .any(|word| word == "keeper-daemon");
    (daemon && (cmdline.contains("herdr-host") || cmdline.contains("herdr-tui")))
        || cmdline.contains("herdr-keeper")
        || (cmdline.contains("keeper-") && cmdline.contains(".py"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::cell::RefCell;

    struct Fake {
        alive: Vec<i64>,
        sockets: bool,
        probed: RefCell<u32>,
    }

    impl Liveness for Fake {
        fn pid_alive(&self, pid: i64) -> bool {
            self.alive.contains(&pid)
        }
        fn sock_alive(&self, _: &StateDir, _: &str) -> bool {
            *self.probed.borrow_mut() += 1;
            self.sockets
        }
    }

    fn fake(alive: &[i64], sockets: bool) -> Fake {
        Fake {
            alive: alive.to_vec(),
            sockets,
            probed: RefCell::new(0),
        }
    }

    fn dir() -> (tempfile::TempDir, StateDir) {
        let home = tempfile::tempdir().expect("tempdir");
        let d = StateDir::create(home.path()).expect("state dir");
        (home, d)
    }

    fn info(id: &str, state: State, pid: i64, started: i64) -> Info {
        Info {
            id: id.into(),
            agent: "omp".into(),
            cwd: "/w".into(),
            state,
            pid: Some(pid),
            started_at: Some(started),
            ..Info::default()
        }
    }

    #[test]
    fn the_directory_and_its_files_are_private() {
        let (_h, d) = dir();
        d.write(&info("abc123", State::Running, 5, 1))
            .expect("write");
        let mode = |p: PathBuf| fs::metadata(p).expect("stat").permissions().mode() & 0o777;
        assert_eq!(
            mode(d.path("", "").parent().expect("parent").to_path_buf()),
            0o700
        );
        assert_eq!(mode(d.path("abc123", "json")), 0o600);
    }

    #[test]
    fn a_record_keeps_fields_this_version_does_not_know() {
        let (_h, d) = dir();
        let raw = json!({"id":"abc123","agent":"omp","cwd":"/w","state":"running","launchd":"dev.herdrmobile.keeper.0123456789ab","future":{"a":1}});
        fs::write(d.path("abc123", "json"), raw.to_string()).expect("write");
        let read = d.read("abc123").expect("read");
        d.write(&read).expect("write back");
        let back: Value =
            serde_json::from_slice(&fs::read(d.path("abc123", "json")).expect("read"))
                .expect("json");
        assert_eq!(back["future"], json!({"a": 1}));
        assert_eq!(back["launchd"], "dev.herdrmobile.keeper.0123456789ab");
    }

    #[test]
    fn ids_are_valid_and_the_alphabet_has_no_lookalikes() {
        for _ in 0..50 {
            let id = random_id().expect("id");
            assert!(is_valid_id(&id) && id.len() == 6, "{id}");
            assert!(!id.contains(['i', 'l', 'o', '0', '1']), "{id}");
        }
        assert!(!is_valid_id("AB") && !is_valid_id("a/b") && !is_valid_id(&"a".repeat(33)));
    }

    #[test]
    fn a_keeper_with_no_process_is_recorded_as_exited_once() {
        let (_h, d) = dir();
        let mut i = info("abc123", State::Running, 99, 1000);
        i.turn_active = true;
        i.pending = 2;
        d.write(&i).expect("write");
        let got = d.scan(2000, &fake(&[], true));
        assert_eq!(got[0].state, State::Exited);
        assert_eq!(
            (got[0].pending, got[0].turn_active, got[0].exited_at),
            (0, false, Some(2000))
        );
        assert!(got[0]
            .exit_reason
            .as_deref()
            .is_some_and(|r| r.contains("gone")));
        // The change was saved: the next scan does not need to probe again.
        assert_eq!(d.read("abc123").expect("read").state, State::Exited);
    }

    #[test]
    fn a_starting_keeper_is_judged_by_its_process_alone() {
        let (_h, d) = dir();
        d.write(&info("abc123", State::Starting, 7, 1000))
            .expect("write");
        let f = fake(&[7], false);
        assert_eq!(d.scan(2000, &f)[0].state, State::Starting);
        assert_eq!(*f.probed.borrow(), 0);
        // Older than it may be: probed like any other, and its socket is dead.
        assert_eq!(d.scan(1000 + 200_000, &f)[0].state, State::Exited);
    }

    #[test]
    fn an_old_exited_record_is_removed_and_a_recent_one_stays() {
        let (_h, d) = dir();
        let mut old = info("old111", State::Exited, 1, 1);
        old.exited_at = Some(1);
        let mut recent = info("new111", State::Exited, 1, 1);
        recent.exited_at = Some(90_000_000);
        d.write(&old).expect("write");
        d.write(&recent).expect("write");
        let got = d.scan(100_000_000, &fake(&[], false));
        assert_eq!(
            got.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
            ["new111"]
        );
        assert!(!d.path("old111", "json").exists());
    }

    #[test]
    fn scan_lists_newest_first_and_ignores_files_that_are_not_records() {
        let (_h, d) = dir();
        d.write(&info("aaa111", State::Running, 1, 10))
            .expect("write");
        d.write(&info("bbb222", State::Running, 1, 20))
            .expect("write");
        fs::write(d.path("zzz999", "json"), "not json").expect("write");
        fs::write(d.path("BAD", "json"), "{}").expect("write");
        let got = d.scan(30, &fake(&[1], true));
        assert_eq!(
            got.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
            ["bbb222", "aaa111"]
        );
    }

    #[test]
    fn the_system_probe_knows_this_process_is_alive_and_a_bad_pid_is_not() {
        let me = i64::from(std::process::id());
        assert!(System.pid_alive(me));
        assert!(!System.pid_alive(0) && !System.pid_alive(-5) && !System.pid_alive(i64::MAX));
    }

    #[test]
    fn a_keeper_is_a_daemon_of_herdr_host_or_herdr_tui_and_nothing_else() {
        for yes in [
            "/home/me/.herdr-mobile/bin/herdr-host-0.1.67\0keeper-daemon\0--agent\0omp\0--cwd\0/w\0",
            "/home/me/.herdr-mobile/bin/herdr-host keeper-daemon --agent omp --cwd /w",
            "/usr/local/bin/herdr-tui\0keeper-daemon\0--agent\0claude\0--cwd\0/w\0",
            "herdr-tui keeper-daemon --agent omp --cwd /w",
            // The python keeper of earlier versions.
            "python3\0/home/me/.herdr-mobile/keeper-0.1.30.py\0daemon\0",
            "herdr-keeper abc123",
        ] {
            assert!(is_keeper_command(yes), "{yes:?}");
        }
        for no in [
            "",
            "sleep\x00100\x00",
            "/home/me/.herdr-mobile/bin/herdr-host-0.1.67\0serve\0",
            "herdr-tui attach abc123",
            "herdr-host start --agent omp --cwd /w",
            "bash\0-c\0keeper-daemon\0",
            "/usr/bin/vim keeper-daemon",
        ] {
            assert!(!is_keeper_command(no), "{no:?}");
        }
        assert!(!is_keeper_pid(1) && !is_keeper_pid(0) && !is_keeper_pid(-1));
        assert!(
            !is_keeper_pid(i64::from(std::process::id())),
            "the test process is no keeper"
        );
    }
}
