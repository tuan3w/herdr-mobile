//! `made`: turns "the transcript says the agent made X" into a fact. The phone
//! scans transcripts (one scanner, in Dart); this service only answers whether
//! a file still exists and whether a port is listening right now.

use super::ports::{parse_args, scan, Scan};
use crate::service::{Class, MethodKind, MethodSpec, Service};
use crate::session::StreamCtx;
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;
use wire::{ClientHello, ErrorCode, ServiceStatus, WireError};

/// Items per call.
const MAX_ITEMS: usize = 200;

static METHODS: &[MethodSpec] = &[MethodSpec {
    name: "verify",
    kind: MethodKind::Call,
    class: Class::Interactive,
    summary: "facts for up to 200 items, each a path (exists, kind, size, mtime) or a port (listening now, and by whom)",
    args_example: "{\"items\":[{\"id\":\"a\",\"path\":\"~/app/dist/index.html\"},{\"id\":\"b\",\"port\":3000}]}",
    result_example: "{\"results\":[{\"id\":\"a\",\"exists\":true,\"kind\":\"file\",\"size\":1024,\"mtime_ms\":1700000000000},{\"id\":\"b\",\"listening\":true,\"pid\":4242,\"process\":\"node\"}]}",
}];

pub struct MadeService;

impl MadeService {
    #[must_use]
    pub fn new() -> Self {
        Self
    }
}

impl Default for MadeService {
    fn default() -> Self {
        Self::new()
    }
}

impl Service for MadeService {
    fn name(&self) -> &'static str {
        "made"
    }

    fn methods(&self) -> &'static [MethodSpec] {
        METHODS
    }

    /// Path checks work everywhere; `ports` says whether port items can be answered.
    fn availability(&self, _: &ClientHello) -> ServiceStatus {
        ServiceStatus::available().with("ports", json!(super::ports::source().is_ok()))
    }

    fn open(&self, method: &str, ctx: &StreamCtx) -> Result<Value, WireError> {
        match method {
            "verify" => {
                let args: VerifyArgs = parse_args(ctx.args())?;
                verify(&args.items, ctx.home(), scan)
            }
            other => Err(WireError::new(
                ErrorCode::UnknownMethod,
                format!("made has no method {other}"),
            )),
        }
    }
}

#[derive(Debug, Deserialize)]
struct VerifyArgs {
    items: Vec<Item>,
}

#[derive(Debug, Deserialize)]
struct Item {
    id: Value,
    path: Option<String>,
    port: Option<u16>,
}

/// An item once validated.
enum Probe {
    Path(PathBuf),
    Port(u16),
}

fn bad(message: impl Into<String>) -> WireError {
    WireError::new(ErrorCode::BadRequest, message)
}

/// `~` and `~/x` expand to `home`; anything else must be absolute and free of NUL.
fn resolve(path: &str, home: &Path) -> Result<PathBuf, WireError> {
    if path.contains('\0') {
        return Err(bad("a path contains a NUL byte"));
    }
    let resolved = if path == "~" {
        home.to_path_buf()
    } else if let Some(rest) = path.strip_prefix("~/") {
        home.join(rest)
    } else {
        PathBuf::from(path)
    };
    if resolved.is_absolute() {
        Ok(resolved)
    } else {
        Err(bad(format!("path {path:?} is not absolute")))
    }
}

/// Checks every item before anything touches the file system.
fn validate(items: &[Item], home: &Path) -> Result<Vec<Probe>, WireError> {
    if items.len() > MAX_ITEMS {
        return Err(WireError::new(
            ErrorCode::TooLarge,
            format!("at most {MAX_ITEMS} items per call, got {}", items.len()),
        ));
    }
    items
        .iter()
        .map(|item| match (&item.path, item.port) {
            (Some(path), None) => Ok(Probe::Path(resolve(path, home)?)),
            (None, Some(0)) => Err(bad("port must be 1..=65535")),
            (None, Some(port)) => Ok(Probe::Port(port)),
            _ => Err(bad("each item needs exactly one of path and port")),
        })
        .collect()
}

