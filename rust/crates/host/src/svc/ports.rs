//! `ports`: which TCP ports listen on this machine, live, and whether one
//! accepts connections. Read-only: nothing here proxies traffic (port
//! forwarding stays SSH `direct-tcpip`, so an admin's `AllowTcpForwarding no`
//! still decides).
//!
//! Linux reads `/proc/net/tcp{,6}` and finds each socket's owner through
//! `/proc/<pid>/fd` (only for processes this user may look at). macOS runs
//! `lsof`. Anything else is unavailable.

use crate::service::{Class, MethodKind, MethodSpec, Service};
use crate::session::StreamCtx;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::io::Read;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpStream};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{channel, RecvTimeoutError};
use std::time::Duration;
use wire::{ClientHello, ErrorCode, ServiceStatus, WireError};

/// `lsof` gets this long before it is killed.
const LSOF_TIMEOUT: Duration = Duration::from_secs(3);
/// A connect to a loopback port that does not answer in this time is "closed".
const PROBE_TIMEOUT: Duration = Duration::from_millis(500);
/// The scan looks at no more processes than this.
const MAX_PIDS: usize = 2000;
/// ... and at no more descriptors per process than this.
const MAX_FDS: usize = 20_000;
const MIN_INTERVAL_MS: u64 = 1000;
const DEFAULT_INTERVAL_MS: u64 = 2000;
/// Longer waits are clamped: `Instant` arithmetic must not overflow.
const MAX_INTERVAL_MS: u64 = 3_600_000;

static METHODS: &[MethodSpec] = &[
    MethodSpec {
        name: "list",
        kind: MethodKind::Call,
        class: Class::Interactive,
        summary: "TCP listeners on this machine; pid, process and user only where this user may see the owner",
        args_example: "{}",
        result_example: "{\"source\":\"proc\",\"listeners\":[{\"family\":4,\"addr\":\"127.0.0.1\",\"port\":3000,\"pid\":4242,\"process\":\"node\",\"user\":\"dev\"}]}",
    },
    MethodSpec {
        name: "watch",
        kind: MethodKind::Stream,
        class: Class::Interactive,
        summary: "the full listener list first, then {opened,closed} whenever the set changes",
        args_example: "{\"interval_ms\":2000}",
        result_example: "{\"opened\":[{\"family\":4,\"addr\":\"127.0.0.1\",\"port\":3000}],\"closed\":[]}",
    },
    MethodSpec {
        name: "probe",
        kind: MethodKind::Call,
        class: Class::Interactive,
        summary: "whether a loopback port accepts a connection (500 ms timeout); the host must be a loopback address",
        args_example: "{\"port\":3000,\"host\":\"127.0.0.1\"}",
        result_example: "{\"open\":true}",
    },
];

/// One listening TCP socket.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Listener {
    pub family: u8,
    pub addr: String,
    pub port: u16,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub process: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
}

type Key = (u8, String, u16);

impl Listener {
    fn bare(family: u8, addr: String, port: u16) -> Self {
        Self {
            family,
            addr,
            port,
            pid: None,
            process: None,
            user: None,
        }
    }

    fn key(&self) -> Key {
        (self.family, self.addr.clone(), self.port)
    }
}

/// A scan: what was found and by which mechanism.
#[derive(Clone, Debug)]
pub(crate) struct Scan {
    pub source: &'static str,
    pub listeners: Vec<Listener>,
}

pub struct PortsService;

impl PortsService {
    #[must_use]
    pub fn new() -> Self {
        Self
    }
}

impl Default for PortsService {
    fn default() -> Self {
        Self::new()
    }
}

/// Which mechanism this machine has, or why none.
pub(crate) fn source() -> Result<&'static str, String> {
    match std::env::consts::OS {
        "linux" => {
            if std::fs::File::open("/proc/net/tcp").is_ok() {
                Ok("proc")
            } else {
                Err("cannot read /proc/net/tcp on this machine".to_string())
            }
        }
        "macos" => match find_lsof() {
            Some(_) => Ok("lsof"),
            None => Err("needs lsof on this machine".to_string()),
        },
        os => Err(format!("ports are not supported on {os}")),
    }
}

