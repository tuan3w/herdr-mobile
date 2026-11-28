//! Starting and ending a keeper on this machine. The keeper is this program's own library
//! (`keeper::ctl`): a session's daemon is `herdr-tui keeper-daemon`, started detached so it
//! outlives the screen, and nothing else needs to be installed.

use std::path::Path;

/// Why a keeper did not start, in words, with the exit code the command should end with.
#[derive(Debug, PartialEq, Eq)]
pub struct StartError {
    pub code: i32,
    pub message: String,
}

impl From<keeper::ctl::CtlError> for StartError {
    fn from(e: keeper::ctl::CtlError) -> Self {
        StartError {
            code: e.code,
            message: e.message,
        }
    }
}

/// `$HOME` (given) and `$PATH` (this process's), the machine keepers run on.
fn env(home: &Path) -> keeper::ctl::Env {
    keeper::ctl::Env {
        home: home.to_path_buf(),
        ..keeper::ctl::Env::from_process()
    }
}

/// Ends keeper `id` for good: its agent, its socket and, in herdr, its tab. The keeper's own
/// `kill` does it, so the checks that protect a recycled pid stay in one place.
///
/// # Errors
/// When the keeper says no (no such session, not an id).
pub fn kill(home: &Path, id: &str) -> Result<(), StartError> {
    keeper::ctl::kill(&env(home), id).map_err(StartError::from)
}

/// This computer's name up to the first dot (`dev-box` for `dev-box.lan`), as the keeper tells other
/// clients which terminal is attached; `this computer` when it cannot be read.
#[must_use]
pub fn short_host() -> String {
    let raw = std::fs::read_to_string("/proc/sys/kernel/hostname")
        .ok()
        .or_else(|| std::env::var("HOSTNAME").ok())
        .unwrap_or_default();
    let short = crate::md::one_line(raw.trim().split('.').next().unwrap_or(""), 64);
    if short.is_empty() {
        "this computer".to_string()
    } else {
        short
    }
}

/// Starts a keeper for `agent` in `cwd` and returns its id. The keeper outlives this process.
/// The viewer is the pane (it reports to herdr itself, see herdr.rs), so the keeper is told not
/// to open a second herdr tab for the same session.
///
/// # Errors
/// When the keeper refuses (agent not installed, folder missing, the agent failing `initialize`).
pub fn start(home: &Path, agent: &str, cwd: &Path) -> Result<String, StartError> {
    let req = keeper::ctl::StartRequest {
        agent: agent.to_string(),
        cwd: cwd.to_string_lossy().into_owned(),
    };
    Ok(keeper::ctl::start_with(&env(home), &req, true)?.id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_keeper_that_refuses_gives_its_words_and_its_exit_code() {
        let home = tempfile::tempdir().expect("tempdir");
        let err = start(home.path(), "no-such-agent", home.path()).expect_err("refused");
        assert_eq!(err.code, keeper::exit::USAGE);
        assert_eq!(err.message, "unknown agent no-such-agent");
        let err = start(home.path(), "omp", &home.path().join("gone")).expect_err("no folder");
        assert_eq!(err.code, keeper::exit::GONE);
    }

    #[test]
    fn killing_a_session_that_does_not_exist_says_so() {
        let home = tempfile::tempdir().expect("tempdir");
        assert_eq!(
            kill(home.path(), "zzz999"),
            Err(StartError {
                code: keeper::exit::GONE,
                message: "no such keeper: zzz999".into()
            })
        );
    }

    #[test]
    fn the_host_name_is_short_one_line_and_never_empty() {
        let h = short_host();
        assert!(
            !h.is_empty() && !h.contains('.') && !h.chars().any(char::is_control),
            "{h:?}"
        );
    }
}
