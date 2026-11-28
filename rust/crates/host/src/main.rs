//! `herdr-host`: the host side of herdr-mobile. `serve` speaks hostwire/1 to the
//! app on one exec channel; `keeper-daemon` owns an agent process; `start`,
//! `attach`, `kill`, `probe`, `list`, `follow`, `blob` and `history` are the
//! keeper's command line; `api` prints the service catalog.
// A CLI: its output is stdout.
#![allow(clippy::print_stdout)]
use keeper::ctl;
use keeper::daemon;
use std::process::ExitCode;

const USAGE: &str =
    "usage: herdr-host <serve|api|start|attach|kill|probe|list|follow|blob|history …>";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match args.first().map(String::as_str) {
        Some("keeper-daemon") => daemon::run(),
        Some("serve") => host::serve::run(),
        Some("api") => cmd_api(),
        Some("probe") => cmd_probe(),
        Some("list") => cmd_list(),
        Some("start") => cmd_start(&args[1..]),
        Some("attach") => cmd_attach(&args[1..]),
        Some("kill") => cmd_kill(&args[1..]),
        Some("follow") => keeper::follow::cmd_follow(&args[1..]),
        Some("blob") => keeper::follow::cmd_blob(&args[1..]),
        Some("history") => keeper::history::cmd_history(&args[1..]),
        Some("--version") | Some("-V") => {
            println!("herdr-host {}", host::VERSION);
            0
        }
        _ => {
            eprintln!("{USAGE}");
            keeper::exit::USAGE
        }
    };
    ExitCode::from(code as u8)
}

/// `api`: the catalog of every service and method, as checked in at
/// `docs/host-api.json`.
fn cmd_api() -> i32 {
    let catalog = host::registry().catalog();
    println!(
        "{}",
        serde_json::to_string_pretty(&catalog).unwrap_or_default()
    );
    0
}

/// What every failing command prints: `herdr-mobile: <sentence>`, and its code.
fn fail(e: &ctl::CtlError) -> i32 {
    eprintln!("herdr-mobile: {e}");
    e.code
}

/// `probe`: the routes whose binary (or npx) the host can run.
fn cmd_probe() -> i32 {
    let routes = ctl::probe(&ctl::Env::from_process());
    println!("{}", serde_json::json!({"routes": routes}));
    0
}

/// `list`: every keeper on disk, newest first; stale ones are marked exited.
fn cmd_list() -> i32 {
    match ctl::list(&ctl::Env::from_process()) {
        Ok(infos) => {
            println!(
                "{}",
                serde_json::to_string(&infos).unwrap_or_else(|_| "[]".into())
            );
            0
        }
        Err(e) => fail(&e),
    }
}

/// `start --agent A --cwd D`: spawn a detached daemon and poll for its record.
fn cmd_start(args: &[String]) -> i32 {
    let mut agent = None;
    let mut cwd = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--agent" => {
                i += 1;
                agent = args.get(i).cloned();
            }
            "--cwd" => {
                i += 1;
                cwd = args.get(i).cloned();
            }
            _ => {}
        }
        i += 1;
    }
    let Some(agent) = agent else {
        eprintln!("herdr-mobile: start needs --agent");
        return keeper::exit::USAGE;
    };
    let Some(cwd) = cwd else {
        eprintln!("herdr-mobile: start needs --cwd");
        return keeper::exit::USAGE;
    };
    match ctl::start(&ctl::Env::from_process(), &ctl::StartRequest { agent, cwd }) {
        Ok(info) => {
            println!("{}", serde_json::to_string(&info).unwrap_or_default());
            0
        }
        Err(e) => fail(&e),
    }
}

/// `attach ID [--z]`: bridge this process's stdin/stdout to the keeper's
/// socket. The `--z` (zipped) variant is the app's path (whole-line batches of
/// at least [`keeper::zlib_batch::ATTACH_ZIP_MIN`] bytes go as `Z<base64>` of
/// one zlib stream); a plain attach forwards bytes both ways.
fn cmd_attach(args: &[String]) -> i32 {
    let mut id = None;
    let mut zipped = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--z" => zipped = true,
            other if other.starts_with('-') => {
                eprintln!("herdr-mobile: unknown attach flag {other}");
                return keeper::exit::USAGE;
            }
            other => {
                if id.is_some() {
                    eprintln!("herdr-mobile: attach takes one keeper id");
                    return keeper::exit::USAGE;
                }
                id = Some(other.to_string());
            }
        }
        i += 1;
    }
    let Some(id) = id else {
        eprintln!("herdr-mobile: attach needs a keeper id");
        return keeper::exit::USAGE;
    };
    match ctl::connect(&ctl::Env::from_process(), &id) {
        Ok(stream) => {
            bridge(stream, zipped);
            0
        }
        Err(e) => fail(&e),
    }
}