impl Service for PortsService {
    fn name(&self) -> &'static str {
        "ports"
    }

    fn methods(&self) -> &'static [MethodSpec] {
        METHODS
    }

    fn availability(&self, _: &ClientHello) -> ServiceStatus {
        match source() {
            Ok(source) => ServiceStatus::available().with("source", json!(source)),
            Err(reason) => ServiceStatus::unavailable(reason),
        }
    }

    fn open(&self, method: &str, ctx: &StreamCtx) -> Result<Value, WireError> {
        match method {
            "list" => {
                let scan = scan()?;
                Ok(json!({"source": scan.source, "listeners": scan.listeners}))
            }
            "watch" => watch(ctx),
            "probe" => probe(ctx),
            other => Err(WireError::new(
                ErrorCode::UnknownMethod,
                format!("ports has no method {other}"),
            )),
        }
    }
}

// --- scanning -------------------------------------------------------------

/// Every TCP listener on this machine, sorted by port, then family, then
/// address. One full look at `/proc/<pid>/fd` per call.
pub(crate) fn scan() -> Result<Scan, WireError> {
    scan_with(&mut OwnerCache::default())
}

fn scan_with(cache: &mut OwnerCache) -> Result<Scan, WireError> {
    let source = source().map_err(|reason| WireError::new(ErrorCode::Unavailable, reason))?;
    let mut listeners = if source == "proc" {
        scan_proc(cache)?
    } else {
        scan_lsof()?
    };
    listeners.sort_by(|a, b| {
        (a.port, a.family, &a.addr, a.pid.is_none()).cmp(&(
            b.port,
            b.family,
            &b.addr,
            b.pid.is_none(),
        ))
    });
    // The same socket may show up twice (a name in both tables); only an exact
    // duplicate is dropped, and the copy that knows its owner wins (it sorts first).
    listeners.dedup_by(|b, a| a.key() == b.key());
    Ok(Scan { source, listeners })
}

/// What a `watch` remembers between ticks so the steady state reads only the
/// two cheap `net` tables: who owns each listening socket, and which sockets
/// had no visible owner when last looked for (another user's, or a process
/// beyond the scan's bounds). `/proc/<pid>/fd` is walked again only for a
/// socket in neither list, or after an owner's process is gone.
#[derive(Default)]
struct OwnerCache {
    owners: HashMap<u64, Owner>,
    unowned: HashSet<u64>,
    /// Process folders looked into so far; tests count walks with it.
    #[cfg(test)]
    pid_dirs_read: usize,
}

fn scan_proc(cache: &mut OwnerCache) -> Result<Vec<Listener>, WireError> {
    scan_proc_in(Path::new("/proc"), cache)
}

fn scan_proc_in(proc_dir: &Path, cache: &mut OwnerCache) -> Result<Vec<Listener>, WireError> {
    let v4 = std::fs::read_to_string(proc_dir.join("net/tcp"));
    // IPv6 may be compiled out or disabled: its table is optional.
    let v6 = std::fs::read_to_string(proc_dir.join("net/tcp6")).unwrap_or_default();
    let v4 = v4.map_err(|e| {
        WireError::new(ErrorCode::Failed, format!("cannot read /proc/net/tcp: {e}"))
    })?;
    let mut rows = parse_proc_net(&v4, 4);
    rows.extend(parse_proc_net(&v6, 6));
    let current: HashSet<u64> = rows.iter().map(|r| r.inode).filter(|i| *i != 0).collect();
    cache
        .owners
        .retain(|inode, o| current.contains(inode) && proc_dir.join(o.pid.to_string()).exists());
    cache.unowned.retain(|inode| current.contains(inode));
    let missing: HashSet<u64> = current
        .iter()
        .copied()
        .filter(|i| !cache.owners.contains_key(i) && !cache.unowned.contains(i))
        .collect();
    if !missing.is_empty() {
        let (found, _pids) = owners_of(proc_dir, &missing);
        #[cfg(test)]
        {
            cache.pid_dirs_read += _pids;
        }
        cache
            .unowned
            .extend(missing.iter().filter(|i| !found.contains_key(i)));
        cache.owners.extend(found);
    }
    Ok(rows
        .into_iter()
        .map(|row| {
            let mut l = row.listener;
            if let Some(o) = cache.owners.get(&row.inode) {
                l.pid = Some(o.pid);
                l.process.clone_from(&o.process);
                l.user.clone_from(&o.user);
            }
            l
        })
        .collect())
}

/// A listener row of `/proc/net/tcp{,6}` and the inode of its socket.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ProcRow {
    pub listener: Listener,
    pub inode: u64,
}

