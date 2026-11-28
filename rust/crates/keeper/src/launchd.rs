//! macOS: starting a keeper as a launchd job of the person's desktop session.
//!
//! Claude Code on macOS keeps its login in the login Keychain, which macOS
//! opens only for processes of the desktop session. A keeper the phone starts
//! over SSH is a child of sshd, so the agent answers "Please run /login"
//! however often the person signs in. The fix is to start that keeper as a job
//! of `gui/<uid>`: the job runs the same `keeper-daemon` with the starter's
//! whole environment, outlives the SSH session like any daemon, and unloads
//! itself when the keeper ends. Ported from the python `start_via_launchd`
//! family (`keeper_script.dart` 308-331, 2727-2860).
//!
//! Everything that can be decided without macOS is plain data here — the
//! label, the property list, the `launchctl` command lines, and the rules for
//! when a keeper is started this way — so it is tested on any host. Only the
//! calls that run `launchctl` exist for macOS alone (elsewhere they do
//! nothing, and [`try_start`] never starts a job).

use std::collections::BTreeMap;
use std::path::Path;

/// A job's label is this, a dot and 12 hex digits.
pub const LABEL_PREFIX: &str = "dev.herdrmobile.keeper";

/// What gives Claude Code a login without the Keychain.
pub const CLAUDE_ENV_LOGINS: [&str; 6] = [
    "CLAUDE_CODE_OAUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
];

/// The job label for a 12-digit hex token.
#[must_use]
pub fn label(token: &str) -> String {
    format!("{LABEL_PREFIX}.{token}")
}

