//! herdr as a [`Backend`]: its API is one JSON request per connection on a unix
//! socket, one JSON line back; `events.subscribe` keeps its connection and
//! streams one JSON line per event.

use super::{Availability, Backend, BackendError, EventSource};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::unix::fs::FileTypeExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;
use wire::{ClientHello, HerdrHello};

/// How long herdr may take to answer a request or acknowledge a subscription.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(30);

/// The longest line read from herdr: a 1000-row pane read is ~140 KB, so this
/// only stops a runaway peer from filling the host's memory.
const MAX_LINE: u64 = 64 << 20;

/// What the session name may be: `^[A-Za-z0-9._-]+$`, the same rule the app
/// applies (`_checkSession` in `bridge_command.dart`).
#[must_use]
pub fn is_safe_session(session: &str) -> bool {
    !session.is_empty()
        && session
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// herdr's socket for `session`: `socket` when the client gave one, else
/// `<config>/herdr[/sessions/<session>]/herdr.sock` where `<config>` is
/// `$XDG_CONFIG_HOME` (when set and not empty) or `$HOME/.config`.
///
/// # Errors
/// The reason, when `session` is not a safe name or no config folder can be
/// found.
pub fn socket_path(
    socket: Option<&str>,
    session: &str,
    xdg_config_home: Option<&Path>,
    home: Option<&Path>,
) -> Result<PathBuf, String> {
    if !is_safe_session(session) {
        return Err(format!("invalid herdr session name {session:?}"));
    }
    if let Some(socket) = socket.filter(|s| !s.is_empty()) {
        return Ok(PathBuf::from(socket));
    }
    let config = match (xdg_config_home.filter(|p| !p.as_os_str().is_empty()), home) {
        (Some(xdg), _) => xdg.to_path_buf(),
        (None, Some(home)) => home.join(".config"),
        (None, None) => return Err("neither $XDG_CONFIG_HOME nor $HOME is set".to_string()),
    };
    let mut path = config.join("herdr");
    if session != "default" {
        path.push("sessions");
        path.push(session);
    }
    path.push("herdr.sock");
    Ok(path)
}

#[derive(Clone, Debug)]
enum Config {
    /// `$XDG_CONFIG_HOME` / `$HOME`, read when the socket is looked for.
    Env,
    /// A fixed config folder (the one that holds `herdr/`).
    Dir(PathBuf),
}

/// herdr, found the way herdr itself finds its socket.
#[derive(Clone, Debug)]
pub struct HerdrBackend {
    config: Config,
    /// The socket of a backend [`bind`](Backend::bind)-ed to one stream.
    bound: Option<Result<PathBuf, String>>,
}

impl Default for HerdrBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl HerdrBackend {
    /// Reads `$XDG_CONFIG_HOME` and `$HOME` from the process environment each
    /// time it looks for the socket.
    #[must_use]
    pub fn new() -> Self {
        Self {
            config: Config::Env,
            bound: None,
        }
    }

    /// Looks for sockets under `config_dir/herdr/` whatever the environment
    /// says (tests).
    #[must_use]
    pub fn with_config_dir(config_dir: impl Into<PathBuf>) -> Self {
        Self {
            config: Config::Dir(config_dir.into()),
            bound: None,
        }
    }

    /// The socket `hello` names, or why there is none.
    ///
    /// # Errors
    /// See [`socket_path`].
    pub fn resolve(&self, hello: &ClientHello) -> Result<PathBuf, String> {
        let herdr = &hello.herdr;
        match &self.config {
            Config::Env => {
                let xdg = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from);
                let home = std::env::var_os("HOME").map(PathBuf::from);
                socket_path(
                    herdr.socket.as_deref(),
                    &herdr.session,
                    xdg.as_deref(),
                    home.as_deref(),
                )
            }
            Config::Dir(dir) => {
                socket_path(herdr.socket.as_deref(), &herdr.session, Some(dir), None)
            }
        }
    }

    fn socket(&self) -> Result<PathBuf, BackendError> {
        let found = match &self.bound {
            Some(found) => found.clone(),
            None => self.resolve(&client_default()),
        };
        found.map_err(BackendError::Unavailable)
    }

    fn connect(&self) -> Result<UnixStream, BackendError> {
        let path = self.socket()?;
        let stream = UnixStream::connect(&path).map_err(|e| {
            BackendError::Unavailable(format!("cannot reach herdr at {}: {e}", path.display()))
        })?;
        stream
            .set_read_timeout(Some(ANSWER_TIMEOUT))
            .and_then(|()| stream.set_write_timeout(Some(ANSWER_TIMEOUT)))
            .map_err(failed)?;
        Ok(stream)
    }
}

fn client_default() -> ClientHello {
    ClientHello {
        proto: wire::PROTO,
        client: wire::ClientInfo {
            name: String::new(),
            version: String::new(),
        },
        herdr: HerdrHello::default(),
    }
}

