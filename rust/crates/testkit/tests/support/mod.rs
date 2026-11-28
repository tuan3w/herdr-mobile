//! A child process with line-oriented stdout, for driving the fixtures.
#![allow(dead_code)]

use serde_json::Value;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Long enough for a loaded CI machine, short enough to fail a hung test.
pub const WAIT: Duration = Duration::from_secs(20);

pub struct Proc {
    pub child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<String>,
    stderr: Arc<Mutex<Vec<u8>>>,
}

impl Proc {
    /// Starts `exe` with `FAKE_ACP_*` removed from the environment, then `env` set.
    pub fn spawn(exe: &Path, args: &[&str], env: &[(&str, &str)], cwd: Option<&Path>) -> Proc {
        let mut cmd = Command::new(exe);
        cmd.args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for (key, _) in std::env::vars() {
            if key.starts_with("FAKE_ACP") || key == "BENCH_SEED" {
                cmd.env_remove(key);
            }
        }
        cmd.envs(env.iter().copied());
        if let Some(cwd) = cwd {
            cmd.current_dir(cwd);
        }
        let mut child = cmd.spawn().expect("the fixture starts");
        let stdout = child.stdout.take().expect("piped stdout");
        let mut stderr = child.stderr.take().expect("piped stderr");
        let (tx, lines) = channel();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            let mut buf = Vec::new();
            loop {
                buf.clear();
                match reader.read_until(b'\n', &mut buf) {
                    Ok(0) | Err(_) => return,
                    Ok(_) => {
                        let line = String::from_utf8_lossy(&buf)
                            .trim_end_matches('\n')
                            .to_string();
                        if tx.send(line).is_err() {
                            return;
                        }
                    }
                }
            }
        });
        let captured = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&captured);
        std::thread::spawn(move || {
            let mut chunk = [0u8; 4096];
            while let Ok(n) = stderr.read(&mut chunk) {
                if n == 0 {
                    return;
                }
                if let Ok(mut all) = sink.lock() {
                    all.extend_from_slice(&chunk[..n]);
                }
            }
        });
        let stdin = child.stdin.take();
        Proc {
            child,
            stdin,
            lines,
            stderr: captured,
        }
    }

    pub fn send_raw(&mut self, text: &str) {
        let stdin = self.stdin.as_mut().expect("stdin is open");
        stdin
            .write_all(text.as_bytes())
            .expect("write to the fixture");
        stdin.flush().expect("flush to the fixture");
    }

    pub fn send(&mut self, value: &Value) {
        self.send_raw(&format!("{value}\n"));
    }

    pub fn close_stdin(&mut self) {
        self.stdin = None;
    }

    /// The next stdout line; `None` at EOF; panics after [`WAIT`].
    pub fn line(&self) -> Option<String> {
        match self.lines.recv_timeout(WAIT) {
            Ok(line) => Some(line),
            Err(RecvTimeoutError::Disconnected) => None,
            Err(RecvTimeoutError::Timeout) => {
                panic!("no output for {WAIT:?}; stderr: {}", self.stderr())
            }
        }
    }

    /// The next stdout line, `None` when nothing arrives within `wait`.
    pub fn line_within(&self, wait: Duration) -> Option<String> {
        self.lines.recv_timeout(wait).ok()
    }

    /// The next line as JSON.
    pub fn msg(&self) -> Value {
        let line = self.line().expect("the fixture is still writing");
        serde_json::from_str(&line).unwrap_or_else(|e| panic!("not JSON ({e}): {line}"))
    }

    /// Everything up to and including the first message `done` accepts.
    pub fn until(&self, done: impl Fn(&Value) -> bool) -> Vec<Value> {
        let mut seen = Vec::new();
        loop {
            let m = self.msg();
            let end = done(&m);
            seen.push(m);
            if end {
                return seen;
            }
        }
    }

    pub fn stderr(&self) -> String {
        let all = self.stderr.lock().map(|b| b.clone()).unwrap_or_default();
        String::from_utf8_lossy(&all).into_owned()
    }

    /// Waits for the process to exit (polls; panics after [`WAIT`]).
    pub fn wait(&mut self) -> ExitStatus {
        let start = Instant::now();
        loop {
            if let Some(status) = self.child.try_wait().expect("wait") {
                return status;
            }
            assert!(
                start.elapsed() < WAIT,
                "the fixture did not exit; stderr: {}",
                self.stderr()
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

impl Drop for Proc {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