/// The LISTEN rows (`st` = `0A`) of a `/proc/net/tcp` (`family` 4) or
/// `/proc/net/tcp6` (`family` 6) table. Rows that do not parse are skipped.
pub(crate) fn parse_proc_net(text: &str, family: u8) -> Vec<ProcRow> {
    text.lines()
        .filter_map(|line| parse_row(line, family))
        .collect()
}

fn parse_row(line: &str, family: u8) -> Option<ProcRow> {
    let mut f = line.split_whitespace();
    let _slot = f.next()?;
    let local = f.next()?;
    let _remote = f.next()?;
    if f.next()? != "0A" {
        return None;
    }
    // tx:rx, tr:tm, retrnsmt, uid, timeout, then the inode.
    let inode = f.nth(5)?.parse::<u64>().ok()?;
    let (addr, port) = local.split_once(':')?;
    if port.len() != 4 {
        return None;
    }
    let port = u16::from_str_radix(port, 16).ok()?;
    let addr = match family {
        4 => parse_v4(addr)?.to_string(),
        _ => parse_v6(addr)?.to_string(),
    };
    Some(ProcRow {
        listener: Listener::bare(family, addr, port),
        inode,
    })
}

/// The kernel prints each 32-bit word of the address in the machine's own byte
/// order, so its native bytes are the address in network order on any CPU.
fn word(hex: &str) -> Option<[u8; 4]> {
    if hex.len() != 8 {
        return None;
    }
    Some(u32::from_str_radix(hex, 16).ok()?.to_ne_bytes())
}

fn parse_v4(hex: &str) -> Option<Ipv4Addr> {
    Some(Ipv4Addr::from(word(hex)?))
}

fn parse_v6(hex: &str) -> Option<Ipv6Addr> {
    if hex.len() != 32 || !hex.is_ascii() {
        return None;
    }
    let mut bytes = [0u8; 16];
    for i in 0..4 {
        bytes[i * 4..i * 4 + 4].copy_from_slice(&word(&hex[i * 8..i * 8 + 8])?);
    }
    Some(Ipv6Addr::from(bytes))
}

struct Owner {
    pid: u32,
    process: Option<String>,
    user: Option<String>,
}

/// One pass over `<proc>/<pid>/fd` for the sockets in `wanted`. Looks at
/// bounded work, skips what it may not read or what vanished, and stops once
/// every wanted socket has an owner. Returns the owners and how many process
/// folders it looked into.
fn owners_of(proc_dir: &Path, wanted: &HashSet<u64>) -> (HashMap<u64, Owner>, usize) {
    let mut found: HashMap<u64, Owner> = HashMap::new();
    let mut pids = 0;
    if wanted.is_empty() {
        return (found, pids);
    }
    let Ok(entries) = std::fs::read_dir(proc_dir) else {
        return (found, pids);
    };
    let mut users: HashMap<u32, String> = HashMap::new();
    let mut passwd: Option<HashMap<u32, String>> = None;
    for entry in entries
        .flatten()
        .filter_map(|e| {
            let pid = e.file_name().to_str()?.parse::<u32>().ok()?;
            Some((pid, e.path()))
        })
        .take(MAX_PIDS)
    {
        let (pid, dir) = entry;
        pids += 1;
        let Ok(fds) = std::fs::read_dir(dir.join("fd")) else {
            continue;
        };
        let mut mine: Vec<u64> = Vec::new();
        for fd in fds.flatten().take(MAX_FDS) {
            let Ok(target) = std::fs::read_link(fd.path()) else {
                continue;
            };
            let Some(inode) = target
                .to_str()
                .and_then(|t| t.strip_prefix("socket:["))
                .and_then(|t| t.strip_suffix(']'))
                .and_then(|t| t.parse::<u64>().ok())
            else {
                continue;
            };
            if wanted.contains(&inode) && !found.contains_key(&inode) {
                mine.push(inode);
            }
        }
        if mine.is_empty() {
            continue;
        }
        let process = std::fs::read_to_string(dir.join("comm"))
            .ok()
            .map(|s| s.trim_end().to_string())
            .filter(|s| !s.is_empty());
        let user = std::fs::metadata(&dir).ok().map(|m| {
            let uid = m.uid();
            users
                .entry(uid)
                .or_insert_with(|| {
                    let table = passwd.get_or_insert_with(read_passwd);
                    table.get(&uid).cloned().unwrap_or_else(|| uid.to_string())
                })
                .clone()
        });
        for inode in mine {
            found.insert(
                inode,
                Owner {
                    pid,
                    process: process.clone(),
                    user: user.clone(),
                },
            );
        }
        if found.len() == wanted.len() {
            break;
        }
    }
    (found, pids)
}

