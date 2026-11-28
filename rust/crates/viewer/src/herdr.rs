//! Tells herdr what this session is doing, so its agent list shows `working`, `blocked` or `idle`
//! for the pane `herdr-tui` runs in: only from inside a herdr pane, only on a change, never waited
//! for by the screen, one command at a time, the newest state winning.

use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// The source herdr keys these reports by; the same one the phone's keeper uses.
pub const SOURCE: &str = "herdr-mobile";
/// How long one `herdr pane ...` command may take before it is given up on.
const TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Working,
    /// A request waits for the person.
    Blocked,
    Idle,
}

impl State {
    fn word(self) -> &'static str {
        match self {
            State::Working => "working",
            State::Blocked => "blocked",
            State::Idle => "idle",
        }
    }
}

/// The herdr pane to report on, when this process runs inside one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    bin: PathBuf,
    pane: String,
}

impl Target {
    /// From the environment herdr gives its panes: `HERDR_ENV=1`, `HERDR_BIN_PATH`, `HERDR_PANE_ID`.
    #[must_use]
    pub fn from_env(get: impl Fn(&str) -> Option<String>) -> Option<Target> {
        if get("HERDR_ENV").as_deref() != Some("1") {
            return None;
        }
        let bin = get("HERDR_BIN_PATH").filter(|b| !b.is_empty())?;
        let pane = get("HERDR_PANE_ID").filter(|p| !p.is_empty())?;
        Some(Target {
            bin: PathBuf::from(bin),
            pane,
        })
    }
}

/// `herdr pane report-agent ...`
#[must_use]
pub fn report_argv(
    t: &Target,
    agent: &str,
    state: State,
    session_id: Option<&str>,
    resume: &[String],
    seq: u64,
) -> Vec<String> {
    let mut argv: Vec<String> = [
        &t.bin.to_string_lossy(),
        "pane",
        "report-agent",
        &t.pane,
        "--source",
        SOURCE,
        "--agent",
        agent,
        "--state",
        state.word(),
        "--seq",
        &seq.to_string(),
    ]
    .iter()
    .map(|s| (*s).to_string())
    .collect();
    if let Some(sid) = session_id.filter(|s| !s.is_empty()) {
        argv.extend(["--agent-session-id".to_string(), sid.to_string()]);
    }
    if !resume.is_empty() {
        argv.push("--".to_string());
        argv.extend(resume.iter().cloned());
    }
    argv
}

/// `herdr pane release-agent ...`: the pane is no agent any more.
#[must_use]
pub fn release_argv(t: &Target, agent: &str, seq: u64) -> Vec<String> {
    [
        &t.bin.to_string_lossy(),
        "pane",
        "release-agent",
        &t.pane,
        "--source",
        SOURCE,
        "--agent",
        agent,
        "--seq",
        &seq.to_string(),
    ]
    .iter()
    .map(|s| (*s).to_string())
    .collect()
}

/// A command for the worker to run.
#[derive(Debug, PartialEq, Eq)]
pub enum Job {
    Report(Vec<String>),
    Release(Vec<String>),
}

pub struct Reporter {
    target: Target,
    agent: String,
    resume: Vec<String>,
    last: Option<(State, Option<String>)>,
    seq: u64,
    tx: Sender<Job>,
    worker: Option<JoinHandle<()>>,
}

impl Reporter {
    /// A reporter that runs herdr commands on a worker thread.
    #[must_use]
    pub fn new(target: Target, agent: String, resume: Vec<String>) -> Reporter {
        let (reporter, rx) = Reporter::detached(target, agent, resume);
        let worker = thread::spawn(move || work(&rx));
        Reporter {
            worker: Some(worker),
            ..reporter
        }
    }

    /// A reporter whose jobs go to the returned receiver instead of being run (for tests).
    #[must_use]
    pub fn detached(
        target: Target,
        agent: String,
        resume: Vec<String>,
    ) -> (Reporter, Receiver<Job>) {
        let (tx, rx) = mpsc::channel();
        (
            Reporter {
                target,
                agent,
                resume,
                last: None,
                seq: 0,
                tx,
                worker: None,
            },
            rx,
        )
    }

    /// herdr ignores a report whose number is not above the last it took from this source, across
    /// restarts too, so the number is the clock.
    fn next_seq(&mut self) -> u64 {
        let micros = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| u64::try_from(d.as_micros()).unwrap_or(u64::MAX));
        self.seq = micros.max(self.seq + 1);
        self.seq
    }

    /// Reports `state` for session `sid`; nothing is sent when it is what was last reported.
    pub fn set(&mut self, state: State, sid: Option<&str>) {
        let now = (state, sid.map(str::to_string));
        if self.last.as_ref() == Some(&now) {
            return;
        }
        self.last = Some(now);
        let seq = self.next_seq();
        let argv = report_argv(&self.target, &self.agent, state, sid, &self.resume, seq);
        let _ = self.tx.send(Job::Report(argv));
    }

    /// The viewer leaves: the pane is no agent any more. Waits for the worker, a few seconds at most.
    pub fn release(mut self) {
        if self.last.is_none() {
            return;
        }
        let seq = self.next_seq();
        let _ = self
            .tx
            .send(Job::Release(release_argv(&self.target, &self.agent, seq)));
        let Reporter { tx, worker, .. } = self;
        drop(tx);
        if let Some(w) = worker {
            let _ = w.join();
        }
    }
}

impl Job {
    fn argv(&self) -> &[String] {
        match self {
            Job::Report(a) | Job::Release(a) => a,
        }
    }
}

/// Runs jobs one at a time. Reports that queued up while one ran are stale: only the newest is run,
/// but a release is never skipped.
fn work(rx: &Receiver<Job>) {
    while let Ok(mut job) = rx.recv() {
        while let Ok(next) = rx.try_recv() {
            if matches!(job, Job::Release(_)) {
                run(job.argv());
            }
            job = next;
        }
        run(job.argv());
    }
}

