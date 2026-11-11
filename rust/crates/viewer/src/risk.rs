//! How much a session mode lowers the guard between the agent and the machine. A port of the
//! phone's `app/lib/data/decision/mode_danger.dart` (same table, same words), so both surfaces
//! agree on which modes need a deliberate choice: a stray Shift-Tab must never switch the
//! permission prompts off.
//!
//! Pure. A mode is read by its id and by its display name and the worse reading wins.

/// How far a mode goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Risk {
    /// The agent asks as the person expects (default, plan, read-only).
    None,
    /// Part of the asking is switched off or delegated (accept edits, auto).
    Elevated,
    /// Nothing is asked: the agent runs and writes freely.
    Dangerous,
}

/// What a risky mode does, in a few words, for the line that asks the person to confirm.
#[must_use]
pub fn why(risk: Risk) -> &'static str {
    match risk {
        Risk::None => "",
        Risk::Elevated => "asks for less than usual",
        Risk::Dangerous => "skips permission checks",
    }
}

/// The risk of the mode with this `id` and display `name`.
#[must_use]
pub fn assess(id: &str, name: &str) -> Risk {
    one(id)
        .max(id_tail(id).map_or(Risk::None, one))
        .max(hermes(id))
        .max(one(name))
}

/// The last segment of an id that is a URL or path (Copilot's mode ids are
/// `https://agentclientprotocol.com/protocol/session-modes#autopilot`): the text after the last
/// `#`, else after the last `/`. `None` when the id has neither. The whole id is read too, so a
/// risky word before the segment still counts.
fn id_tail(id: &str) -> Option<&str> {
    let cut = if id.contains('#') {
        id.rfind('#')
    } else {
        id.rfind('/')
    }?;
    Some(&id[cut + 1..])
}

/// Hermes's edit modes by their own snake_case ids: `workspace_session` (edits in the workspace
/// are allowed), `dont_ask` and `session` (edits are allowed for the session; sensitive paths
/// still ask). The name `Don't Ask` is Claude's mode that runs nothing new, so Hermes's is told
/// by its id.
fn hermes(id: &str) -> Risk {
    match id {
        "dont_ask" | "workspace_session" | "session" => Risk::Elevated,
        _ => Risk::None,
    }
}

/// Modes the routes are known to send (`docs/AGENT_SESSIONS.md`), by compacted id or name.
fn known(key: &str) -> Option<Risk> {
    Some(match key {
        "bypasspermissions" | "agentfullaccess" | "fullaccess" | "dangerfullaccess"
        | "autopilot" => Risk::Dangerous,
        // Codex's `agent` is told by its name `Auto review`: the id is also Copilot's and
        // Cursor's default mode, whose policy is not on record (an unlisted `agent` is none).
        "acceptedits" | "auto" | "autoreview" => Risk::Elevated,
        "default" | "plan" | "build" | "planmode" | "dontask" | "readonly" | "workspacewrite"
        | "workspaceaccess" => Risk::None,
        _ => return None,
    })
}

/// Words (compacted) that make an unlisted mode dangerous.
const DANGER: [&str; 8] = [
    "bypass",
    "yolo",
    "fullaccess",
    "dangerously",
    "dangerfull",
    "skippermission",
    "skipapproval",
    "nosandbox",
];

/// Words (compacted) that make an unlisted mode elevated. A wrong "elevated" costs one extra
/// confirmation; a missed one costs the person's trust.
const ELEVATED: [&str; 11] = [
    "acceptedits",
    "autoaccept",
    "autoapprove",
    "autoedit",
    "acceptall",
    "dontask",
    "neverask",
    "noprompt",
    "noapproval",
    "unrestricted",
    "unsafe",
];

/// Lower-case letters and digits only (any script's letters stay).
fn compact(s: &str) -> String {
    s.to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_digit() || c.is_ascii_lowercase() || !c.is_ascii())
        .collect()
}