/// The answers for `items`; `scan` is called at most once, and only when a port
/// item asks.
fn verify(
    items: &[Item],
    home: &Path,
    scan: impl FnOnce() -> Result<Scan, WireError>,
) -> Result<Value, WireError> {
    let probes = validate(items, home)?;
    let mut scan = Some(scan);
    let mut listeners: Option<Result<Scan, WireError>> = None;
    let mut results = Vec::with_capacity(items.len());
    for (item, probe) in items.iter().zip(&probes) {
        let mut out = Map::new();
        out.insert("id".to_string(), item.id.clone());
        match probe {
            Probe::Path(path) => stat_into(path, &mut out),
            Probe::Port(port) => {
                if listeners.is_none() {
                    listeners = scan.take().map(|f| f());
                }
                match &listeners {
                    Some(Ok(found)) => port_into(*port, found, &mut out),
                    _ => {
                        out.insert("error".to_string(), json!("unavailable"));
                    }
                }
            }
        }
        results.push(Value::Object(out));
    }
    Ok(json!({"results": results}))
}

fn port_into(port: u16, scan: &Scan, out: &mut Map<String, Value>) {
    let mut on_port = scan.listeners.iter().filter(|l| l.port == port).peekable();
    out.insert("listening".to_string(), json!(on_port.peek().is_some()));
    // Both address families may listen; the one whose owner is visible tells.
    if let Some(owner) = on_port.find(|l| l.pid.is_some()) {
        out.insert("pid".to_string(), json!(owner.pid));
        if let Some(name) = &owner.process {
            out.insert("process".to_string(), json!(name));
        }
    }
}