/// Runs one command with its output discarded, giving up on it after [`TIMEOUT`].
fn run(argv: &[String]) {
    let Some((bin, args)) = argv.split_first() else {
        return;
    };
    let Ok(mut child) = Command::new(bin)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
    else {
        return;
    };
    let deadline = Instant::now() + TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) | Err(_) => return,
            Ok(None) if Instant::now() >= deadline => {
                // The child is ours, started a moment ago: stop it and reap it.
                let _ = child.kill();
                let _ = child.wait();
                return;
            }
            Ok(None) => thread::sleep(Duration::from_millis(15)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target() -> Target {
        Target {
            bin: PathBuf::from("/usr/bin/herdr"),
            pane: "w1:p2".into(),
        }
    }

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let pairs: Vec<(String, String)> = pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect();
        move |k| pairs.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone())
    }

    #[test]
    fn it_reports_only_from_inside_a_herdr_pane() {
        let full = [
            ("HERDR_ENV", "1"),
            ("HERDR_BIN_PATH", "/usr/bin/herdr"),
            ("HERDR_PANE_ID", "w1:p2"),
        ];
        assert_eq!(Target::from_env(env(&full)), Some(target()));
        assert_eq!(
            Target::from_env(env(&[("HERDR_BIN_PATH", "/x"), ("HERDR_PANE_ID", "p")])),
            None,
            "no HERDR_ENV"
        );
        assert_eq!(
            Target::from_env(env(&[("HERDR_ENV", "1"), ("HERDR_PANE_ID", "p")])),
            None,
            "no binary"
        );
        assert_eq!(
            Target::from_env(env(&[("HERDR_ENV", "1"), ("HERDR_BIN_PATH", "/x")])),
            None,
            "no pane"
        );
        assert_eq!(
            Target::from_env(env(&[
                ("HERDR_ENV", "0"),
                ("HERDR_BIN_PATH", "/x"),
                ("HERDR_PANE_ID", "p")
            ])),
            None
        );
    }

    #[test]
    fn a_report_names_the_pane_source_agent_state_and_how_to_come_back() {
        let resume = vec![
            "/bin/herdr-tui".to_string(),
            "attach".to_string(),
            "abc123".to_string(),
        ];
        let argv = report_argv(
            &target(),
            "omp · phone",
            State::Blocked,
            Some("sess-1"),
            &resume,
            42,
        );
        assert_eq!(
            argv,
            [
                "/usr/bin/herdr",
                "pane",
                "report-agent",
                "w1:p2",
                "--source",
                "herdr-mobile",
                "--agent",
                "omp · phone",
                "--state",
                "blocked",
                "--seq",
                "42",
                "--agent-session-id",
                "sess-1",
                "--",
                "/bin/herdr-tui",
                "attach",
                "abc123"
            ]
        );
        let bare = report_argv(&target(), "omp · phone", State::Idle, None, &[], 1);
        assert!(
            !bare.contains(&"--agent-session-id".to_string()) && !bare.contains(&"--".to_string())
        );
    }

    #[test]
    fn releasing_names_the_same_source_and_agent() {
        assert_eq!(
            release_argv(&target(), "omp · phone", 9),
            [
                "/usr/bin/herdr",
                "pane",
                "release-agent",
                "w1:p2",
                "--source",
                "herdr-mobile",
                "--agent",
                "omp · phone",
                "--seq",
                "9"
            ]
        );
    }

    #[test]
    fn only_a_change_is_sent_and_every_report_outranks_the_last() {
        let (mut r, rx) = Reporter::detached(target(), "omp · phone".into(), vec![]);
        r.set(State::Idle, Some("s"));
        r.set(State::Idle, Some("s"));
        r.set(State::Working, Some("s"));
        r.set(State::Idle, Some("s"));
        let seqs: Vec<u64> = rx
            .try_iter()
            .map(|j| match j {
                Job::Report(a) => a[a.iter().position(|x| x == "--seq").expect("a seq") + 1]
                    .parse()
                    .expect("a number"),
                Job::Release(_) => panic!("no release yet"),
            })
            .collect();
        assert_eq!(seqs.len(), 3, "the repeated idle was not sent");
        assert!(seqs.windows(2).all(|w| w[1] > w[0]), "{seqs:?}");
    }

    #[test]
    fn a_new_session_id_is_a_change_even_in_the_same_state() {
        let (mut r, rx) = Reporter::detached(target(), "a".into(), vec![]);
        r.set(State::Idle, Some("one"));
        r.set(State::Idle, Some("two"));
        assert_eq!(rx.try_iter().count(), 2);
    }

    #[test]
    fn leaving_releases_only_when_something_was_reported() {
        let (r, rx) = Reporter::detached(target(), "a".into(), vec![]);
        r.release();
        assert_eq!(
            rx.try_iter().count(),
            0,
            "nothing was reported, so nothing to release"
        );
        let (mut r, rx) = Reporter::detached(target(), "a".into(), vec![]);
        r.set(State::Working, None);
        r.release();
        let jobs: Vec<Job> = rx.try_iter().collect();
        assert!(matches!(jobs.last(), Some(Job::Release(_))), "{jobs:?}");
    }

    #[test]
    fn a_command_that_hangs_is_given_up_on_and_one_that_is_missing_is_ignored() {
        let started = Instant::now();
        run(&["/bin/sleep".to_string(), "30".to_string()]);
        assert!(
            started.elapsed() < Duration::from_secs(8),
            "the hung command was killed after the timeout"
        );
        run(&["/definitely/not/a/herdr".to_string()]);
        run(&[]);
    }
}
