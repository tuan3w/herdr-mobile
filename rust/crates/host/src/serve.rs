//! `herdr-host serve`: the process the app starts on one exec channel.

use crate::session::{self, SessionOptions};
use std::fs::File;
use std::path::PathBuf;
use std::sync::Arc;
use wire::{HostInfo, Limits};

/// The first line of a failure the app shows: what `serve` could not do.
const WHO: &str = "herdr-host:";

/// What this host is, for the HELLO.
#[must_use]
pub fn host_info(home: &std::path::Path) -> HostInfo {
    let uname = rustix::system::uname();
    let hostname = uname.nodename().to_string_lossy().into_owned();
    let user = std::env::var("USER")
        .or_else(|_| std::env::var("LOGNAME"))
        .unwrap_or_else(|_| format!("uid{}", rustix::process::getuid().as_raw()));
    HostInfo {
        version: crate::VERSION.to_string(),
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        home: home.to_string_lossy().into_owned(),
        hostname,
        user,
    }
}

/// Moves the real stdout to a private file and points fd 1 at `/dev/null`, so a
/// stray `println!` anywhere in the process cannot corrupt the frames. The
/// private copy is close-on-exec: a keeper (or anything else `serve` starts)
/// must not inherit the wire, or the SSH channel would stay open, waiting for
/// that child, after `serve` itself has gone.
fn take_stdout() -> std::io::Result<File> {
    let real = rustix::io::fcntl_dupfd_cloexec(std::io::stdout(), 3)?;
    let null = File::options().write(true).open("/dev/null")?;
    rustix::stdio::dup2_stdout(&null)?;
    Ok(File::from(real))
}

/// `serve`: returns the process exit code.
#[must_use]
pub fn run() -> i32 {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        eprintln!("{WHO} serve needs $HOME");
        return keeper::exit::USAGE;
    };
    let out = match take_stdout() {
        Ok(f) => f,
        Err(e) => {
            eprintln!("{WHO} cannot take over stdout: {e}");
            return keeper::exit::FAILED;
        }
    };
    crate::install::prune_old_versions(&home);
    let options = SessionOptions {
        host: host_info(&home),
        home,
        limits: Limits::default(),
        stall: session::STALL,
        exit_on_write_error: true,
    };
    let stdin = std::io::stdin();
    session::run(stdin.lock(), out, Arc::new(crate::registry()), options)
}