fn failed(e: std::io::Error) -> BackendError {
    match e.kind() {
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut => {
            BackendError::Failed("herdr did not answer in time".to_string())
        }
        _ => BackendError::Failed(e.to_string()),
    }
}

/// One line without its newline; `None` at end of stream before any byte.
fn read_line<R: BufRead>(reader: &mut R) -> Result<Option<Vec<u8>>, BackendError> {
    let mut line = Vec::new();
    let n = reader
        .by_ref()
        .take(MAX_LINE)
        .read_until(b'\n', &mut line)
        .map_err(failed)?;
    if n == 0 {
        return Ok(None);
    }
    if line.last() == Some(&b'\n') {
        line.pop();
    }
    if line.last() == Some(&b'\r') {
        line.pop();
    }
    Ok(Some(line))
}

/// herdr cannot correlate a request it fails to parse (an unknown method) and
/// answers with id `""`: give the answer the id the request was sent with, or
/// the client would wait for a reply that is never matched.
fn restore_id(response: &mut Value, sent: &Value) {
    if sent.is_null() {
        return;
    }
    if let Some(map) = response.as_object_mut() {
        let first_is_empty_id = map.len() > 1
            && map
                .iter()
                .next()
                .is_some_and(|(k, v)| k == "id" && v.as_str() == Some(""));
        if first_is_empty_id {
            map.insert("id".to_string(), sent.clone());
        }
    }
}

impl Backend for HerdrBackend {
    fn id(&self) -> &'static str {
        "herdr"
    }

    fn discover(&self, hello: &ClientHello) -> Availability {
        let path = match self.resolve(hello) {
            Ok(path) => path,
            Err(reason) => return Availability::Unavailable { reason },
        };
        match std::fs::metadata(&path) {
            Ok(meta) if meta.file_type().is_socket() => Availability::Available,
            _ => Availability::Unavailable {
                reason: format!(
                    "no herdr socket at {} for session {}",
                    path.display(),
                    hello.herdr.session
                ),
            },
        }
    }

    fn bind(&self, hello: &ClientHello) -> Self {
        Self {
            config: self.config.clone(),
            bound: Some(self.resolve(hello)),
        }
    }

    fn call(&self, request: &Value) -> Result<Value, BackendError> {
        let mut line =
            serde_json::to_vec(request).map_err(|e| BackendError::Failed(e.to_string()))?;
        line.push(b'\n');
        let stream = self.connect()?;
        (&stream).write_all(&line).map_err(failed)?;
        let mut reader = BufReader::new(&stream);
        let answer = read_line(&mut reader)?.ok_or_else(|| {
            BackendError::Failed("herdr closed the connection without answering".to_string())
        })?;
        let mut response: Value = serde_json::from_slice(&answer).map_err(|e| {
            BackendError::Failed(format!("herdr sent an answer that is not JSON: {e}"))
        })?;
        restore_id(&mut response, request.get("id").unwrap_or(&Value::Null));
        Ok(response)
    }

    fn subscribe(&self, request: &Value) -> Result<Box<dyn EventSource>, BackendError> {
        let subscribe = json!({"id": "events", "method": "events.subscribe", "params": request});
        let mut line =
            serde_json::to_vec(&subscribe).map_err(|e| BackendError::Failed(e.to_string()))?;
        line.push(b'\n');
        let stream = self.connect()?;
        (&stream).write_all(&line).map_err(failed)?;
        let mut reader = BufReader::new(stream);
        let ack = read_line(&mut reader)?.ok_or_else(|| {
            BackendError::Failed("herdr closed the connection without answering".to_string())
        })?;
        let ack: Value = serde_json::from_slice(&ack).map_err(|e| {
            BackendError::Failed(format!("herdr sent an answer that is not JSON: {e}"))
        })?;
        // Events are as rare as the user's work: no read deadline from here on.
        reader.get_ref().set_read_timeout(None).map_err(failed)?;
        Ok(Box::new(HerdrEvents { reader, ack }))
    }
}

struct HerdrEvents {
    reader: BufReader<UnixStream>,
    ack: Value,
}

impl EventSource for HerdrEvents {
    fn ack(&self) -> Value {
        self.ack.clone()
    }

    fn next_event(&mut self) -> Option<Result<Value, BackendError>> {
        loop {
            let line = match read_line(&mut self.reader) {
                Ok(Some(line)) => line,
                Ok(None) => return None,
                Err(e) => return Some(Err(e)),
            };
            if line.is_empty() {
                continue;
            }
            return Some(Ok(serde_json::from_slice(&line).unwrap_or_else(|_| {
                Value::String(String::from_utf8_lossy(&line).into_owned())
            })));
        }
    }

