//! What a child the keeper starts must not inherit: every file descriptor above
//! stderr. The agent, a hook and a `herdr` command are run on the person's
//! behalf; a stray descriptor in one of them (the SSH channel's socket, a pipe
//! of the process that started the keeper) would keep that channel open for as
//! long as the child lives, and hand the child something it never asked for.
//! Python's `subprocess` closes them by default (`close_fds=True`); `std`'s
//! `Command` does not, for descriptors that are not already close-on-exec.
//!
//! This is the one module of the workspace that uses `unsafe`: `pre_exec` is
//! unsafe by contract, and so are the two system calls it makes.
//!
//! The descriptors are marked close-on-exec rather than closed. `std` reports a
//! failed `exec` to the parent through a close-on-exec pipe it keeps open in the
//! child; closing every descriptor from `pre_exec` would close that pipe too, a
//! failed `exec` would then read as a successful spawn, and the parent would
//! wait on a child that is already gone. Marked, the pipe stays usable until
//! `exec` succeeds, and every other descriptor is closed by `exec` itself.

#![allow(unsafe_code)]

use std::os::unix::process::CommandExt;
use std::process::Command;

/// The first descriptor a child may not inherit.
const FIRST: libc::c_int = 3;
/// The fallback sweeps at most this many descriptors.
const SWEEP_MAX: libc::c_long = 4096;

/// How the descriptors are found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Strategy {
    /// One `close_range(3, ~0, CLOSE_RANGE_CLOEXEC)` call (Linux 5.11 and
    /// later); the [`Sweep`](Strategy::Sweep) when that call is refused or the
    /// system has none (macOS, an older kernel).
    Auto,
    /// Every descriptor from 3 to `min(open-file limit, 4096)`, one by one.
    Sweep,
}

impl Strategy {
    /// [`Sweep`](Strategy::Sweep) when `HERDR_KEEPER_FD_SWEEP` is set (so the
    /// fallback can be exercised on a kernel that has `close_range`), else
    /// [`Auto`](Strategy::Auto).
    #[must_use]
    pub fn from_env() -> Strategy {
        if std::env::var_os("HERDR_KEEPER_FD_SWEEP").is_some() {
            Strategy::Sweep
        } else {
            Strategy::Auto
        }
    }
}

/// Makes `cmd`'s child start with only descriptors 0, 1 and 2.
pub fn close_inherited(cmd: &mut Command, strategy: Strategy) {
    let limit = sweep_limit();
    // SAFETY: the closure runs in the forked child, before `exec`, where only
    // async-signal-safe calls are allowed. `mark_close_on_exec` makes nothing
    // but raw system calls on integers: no allocation, no lock, no panic, and
    // it touches no memory of the parent.
    unsafe {
        cmd.pre_exec(move || {
            mark_close_on_exec(strategy, limit);
            Ok(())
        });
    }
}

/// How far the fallback sweeps: the open-file limit, at most [`SWEEP_MAX`].
/// Read in the parent, so the child makes no call that is not a plain syscall.
fn sweep_limit() -> libc::c_int {
    // SAFETY: `sysconf` reads a system constant and takes an integer name.
    let open_max = unsafe { libc::sysconf(libc::_SC_OPEN_MAX) };
    let limit = if open_max < 0 { 1024 } else { open_max };
    libc::c_int::try_from(limit.min(SWEEP_MAX)).unwrap_or(1024)
}

/// In the child: every descriptor from 3 up is closed by the coming `exec`.
fn mark_close_on_exec(strategy: Strategy, limit: libc::c_int) {
    #[cfg(target_os = "linux")]
    if strategy == Strategy::Auto {
        // SAFETY: `close_range(first, last, flags)` takes integers and only
        // sets or closes descriptors of this process; a kernel that does not
        // know it (or the flag) answers an error, handled below.
        let done = unsafe {
            libc::syscall(
                libc::SYS_close_range,
                libc::c_uint::try_from(FIRST).unwrap_or(3),
                libc::c_uint::MAX,
                libc::CLOSE_RANGE_CLOEXEC,
            )
        };
        if done == 0 {
            return;
        }
    }
    let _ = strategy;
    for fd in FIRST..limit {
        // SAFETY: `fcntl(fd, F_SETFD, FD_CLOEXEC)` on an integer; a descriptor
        // that is not open answers `EBADF`, which is the common case and is
        // ignored. It never closes anything, so no descriptor `std` still
        // needs in the child (its `exec` error pipe) is lost.
        unsafe {
            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
        }
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::process::Stdio;

    /// The descriptors a shell started with `cmd` sees, as numbers.
    fn seen_by_child(strategy: Option<Strategy>) -> Vec<u32> {
        let mut cmd = Command::new("/bin/sh");
        cmd.args([
            "-c",
            // The glob's own directory descriptor is listed but already closed
            // when the body runs: only descriptors that still exist count.
            "for f in /proc/$$/fd/*; do [ -e \"$f\" ] && echo ${f##*/}; done",
        ])
        .stdin(Stdio::null())
        .stderr(Stdio::null());
        if let Some(s) = strategy {
            close_inherited(&mut cmd, s);
        }
        let out = cmd.output().expect("sh runs");
        let mut fds: Vec<u32> = String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|l| l.trim().parse().ok())
            .collect();
        fds.sort_unstable();
        fds
    }

    #[test]
    fn a_stray_descriptor_is_not_inherited_by_either_strategy() {
        // `dup` makes a descriptor that is not close-on-exec: the kind a
        // starter leaks into the keeper.
        let file = std::fs::File::open("/proc/self/exe").expect("a file");
        let leaked = rustix::io::dup(&file).expect("a plain duplicate");
        let number = u32::try_from(std::os::fd::AsRawFd::as_raw_fd(&leaked)).expect("fd");

        let control = seen_by_child(None);
        assert!(
            control.contains(&number),
            "without the fix the child inherits {number}: {control:?}"
        );
        for strategy in [Strategy::Auto, Strategy::Sweep] {
            let seen = seen_by_child(Some(strategy));
            assert_eq!(seen, vec![0, 1, 2], "{strategy:?}");
        }
    }

    #[test]
    fn a_child_that_cannot_be_executed_is_still_reported_as_an_error() {
        // `std` reports a failed exec through a descriptor above 2: it must
        // survive the marking.
        for strategy in [Strategy::Auto, Strategy::Sweep] {
            let mut cmd = Command::new("/definitely/not/a/program");
            close_inherited(&mut cmd, strategy);
            let err = cmd.spawn().expect_err("exec fails");
            assert_eq!(err.kind(), std::io::ErrorKind::NotFound, "{strategy:?}");
        }
    }
}