fn read_passwd() -> HashMap<u32, String> {
    std::fs::read_to_string("/etc/passwd")
        .map(|t| parse_passwd(&t))
        .unwrap_or_default()
}

/// `uid → name` from `/etc/passwd` text; the first entry of a uid wins.
fn parse_passwd(text: &str) -> HashMap<u32, String> {
    let mut table = HashMap::new();
    for line in text.lines() {
        let mut f = line.split(':');
        let (Some(name), Some(_), Some(uid)) = (f.next(), f.next(), f.next()) else {
            continue;
        };
        if let (false, Ok(uid)) = (name.is_empty(), uid.parse::<u32>()) {
            table.entry(uid).or_insert_with(|| name.to_string());
        }
    }
    table
}

// --- lsof (macOS) ---------------------------------------------------------

fn find_lsof() -> Option<PathBuf> {
    let path = std::env::var_os("PATH").unwrap_or_default();
    let extra = [PathBuf::from("/usr/sbin"), PathBuf::from("/usr/bin")];
    std::env::split_paths(&path)
        .chain(extra)
        .map(|d| d.join("lsof"))
        .find(|p| p.is_file())
}

fn scan_lsof() -> Result<Vec<Listener>, WireError> {
    let unavailable = || WireError::new(ErrorCode::Unavailable, "needs lsof on this machine");
    let lsof = find_lsof().ok_or_else(unavailable)?;
    let mut child = Command::new(lsof)
        .args(["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcnt"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| WireError::new(ErrorCode::Failed, format!("cannot run lsof: {e}")))?;
    let Some(mut stdout) = child.stdout.take() else {
        let _ = child.kill();
        let _ = child.wait();
        return Err(WireError::new(
            ErrorCode::Failed,
            "lsof gave no output pipe",
        ));
    };
    let (tx, rx) = channel();
    std::thread::spawn(move || {
        let mut text = Vec::new();
        let _ = stdout.read_to_end(&mut text);
        let _ = tx.send(text);
    });
    match rx.recv_timeout(LSOF_TIMEOUT) {
        Ok(text) => {
            // Exit status 1 is lsof's "nothing matched": an empty list, not a failure.
            let _ = child.wait();
            Ok(parse_lsof(&String::from_utf8_lossy(&text)))
        }
        Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => {
            let _ = child.kill();
            let _ = child.wait();
            Err(WireError::new(ErrorCode::Failed, "lsof did not answer in 3 s").retryable())
        }
    }
}

/// The listeners of `lsof -Fpcnt` output: a `p<pid>` line starts a process,
/// `c<name>` names it, and each socket is `t<IPv4|IPv6>` then `n<addr>:<port>`
/// (`*` is the wildcard of that family). Connected sockets (`->`) are skipped.
pub(crate) fn parse_lsof(text: &str) -> Vec<Listener> {
    let mut out = Vec::new();
    let mut pid: Option<u32> = None;
    let mut process: Option<String> = None;
    let mut family: Option<u8> = None;
    for line in text.lines() {
        let Some(tag) = line.chars().next() else {
            continue;
        };
        let rest = &line[tag.len_utf8()..];
        match tag {
            'p' => {
                pid = rest.parse().ok();
                process = None;
                family = None;
            }
            'c' => process = Some(rest.to_string()).filter(|s| !s.is_empty()),
            't' => {
                family = match rest {
                    "IPv4" => Some(4),
                    "IPv6" => Some(6),
                    _ => None,
                }
            }
            'n' => {
                if let Some(mut l) = parse_lsof_name(rest, family) {
                    l.pid = pid;
                    l.process.clone_from(&process);
                    out.push(l);
                }
            }
            _ => {}
        }
    }
    out
}

fn parse_lsof_name(name: &str, family: Option<u8>) -> Option<Listener> {
    if name.contains("->") {
        return None;
    }
    let (host, port) = name.rsplit_once(':')?;
    let port = port.parse::<u16>().ok()?;
    let (family, addr) = if host == "*" {
        match family? {
            4 => (4, Ipv4Addr::UNSPECIFIED.to_string()),
            _ => (6, Ipv6Addr::UNSPECIFIED.to_string()),
        }
    } else if let Some(inner) = host.strip_prefix('[').and_then(|h| h.strip_suffix(']')) {
        (6, inner.parse::<Ipv6Addr>().ok()?.to_string())
    } else {
        (4, host.parse::<Ipv4Addr>().ok()?.to_string())
    };
    Some(Listener::bare(family, addr, port))
}

// --- watch ----------------------------------------------------------------

/// What `watch` sends after the first message: sockets that appeared and
/// sockets that went away, keyed by family, address and port (an owner that
/// becomes visible later is not a change).
pub(crate) fn diff(old: &[Listener], new: &[Listener]) -> (Vec<Listener>, Vec<Listener>) {
    let had: BTreeSet<Key> = old.iter().map(Listener::key).collect();
    let has: BTreeSet<Key> = new.iter().map(Listener::key).collect();
    let opened = new
        .iter()
        .filter(|l| !had.contains(&l.key()))
        .cloned()
        .collect();
    let closed = old
        .iter()
        .filter(|l| !has.contains(&l.key()))
        .cloned()
        .collect();
    (opened, closed)
}

#[derive(Deserialize)]
struct WatchArgs {
    interval_ms: Option<u64>,
}

/// Parses a method's args; anything malformed is `bad_request`.
pub(crate) fn parse_args<T: serde::de::DeserializeOwned>(args: &Value) -> Result<T, WireError> {
    serde_json::from_value(args.clone())
        .map_err(|e| WireError::new(ErrorCode::BadRequest, format!("bad arguments: {e}")))
}

fn watch(ctx: &StreamCtx) -> Result<Value, WireError> {
    let args: WatchArgs = parse_args(ctx.args())?;
    let ms = args.interval_ms.unwrap_or(DEFAULT_INTERVAL_MS);
    if ms < MIN_INTERVAL_MS {
        return Err(WireError::new(
            ErrorCode::BadRequest,
            format!("interval_ms must be at least {MIN_INTERVAL_MS}"),
        ));
    }
    let interval = Duration::from_millis(ms.min(MAX_INTERVAL_MS));
    let mut cache = OwnerCache::default();
    let mut known = scan_with(&mut cache)?.listeners;
    ctx.send_msg(&json!({"listeners": known}))?;
    while ctx.sleep(interval) {
        let now = scan_with(&mut cache)?.listeners;
        let (opened, closed) = diff(&known, &now);
        if !opened.is_empty() || !closed.is_empty() {
            ctx.send_msg(&json!({"opened": opened, "closed": closed}))?;
        }
        known = now;
    }
    Ok(json!({}))
}

// --- probe ----------------------------------------------------------------

#[derive(Deserialize)]
struct ProbeArgs {
    port: u16,
    host: Option<String>,
}

fn probe(ctx: &StreamCtx) -> Result<Value, WireError> {
    let args: ProbeArgs = parse_args(ctx.args())?;
    let host = args.host.as_deref().unwrap_or("127.0.0.1");
    Ok(json!({"open": probe_port(host, args.port)?}))
}

/// Whether `host:port` accepts a connection. `host` must be a loopback address
/// literal: this is a liveness check for local servers, not a port scanner.
pub(crate) fn probe_port(host: &str, port: u16) -> Result<bool, WireError> {
    if port == 0 {
        return Err(WireError::new(
            ErrorCode::BadRequest,
            "port must be 1..=65535",
        ));
    }
    let ip: IpAddr = host.parse().map_err(|_| {
        WireError::new(
            ErrorCode::BadRequest,
            "host must be a loopback address such as 127.0.0.1",
        )
    })?;
    if !ip.is_loopback() {
        return Err(WireError::new(
            ErrorCode::BadRequest,
            "only loopback addresses can be probed",
        ));
    }
    Ok(TcpStream::connect_timeout(&SocketAddr::new(ip, port), PROBE_TIMEOUT).is_ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Real rows (trimmed of trailing columns), little-endian CPU.
    const TCP4: &str = "\
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 11111 1 0000000000000000 100 0 0 10 0
   1: 0100007F:0035 00000000:0000 0A 00000000:00000000 00:00000000 00000000   101        0 22222 1 0000000000000000 100 0 0 10 0
   2: 0100007F:C350 0100007F:8F10 01 00000000:00000000 00:00000000 00000000  1000        0 33333 1 0000000000000000 20 4 30 10 -1
   3: 0100007F:BAD 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 44444 1
   4: 0100007F:7FFF 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 55555 1
   5: 0100007F:8000 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 66666 1
   6: ZZZZZZZZ:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 77777 1
   7: 00000000:FFFF 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 88888 1
";

    const TCP6: &str = "\
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000000000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 99991 1 0000000000000000 100 0 0 10 0
   1: 00000000000000000000000001000000:0BB8 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 99992 1 0000000000000000 100 0 0 10 0
   2: 00000000000000000000000001000000:0BB9 00000000000000000000000001000000:D431 01 00000000:00000000 00:00000000 00000000  1000        0 99993 1
   3: 0000000000000000FFFF00000100007F:1F91 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 99994 1
   4: 00000000000000000000000001000000:0BBA 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0
";

    fn row(l: &ProcRow) -> (u8, &str, u16, u64) {
        (
            l.listener.family,
            l.listener.addr.as_str(),
            l.listener.port,
            l.inode,
        )
    }

    #[test]
    fn ipv4_rows_keep_only_listening_sockets_with_their_inode() {
        let rows = parse_proc_net(TCP4, 4);
        let got: Vec<_> = rows.iter().map(row).collect();
        // The header, the ESTABLISHED row (01), the row with a 3-digit port,
        // the one with a non-hex address and the one cut short are all skipped.
        assert_eq!(
            got,
            vec![
                (4, "0.0.0.0", 22, 11111),
                (4, "127.0.0.1", 53, 22222),
                (4, "127.0.0.1", 32767, 55555),
                (4, "127.0.0.1", 32768, 66666),
                (4, "0.0.0.0", 65535, 88888),
            ]
        );
    }

    #[cfg(target_endian = "little")]
    #[test]
    fn ipv6_rows_decode_the_address_words_and_skip_other_states_and_cut_rows() {
        let rows = parse_proc_net(TCP6, 6);
        let got: Vec<_> = rows.iter().map(row).collect();
        assert_eq!(
            got,
            vec![
                (6, "::", 8080, 99991),
                (6, "::1", 3000, 99992),
                (6, "::ffff:127.0.0.1", 8081, 99994),
            ]
        );
    }

    #[test]
    fn a_header_only_or_empty_table_has_no_listeners() {
        assert!(parse_proc_net("", 4).is_empty());
        assert!(parse_proc_net("  sl  local_address rem_address   st\n", 6).is_empty());
    }

    const LSOF: &str = "\
p312
cControlCenter
t IPv4
tIPv4
n*:7000
tIPv6
n*:7000
p4001
cnode
tIPv4
n127.0.0.1:3000
tIPv6
n[::1]:3000
n[fe80::1]:3001
tIPv4
n10.0.0.2:5000->10.0.0.9:443
p77
tIPv4
n*:notaport
n127.0.0.1:9229
";

    #[test]
    fn lsof_output_gives_listeners_with_the_owner_of_the_preceding_p_line() {
        let got: Vec<_> = parse_lsof(LSOF)
            .into_iter()
            .map(|l| (l.pid, l.process, l.family, l.addr, l.port))
            .collect();
        let s = |v: &str| Some(v.to_string());
        assert_eq!(
            got,
            vec![
                (Some(312), s("ControlCenter"), 4, "0.0.0.0".into(), 7000),
                (Some(312), s("ControlCenter"), 6, "::".into(), 7000),
                (Some(4001), s("node"), 4, "127.0.0.1".into(), 3000),
                (Some(4001), s("node"), 6, "::1".into(), 3000),
                (Some(4001), s("node"), 6, "fe80::1".into(), 3001),
                // The process name of pid 312 must not leak into pid 77.
                (Some(77), None, 4, "127.0.0.1".into(), 9229),
            ]
        );
    }

    fn l(family: u8, addr: &str, port: u16) -> Listener {
        Listener::bare(family, addr.to_string(), port)
    }

    #[test]
    fn the_diff_is_keyed_by_family_address_and_port_not_by_owner() {
        let mut owned = l(4, "127.0.0.1", 3000);
        owned.pid = Some(7);
        let old = vec![
            l(4, "127.0.0.1", 3000),
            l(4, "0.0.0.0", 22),
            l(6, "::", 8080),
        ];
        let new = vec![owned, l(6, "::", 22), l(6, "::", 8080)];
        let (opened, closed) = diff(&old, &new);
        assert_eq!(
            opened,
            vec![l(6, "::", 22)],
            "same port, other family is a new socket"
        );
        assert_eq!(closed, vec![l(4, "0.0.0.0", 22)]);
        let (opened, closed) = diff(&new, &new);
        assert!(opened.is_empty() && closed.is_empty());
    }

    #[test]
    fn a_listener_without_a_visible_owner_serialises_without_owner_fields() {
        let json = serde_json::to_value(l(4, "0.0.0.0", 22)).expect("serialises");
        assert_eq!(json, json!({"family": 4, "addr": "0.0.0.0", "port": 22}));
    }

    #[test]
    fn passwd_text_maps_uids_to_the_first_name() {
        let t = parse_passwd("root:x:0:0:root:/root:/bin/sh\nbad line\ndev:x:1000:1000::/home/dev:/bin/sh\ntoor:x:0:0::/:/bin/sh\n");
        assert_eq!(t.get(&0).map(String::as_str), Some("root"));
        assert_eq!(t.get(&1000).map(String::as_str), Some("dev"));
        assert_eq!(t.len(), 2);
    }

    #[test]
    fn the_catalog_examples_parse_into_the_typed_args() {
        for spec in METHODS {
            let args: Value =
                serde_json::from_str(spec.args_example).expect("args example is JSON");
            let _: Value =
                serde_json::from_str(spec.result_example).expect("result example is JSON");
            match spec.name {
                "list" => {}
                "watch" => {
                    let a: WatchArgs = parse_args(&args).expect("typed");
                    assert!(a.interval_ms.expect("interval") >= MIN_INTERVAL_MS);
                }
                "probe" => {
                    let a: ProbeArgs = parse_args(&args).expect("typed");
                    assert_eq!(a.port, 3000);
                }
                other => panic!("no typed args check for {other}"),
            }
        }
    }

    #[test]
    fn probing_refuses_anything_but_a_loopback_address_and_a_real_port() {
        for host in [
            "8.8.8.8",
            "localhost",
            "example.com",
            "",
            "::ffff:8.8.8.8",
            "0.0.0.0",
            "10.0.0.1",
        ] {
            let e = probe_port(host, 80).expect_err(host);
            assert_eq!(e.code, ErrorCode::BadRequest, "{host}");
        }
        assert_eq!(
            probe_port("127.0.0.1", 0).expect_err("port 0").code,
            ErrorCode::BadRequest
        );
    }

    #[test]
    fn a_wrongly_typed_port_is_a_bad_request() {
        for args in [
            json!({"port": "80"}),
            json!({"port": 70000}),
            json!({"port": -1}),
            json!({}),
        ] {
            let e = parse_args::<ProbeArgs>(&args).err().expect("refused");
            assert_eq!(e.code, ErrorCode::BadRequest);
        }
    }

    /// A tempdir laid out like `/proc`: `net/tcp` rows and `<pid>/fd/<n>`
    /// symlinks to `socket:[inode]`.
    struct FakeProc {
        dir: tempfile::TempDir,
    }

    impl FakeProc {
        fn new() -> Self {
            let dir = tempfile::tempdir().expect("dir");
            std::fs::create_dir(dir.path().join("net")).expect("net");
            let fake = Self { dir };
            fake.listen(&[]);
            fake
        }

        /// Replaces the table with a LISTEN row `(port, inode)` each.
        fn listen(&self, rows: &[(u16, u64)]) {
            let addr = format!("{:08X}", u32::from_ne_bytes([127, 0, 0, 1]));
            let mut text = String::from("  sl  local_address rem_address   st\n");
            for (i, (port, inode)) in rows.iter().enumerate() {
                text.push_str(&format!(
                    "  {i}: {addr}:{port:04X} 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 {inode} 1\n"
                ));
            }
            std::fs::write(self.dir.path().join("net/tcp"), text).expect("tcp");
        }

        fn process(&self, pid: u32, comm: &str, sockets: &[u64]) {
            let fds = self.dir.path().join(pid.to_string()).join("fd");
            std::fs::create_dir_all(&fds).expect("fd dir");
            std::fs::write(
                fds.parent().expect("pid dir").join("comm"),
                format!("{comm}\n"),
            )
            .expect("comm");
            std::os::unix::fs::symlink("pipe:[1]", fds.join("0")).expect("pipe fd");
            for (n, inode) in sockets.iter().enumerate() {
                std::os::unix::fs::symlink(
                    format!("socket:[{inode}]"),
                    fds.join((n + 1).to_string()),
                )
                .expect("socket fd");
            }
        }

        fn exit(&self, pid: u32) {
            std::fs::remove_dir_all(self.dir.path().join(pid.to_string())).expect("remove");
        }

        fn tick(&self, cache: &mut OwnerCache) -> (Vec<Option<u32>>, usize) {
            let before = cache.pid_dirs_read;
            let listeners = scan_proc_in(self.dir.path(), cache).expect("scan");
            (
                listeners.iter().map(|l| l.pid).collect(),
                cache.pid_dirs_read - before,
            )
        }
    }

    #[test]
    fn an_unchanged_tick_reads_no_process_folders() {
        let proc = FakeProc::new();
        proc.listen(&[(3000, 100)]);
        proc.process(10, "node", &[100]);
        proc.process(11, "other", &[]);
        let mut cache = OwnerCache::default();
        let (pids, walked) = proc.tick(&mut cache);
        assert_eq!(pids, vec![Some(10)]);
        assert!(walked >= 1, "the first look has to walk");
        for _ in 0..3 {
            let (pids, walked) = proc.tick(&mut cache);
            assert_eq!(pids, vec![Some(10)], "same answer from the cache");
            assert_eq!(walked, 0);
        }
        let listeners = scan_proc_in(proc.dir.path(), &mut cache).expect("scan");
        assert_eq!(listeners[0].process.as_deref(), Some("node"));
        assert!(listeners[0].user.is_some());
    }

    #[test]
    fn a_new_listener_triggers_one_walk_and_the_known_ones_keep_their_owner() {
        let proc = FakeProc::new();
        proc.listen(&[(3000, 100)]);
        proc.process(10, "node", &[100]);
        let mut cache = OwnerCache::default();
        proc.tick(&mut cache);
        proc.process(12, "vite", &[200]);
        proc.listen(&[(3000, 100), (4000, 200)]);
        let (pids, walked) = proc.tick(&mut cache);
        assert_eq!(pids, vec![Some(10), Some(12)]);
        assert!(walked >= 1);
        assert_eq!(proc.tick(&mut cache).1, 0);
    }

    #[test]
    fn a_closed_listener_drops_its_cache_entry_without_a_walk() {
        let proc = FakeProc::new();
        proc.listen(&[(3000, 100), (4000, 200)]);
        proc.process(10, "node", &[100, 200]);
        let mut cache = OwnerCache::default();
        proc.tick(&mut cache);
        assert_eq!(cache.owners.len(), 2);
        proc.listen(&[(4000, 200)]);
        let (pids, walked) = proc.tick(&mut cache);
        assert_eq!(pids, vec![Some(10)]);
        assert_eq!(walked, 0);
        assert_eq!(cache.owners.keys().copied().collect::<Vec<_>>(), vec![200]);
    }

    #[test]
    fn an_owner_that_exited_is_looked_for_again_once() {
        let proc = FakeProc::new();
        proc.listen(&[(3000, 100)]);
        proc.process(10, "node", &[100]);
        proc.process(11, "bystander", &[]);
        let mut cache = OwnerCache::default();
        proc.tick(&mut cache);
        // The process is gone but the socket is still listed (a child holds it).
        proc.exit(10);
        proc.process(20, "child", &[100]);
        let (pids, walked) = proc.tick(&mut cache);
        assert_eq!(pids, vec![Some(20)]);
        assert!(walked >= 1);
        // Nobody holds it any more but the table still lists it: one more look, then none.
        proc.exit(20);
        let (pids, walked) = proc.tick(&mut cache);
        assert_eq!(pids, vec![None]);
        assert!(walked >= 1);
        assert_eq!(proc.tick(&mut cache), (vec![None], 0));
    }

    #[test]
    fn a_listener_nobody_visible_owns_is_not_searched_for_on_every_tick() {
        let proc = FakeProc::new();
        proc.listen(&[(22, 300)]);
        proc.process(10, "node", &[]);
        let mut cache = OwnerCache::default();
        let (pids, walked) = proc.tick(&mut cache);
        assert_eq!(pids, vec![None]);
        assert!(walked >= 1);
        assert_eq!(proc.tick(&mut cache), (vec![None], 0));
        // Once it closes, its inode is forgotten: a later socket with that inode is searched for.
        proc.listen(&[]);
        proc.tick(&mut cache);
        assert!(cache.unowned.is_empty());
    }
}