/// Words of `s`, split at anything that is not a letter or digit and at camelCase boundaries
/// (`autoAccept` is `auto`, `accept`).
fn tokens(s: &str) -> Vec<String> {
    let mut out = vec![String::new()];
    let mut prev_lower = false;
    for c in s.chars() {
        if !c.is_alphanumeric() {
            out.push(String::new());
            prev_lower = false;
            continue;
        }
        if c.is_uppercase() && prev_lower {
            out.push(String::new());
        }
        prev_lower = c.is_lowercase() || c.is_ascii_digit();
        if let Some(last) = out.last_mut() {
            last.extend(c.to_lowercase());
        }
    }
    out.retain(|t| !t.is_empty());
    out
}

fn one(raw: &str) -> Risk {
    let key = compact(raw);
    if key.is_empty() {
        return Risk::None;
    }
    if let Some(r) = known(&key) {
        return r;
    }
    if DANGER.iter().any(|w| key.contains(w)) {
        return Risk::Dangerous;
    }
    if ELEVATED.iter().any(|w| key.contains(w)) {
        return Risk::Elevated;
    }
    if tokens(raw)
        .iter()
        .any(|t| t == "auto" || t.starts_with("autonom"))
    {
        return Risk::Elevated;
    }
    Risk::None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_modes_the_routes_send_are_read_as_the_phone_reads_them() {
        // Claude Code, codex, omp.
        assert_eq!(
            assess("bypassPermissions", "Bypass Permissions"),
            Risk::Dangerous
        );
        assert_eq!(assess("agent-full-access", "Full access"), Risk::Dangerous);
        assert_eq!(assess("danger-full-access", ""), Risk::Dangerous);
        assert_eq!(assess("acceptEdits", "Accept Edits"), Risk::Elevated);
        assert_eq!(assess("auto", "Auto"), Risk::Elevated);
        assert_eq!(assess("agent", "Auto review"), Risk::Elevated);
        for safe in ["default", "plan", "dontAsk", "read-only", "workspace-write"] {
            assert_eq!(assess(safe, safe), Risk::None, "{safe}");
        }
        assert_eq!(assess("plan", "Plan Mode"), Risk::None);
    }

    #[test]
    fn copilot_hermes_and_the_unlisted_agent_mode_are_read_as_the_phone_reads_them() {
        let base = "https://agentclientprotocol.com/protocol/session-modes#";
        assert_eq!(
            assess(&format!("{base}autopilot"), "Autopilot"),
            Risk::Dangerous
        );
        assert_eq!(assess(&format!("{base}plan"), "Plan"), Risk::None);
        assert_eq!(assess(&format!("{base}agent"), "Agent"), Risk::None);
        assert_eq!(assess("agent", "Cursor Agent"), Risk::None);
        assert_eq!(
            assess("https://example.com/bypass#plan", "Plan"),
            Risk::Dangerous
        );
        assert_eq!(assess("accept_edits", "Accept Edits"), Risk::Elevated);
        assert_eq!(assess("dont_ask", "Don't Ask"), Risk::Elevated);
        assert_eq!(assess("workspace_session", "Accept Edits"), Risk::Elevated);
        assert_eq!(assess("session", "Don't Ask"), Risk::Elevated);
        assert_eq!(assess("ask", "Default"), Risk::None);
        assert_eq!(assess("dontAsk", "Don't Ask"), Risk::None, "Claude's own");
    }

    #[test]
    fn the_worse_of_the_id_and_the_name_wins_and_unlisted_modes_are_read_by_their_words() {
        assert_eq!(assess("m1", "Bypass everything"), Risk::Dangerous);
        assert_eq!(assess("yolo", "Fast"), Risk::Dangerous);
        assert_eq!(assess("autoAccept", ""), Risk::Elevated);
        assert_eq!(assess("m2", "Autonomous"), Risk::Elevated);
        assert_eq!(
            assess("m3", "Automatic"),
            Risk::None,
            "auto is a word, not a prefix"
        );
        assert_eq!(assess("review", "Careful"), Risk::None);
        assert_eq!(assess("", ""), Risk::None);
    }
}
