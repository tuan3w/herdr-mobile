//! The keeper: a small process that owns one agent process, so the agent
//! outlives the client (phone or terminal) that started it. See
//! `docs/AGENT_SESSIONS.md`.
//!
//! This crate is the reference for the keeper's files and wire: the phone
//! (through `herdr-host serve`) and the terminal client (`herdr-tui`) share
//! `~/.herdr-mobile/keepers/`, so what is written there and spoken on a
//! keeper's socket changes only with a matching change in both.

pub mod alerts;
pub mod ctl;
pub mod daemon;
pub mod fds;
pub mod follow;
pub mod history;
pub mod launchd;
pub mod linebuf;
pub mod pane;
pub mod records;
pub mod redact;
pub mod replay_log;
pub mod router;
pub mod routes;
pub mod search;
pub mod spawn;
pub mod zlib_batch;

/// Exit codes of the keeper commands, shared with the app (`keeper_command.dart`).
pub mod exit {
    pub const USAGE: i32 = 64;
    /// The folder does not exist, or no such keeper.
    pub const GONE: i32 = 66;
    /// The keeper's agent has exited.
    pub const EXITED: i32 = 67;
    /// The agent is not installed on this host.
    pub const MISSING: i32 = 69;
    /// The agent failed `initialize`, or the keeper did not start.
    pub const FAILED: i32 = 70;
}