    fn closer(&self) -> Box<dyn Fn() + Send + Sync> {
        match self.reader.get_ref().try_clone() {
            Ok(stream) => Box::new(move || {
                let _ = stream.shutdown(Shutdown::Both);
            }),
            Err(_) => Box::new(|| {}),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    fn hello(session: &str, socket: Option<&str>) -> ClientHello {
        ClientHello {
            herdr: HerdrHello {
                session: session.to_string(),
                socket: socket.map(str::to_string),
            },
            ..client_default()
        }
    }

    #[test]
    fn the_socket_is_under_xdg_config_home_when_that_is_set() {
        let p = socket_path(
            None,
            "default",
            Some(Path::new("/x/cfg")),
            Some(Path::new("/home/u")),
        );
        assert_eq!(p, Ok(PathBuf::from("/x/cfg/herdr/herdr.sock")));
    }

    #[test]
    fn without_xdg_config_home_it_is_under_home_dot_config_and_empty_counts_as_unset() {
        let want = Ok(PathBuf::from("/home/u/.config/herdr/herdr.sock"));
        assert_eq!(
            socket_path(None, "default", None, Some(Path::new("/home/u"))),
            want
        );
        assert_eq!(
            socket_path(
                None,
                "default",
                Some(Path::new("")),
                Some(Path::new("/home/u"))
            ),
            want
        );
    }

    #[test]
    fn a_named_session_has_its_own_folder_and_default_does_not() {
        let home = Some(Path::new("/home/u"));
        assert_eq!(
            socket_path(None, "work", None, home),
            Ok(PathBuf::from(
                "/home/u/.config/herdr/sessions/work/herdr.sock"
            ))
        );
        assert_eq!(
            socket_path(None, "default", None, home),
            Ok(PathBuf::from("/home/u/.config/herdr/herdr.sock"))
        );
    }

    #[test]
    fn an_explicit_socket_wins_but_an_empty_one_does_not() {
        let home = Some(Path::new("/home/u"));
        assert_eq!(
            socket_path(Some("/run/h.sock"), "work", None, home),
            Ok(PathBuf::from("/run/h.sock"))
        );
        assert_eq!(
            socket_path(Some(""), "default", None, home),
            Ok(PathBuf::from("/home/u/.config/herdr/herdr.sock"))
        );
    }

    #[test]
    fn session_names_follow_the_apps_pattern() {
        for ok in ["default", "a.b_c-D9", ".", ".."] {
            assert!(is_safe_session(ok), "{ok}");
        }
        for bad in ["", "a b", "a/b", "é", "a;b", "a\n", "$(x)"] {
            assert!(!is_safe_session(bad), "{bad:?}");
        }
        // Checked even when a socket path is given, as the app does.
        assert!(socket_path(Some("/s"), "a/b", None, None).is_err());
    }

    #[test]
    fn no_config_folder_at_all_is_an_error_not_a_guess() {
        assert!(socket_path(None, "default", None, None).is_err());
    }

    #[test]
    fn discover_names_the_path_and_session_when_there_is_no_socket() {
        let dir = tempfile::tempdir().expect("dir");
        let backend = HerdrBackend::with_config_dir(dir.path());
        let want = format!(
            "no herdr socket at {}/herdr/sessions/work/herdr.sock for session work",
            dir.path().display()
        );
        assert_eq!(
            backend.discover(&hello("work", None)),
            Availability::Unavailable { reason: want }
        );
    }

    #[test]
    fn discover_refuses_a_regular_file_and_accepts_a_socket() {
        let dir = tempfile::tempdir().expect("dir");
        let herdr_dir = dir.path().join("herdr");
        std::fs::create_dir_all(&herdr_dir).expect("mkdir");
        let sock = herdr_dir.join("herdr.sock");
        std::fs::write(&sock, b"").expect("file");
        let backend = HerdrBackend::with_config_dir(dir.path());
        assert!(matches!(
            backend.discover(&hello("default", None)),
            Availability::Unavailable { .. }
        ));
        std::fs::remove_file(&sock).expect("rm");
        let _listener = UnixListener::bind(&sock).expect("bind");
        assert_eq!(
            backend.discover(&hello("default", None)),
            Availability::Available
        );
    }

    #[test]
    fn discover_reports_an_invalid_session_instead_of_looking() {
        let backend = HerdrBackend::with_config_dir("/nonexistent");
        assert!(matches!(
            backend.discover(&hello("../x", None)),
            Availability::Unavailable { reason } if reason.contains("invalid herdr session name")
        ));
    }

    #[test]
    fn an_answer_with_an_empty_id_gets_the_id_that_was_sent() {
        let mut r = json!({"id": "", "error": {"code": "invalid_request"}});
        restore_id(&mut r, &json!("m7"));
        assert_eq!(r, json!({"id": "m7", "error": {"code": "invalid_request"}}));
        assert_eq!(
            r.as_object()
                .and_then(|m| m.keys().next())
                .map(String::as_str),
            Some("id")
        );
        let mut kept = json!({"id": "m1", "result": {}});
        restore_id(&mut kept, &json!("m7"));
        assert_eq!(kept["id"], "m1");
        let mut unsent = json!({"id": "", "error": {}});
        restore_id(&mut unsent, &Value::Null);
        assert_eq!(unsent["id"], "");
    }
}