fn stat_into(path: &Path, out: &mut Map<String, Value>) {
    match std::fs::metadata(path) {
        Ok(meta) => {
            let kind = if meta.is_file() {
                "file"
            } else if meta.is_dir() {
                "dir"
            } else {
                "other"
            };
            let mtime_ms = match meta.modified().map(|t| t.duration_since(UNIX_EPOCH)) {
                Ok(Ok(d)) => i64::try_from(d.as_millis()).unwrap_or(i64::MAX),
                Ok(Err(before)) => {
                    -i64::try_from(before.duration().as_millis()).unwrap_or(i64::MAX)
                }
                Err(_) => 0,
            };
            out.insert("exists".to_string(), json!(true));
            out.insert("kind".to_string(), json!(kind));
            out.insert("size".to_string(), json!(meta.len()));
            out.insert("mtime_ms".to_string(), json!(mtime_ms));
        }
        // A file under something that is not a directory is as gone as one that was never there.
        Err(e) if matches!(e.kind(), ErrorKind::NotFound | ErrorKind::NotADirectory) => {
            out.insert("exists".to_string(), json!(false));
        }
        Err(e) if e.kind() == ErrorKind::PermissionDenied => {
            out.insert("error".to_string(), json!("permission"));
        }
        Err(_) => {
            out.insert("error".to_string(), json!("failed"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::svc::ports::Listener;

    fn items(v: &Value) -> Vec<Item> {
        serde_json::from_value::<VerifyArgs>(v.clone())
            .expect("items")
            .items
    }

    fn no_scan() -> Result<Scan, WireError> {
        panic!("no port item asked for a scan")
    }

    fn listening(port: u16, pid: Option<u32>) -> Listener {
        Listener {
            family: 4,
            addr: "127.0.0.1".into(),
            port,
            pid,
            process: pid.map(|_| "node".to_string()),
            user: None,
        }
    }

    #[test]
    fn the_catalog_example_parses_into_the_typed_args() {
        let args: VerifyArgs = serde_json::from_str(METHODS[0].args_example).expect("typed");
        assert_eq!(args.items.len(), 2);
        let _: Value = serde_json::from_str(METHODS[0].result_example).expect("result is JSON");
    }

    #[test]
    fn paths_answer_with_facts_and_a_missing_one_is_not_an_error() {
        let dir = tempfile::tempdir().expect("dir");
        std::fs::write(dir.path().join("a.txt"), b"hello").expect("write");
        std::fs::create_dir(dir.path().join("sub")).expect("mkdir");
        let base = dir.path().to_string_lossy();
        let req = json!({"items": [
            {"id": "f", "path": format!("{base}/a.txt")},
            {"id": "d", "path": format!("{base}/sub")},
            {"id": "gone", "path": format!("{base}/nope")},
            {"id": 7, "path": format!("{base}/a.txt/below-a-file")},
        ]});
        let out = verify(&items(&req), Path::new("/"), no_scan).expect("verifies");
        let r = &out["results"];
        assert_eq!(r[0]["id"], "f");
        assert_eq!(
            (&r[0]["exists"], &r[0]["kind"], &r[0]["size"]),
            (&json!(true), &json!("file"), &json!(5))
        );
        assert!(r[0]["mtime_ms"].as_i64().expect("mtime") > 1_000_000_000_000);
        assert_eq!(
            (&r[1]["exists"], &r[1]["kind"]),
            (&json!(true), &json!("dir"))
        );
        assert_eq!(r[2], json!({"id": "gone", "exists": false}));
        assert_eq!(r[3], json!({"id": 7, "exists": false}));
    }

    #[test]
    fn tilde_means_the_home_of_the_user_serve_runs_as() {
        let home = tempfile::tempdir().expect("home");
        std::fs::write(home.path().join("x"), b"").expect("write");
        let req = json!({"items": [{"id": 1, "path": "~/x"}, {"id": 2, "path": "~"}, {"id": 3, "path": "~/y"}]});
        let out = verify(&items(&req), home.path(), no_scan).expect("verifies");
        assert_eq!(out["results"][0]["kind"], "file");
        assert_eq!(out["results"][1]["kind"], "dir");
        assert_eq!(out["results"][2]["exists"], false);
    }

    #[test]
    fn a_bad_item_refuses_the_whole_call_before_anything_is_checked() {
        let bad_items = [
            json!({"id": 1, "path": "relative/path"}),
            json!({"id": 1, "path": ""}),
            json!({"id": 1, "path": "~someone/x"}),
            json!({"id": 1, "path": "/tmp/a\u{0}b"}),
            json!({"id": 1}),
            json!({"id": 1, "path": "/tmp", "port": 80}),
            json!({"id": 1, "port": 0}),
        ];
        for bad in bad_items {
            let req = json!({"items": [{"id": 0, "path": "/"}, bad.clone()]});
            let e = verify(&items(&req), Path::new("/"), no_scan).expect_err(&bad.to_string());
            assert_eq!(e.code, ErrorCode::BadRequest, "{bad}");
        }
    }

    #[test]
    fn more_than_200_items_is_too_large() {
        let many: Vec<Value> = (0..201).map(|i| json!({"id": i, "path": "/"})).collect();
        let e =
            verify(&items(&json!({"items": many})), Path::new("/"), no_scan).expect_err("refused");
        assert_eq!(e.code, ErrorCode::TooLarge);
        let ok: Vec<Value> = (0..200).map(|i| json!({"id": i, "path": "/"})).collect();
        assert!(verify(&items(&json!({"items": ok})), Path::new("/"), no_scan).is_ok());
    }

    #[test]
    fn ports_come_from_one_scan_shared_by_all_port_items() {
        let mut calls = 0;
        let scan = || {
            calls += 1;
            Ok(Scan {
                source: "proc",
                listeners: vec![listening(3000, Some(42)), listening(4000, None)],
            })
        };
        let req = json!({"items": [
            {"id": "a", "port": 3000},
            {"id": "b", "port": 4000},
            {"id": "c", "port": 5000},
            {"id": "d", "path": "/"},
        ]});
        let out = verify(&items(&req), Path::new("/"), scan).expect("verifies");
        let r = &out["results"];
        assert_eq!(
            r[0],
            json!({"id": "a", "listening": true, "pid": 42, "process": "node"})
        );
        assert_eq!(
            r[1],
            json!({"id": "b", "listening": true}),
            "owner not visible"
        );
        assert_eq!(r[2], json!({"id": "c", "listening": false}));
        assert_eq!(r[3]["kind"], "dir");
        assert_eq!(calls, 1);
    }

    #[test]
    fn when_ports_cannot_be_listed_port_items_say_so_and_path_items_still_answer() {
        let scan = || {
            Err(WireError::new(
                ErrorCode::Unavailable,
                "needs lsof on this machine",
            ))
        };
        let req = json!({"items": [{"id": "a", "port": 3000}, {"id": "b", "path": "/"}]});
        let out = verify(&items(&req), Path::new("/"), scan).expect("verifies");
        assert_eq!(
            out["results"][0],
            json!({"id": "a", "error": "unavailable"})
        );
        assert_eq!(out["results"][1]["exists"], true);
    }

    #[test]
    fn a_path_the_user_may_not_look_at_reports_permission_not_absence() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().expect("dir");
        let locked = dir.path().join("locked");
        std::fs::create_dir(&locked).expect("mkdir");
        std::fs::write(locked.join("f"), b"x").expect("write");
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000)).expect("chmod");
        let readable = std::fs::read_dir(&locked).is_ok(); // root ignores the mode
        let req = json!({"items": [{"id": 1, "path": locked.join("f").to_string_lossy()}]});
        let out = verify(&items(&req), Path::new("/"), no_scan).expect("verifies");
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o700)).expect("restore");
        if readable {
            assert_eq!(out["results"][0]["exists"], true);
        } else {
            assert_eq!(out["results"][0], json!({"id": 1, "error": "permission"}));
        }
    }
}