/// `kill ID`: SIGTERM the daemon (its pgroup takes the agent), then clean up.
fn cmd_kill(args: &[String]) -> i32 {
    let Some(id) = args.first() else {
        eprintln!("herdr-mobile: kill needs a keeper id");
        return keeper::exit::USAGE;
    };
    match ctl::kill(&ctl::Env::from_process(), id) {
        Ok(()) => {
            println!("{}", serde_json::json!({"ok": true}));
            0
        }
        Err(e) => fail(&e),
    }
}

/// The attach bridge: stdin → socket, socket → stdout. Closing stdin
/// detaches (the agent keeps running).
///
/// With [zipped] the socket → stdout direction is cut into whole lines and a
/// batch of at least [`zlib_batch::ATTACH_ZIP_MIN`] bytes travels as one
/// `Z<base64>` line of one zlib stream (the app's `ZippedLines` reads it); the
/// stdin → socket direction is always plain. A plain attach forwards bytes
/// both ways. The bridge lives exactly as long as its client: when the phone
/// detaches (stdin EOF) the stdin thread sets a flag, and the main loop —
/// reading the socket with a short timeout — breaks on it. The socket stays
/// blocking (a blocking write from the stdin thread never drops data), and the
/// keeper daemon keeps running.
fn bridge(mut stream: std::os::unix::net::UnixStream, zipped: bool) {
    use std::io::{Read, Write};
    let client_gone = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_millis(100)));
    // stdin → socket: plain, line for line (a partial line is held until its
    // newline, so the keeper never sees a split ACP message).
    let write_half = stream.try_clone().expect("a socket can be cloned");
    let stdin = std::io::stdin();
    let gone = std::sync::Arc::clone(&client_gone);
    let to_sock = std::thread::spawn(move || {
        let mut write = write_half;
        let mut buf = [0u8; 65536];
        let mut line = Vec::new();
        loop {
            match stdin.lock().read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    line.extend_from_slice(&buf[..n]);
                    while let Some(pos) = line.iter().position(|&b| b == b'\n') {
                        let l: Vec<u8> = line.drain(..=pos).collect();
                        let _ = write.write_all(&l);
                    }
                    if line.len() > 32 * 1024 * 1024 {
                        line.clear();
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                Err(_) => break,
            }
        }
        gone.store(true, std::sync::atomic::Ordering::Relaxed);
    });
    // socket → stdout: the batcher.
    let z = zipped.then(keeper::zlib_batch::new_stream);
    let mut buf = [0u8; 65536];
    let mut held = Vec::new();
    let stdout = std::io::stdout();
    let send = |out: &[u8]| -> bool { stdout.lock().write_all(out).is_ok() };
    loop {
        if client_gone.load(std::sync::atomic::Ordering::Relaxed) {
            break;
        }
        match stream.read(&mut buf) {
            Ok(0) => {
                // The keeper hung up, possibly mid-line: send the remainder.
                if !held.is_empty() {
                    let whole = std::mem::take(&mut held);
                    let out = zipped_out(z.as_ref(), &whole);
                    if !send(&out) {
                        break;
                    }
                }
                break;
            }
            Ok(n) => {
                held.extend_from_slice(&buf[..n]);
                match held.iter().rposition(|&b| b == b'\n') {
                    Some(pos) => {
                        let whole: Vec<u8> = held.drain(..=pos).collect();
                        let out = zipped_out(z.as_ref(), &whole);
                        if !send(&out) {
                            break;
                        }
                    }
                    None => {
                        // No complete line yet: keep accumulating.
                        if held.len() > 64 * 1024 * 1024 {
                            held.clear();
                        }
                    }
                }
            }
            // No data this tick: the client may have detached; the flag above
            // says.
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock
                        | std::io::ErrorKind::TimedOut
                        | std::io::ErrorKind::Interrupted
                ) =>
            {
                continue;
            }
            Err(_) => break,
        }
    }
    // Join only when the client detached (stdin EOF): then the stdin thread has
    // already finished. When the *keeper* hung up, the thread is still blocked
    // reading a stdin the client will never close — joining it would hang the
    // attach forever.
    if client_gone.load(std::sync::atomic::Ordering::Relaxed) {
        let _ = to_sock.join();
    }
}

/// A whole-line batch [whole] as it goes to the phone: `Z<base64>` when [z] is
/// a zipped stream and the batch is big enough, else [whole] as-is.
fn zipped_out(z: Option<&keeper::zlib_batch::Zlib>, whole: &[u8]) -> Vec<u8> {
    match z {
        Some(z) => keeper::zlib_batch::zipped_batch(z, whole),
        None => whole.to_vec(),
    }
}