/// Whether `s` is a label this keeper makes: nothing else is ever handed to
/// `launchctl bootout`.
#[must_use]
pub fn is_label(s: &str) -> bool {
    s.strip_prefix(LABEL_PREFIX)
        .and_then(|rest| rest.strip_prefix('.'))
        .is_some_and(|tok| {
            tok.len() == 12
                && tok
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
}

/// Whether the environment already holds a Claude login (a token needs no
/// Keychain); `var` reads one variable.
pub fn has_env_login(var: impl Fn(&str) -> Option<String>) -> bool {
    CLAUDE_ENV_LOGINS
        .iter()
        .any(|k| var(k).is_some_and(|v| !v.is_empty()))
}

/// Whether the keeper of `agent` is started as a job of the desktop session:
/// on macOS, for Claude Code, unless the environment holds a login or the
/// person switched it off (`HERDR_MOBILE_NO_LAUNCHD`, for tests).
pub fn in_desktop_session(
    is_macos: bool,
    agent: &str,
    var: impl Fn(&str) -> Option<String>,
) -> bool {
    is_macos
        && agent == "claude"
        && var("HERDR_MOBILE_NO_LAUNCHD").is_none_or(|v| v.is_empty())
        && !has_env_login(var)
}

/// Whether the record says "this agent's login is in the Keychain, which this
/// keeper cannot open": Claude Code on macOS, in a keeper that is not a
/// desktop-session job, with no login in the environment. The phone tells the
/// person so when the agent asks for a login.
pub fn keychain_login(is_macos: bool, agent: &str, is_job: bool, env_login: bool) -> bool {
    is_macos && agent == "claude" && !is_job && !env_login
}

/// `gui/<uid>`: the desktop session's launchd domain.
#[must_use]
pub fn domain(uid: u32) -> String {
    format!("gui/{uid}")
}

/// `launchctl print gui/<uid>`: succeeds when somebody is logged in at the desktop.
#[must_use]
pub fn print_domain_argv(uid: u32) -> Vec<String> {
    argv(["print".to_string(), domain(uid)])
}

/// `launchctl print gui/<uid>/<label>`: the job's state.
#[must_use]
pub fn print_job_argv(uid: u32, label: &str) -> Vec<String> {
    argv(["print".to_string(), format!("{}/{label}", domain(uid))])
}

/// `launchctl bootstrap gui/<uid> <plist>`: loads (and so starts) the job.
#[must_use]
pub fn bootstrap_argv(uid: u32, plist: &Path) -> Vec<String> {
    argv([
        "bootstrap".to_string(),
        domain(uid),
        plist.to_string_lossy().into_owned(),
    ])
}

/// `launchctl bootout gui/<uid>/<label>`: unloads the job; a process it still
/// runs gets SIGTERM.
#[must_use]
pub fn bootout_argv(uid: u32, label: &str) -> Vec<String> {
    argv(["bootout".to_string(), format!("{}/{label}", domain(uid))])
}

fn argv(rest: impl IntoIterator<Item = String>) -> Vec<String> {
    std::iter::once("launchctl".to_string())
        .chain(rest)
        .collect()
}

/// What `launchctl print <job>` says about a job that is up.
#[must_use]
pub fn job_is_running(stdout: &str) -> bool {
    stdout.contains("state = running")
}

/// The property list of the job: the keeper daemon (`program`, its first
/// element the executable) run with `env`, in `working_dir`, once, with no
/// output. Keys are sorted, as the python's `plistlib` wrote them. `None` when
/// a string holds a character XML cannot carry (the python's `plistlib` refused
/// those too, and the keeper was then started the usual way).
#[must_use]
pub fn plist(
    label: &str,
    program: &[String],
    env: &BTreeMap<String, String>,
    working_dir: &Path,
) -> Option<String> {
    let working_dir = working_dir.to_string_lossy();
    let strings = std::iter::once(label)
        .chain(program.iter().map(String::as_str))
        .chain(env.iter().flat_map(|(k, v)| [k.as_str(), v.as_str()]))
        .chain(std::iter::once(&*working_dir));
    for s in strings {
        if s.chars()
            .any(|c| matches!(c, '\u{0}'..='\u{8}' | '\u{b}' | '\u{c}' | '\u{e}'..='\u{1f}'))
        {
            return None;
        }
    }
    let mut out = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
         <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
         <plist version=\"1.0\">\n<dict>\n",
    );
    out.push_str("\t<key>EnvironmentVariables</key>\n\t<dict>\n");
    for (k, v) in env {
        out.push_str(&format!(
            "\t\t<key>{}</key>\n\t\t<string>{}</string>\n",
            escape(k),
            escape(v)
        ));
    }
    out.push_str("\t</dict>\n\t<key>KeepAlive</key>\n\t<false/>\n");
    out.push_str(&format!(
        "\t<key>Label</key>\n\t<string>{}</string>\n",
        escape(label)
    ));
    out.push_str("\t<key>ProgramArguments</key>\n\t<array>\n");
    for p in program {
        out.push_str(&format!("\t\t<string>{}</string>\n", escape(p)));
    }
    out.push_str("\t</array>\n\t<key>RunAtLoad</key>\n\t<true/>\n");
    out.push_str("\t<key>StandardErrorPath</key>\n\t<string>/dev/null</string>\n");
    out.push_str("\t<key>StandardOutPath</key>\n\t<string>/dev/null</string>\n");
    out.push_str(&format!(
        "\t<key>WorkingDirectory</key>\n\t<string>{}</string>\n",
        escape(&working_dir)
    ));
    out.push_str("</dict>\n</plist>\n");
    Some(out)
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

// -- the daemon side ---------------------------------------------------------

/// What a keeper that runs as a job reads from its environment, and removes
/// from it so the agent never sees them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JobEnv {
    pub label: String,
    /// The login's umask, which a job does not start with.
    pub umask: Option<u32>,
}

/// Parses `HERDR_KEEPER_LABEL` and `HERDR_KEEPER_UMASK` (octal); `None` when
/// the label is missing or is not one of ours (an ordinary keeper).
#[must_use]
pub fn job_env(label: Option<&str>, umask: Option<&str>) -> Option<JobEnv> {
    let label = label.filter(|l| is_label(l))?;
    Some(JobEnv {
        label: label.to_string(),
        umask: umask
            .and_then(|u| u32::from_str_radix(u.trim(), 8).ok())
            .map(|m| m & 0o777),
    })
}

/// Reads and removes the job variables of this process. Call once, at the
/// start of the daemon, before any thread or child exists.
pub fn take_job_env() -> Option<JobEnv> {
    let label = std::env::var("HERDR_KEEPER_LABEL").ok();
    let umask = std::env::var("HERDR_KEEPER_UMASK").ok();
    let job = job_env(label.as_deref(), umask.as_deref());
    for k in ["HERDR_KEEPER_LABEL", "HERDR_KEEPER_UMASK"] {
        std::env::remove_var(k);
    }
    job
}

/// Unloads the job `label`: best effort, never an error. Waits for `launchctl`
/// only when `wait` (a keeper that ends unloads its own job without waiting:
/// the unload ends it).
pub fn bootout(label: &str, wait: bool) {
    if is_label(label) {
        run_launchctl(&bootout_argv(uid(), label), wait);
    }
}

fn uid() -> u32 {
    rustix::process::getuid().as_raw()
}

/// A job started by [`try_start`].
#[derive(Clone, Debug)]
pub struct Job {
    pub label: String,
    started: std::time::Instant,
    checked: std::time::Instant,
}

impl Job {
    /// Whether the job has ended without a trace: asked at most once a second
    /// and not in the first three, as the python did.
    pub fn ended(&mut self) -> bool {
        let now = std::time::Instant::now();
        if now.duration_since(self.started) <= std::time::Duration::from_secs(3)
            || now.duration_since(self.checked) < std::time::Duration::from_secs(1)
        {
            return false;
        }
        self.checked = now;
        match launchctl_output(&print_job_argv(uid(), &self.label)) {
            Some((status, stdout)) => !status || !job_is_running(&stdout),
            None => false,
        }
    }

    /// The job failed to start the keeper: unload it.
    pub fn abandon(&self) {
        bootout(&self.label, true);
    }
}

/// Starts the keeper of `agent` in `cwd` as a job of the desktop session when
/// that is wanted and possible. `None`: start it the usual way (not macOS, not
/// Claude, a login in the environment, nobody logged in at the desktop,
/// `launchctl` refused).
#[must_use]
pub fn try_start(
    state_dir: &Path,
    exe: &Path,
    id: &str,
    agent: &str,
    cwd: &Path,
    no_pane: bool,
) -> Option<Job> {
    #[cfg(target_os = "macos")]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let var = |k: &str| std::env::var(k).ok();
        if !in_desktop_session(true, agent, var) {
            return None;
        }
        let uid = uid();
        let (up, _) = launchctl_output(&print_domain_argv(uid))?;
        if !up {
            return None;
        }
        let token = crate::spawn::epoch();
        let label = label(&token);
        let mut env: BTreeMap<String, String> = std::env::vars_os()
            .filter_map(|(k, v)| Some((k.into_string().ok()?, v.into_string().ok()?)))
            .collect();
        env.insert("HERDR_KEEPER_ID".into(), id.into());
        env.insert("HERDR_KEEPER_LABEL".into(), label.clone());
        // The job starts with launchd's umask, not the login's.
        env.insert("HERDR_KEEPER_UMASK".into(), format!("{:o}", login_umask()));
        if no_pane {
            env.insert("HERDR_MOBILE_NO_PANE".into(), "1".into());
        }
        let program: Vec<String> = vec![
            exe.to_string_lossy().into_owned(),
            "keeper-daemon".into(),
            "--agent".into(),
            agent.into(),
            "--cwd".into(),
            cwd.to_string_lossy().into_owned(),
        ];
        let text = plist(&label, &program, &env, state_dir)?;
        // The environment can hold a token: the file is private and gone once
        // launchd has read it.
        let path = state_dir.join(format!("start-{token}.plist"));
        let written = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .and_then(|mut f| f.write_all(text.as_bytes()));
        let loaded = written.is_ok()
            && launchctl_output(&bootstrap_argv(uid, &path)).is_some_and(|(ok, _)| ok);
        let _ = std::fs::remove_file(&path);
        if !loaded {
            return None;
        }
        let now = std::time::Instant::now();
        Some(Job {
            label,
            started: now,
            checked: now,
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (state_dir, exe, id, agent, cwd, no_pane);
        None
    }
}

/// This process's umask. Linux says so in `/proc`; elsewhere it is read by
/// setting a value and putting the old one back.
#[cfg(target_os = "macos")]
fn login_umask() -> u32 {
    use rustix::fs::Mode;
    let old = rustix::process::umask(Mode::from_bits_truncate(0o077));
    rustix::process::umask(old);
    u32::from(old.bits()) & 0o777
}

/// Runs `launchctl` and returns whether it exited 0 and what it printed.
/// `None` when it cannot be run or does not finish in ten seconds.
#[cfg(target_os = "macos")]
fn launchctl_output(argv: &[String]) -> Option<(bool, String)> {
    use std::io::Read;
    use std::process::{Command, Stdio};
    let mut child = Command::new(argv.first()?)
        .args(&argv[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = stdout.read_to_string(&mut text);
        text
    });
    let end = std::time::Instant::now() + std::time::Duration::from_secs(10);
    let status = loop {
        match child.try_wait().ok()? {
            Some(s) => break s,
            None if std::time::Instant::now() >= end => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            None => std::thread::sleep(std::time::Duration::from_millis(20)),
        }
    };
    Some((status.success(), reader.join().unwrap_or_default()))
}

#[cfg(not(target_os = "macos"))]
fn launchctl_output(_argv: &[String]) -> Option<(bool, String)> {
    None
}

/// `launchctl <argv>` without a wait or an answer.
#[cfg(target_os = "macos")]
fn run_launchctl(argv: &[String], wait: bool) {
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};
    let Some(program) = argv.first() else { return };
    let Ok(mut child) = Command::new(program)
        .args(&argv[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
    else {
        return;
    };
    if wait {
        let end = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while std::time::Instant::now() < end {
            if child.try_wait().is_ok_and(|s| s.is_some()) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        let _ = child.kill();
        let _ = child.wait();
    }
}

#[cfg(not(target_os = "macos"))]
fn run_launchctl(_argv: &[String], _wait: bool) {}

#[cfg(test)]
mod tests {
    use super::*;

    const LABEL: &str = "dev.herdrmobile.keeper.0123456789ab";

    fn none(_: &str) -> Option<String> {
        None
    }

    #[test]
    fn only_a_label_this_keeper_makes_is_one() {
        assert_eq!(label("0123456789ab"), LABEL);
        assert!(is_label(LABEL));
        for bad in [
            "",
            "dev.herdrmobile.keeper.",
            "dev.herdrmobile.keeper.0123456789a",
            "dev.herdrmobile.keeper.0123456789abc",
            "dev.herdrmobile.keeper.0123456789AB",
            "dev.herdrmobile.keeper.0123456789ag",
            "com.apple.something.0123456789ab",
            "dev.herdrmobile.keeper.0123456789ab/../x",
        ] {
            assert!(!is_label(bad), "{bad:?}");
        }
    }

    #[test]
    fn the_command_lines_are_launchctls_gui_domain() {
        let path = Path::new("/h/.herdr-mobile/keepers/start-0123456789ab.plist");
        assert_eq!(domain(501), "gui/501");
        assert_eq!(print_domain_argv(501), ["launchctl", "print", "gui/501"]);
        assert_eq!(
            print_job_argv(501, LABEL),
            [
                "launchctl",
                "print",
                "gui/501/dev.herdrmobile.keeper.0123456789ab"
            ]
        );
        assert_eq!(
            bootstrap_argv(501, path),
            [
                "launchctl",
                "bootstrap",
                "gui/501",
                "/h/.herdr-mobile/keepers/start-0123456789ab.plist"
            ]
        );
        assert_eq!(
            bootout_argv(501, LABEL),
            [
                "launchctl",
                "bootout",
                "gui/501/dev.herdrmobile.keeper.0123456789ab"
            ]
        );
    }

    #[test]
    fn the_plist_is_the_job_the_python_wrote() {
        let env: BTreeMap<String, String> = [
            ("HERDR_KEEPER_ID".to_string(), "abc123".to_string()),
            ("HERDR_KEEPER_LABEL".to_string(), LABEL.to_string()),
            ("HERDR_KEEPER_UMASK".to_string(), "27".to_string()),
            ("NOTE".to_string(), "a<b & c>d".to_string()),
        ]
        .into();
        let program: Vec<String> = [
            "/h/bin/herdr-host-1",
            "keeper-daemon",
            "--agent",
            "claude",
            "--cwd",
            "/w/p&q",
        ]
        .map(String::from)
        .into();
        let text =
            plist(LABEL, &program, &env, Path::new("/h/.herdr-mobile/keepers")).expect("a plist");
        let want = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
\t<key>EnvironmentVariables</key>
\t<dict>
\t\t<key>HERDR_KEEPER_ID</key>
\t\t<string>abc123</string>
\t\t<key>HERDR_KEEPER_LABEL</key>
\t\t<string>dev.herdrmobile.keeper.0123456789ab</string>
\t\t<key>HERDR_KEEPER_UMASK</key>
\t\t<string>27</string>
\t\t<key>NOTE</key>
\t\t<string>a&lt;b &amp; c&gt;d</string>
\t</dict>
\t<key>KeepAlive</key>
\t<false/>
\t<key>Label</key>
\t<string>dev.herdrmobile.keeper.0123456789ab</string>
\t<key>ProgramArguments</key>
\t<array>
\t\t<string>/h/bin/herdr-host-1</string>
\t\t<string>keeper-daemon</string>
\t\t<string>--agent</string>
\t\t<string>claude</string>
\t\t<string>--cwd</string>
\t\t<string>/w/p&amp;q</string>
\t</array>
\t<key>RunAtLoad</key>
\t<true/>
\t<key>StandardErrorPath</key>
\t<string>/dev/null</string>
\t<key>StandardOutPath</key>
\t<string>/dev/null</string>
\t<key>WorkingDirectory</key>
\t<string>/h/.herdr-mobile/keepers</string>
</dict>
</plist>
";
        assert_eq!(text, want);
    }

    #[test]
    fn a_string_xml_cannot_carry_means_no_job() {
        let env: BTreeMap<String, String> = [("X".to_string(), "bell\u{7}".to_string())].into();
        let program = vec!["/bin/x".to_string()];
        assert_eq!(plist(LABEL, &program, &env, Path::new("/w")), None);
        // Tab, newline and carriage return are fine.
        let ok: BTreeMap<String, String> = [("X".to_string(), "a\tb\nc\r".to_string())].into();
        assert!(plist(LABEL, &program, &ok, Path::new("/w")).is_some());
    }

    #[test]
    fn claude_on_a_mac_without_a_login_in_the_environment_starts_in_the_desktop_session() {
        assert!(in_desktop_session(true, "claude", none));
        assert!(!in_desktop_session(false, "claude", none), "not macOS");
        assert!(!in_desktop_session(true, "omp", none), "not Claude");
        for k in CLAUDE_ENV_LOGINS {
            let var = |name: &str| (name == k).then(|| "x".to_string());
            assert!(!in_desktop_session(true, "claude", var), "{k} is a login");
        }
        let empty = |name: &str| (name == "ANTHROPIC_API_KEY").then(String::new);
        assert!(
            in_desktop_session(true, "claude", empty),
            "an empty variable is none"
        );
        let off = |name: &str| (name == "HERDR_MOBILE_NO_LAUNCHD").then(|| "1".to_string());
        assert!(!in_desktop_session(true, "claude", off), "switched off");
    }

    #[test]
    fn the_keychain_note_is_for_claude_keepers_that_cannot_open_it() {
        assert!(keychain_login(true, "claude", false, false));
        assert!(
            !keychain_login(true, "claude", true, false),
            "a desktop-session job can"
        );
        assert!(
            !keychain_login(true, "claude", false, true),
            "a token in the environment"
        );
        assert!(
            !keychain_login(false, "claude", false, false),
            "no Keychain off macOS"
        );
        assert!(!keychain_login(true, "omp", false, false));
    }

    #[test]
    fn a_job_reads_its_label_and_umask_and_nothing_else_is_a_job() {
        assert_eq!(
            job_env(Some(LABEL), Some("27")),
            Some(JobEnv {
                label: LABEL.into(),
                umask: Some(0o27)
            })
        );
        assert_eq!(
            job_env(Some(LABEL), Some("1777")).map(|j| j.umask),
            Some(Some(0o777)),
            "only the permission bits"
        );
        assert_eq!(
            job_env(Some(LABEL), Some("zz")).map(|j| j.umask),
            Some(None)
        );
        assert_eq!(job_env(Some(LABEL), None).map(|j| j.umask), Some(None));
        assert_eq!(
            job_env(Some("dev.herdrmobile.keeper.nope"), Some("27")),
            None
        );
        assert_eq!(job_env(None, Some("27")), None);
    }

    #[test]
    fn a_job_that_is_up_says_so() {
        assert!(job_is_running("x = {\n\tstate = running\n}"));
        assert!(!job_is_running("x = {\n\tstate = waiting\n}"));
        assert!(!job_is_running(""));
    }
}
