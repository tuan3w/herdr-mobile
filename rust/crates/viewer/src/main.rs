//! herdr-tui: a terminal client for one keeper session: the keeper's socket, a full-screen UI.
//! The keeper itself is the `keeper` library in this binary (`herdr-tui keeper-daemon`).
//!
//! No async runtime. Two threads feed one channel (socket, keyboard); the UI
//! redraws only when something arrives, so it costs nothing at rest.
//!
//! This file is the only impure layer: it carries out the [`herdr_tui::session::Effect`]s
//! the pure session asks for.

use acp::Message;
use crossterm::{
    event::{
        self, DisableBracketedPaste, DisableFocusChange, EnableBracketedPaste, EnableFocusChange,
        Event as Term, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent,
        MouseEventKind,
    },
    execute,
    terminal::{
        self, BeginSynchronizedUpdate, EndSynchronizedUpdate, EnterAlternateScreen,
        LeaveAlternateScreen, SetTitle,
    },
};
use herdr_tui::attach;
use herdr_tui::composer::Composer;
use herdr_tui::question::{self, Act};
use herdr_tui::select::Selection;
use herdr_tui::session::{Effect, Event, Phase, Record, Refused, Session, Start};
use herdr_tui::transcript::Transcript;
use herdr_tui::ui;
use herdr_tui::{
    cli, clip, elapsed, fold, herdr, highlight, host, input, lines, md, queue, risk, select,
    sessions, slash, termbg, theme, update,
};
use keeper::records::StateDir;
use std::io::{BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// Lines one press of Up or Down (or one tick of the wheel) scrolls.
const SCROLL_STEP: usize = 3;
/// Said when a key or a paste lands on a question's choices, where it would do nothing.
const QUESTION_HINT: &str = "Answer on the panel: ↑↓ or a number, then Enter; Esc declines";

enum Ev {
    Key(KeyEvent),
    /// A press, drag or release of the left button, or a turn of the wheel, when the mouse is ours
    /// (`input::mouse_wanted`).
    Mouse(MouseEvent),
    Resize,
    /// Text pasted (the terminal marks it, so it is one insertion and not a run of keys).
    Paste(String),
    /// SIGTERM, SIGHUP or SIGINT: leave cleanly.
    Signal(i32),
    /// Something outside wrote on the screen, or the window was away: draw everything again.
    Repaint,
    Session(Event),
    /// An update (`/update`) reporting progress, or finished.
    Update(UpdateMsg),
    /// The picture read from the clipboard (saved in the inbox), or why there is none.
    Clip(Result<PathBuf, String>),
}

/// What the thread running an update tells the screen.
enum UpdateMsg {
    /// A line saying how far it has got.
    Progress(String),
    /// It ended: the sentence to show, or what went wrong.
    Done(Result<String, String>),
}

struct App {
    dir: StateDir,
    id: String,
    out: UnixStream,
    session: Session,
    transcript: Transcript,
    composer: Composer,
    view: ui::View,
    hint: Option<String>,
    agent: String,
    cwd: String,
    theme: theme::Theme,
    turn_started: Option<Instant>,
    /// A standing grant waits for the same key a second time.
    confirm: Option<(acp::Id, usize)>,
    turn_live: bool,
    was_attention: bool,
    last_title: String,
    /// The request the chosen option belongs to; a new one starts at the first option.
    sel_for: Option<acp::Id>,
    /// The permission option a click last chose, and for which request: a second click on it
    /// answers.
    clicked: Option<(acp::Id, usize)>,
    /// The file this program was started from, watched for being replaced by a newer one.
    watch: update::Watch,
    /// The version of a newer herdr-tui installed since this one started; `Ctrl-R` loads it.
    newer: Option<String>,
    /// When the file was last looked at (at most every few seconds, and only on something that
    /// already woke the screen: no timer).
    watched: Instant,
    /// Leave to start the newer one in this session.
    reload: bool,
    /// While a question waits the composer is its box: the person's own draft, set aside until
    /// the question goes.
    stash: Option<String>,
    /// The question and field whose text the composer holds.
    boxed: Option<(acp::Id, usize)>,
    repaint: bool,
    /// The selection was finished: copy what it covers from the frame about to be drawn.
    copy: bool,
    /// The signal that asked the program to end, if one did.
    signal: Option<i32>,
    /// Tells herdr what this session is doing, when run inside a herdr pane.
    reporter: Option<herdr::Reporter>,
    t0: Instant,
    tx: mpsc::Sender<Ev>,
    quit: bool,
    /// Whose folder holds the session records (and starts another session).
    home: PathBuf,
    /// The agent's id (`omp`), to start another session of the same kind.
    agent_id: String,
    /// Leave to start a fresh session of the same agent in the same folder (`/new`, `/clear`).
    fresh: bool,
    /// The line whose command list was closed with Esc.
    dismissed: Option<String>,
    /// The line held as a command the agent does not list; Enter again sends it as a message.
    held: Option<String>,
    /// The line the command list's chosen row belongs to.
    palette_text: String,
    /// Files to send with the next message: a path pasted into an empty box.
    files: Vec<attach::Attachment>,
    /// The mode `/plan` left, so that `/plan` again goes back to it.
    before_plan: Option<String>,
    /// An update is running; a second one waits for it.
    updating: bool,
    /// What `can_fresh` said at the start: the command list asks on every key, the check reads
    /// the disk.
    fresh_ok: bool,
    /// The risky mode the person chose once and is asked to choose again.
    mode_confirm: Option<String>,
    /// A clipboard picture is being read; a second Ctrl-V waits for it.
    clipping: bool,
    /// The number the last picture of this message was given (`[Image #n]`); 0 with none.
    next_picture: u32,
    /// Messages typed while the agent works, sent one at a time when the turn ends. Memory only.
    queue: queue::Queue,
    /// The person pressed Stop on the running turn: the queue goes on after it.
    stop_requested: bool,
    /// A leave was refused because messages are queued; an immediate repeat leaves.
    leave_asked: bool,
    leave_was: bool,
}

/// While this program owns the screen, a background job of the same terminal that tries to write
/// (an image viewer's warnings, a build left running with `&`) is stopped by the kernel instead of
/// writing over the interface. The shell lists it as Stopped, and `fg` resumes it. Undone with the
/// rest of the terminal's modes when raw mode ends.
fn stop_background_writers() {
    use rustix::termios::{tcgetattr, tcsetattr, LocalModes, OptionalActions};
    let tty = std::io::stdin();
    if let Ok(mut modes) = tcgetattr(&tty) {
        modes.local_modes |= LocalModes::TOSTOP;
        let _ = tcsetattr(&tty, OptionalActions::Now, &modes);
    }
}

/// `herdr-tui ls`: the sessions on this machine as a table.
fn list_sessions(home: &std::path::Path, all: bool) {
    let dir = StateDir::create(home)
        .unwrap_or_else(|e| die(keeper::exit::FAILED, &format!("no state directory ({e})")));
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX));
    let infos = dir.scan(now, &keeper::records::System);
    let width = terminal::size().map_or(100, |(w, _)| usize::from(w));
    let table = sessions::render(
        &sessions::rows(&infos, now, &home.to_string_lossy()),
        all,
        width,
    );
    let _ = std::io::stdout().write_all(table.as_bytes());
}

/// `herdr-tui kill ID...`: ends each session for good, and says what it did to each.
fn kill_sessions(home: &std::path::Path, ids: &[String]) -> ! {
    let mut failed = false;
    for id in ids {
        match host::kill(home, id) {
            Ok(()) => {
                let _ = writeln!(std::io::stdout(), "ended {id}");
            }
            Err(e) => {
                failed = true;
                eprintln!("herdr-tui: {id}: {}", md::one_line(&e.message, 200));
            }
        }
    }
    std::process::exit(i32::from(failed));
}

fn die(code: i32, message: &str) -> ! {
    eprintln!("herdr-tui: {}", md::one_line(message, 400));
    std::process::exit(code);
}

/// Opens the state directory and connects to keeper `id`.
fn connect(home: &std::path::Path, id: &str) -> (StateDir, UnixStream) {
    StateDir::create(home)
        .and_then(|mut d| {
            d.enter()?;
            let s = d.connect(id)?;
            Ok((d, s))
        })
        .unwrap_or_else(|e| die(keeper::exit::GONE, &format!("no such session: {id} ({e})")))
}

fn main() {
    // `keeper::ctl::start` re-executes this program as the session's daemon. It is not a client:
    // no arguments are parsed, no terminal is touched.
    if std::env::args().nth(1).as_deref() == Some("keeper-daemon") {
        std::process::exit(keeper::daemon::run());
    }
    let cmd = cli::parse(std::env::args().skip(1)).unwrap_or_else(|e| {
        eprintln!("herdr-tui: {e}\n\n{}", cli::USAGE);
        std::process::exit(keeper::exit::USAGE);
    });
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let (id, start) = match cmd {
        cli::Cmd::Help => {
            eprintln!("{}", cli::USAGE);
            return;
        }
        cli::Cmd::Version => {
            eprintln!("herdr-tui {}", cli::VERSION);
            return;
        }
        cli::Cmd::Ls { all } => {
            list_sessions(&home, all);
            return;
        }
        cli::Cmd::Kill { ids } => kill_sessions(&home, &ids),
        cli::Cmd::Update { check, version } => {
            let exe = std::env::current_exe()
                .unwrap_or_else(|e| die(keeper::exit::FAILED, &format!("no path to itself ({e})")));
            let base = update::base_url(|k| std::env::var(k).ok(), version.as_deref());
            use std::io::IsTerminal;
            let output = if std::io::stderr().is_terminal() {
                update::Output::Terminal {
                    colour: std::env::var_os("NO_COLOR").is_none_or(|v| v.is_empty()),
                }
            } else {
                update::Output::Plain
            };
            let mut console = update::Console::new(output);
            // A signal only raises a flag: the update stops at its next step, curl is stopped and
            // the folder it made beside the program is removed (a default SIGINT would leave it).
            let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
            for sig in [
                signal_hook::consts::SIGINT,
                signal_hook::consts::SIGTERM,
                signal_hook::consts::SIGHUP,
            ] {
                let _ = signal_hook::flag::register(sig, std::sync::Arc::clone(&cancel));
            }
            let plan = update::Plan {
                base: &base,
                target: if version.is_some() {
                    update::Target::Pinned
                } else {
                    update::Target::Latest
                },
                action: if check {
                    update::Action::Check
                } else {
                    update::Action::Install
                },
                cancel: &cancel,
            };
            let result = update::run(&exe, cli::VERSION, &plan, &mut |e| console.event(&e));
            match result {
                Ok(said) => {
                    let _ = writeln!(std::io::stdout(), "herdr-tui: {said}");
                }
                Err(why) => die(keeper::exit::FAILED, &why),
            }
            return;
        }
        cli::Cmd::Attach { id } => (id, Start::Attach),
        cli::Cmd::New { agent, cwd } => {
            if keeper::routes::by_id(&agent).is_none() {
                let known: Vec<String> = keeper::routes::all().into_iter().map(|r| r.id).collect();
                die(
                    keeper::exit::USAGE,
                    &format!("unknown agent {agent:?} (known: {})", known.join(", ")),
                );
            }
            let cwd = cwd
                .map(PathBuf::from)
                .map_or_else(std::env::current_dir, Ok)
                .unwrap_or_else(|e| die(keeper::exit::GONE, &format!("no current folder ({e})")));
            let cwd = cwd.canonicalize().unwrap_or(cwd);
            let id = host::start(&home, &agent, &cwd).unwrap_or_else(|e| die(e.code, &e.message));
            (
                id,
                Start::Create {
                    cwd: cwd.to_string_lossy().into_owned(),
                },
            )
        }
    };
    let (dir, stream) = connect(&home, &id);
    let (tx, rx) = mpsc::channel();
    spawn_reader(
        stream.try_clone().expect("a socket can be cloned"),
        tx.clone(),
    );
    let info = dir.read(&id);
    let (session, first) = Session::begin(start, std::env::var("HERDR_PANE_ID").ok());
    let mut app = App {
        dir,
        id: id.clone(),
        out: stream,
        session,
        transcript: Transcript::default(),
        composer: Composer::default(),
        view: ui::View::default(),
        hint: None,
        agent: info.as_ref().map_or_else(String::new, |i| {
            keeper::routes::by_id(&i.agent).map_or(i.agent.clone(), |r| r.label)
        }),
        cwd: info.as_ref().map_or_else(String::new, |i| i.cwd.clone()),
        theme: theme::Theme::detect(None),
        turn_started: None,
        confirm: None,
        turn_live: false,
        was_attention: false,
        last_title: String::new(),
        sel_for: None,
        clicked: None,
        watch: update::Watch::new(&std::env::current_exe().unwrap_or_default(), cli::VERSION),
        newer: None,
        watched: Instant::now(),
        reload: false,
        stash: None,
        boxed: None,
        repaint: false,
        copy: false,
        signal: None,
        reporter: None,
        t0: Instant::now(),
        tx: tx.clone(),
        quit: false,
        home: home.clone(),
        agent_id: info.as_ref().map_or_else(String::new, |i| i.agent.clone()),
        fresh: false,
        dismissed: None,
        held: None,
        palette_text: String::new(),
        files: Vec::new(),
        before_plan: None,
        updating: false,
        fresh_ok: false,
        mode_confirm: None,
        clipping: false,
        next_picture: 0,
        queue: queue::Queue::default(),
        stop_requested: false,
        leave_asked: false,
        leave_was: false,
    };
    // A fresh session started from another one (`/new`): say where the earlier one went.
    if let Some(prev) = std::env::var("HERDR_TUI_PREVIOUS")
        .ok()
        .filter(|p| keeper::records::is_valid_id(p))
    {
        app.hint = Some(format!(
            "Fresh session · the earlier one, {prev}, is still running"
        ));
    }
    app.fresh_ok = app.can_fresh();
    app.run(first);
    app.reporter = herdr::Target::from_env(|k| std::env::var(k).ok()).map(|target| {
        let exe = std::env::current_exe().map_or_else(
            |_| "herdr-tui".to_string(),
            |p| p.to_string_lossy().into_owned(),
        );
        herdr::Reporter::new(
            target,
            format!("{} · phone", app.agent),
            vec![exe, "attach".to_string(), id.clone()],
        )
    });

    let mut term = ratatui::init();
    let _ = execute!(std::io::stdout(), EnterAlternateScreen, SetTitle("herdr"));
    // Ask the terminal to send the wheel as Up and Down while we own the screen (what the wheel
    // does when the mouse is not ours, below).
    let _ = std::io::stdout().write_all(b"\x1b[?1007h");
    let _ = execute!(std::io::stdout(), EnableFocusChange, EnableBracketedPaste);
    let _ = terminal::enable_raw_mode();
    stop_background_writers();
    install_restore_hook();
    // The tint behind messages is derived from the real background, so ask for it, once, now:
    // the keyboard thread is not reading yet.
    app.theme = theme::Theme::detect(termbg::query());
    // Clicks and the wheel come to us (after the colour query, so no click lands in its reply):
    // a click opens what it is on, and a drag selects and copies (`select.rs`).
    if input::mouse_wanted(|k| std::env::var(k).ok()) {
        let _ = std::io::stdout().write_all(input::MOUSE_ON);
        let _ = std::io::stdout().flush();
    }
    spawn_input(tx.clone());
    highlight::warm();
    spawn_signals(tx);

    while !app.quit {
        let working = app.transcript.running() || app.session.prompting();
        if working {
            if app.turn_started.is_none() {
                app.turn_live = app.session.ready();
            }
            app.turn_started = app.turn_started.or_else(|| Some(Instant::now()));
        } else if let Some(started) = app.turn_started.take() {
            // The turn the person watched ended: say what it did. A turn that
            // ended while the history was replaying is not news.
            if app.turn_live && app.session.ready() {
                app.transcript.done(started.elapsed().as_secs());
            }
            app.settle_queue();
        }
        // The turn just ended: the next queued message goes out at once, before herdr or the
        // window title are told the pane is idle.
        if app.pump_queue() {
            continue;
        }
        app.attend();
        app.report();
        let working_secs = app.turn_started.map(|t| t.elapsed().as_secs());
        let ctx = ui::Frame_ {
            transcript: &app.transcript,
            session: &app.session,
            composer: &app.composer,
            header: ui::Header {
                agent: &app.agent,
                cwd: &app.cwd,
            },
            theme: app.theme,
            hint: app.hint.as_deref(),
            working_secs,
            queue: &app.queue,
            newer: app.newer.as_deref(),
        };
        if std::mem::take(&mut app.repaint) {
            let _ = term.clear();
        }
        // One frame reaches the terminal whole: where it is supported, it shows nothing half-drawn.
        let _ = execute!(std::io::stdout(), BeginSynchronizedUpdate);
        let drawn = term.draw(|f| ui::draw(f, &ctx, &mut app.view));
        let _ = execute!(std::io::stdout(), EndSynchronizedUpdate);
        // A selection was just finished: copy it from this frame, then draw again at once so the
        // footer says so (nothing else would wake the loop to show it).
        if app.copy && drawn.as_ref().is_ok_and(|d| app.copy_selection(d.buffer)) {
            continue;
        }
        app.copy = false;
        // The loop sleeps until something happens, and wakes by itself only while a turn runs
        // (the elapsed counter, once a second). At rest nothing wakes it.
        let wake = elapsed::next_wake(working);
        let first = match wake {
            Some(d) => match rx.recv_timeout(d) {
                Ok(ev) => ev,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            },
            None => match rx.recv() {
                Ok(ev) => ev,
                Err(_) => break,
            },
        };
        // A streaming agent sends bursts: handle all that is waiting, draw once.
        app.handle(first);
        while let Ok(more) = rx.try_recv() {
            app.handle(more);
        }
    }
    restore_modes();
    let _ = execute!(std::io::stdout(), LeaveAlternateScreen);
    ratatui::restore();
    // Queued messages live in this program only: say which were never sent.
    for q in app.queue.entries() {
        eprintln!("Not sent: {}", md::one_line(&q.text, 200));
    }
    // The pane is no agent any more.
    if let Some(reporter) = app.reporter.take() {
        reporter.release();
    }
    // Load the newer herdr-tui into this session (the keeper holds everything, so the new one
    // attaches and replays), or start a fresh session of the same agent in the same folder
    // (`/new`); the earlier session keeps running and stays on the phone. Same terminal, same
    // pane; this process becomes the new one.
    if app.reload || app.fresh {
        use std::os::unix::process::CommandExt;
        let mut cmd = std::process::Command::new(app.watch.path());
        // Said once, by the program `/new` starts; a reload after it must not say it again.
        cmd.env_remove("HERDR_TUI_PREVIOUS");
        if app.fresh {
            cmd.args(["--agent", &app.agent_id, "--cwd", &app.cwd])
                .env("HERDR_TUI_PREVIOUS", &app.id);
        } else {
            cmd.arg("attach").arg(&app.id);
        }
        let err = cmd.exec();
        die(
            keeper::exit::FAILED,
            &format!(
                "could not start {} ({err}); the session is still running: herdr-tui attach {}",
                if app.fresh {
                    "a new session"
                } else {
                    "the newer herdr-tui"
                },
                app.id
            ),
        );
    }
    // Asked to end by a signal: the terminal is put back, then the exit status says so.
    if let Some(sig) = app.signal {
        std::process::exit(128 + sig);
    }
    if let Phase::Ended(reason) = app.session.phase() {
        eprintln!("herdr-tui: {}", md::one_line(reason, 400));
        std::process::exit(keeper::exit::EXITED);
    }
    eprintln!(
        "Session {id} is still running (it shows on your phone). Reopen it: herdr-tui attach {id}",
        id = app.id
    );
}

/// Puts back every terminal mode this program changed. Run on a normal exit and, through the panic
/// hook, on a crash, so the terminal is never left with its wheel remapped, the mouse taken or
/// focus events on.
fn restore_modes() {
    let mut out = std::io::stdout();
    let _ = out.write_all(input::MOUSE_OFF);
    let _ = out.write_all(b"\x1b[?1007l");
    // A panic between the begin and end of a frame must not leave the terminal holding output.
    let _ = execute!(
        out,
        EndSynchronizedUpdate,
        DisableBracketedPaste,
        DisableFocusChange,
        SetTitle("")
    );
}

/// ratatui's panic hook restores raw mode and the alternate screen; this adds the rest.
fn install_restore_hook() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        restore_modes();
        previous(info);
    }));
}

/// Reads the keyboard on its own thread. Terminal replies that are not typing are dropped here.
fn spawn_input(tx: mpsc::Sender<Ev>) {
    std::thread::spawn(move || {
        let mut replies = input::OscFilter::default();
        loop {
            let ev = match event::read() {
                Ok(Term::Key(k)) if k.kind != KeyEventKind::Release => {
                    if replies.drops(&k) {
                        continue;
                    }
                    Ev::Key(k)
                }
                Ok(Term::Paste(text)) => Ev::Paste(text),
                Ok(Term::Resize(..)) => Ev::Resize,
                Ok(Term::FocusGained) => Ev::Repaint,
                // Only what acts: the buttons (a drag selects), and the wheel. A move with no
                // button held is never asked for.
                Ok(Term::Mouse(m))
                    if matches!(
                        m.kind,
                        MouseEventKind::Down(MouseButton::Left)
                            | MouseEventKind::Drag(MouseButton::Left)
                            | MouseEventKind::Up(MouseButton::Left)
                            | MouseEventKind::ScrollUp
                            | MouseEventKind::ScrollDown
                    ) =>
                {
                    Ev::Mouse(m)
                }
                Ok(_) => continue,
                Err(_) => return,
            };
            if tx.send(ev).is_err() {
                return;
            }
        }
    });
}

/// SIGTERM, SIGHUP (the terminal closed) and SIGINT end the program the way a normal exit does, so
/// the terminal is put back.
fn spawn_signals(tx: mpsc::Sender<Ev>) {
    use signal_hook::{
        consts::{SIGHUP, SIGINT, SIGTERM},
        iterator::Signals,
    };
    let Ok(mut signals) = Signals::new([SIGHUP, SIGINT, SIGTERM]) else {
        return;
    };
    std::thread::spawn(move || {
        if let Some(sig) = signals.forever().next() {
            let _ = tx.send(Ev::Signal(sig));
        }
    });
}

/// The longest line taken from the keeper: what the keeper itself allows from an agent.
const MAX_LINE: usize = 64 * 1024 * 1024;

fn spawn_reader(stream: UnixStream, tx: mpsc::Sender<Ev>) {
    std::thread::spawn(move || {
        for line in lines::Lines::new(BufReader::new(stream), MAX_LINE) {
            let Ok(line) = line else { break };
            // A line that is not JSON-RPC (an agent's stray output) is not ours to show.
            if let Ok(m) = Message::parse(&line) {
                if tx.send(Ev::Session(Event::Message(m))).is_err() {
                    return;
                }
            }
        }
        let _ = tx.send(Ev::Session(Event::Closed));
    });
}

impl App {
    /// Tells herdr what the session is doing: its agent list shows working, blocked or idle.
    fn report(&mut self) {
        let Some(reporter) = self.reporter.as_mut() else {
            return;
        };
        if !self.session.ready() {
            return;
        }
        let state = if !self.session.waiting().is_empty() {
            herdr::State::Blocked
        } else if self.transcript.running() || self.session.prompting() {
            herdr::State::Working
        } else {
            herdr::State::Idle
        };
        reporter.set(state, self.session.session_id());
    }

    /// Calls for the person from a pane they may not be looking at: a bell when a
    /// request arrives, and the window title says what the session needs.
    fn attend(&mut self) {
        let head = self.session.waiting().first().map(|w| w.id.clone());
        if head != self.sel_for {
            self.view.sel = 0;
            self.sel_for = head;
        }
        let waiting = !self.session.waiting().is_empty();
        if waiting && !self.was_attention {
            let mut out = std::io::stdout();
            let _ = out.write_all(b"\x07");
            let _ = out.flush();
        }
        self.was_attention = waiting;
        let title = if waiting {
            format!("▲ {} needs you", self.agent)
        } else if self.transcript.running() || self.session.prompting() {
            format!("● {} working", self.agent)
        } else {
            self.transcript
                .title()
                .map_or_else(|| self.agent.clone(), str::to_string)
        };
        // An agent chooses its session's title; the terminal must only ever see one safe line.
        let title = md::one_line(&title, 100);
        if title != self.last_title {
            let _ = execute!(std::io::stdout(), SetTitle(&title));
            self.last_title = title;
        }
    }

    fn now_ms(&self) -> u64 {
        u64::try_from(self.t0.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    /// The wheel scrolls. A press starts a selection and the release ends it: dragged, it copies
    /// what was covered; not dragged, it is a click. A click on an option of the asking panel
    /// chooses it, and a click on the option already chosen answers with it (the same guards as
    /// Enter; on a question's ticks a click ticks); a click on a tool call, a run of them or the
    /// thinking opens or closes it. The click waits for the release so that a drag that starts on
    /// a tool call selects its text instead of opening it.
    fn mouse(&mut self, m: MouseEvent) {
        let at = (m.column, m.row);
        match m.kind {
            MouseEventKind::ScrollUp => {
                self.view.select = None;
                self.view.scroll = self.view.scroll.saturating_add(SCROLL_STEP);
            }
            MouseEventKind::ScrollDown => {
                self.view.select = None;
                self.view.scroll = self.view.scroll.saturating_sub(SCROLL_STEP);
            }
            MouseEventKind::Down(MouseButton::Left) => {
                // A click must not fall through to the transcript under the picker.
                if self.view.picker.is_some() {
                    return;
                }
                self.hint = None;
                // A press that moves off the option a standing grant waits on takes the
                // "press again" back, as the click used to: a drag must not leave it armed.
                self.confirm = None;
                self.view.select = Some(Selection::begin(at));
            }
            MouseEventKind::Drag(MouseButton::Left) => {
                if let Some(s) = self.view.select.as_mut().filter(|s| !s.done) {
                    s.drag(at);
                }
            }
            MouseEventKind::Up(MouseButton::Left) => {
                // A release with no press seen (the press went to something else) is not a click.
                let Some(mut s) = self.view.select.take().filter(|s| !s.done) else {
                    return;
                };
                s.drag(at);
                if s.range().is_some() {
                    s.done = true;
                    self.view.select = Some(s);
                    self.copy = true;
                } else {
                    self.click(m.row);
                }
            }
            _ => {}
        }
    }

    /// The release of a press that did not move, on screen row `row`.
    fn click(&mut self, row: u16) {
        self.view.help = false;
        if !self.session.waiting().is_empty() {
            if let Some(i) = self.view.option_at(row) {
                if self.asking_question() {
                    self.ask(Act::Click(i));
                    return;
                }
                // A first click only chooses, even on the option already marked (the
                // default is not a choice): the second click on it answers. A tap that
                // lands on a row the panel just moved under the thumb cannot approve.
                let armed = self.view.sel == i
                    && matches!((&self.clicked, &self.sel_for),
                        (Some((id, n)), Some(cur)) if id == cur && *n == i);
                if armed {
                    self.answer(i);
                } else {
                    self.confirm = None;
                    self.view.sel = i;
                    self.clicked = self.sel_for.clone().map(|id| (id, i));
                }
                return;
            }
        }
        self.confirm = None;
        if let Some(id) = self.view.queued_at(row) {
            self.take_back(Some(id));
            return;
        }
        if self.view.click_newest(row) {
            return;
        }
        self.view.click_fold(row);
    }

    /// Puts what the finished selection covers on the clipboard, from the frame just drawn, and
    /// says so. False when there was nothing to copy.
    fn copy_selection(&mut self, drawn: &ratatui::buffer::Buffer) -> bool {
        self.copy = false;
        let Some(range) = self.view.select.and_then(|s| s.range()) else {
            return false;
        };
        let text = select::text(drawn, range);
        if text.is_empty() {
            return false;
        }
        let mut out = std::io::stdout();
        let _ = out.write_all(&select::osc52(&text));
        let _ = out.flush();
        let n = text.chars().count();
        self.hint = Some(format!(
            "Copied {n} character{}",
            if n == 1 { "" } else { "s" }
        ));
        true
    }

    fn handle(&mut self, ev: Ev) {
        // What was selected is screen cells as they were drawn: anything but the pointer itself
        // (or output moving under a finished selection) leaves it pointing at other text.
        match &ev {
            Ev::Mouse(_) | Ev::Repaint => {}
            Ev::Session(_) => {
                // Not while the copy of a just-finished drag is still to be made: the
                // release and this event may arrive in one batch.
                if !self.copy && self.view.select.is_some_and(|s| s.done) {
                    self.view.select = None;
                }
            }
            _ => self.view.select = None,
        }
        match ev {
            Ev::Key(k) => {
                self.hint = None;
                if !matches!(k.code, KeyCode::Char('1'..='9') | KeyCode::Enter) {
                    self.confirm = None;
                }
                if k.code != KeyCode::Enter {
                    self.mode_confirm = None;
                }
                // Only an immediate repeat of the key that asked ("press again to leave") passes.
                self.leave_was = std::mem::take(&mut self.leave_asked);
                self.key(k);
            }
            Ev::Mouse(m) => self.mouse(m),
            Ev::Resize => {}
            Ev::Repaint => self.repaint = true,
            Ev::Paste(text) => self.paste(&text),
            Ev::Signal(sig) => {
                self.signal = Some(sig);
                self.quit = true;
            }
            Ev::Update(UpdateMsg::Progress(line)) => self.view.update = Some(line),
            Ev::Update(UpdateMsg::Done(result)) => self.update_done(result),
            Ev::Clip(Ok(path)) => {
                self.clipping = false;
                let path = path.to_string_lossy().into_owned();
                if !self.attach_paths(&[path]) {
                    self.hint = Some("Could not attach the picture from the clipboard".to_string());
                }
            }
            Ev::Clip(Err(why)) => {
                self.clipping = false;
                self.hint = Some(why);
            }
            Ev::Session(e) => {
                let fx = self.session.handle(e, self.now_ms(), &mut self.transcript);
                self.run(fx);
            }
        }
        self.sync_box();
        self.sync_palette();
        self.look_for_newer();
    }

    /// Looks at the installed file when something already woke the screen, and at most every few
    /// seconds.
    fn look_for_newer(&mut self) {
        if self.watched.elapsed() < Duration::from_secs(3) {
            return;
        }
        self.watched = Instant::now();
        self.refresh_newer();
    }

    /// Reads what the installed file holds now: an offer when it is another version than this
    /// one, none when it is the same, broken or gone, so a hint never outlives what it said.
    fn refresh_newer(&mut self) {
        match self.watch.poll() {
            update::Change::Offer(v) => self.newer = Some(v),
            update::Change::Withdraw => self.newer = None,
            update::Change::Unchanged => {}
        }
    }

    /// `Ctrl-R`: load the newer herdr-tui into this session, when nothing would be lost.
    fn load_newer(&mut self) {
        if !self.composer.text.is_empty() {
            self.hint = Some("Send or clear your message first, then Ctrl-R".to_string());
        } else if !self.files.is_empty() {
            self.hint =
                Some("Send the files or take them off (/files) first, then Ctrl-R".to_string());
        } else if !self.queue.is_empty() {
            self.hint = Some(
                "Queued messages would be lost: send or take them back (Backspace) first, then Ctrl-R"
                    .to_string(),
            );
        } else if !self.session.waiting().is_empty() {
            self.hint = Some("Answer the request first, then Ctrl-R".to_string());
        } else {
            self.reload = true;
            self.quit = true;
        }
    }

    fn asking_question(&self) -> bool {
        self.session
            .waiting()
            .first()
            .is_some_and(|w| w.question().is_some())
    }

    /// While a question waits, the composer belongs to it: the person's own draft is set aside
    /// (it comes back when the question goes), and on a typed field the box holds that field's
    /// text, so Enter can never send a prompt by accident.
    fn sync_box(&mut self) {
        let head = self
            .session
            .waiting()
            .first()
            .and_then(|w| w.question().map(|q| (w.id.clone(), q.at())));
        let Some(at) = head else {
            self.boxed = None;
            if let Some(draft) = self.stash.take() {
                self.composer.clear();
                self.composer.restore(draft);
            }
            return;
        };
        if self.stash.is_none() {
            self.stash = Some(std::mem::take(&mut self.composer.text));
            self.composer.clear();
            self.boxed = None;
        }
        if self.boxed.as_ref() == Some(&at) {
            return;
        }
        self.composer.clear();
        if let Some(q) = self.session.waiting().first().and_then(|w| w.question()) {
            if q.typed() {
                self.composer.restore(q.text().to_string());
            }
        }
        self.boxed = Some(at);
    }

    /// Carries out effects. Reading the record answers at once, so it may produce more.
    fn run(&mut self, effects: Vec<Effect>) {
        let mut pending = std::collections::VecDeque::from(effects);
        while let Some(fx) = pending.pop_front() {
            match fx {
                Effect::Send(m) => {
                    let mut line = m.to_line();
                    line.push('\n');
                    if self.out.write_all(line.as_bytes()).is_err() {
                        let more =
                            self.session
                                .handle(Event::Closed, self.now_ms(), &mut self.transcript);
                        pending.extend(more);
                    }
                }
                Effect::ReadRecord => {
                    let rec = self.dir.read(&self.id).map(|i| Record {
                        session_id: i.session_id,
                        cwd: if i.cwd.is_empty() { "/".into() } else { i.cwd },
                        exited: (i.state == keeper::records::State::Exited)
                            .then(|| i.exit_reason.unwrap_or_else(|| "the agent exited".into())),
                    });
                    let more = self.session.handle(
                        Event::Record(rec),
                        self.now_ms(),
                        &mut self.transcript,
                    );
                    pending.extend(more);
                }
                Effect::RetryIn(d) => {
                    let tx = self.tx.clone();
                    std::thread::spawn(move || {
                        std::thread::sleep(d.max(Duration::from_millis(1)));
                        let _ = tx.send(Ev::Session(Event::Retry));
                    });
                }
                Effect::RestoreInput(t, files) => {
                    self.composer.restore(t);
                    if self.files.is_empty() {
                        self.next_picture = files.iter().map(|f| f.number).max().unwrap_or(0);
                        self.files = files;
                    }
                }
                // A queued message the agent refused keeps its place, held; the box is the
                // person's and is left alone.
                Effect::RestoreQueued {
                    id,
                    text,
                    files,
                    why,
                } => self.queue.hold_front(
                    queue::Queued {
                        id,
                        text,
                        files,
                        held: None,
                    },
                    why,
                ),
            }
        }
    }

    /// A paste goes into the box whole: no line of it is sent, and nothing in it acts as a key.
    fn paste(&mut self, text: &str) {
        // A question's choices are picked on the panel: a paste there would go nowhere.
        let choosing = self
            .session
            .waiting()
            .first()
            .and_then(|w| w.question())
            .is_some_and(|q| !q.typed());
        if choosing {
            self.hint = Some(QUESTION_HINT.to_string());
            return;
        }
        // A paste with no text in it: a terminal that binds Ctrl-V to paste sends exactly that
        // when the clipboard holds a picture (a screenshot). Look for one.
        if text.is_empty() && self.session.waiting().is_empty() {
            self.paste_picture();
            return;
        }
        // A path (or several) pasted into an empty box is a file to send with the message,
        // as the phone's `@file`. Pasted into text, it is text.
        if attach::only_placeholders(&self.composer.text)
            && self.session.waiting().is_empty()
            && self.attach_paste(text)
        {
            return;
        }
        let (clean, cut) = input::clean_paste(text);
        self.view.focus = None;
        self.view.invalidate_lines();
        self.composer.insert_str(&clean);
        self.hint = cut.then(|| format!("The paste was cut at {} KB", input::MAX_PASTE / 1024));
    }

    /// Browse mode starts on the newest thing that can be opened.
    fn enter_browse(&mut self) {
        let keys = fold::focusable(self.transcript.items(), &self.view.expanded);
        match keys.last() {
            Some(last) => {
                self.view.focus = Some(*last);
                self.view.focus_dirty = true;
                self.view.invalidate_lines();
            }
            None => self.hint = Some("Nothing to fold yet".to_string()),
        }
    }

    /// Browse mode: move among what can be opened, open it, close it. `true` when the key
    /// was used here; scrolling and Ctrl chords go on to the usual handling.
    fn browse_key(&mut self, k: KeyEvent) -> bool {
        use fold::Nav;
        if k.modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        {
            return false;
        }
        let nav = match k.code {
            KeyCode::Esc | KeyCode::Char('i') => {
                self.view.focus = None;
                self.view.invalidate_lines();
                return true;
            }
            KeyCode::Up | KeyCode::Char('k') => Nav::Prev,
            KeyCode::Down | KeyCode::Char('j') => Nav::Next,
            KeyCode::Right | KeyCode::Char('l' | ' ') | KeyCode::Enter => Nav::Open,
            KeyCode::Left | KeyCode::Char('h') => Nav::Close,
            KeyCode::Char('a') => Nav::OpenAll,
            KeyCode::Char('z') => Nav::CloseAll,
            KeyCode::PageUp | KeyCode::PageDown | KeyCode::Home | KeyCode::End => return false,
            // Any other letter was meant for the message: leave browsing and type it.
            KeyCode::Char(c) => {
                self.view.focus = None;
                self.view.invalidate_lines();
                self.composer.insert(c);
                return true;
            }
            _ => return true,
        };
        let keys = fold::focusable(self.transcript.items(), &self.view.expanded);
        let Some(&last) = keys.last() else {
            self.view.focus = None;
            self.view.invalidate_lines();
            return true;
        };
        // What was focused may have been dropped to stay in budget.
        let focus = self.view.focus.filter(|f| keys.contains(f)).unwrap_or(last);
        let to = fold::navigate(nav, focus, &keys, &mut self.view.expanded);
        self.view.invalidate_lines();
        self.view.focus = Some(to);
        self.view.focus_dirty = true;
        true
    }

    fn key(&mut self, k: KeyEvent) {
        // The key list closes on `?`, Esc or Enter; any other key closes it and does its own job.
        if self.view.help {
            self.view.help = false;
            if matches!(k.code, KeyCode::Char('?') | KeyCode::Esc | KeyCode::Enter) {
                return;
            }
        } else if k.code == KeyCode::Char('?')
            && self.composer.text.is_empty()
            && self.session.waiting().is_empty()
        {
            self.view.help = true;
            return;
        }
        if self.view.focus.is_some() && self.browse_key(k) {
            return;
        }
        if self.question_key(k) {
            return;
        }
        if self.picker_key(k) || self.palette_key(k) {
            return;
        }
        let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
        let alt = k.modifiers.contains(KeyModifiers::ALT);
        match k.code {
            // With nothing typed and nothing asking, Esc browses what the agent did; with a request
            // waiting it withdraws the request.
            KeyCode::Esc if self.composer.text.is_empty() && self.session.waiting().is_empty() => {
                self.enter_browse()
            }
            KeyCode::Esc if self.composer.text.is_empty() => self.dismiss(),
            KeyCode::Char('d') if ctrl => {
                if self.may_leave() {
                    self.quit = true;
                }
            }
            KeyCode::Char('c') if ctrl => {
                // A picker open: Ctrl-C closes it, whatever else it would do.
                if self.view.picker.take().is_some() {
                    return;
                }
                if self.working() {
                    // The person's own Stop: the queue goes on once the turn ends (`settle_queue`).
                    self.stop_requested = true;
                    let fx = self.session.cancel(&mut self.transcript);
                    self.run(fx);
                } else if attach::only_placeholders(&self.composer.text) && !self.files.is_empty() {
                    self.take_all_files();
                    self.hint = Some("Took the files off".to_string());
                } else if self.composer.text.is_empty() {
                    if self.may_leave() {
                        self.quit = true;
                    }
                } else {
                    self.composer.clear();
                }
            }
            KeyCode::Char('t') if ctrl => {
                self.view.thoughts = !self.view.thoughts;
                self.view.invalidate_lines();
            }
            // Sent messages, as in a shell: Up and Down are for scrolling.
            KeyCode::Char('p') if ctrl => {
                self.composer.older();
            }
            KeyCode::Char('n') if ctrl => {
                self.composer.newer();
            }
            // Another program (an image viewer's warnings, a stray `echo`) can write on this
            // terminal behind our back; this puts the screen right.
            KeyCode::Char('l') if ctrl => self.repaint = true,
            // A picture on the clipboard (a screenshot) is attached: a terminal cannot paste one.
            KeyCode::Char('v') if ctrl && self.session.waiting().is_empty() => self.paste_picture(),
            KeyCode::Char('r') if ctrl && self.newer.is_some() => self.load_newer(),
            KeyCode::Char('w') if ctrl => self.composer.kill_word(),
            KeyCode::Char('u') if ctrl => self.composer.clear(),
            KeyCode::Char('j') if ctrl => self.composer.insert('\n'),
            KeyCode::Enter if alt || k.modifiers.contains(KeyModifiers::SHIFT) => {
                self.composer.insert('\n')
            }
            // On the permission panel, Enter confirms the chosen option, if nothing is typed.
            KeyCode::Enter
                if self.composer.text.is_empty() && !self.session.waiting().is_empty() =>
            {
                self.answer(self.view.sel);
            }
            KeyCode::Enter => self.send(),
            // With nothing asking, Shift-Tab goes to the next mode (plan mode among them).
            KeyCode::BackTab if self.session.waiting().is_empty() => self.cycle_mode(),
            KeyCode::Tab | KeyCode::BackTab if self.session.permission_waiting() => {
                let n = self.session.waiting()[0]
                    .permission()
                    .map_or(1, |r| r.options.len().max(1));
                self.view.sel = if k.code == KeyCode::Tab {
                    (self.view.sel + 1) % n
                } else {
                    (self.view.sel + n - 1) % n
                };
            }
            // With a request waiting and nothing typed, Up and Down walk its options (and stop at
            // the ends); the conversation still scrolls with PgUp, PgDn and the wheel.
            KeyCode::Up | KeyCode::Down
                if self.composer.text.is_empty() && self.session.permission_waiting() =>
            {
                let last = self.session.waiting()[0]
                    .permission()
                    .map_or(0, |r| r.options.len().saturating_sub(1));
                self.view.sel = if k.code == KeyCode::Up {
                    self.view.sel.saturating_sub(1)
                } else {
                    (self.view.sel + 1).min(last)
                };
            }
            // A digit answers only with an empty box: one being typed into a
            // message never answers a permission.
            KeyCode::Char(c @ '1'..='9')
                if !ctrl
                    && !alt
                    && self.composer.text.is_empty()
                    && self.session.permission_waiting() =>
            {
                self.answer(c as usize - '1' as usize);
            }
            KeyCode::Char(c) if !ctrl && !alt => self.composer.insert(c),
            // Nothing typed, nothing attached: Backspace takes the newest queued message back.
            KeyCode::Backspace
                if self.composer.text.is_empty()
                    && self.files.is_empty()
                    && !self.queue.is_empty()
                    && !self.asking_question() =>
            {
                self.take_back(None);
            }
            // Right after a picture's placeholder: Backspace takes the whole of it, and the
            // picture, off.
            KeyCode::Backspace if self.take_placeholder() => {}
            // Nothing typed and files attached: Backspace takes the last one off.
            KeyCode::Backspace
                if attach::only_placeholders(&self.composer.text)
                    && !self.files.is_empty()
                    && self.session.waiting().is_empty() =>
            {
                if !self.files.is_empty() {
                    let f = self.take_file(self.files.len() - 1);
                    self.hint = Some(format!("Took off {}", f.short()));
                }
            }
            KeyCode::Backspace => self.composer.backspace(),
            KeyCode::Delete => self.composer.delete(),
            KeyCode::Left => self.composer.left(),
            KeyCode::Right => self.composer.right(),
            // With nothing typed, Home goes to the start of the conversation.
            KeyCode::Home if self.composer.text.is_empty() => self.view.scroll = usize::MAX,
            KeyCode::Home => self.composer.home(),
            KeyCode::End if self.view.scroll > 0 => self.view.scroll = 0,
            KeyCode::End => self.composer.end(),
            // The wheel arrives as Up and Down in most terminals, so they scroll the
            // conversation; they move within a message only when it has several lines.
            KeyCode::Up => {
                if !(self.composer.text.contains('\n') && self.composer.up()) {
                    self.view.scroll = self.view.scroll.saturating_add(SCROLL_STEP);
                }
            }
            KeyCode::Down => {
                if !(self.composer.text.contains('\n') && self.composer.down()) {
                    self.view.scroll = self.view.scroll.saturating_sub(SCROLL_STEP);
                }
            }
            KeyCode::PageUp => self.view.scroll = self.view.scroll.saturating_add(self.view.page),
            KeyCode::PageDown => self.view.scroll = self.view.scroll.saturating_sub(self.view.page),
            _ => {}
        }
    }

    /// Keys for the question on screen. `true` when the key was the question's: on a typed field
    /// everything but Enter, Shift-Tab and Esc edits the box as usual.
    fn question_key(&mut self, k: KeyEvent) -> bool {
        let Some(typed) = self
            .session
            .waiting()
            .first()
            .and_then(|w| w.question())
            .map(|q| q.typed())
        else {
            return false;
        };
        // Ctrl-C still stops the turn, Ctrl-U clears, Ctrl-J breaks a typed answer's line.
        if k.modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        {
            return false;
        }
        let act = match k.code {
            KeyCode::Esc => {
                if question::esc_declines(typed, &self.composer.text) {
                    self.dismiss();
                }
                return true;
            }
            KeyCode::Enter if typed && k.modifiers.contains(KeyModifiers::SHIFT) => return false,
            // The box is empty on a choice: only a typed field's text goes with it.
            KeyCode::Enter => Act::Enter(self.composer.text.clone()),
            KeyCode::BackTab => Act::Back(self.composer.text.clone()),
            _ if typed => return false,
            KeyCode::Up => Act::Up,
            KeyCode::Down => Act::Down,
            KeyCode::Char(' ') => Act::Toggle,
            KeyCode::Char(c @ '1'..='9') => Act::Pick(c as usize - '1' as usize),
            KeyCode::Char(_) | KeyCode::Tab | KeyCode::Backspace | KeyCode::Delete => {
                self.hint = Some(QUESTION_HINT.to_string());
                return true;
            }
            _ => return false,
        };
        self.ask(act);
        true
    }

    fn ask(&mut self, act: Act) {
        // As for a permission: the question the person is looking at, as last drawn.
        let Some(shown) = self.sel_for.clone() else {
            return;
        };
        let result = self
            .session
            .question_for(&shown, act, self.now_ms(), &mut self.transcript);
        self.finish_answer(result);
    }

    fn answer(&mut self, index: usize) {
        // The request the person is looking at, as last drawn. A key meant for it must never be
        // applied to whatever took its place while the keys were queued.
        let Some(shown) = self.sel_for.clone() else {
            return;
        };
        // An answer that outlives this call ("always allow") is meant twice, for the same request.
        let standing = self
            .session
            .waiting()
            .first()
            .filter(|w| w.id == shown)
            .and_then(|w| w.permission())
            .and_then(|r| r.options.get(index))
            .is_some_and(|o| o.is_standing());
        if standing && self.confirm.as_ref() != Some(&(shown.clone(), index)) {
            self.confirm = Some((shown, index));
            self.hint = Some(format!(
                "This stays allowed. Press {} again to confirm",
                index + 1
            ));
            return;
        }
        self.confirm = None;
        let result = self
            .session
            .answer_for(&shown, index, self.now_ms(), &mut self.transcript);
        self.finish_answer(result);
    }

    /// Esc on a request: withdraw a permission (the way out of one that offers nothing to
    /// choose), decline a question.
    fn dismiss(&mut self) {
        let Some(shown) = self.sel_for.clone() else {
            return;
        };
        self.confirm = None;
        // Withdrawing a permission ends the turn by the person's own hand: the queue goes on.
        if self.session.permission_waiting() {
            self.stop_requested = true;
        }
        let result = self
            .session
            .dismiss_for(&shown, self.now_ms(), &mut self.transcript);
        self.finish_answer(result);
    }

    fn finish_answer(&mut self, result: Result<Vec<Effect>, Refused>) {
        match result {
            // The agent goes on from the answer: follow it. A mark or a move on a question sends
            // nothing and leaves the conversation where the person had scrolled it.
            Ok(fx) => {
                if !fx.is_empty() {
                    self.view.scroll = 0;
                }
                self.run(fx);
            }
            // A key right after the card appeared was meant for something else.
            Err(Refused::TooSoon | Refused::NothingWaiting) => {}
            Err(Refused::Changed) => {
                self.hint =
                    Some("That request was answered elsewhere; look at the next one".to_string())
            }
            Err(Refused::Ended) => self.hint = Some("The session is over".to_string()),
            // The field keeps what was typed; the footer says what is wrong.
            Err(Refused::Invalid(why)) => self.hint = Some(why),
            Err(_) => self.hint = Some("No such option".to_string()),
        }
    }

    fn send(&mut self) {
        let text = self.composer.text.trim().to_string();
        let raw = self.composer.text.clone();
        if text.is_empty() && self.files.is_empty() {
            if self.queue.release() {
                self.hint = Some("Resuming the queue".to_string());
            }
            return;
        }
        match slash::classify(&text, self.transcript.commands()) {
            slash::Run::Local(local, args) => {
                // A command that cannot run leaves what was typed in the box.
                let typed = self.composer.take();
                self.hint = None;
                self.run_local(local, &args);
                if self.hint.is_some() {
                    if let Some(t) = typed {
                        self.composer.restore(t);
                    }
                }
                return;
            }
            // A typo would reach the model as a message and cost a turn: held once, and sent
            // when Enter is pressed again on the same text.
            slash::Run::Unknown(word) => {
                if self.held.as_deref() != Some(raw.as_str()) {
                    self.hint = Some(format!(
                        "/{word} is not a command of {} · Enter sends it as a message",
                        self.agent
                    ));
                    self.held = Some(raw);
                    return;
                }
            }
            slash::Run::Agent | slash::Run::Message => {}
        }
        // Typed while the agent works, or behind messages that already wait: it joins the queue.
        if self.session.ready() && (self.working() || self.queue.has_waiting()) {
            self.enqueue(text);
            return;
        }
        // Pictures are read now, when the message goes, and not when they were pasted: a draft
        // may never be sent.
        if let Err(why) = self.load_pictures() {
            self.hint = Some(why);
            return;
        }
        match self.session.send(&text, &self.files, &mut self.transcript) {
            Ok(fx) => {
                self.composer.take();
                self.files.clear();
                self.next_picture = 0;
                self.held = None;
                self.view.scroll = 0;
                self.run(fx);
            }
            // The text stays in the box.
            Err(Refused::NotReady) => self.hint = Some("The session is not open yet".to_string()),
            Err(Refused::Busy) => self.hint = Some("The agent is working; not sent".to_string()),
            Err(_) => {}
        }
    }

    /// A turn is running: the agent's, or one this program's prompt started.
    fn working(&self) -> bool {
        self.transcript.running() || self.session.prompting()
    }

    /// Enter while the agent works: the message waits (`↳` above the box) and goes when the
    /// turn ends. Its pictures are read then, not now: their bytes would sit in memory for the
    /// whole wait.
    fn enqueue(&mut self, text: String) {
        if self.queue.is_full() {
            self.hint = Some(format!(
                "{} messages are queued already · Backspace takes one back",
                queue::MAX
            ));
            return;
        }
        self.queue.push(text, std::mem::take(&mut self.files));
        self.composer.take();
        self.next_picture = 0;
        self.held = None;
        self.view.scroll = 0;
    }

    /// Sends the oldest queued message when nothing is running and nothing asks. `true` when one
    /// went. A held message blocks the ones behind it, so a refusal never reorders the queue.
    fn pump_queue(&mut self) -> bool {
        if !self.session.ready()
            || self.working()
            || !self.session.waiting().is_empty()
            || self.queue.has_held()
        {
            return false;
        }
        let Some(mut q) = self.queue.pop_waiting() else {
            return false;
        };
        if let Err(why) = load_files(&mut q.files, self.session.accepts_pictures()) {
            self.queue.hold_front(q, why);
            return false;
        }
        match self
            .session
            .send_queued(q.id, &q.text, &q.files, &mut self.transcript)
        {
            Ok(fx) => {
                self.run(fx);
                true
            }
            Err(_) => {
                self.queue.requeue_front(q);
                false
            }
        }
    }

    /// A turn the person watched just ended: decide what happens to the queue. The person's own
    /// Stop goes on (messages typed meanwhile become one); a failed turn or one stopped from
    /// elsewhere holds everything, so nothing goes out on top of a problem unseen.
    fn settle_queue(&mut self) {
        let reason = self.transcript.take_stop();
        let mine = std::mem::take(&mut self.stop_requested);
        if self.queue.is_empty() {
            return;
        }
        match queue::after_turn(mine, reason.as_deref()) {
            queue::Disposition::Merge => self.queue.merge_waiting(),
            queue::Disposition::Hold(why) => self.queue.hold_all(why),
            queue::Disposition::Go => {}
        }
    }

    /// Puts a queued message (the newest, or the one with `id`) back into the box to edit.
    fn take_back(&mut self, id: Option<u64>) {
        // A question's box is the question's: what lands there would be wiped or sent as an answer.
        if self.asking_question() {
            return;
        }
        if !self.composer.text.is_empty() || !self.files.is_empty() {
            self.hint = Some("Send or clear what you are typing first".to_string());
            return;
        }
        let q = match id {
            Some(i) => self.queue.take(i),
            None => self.queue.take_newest(),
        };
        let Some(q) = q else {
            return;
        };
        self.composer.restore(q.text);
        self.next_picture = q.files.iter().map(|f| f.number).max().unwrap_or(0);
        self.files = q.files;
        self.hint = Some("Took it back to edit".to_string());
    }

    /// Leaving loses the queue: the first press says so, an immediate repeat leaves.
    fn may_leave(&mut self) -> bool {
        let n = self.queue.len();
        if n == 0 || self.leave_was {
            return true;
        }
        self.leave_asked = true;
        self.hint = Some(format!(
            "{n} queued message{} will be lost · press again to leave",
            if n == 1 { "" } else { "s" }
        ));
        false
    }

    /// The command list and the picker follow what is typed. A request takes the panel, so a
    /// picker still open when one arrives is dropped.
    fn sync_palette(&mut self) {
        if !self.session.waiting().is_empty() {
            self.view.picker = None;
        }
        let text = self.composer.text.clone();
        if self.dismissed.as_deref() != Some(text.as_str()) {
            self.dismissed = None;
        }
        if self.held.as_deref() != Some(text.as_str()) {
            self.held = None;
        }
        if text != self.palette_text {
            self.view.palette_sel = 0;
            self.palette_text.clone_from(&text);
        }
        let open = text.starts_with('/')
            && self.session.waiting().is_empty()
            && self.view.picker.is_none()
            && self.view.focus.is_none()
            && self.dismissed.is_none();
        self.view.palette = if open {
            slash::entries(
                &text,
                self.transcript.commands(),
                &self.transcript,
                self.fresh_ok,
            )
        } else {
            Vec::new()
        };
        if let Some(last) = self.view.palette.len().checked_sub(1) {
            self.view.palette_sel = self.view.palette_sel.min(last);
        }
        let pictures = self.session.accepts_pictures();
        self.view.chips = self.files.iter().map(|f| f.label(pictures)).collect();
    }

    /// Whether `/new` can start another session of this one's kind: the agent and the folder are
    /// known and still there, and there is a home to keep the session in.
    fn can_fresh(&self) -> bool {
        !self.agent_id.is_empty()
            && !self.cwd.is_empty()
            && std::path::Path::new(&self.cwd).is_dir()
            && keeper::routes::by_id(&self.agent_id).is_some()
            && !self.home.as_os_str().is_empty()
    }

    /// Keys for the picker of `/model` and the like. Ctrl and Alt chords go on to the usual
    /// handling (Ctrl-C still stops a turn).
    fn picker_key(&mut self, k: KeyEvent) -> bool {
        if self.view.picker.is_none()
            || k.modifiers
                .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        {
            return false;
        }
        match k.code {
            KeyCode::Up => {
                if let Some(p) = self.view.picker.as_mut() {
                    p.up();
                }
            }
            KeyCode::Down => {
                if let Some(p) = self.view.picker.as_mut() {
                    p.down();
                }
            }
            KeyCode::Esc => self.view.picker = None,
            KeyCode::Enter => {
                // A mode that lowers the guard is chosen twice: the first Enter says what it does.
                let chosen = self
                    .view
                    .picker
                    .as_ref()
                    .filter(|p| p.kind == slash::PickerKind::Choices)
                    .and_then(|p| p.chosen().cloned().map(|c| (p.option_id.clone(), c)));
                if let Some((id, (value, name))) = chosen {
                    if self.needs_mode_confirm(&id, &value, &name) {
                        return true;
                    }
                }
                if let Some(p) = self.view.picker.take() {
                    if let Some((value, name)) = p.chosen().cloned() {
                        match p.kind {
                            // The list of settings: on to the choices of the one chosen.
                            slash::PickerKind::Settings => {
                                let next = self
                                    .transcript
                                    .options()
                                    .iter()
                                    .find(|o| o.id == value)
                                    .map(|o| slash::pick(o, ""));
                                if let Some(slash::Pick::Open(next)) = next {
                                    self.view.picker = Some(next);
                                }
                            }
                            // The list of attached files: the one chosen comes off.
                            slash::PickerKind::Files => {
                                if let Some(i) = value
                                    .parse::<usize>()
                                    .ok()
                                    .filter(|i| *i < self.files.len())
                                {
                                    let f = self.take_file(i);
                                    self.hint = Some(format!("Took off {}", f.short()));
                                }
                            }
                            slash::PickerKind::Choices => {
                                self.apply_choice(&p.option_id, &p.title, &value, &name);
                            }
                        }
                    }
                }
            }
            KeyCode::PageUp | KeyCode::PageDown | KeyCode::Home | KeyCode::End => return false,
            // Nothing typed here would land anywhere visible.
            _ => {}
        }
        true
    }

    /// Keys for the command list while a `/` is typed. Anything else is typing.
    fn palette_key(&mut self, k: KeyEvent) -> bool {
        if self.view.palette.is_empty()
            || k.modifiers
                .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        {
            return false;
        }
        match k.code {
            KeyCode::Up => self.view.palette_sel = self.view.palette_sel.saturating_sub(1),
            KeyCode::Down => {
                self.view.palette_sel =
                    (self.view.palette_sel + 1).min(self.view.palette.len() - 1);
            }
            KeyCode::Tab => self.complete(),
            KeyCode::Esc => self.dismissed = Some(self.composer.text.clone()),
            KeyCode::Enter if !k.modifiers.contains(KeyModifiers::SHIFT) => self.run_entry(),
            _ => return false,
        }
        true
    }

    /// Puts the chosen command's name in the box, with a space for what it takes.
    fn complete(&mut self) {
        let Some(e) = self.view.palette.get(self.view.palette_sel) else {
            return;
        };
        let line = format!("/{} ", e.name);
        self.composer.clear();
        self.composer.insert_str(&line);
    }

    /// Enter on the chosen row: a command of this program runs; one of the agent's that takes
    /// something waits for it; the rest are sent.
    fn run_entry(&mut self) {
        let Some(e) = self.view.palette.get(self.view.palette_sel).cloned() else {
            return;
        };
        if let Some(why) = &e.reason {
            self.hint = Some(format!("/{} is unavailable: {why}", e.name));
            return;
        }
        let line = format!("/{}", e.name);
        match e.kind {
            // Replaces the program file: asked for twice (the name, then Enter), never by a
            // stray Enter on the list.
            slash::Kind::Local(slash::Local::Update) => self.complete(),
            slash::Kind::Local(local) => {
                self.composer.clear();
                self.composer.insert_str(&line);
                self.composer.take();
                self.run_local(local, "");
            }
            slash::Kind::Agent | slash::Kind::Skill if e.hint.is_some() => self.complete(),
            slash::Kind::Agent | slash::Kind::Skill => {
                self.composer.clear();
                self.composer.insert_str(&line);
                self.send();
            }
        }
    }

    /// Carries out a command of this program. None of them is sent to the agent.
    fn run_local(&mut self, local: slash::Local, args: &str) {
        if !self.session.waiting().is_empty() {
            self.hint = Some("Answer the request first".to_string());
            return;
        }
        if let Some(why) = slash::unavailable(&self.transcript, local, self.can_fresh()) {
            self.hint = Some(format!("Unavailable: {why}"));
            return;
        }
        match local {
            slash::Local::Fresh => {
                if !self.files.is_empty() {
                    self.hint = Some("Send the files or take them off (/files) first".to_string());
                    return;
                }
                if !self.queue.is_empty() {
                    self.hint = Some(
                        "Queued messages would be lost: send or take them back (Backspace) first"
                            .to_string(),
                    );
                    return;
                }
                self.fresh = true;
                self.quit = true;
                return;
            }
            slash::Local::Files => {
                if self.files.is_empty() {
                    self.hint = Some("Nothing is attached".to_string());
                } else {
                    let pictures = self.session.accepts_pictures();
                    let labels: Vec<String> =
                        self.files.iter().map(|f| f.label(pictures)).collect();
                    self.view.picker = Some(slash::attached(&labels));
                }
                return;
            }
            slash::Local::Update => {
                self.start_update(args);
                return;
            }
            slash::Local::Info => {
                self.info();
                return;
            }
            slash::Local::Settings => {
                self.view.picker = slash::settings(&self.transcript);
                return;
            }
            slash::Local::Plan => {
                self.plan();
                return;
            }
            slash::Local::Model | slash::Local::Thinking | slash::Local::Mode => {}
        }
        let Some(opt) = slash::option_of(&self.transcript, local) else {
            return;
        };
        let (id, what) = (opt.id.clone(), opt.name.clone());
        match slash::pick(opt, args) {
            slash::Pick::Open(p) => self.view.picker = Some(p),
            slash::Pick::Apply { value, name } => {
                let current = opt.current.clone();
                // A mode that lowers the guard is confirmed by choosing it again, and retyping the
                // command clears that (any key but Enter does): the list opens on it instead, so
                // Enter confirms.
                let risky = opt.is("mode")
                    && current.as_deref() != Some(value.as_str())
                    && risk::assess(&value, &name) != risk::Risk::None;
                if risky {
                    if let slash::Pick::Open(mut p) = slash::pick(opt, "") {
                        p.sel = p.rows.iter().position(|r| r.0 == value).unwrap_or(p.sel);
                        self.hint = Some(format!(
                            "{name} {} · choose it again to confirm",
                            risk::why(risk::assess(&value, &name))
                        ));
                        self.mode_confirm = Some(value);
                        self.view.picker = Some(p);
                        return;
                    }
                }
                self.apply_choice(&id, &what, &value, &name);
            }
            slash::Pick::Nothing(why) => self.hint = Some(why),
        }
    }

    /// `/update [check|VERSION]`: installs a release (or only says whether that would change
    /// anything) on a thread of its own, so the session stays alive while it downloads. The
    /// program file is replaced whole (a rename) and checked first; a copy that is open keeps
    /// running its old file until `Ctrl-R` loads the new one.
    fn start_update(&mut self, args: &str) {
        if self.updating {
            self.hint = Some("An update is already running".to_string());
            return;
        }
        let request = match update::request(args) {
            Ok(r) => r,
            Err(usage) => {
                self.hint = Some(usage);
                return;
            }
        };
        let (version, action) = match &request {
            update::Request::Latest => (None, update::Action::Install),
            update::Request::Check => (None, update::Action::Check),
            update::Request::Version(v) => (Some(v.clone()), update::Action::Install),
        };
        let target = if version.is_some() {
            update::Target::Pinned
        } else {
            update::Target::Latest
        };
        let base = update::base_url(|k| std::env::var(k).ok(), version.as_deref());
        let exe = self.watch.path().to_path_buf();
        let tx = self.tx.clone();
        self.updating = true;
        self.view.update = Some("starting".to_string());
        std::thread::spawn(move || {
            // No signal reaches this flag: the session ends the whole process itself.
            let cancel = std::sync::atomic::AtomicBool::new(false);
            let plan = update::Plan {
                base: &base,
                target,
                action,
                cancel: &cancel,
            };
            let result = update::run(&exe, cli::VERSION, &plan, &mut |e| {
                let line = match e {
                    update::Event::Step(s) => s.to_string(),
                    update::Event::Bytes {
                        label,
                        done,
                        total,
                        per_sec,
                    } => {
                        // The footer shows it after "↻ updating · ", so leave room for that.
                        let width = terminal::size().map_or(80, |(w, _)| usize::from(w));
                        update::progress_line(label, done, total, per_sec, width.saturating_sub(16))
                    }
                    update::Event::Finished => return,
                };
                let _ = tx.send(Ev::Update(UpdateMsg::Progress(line)));
            });
            let _ = tx.send(Ev::Update(UpdateMsg::Done(result)));
        });
    }

    /// The update ended: say what it did in the conversation, and, when it put a new file in
    /// place, that `Ctrl-R` loads it.
    fn update_done(&mut self, result: Result<String, String>) {
        self.updating = false;
        self.view.update = None;
        self.view.scroll = 0;
        match result {
            Ok(said) => {
                self.transcript.note(said);
                self.refresh_newer();
                if let Some(v) = &self.newer {
                    self.transcript
                        .note(format!("herdr-tui {v} is installed · Ctrl-R loads it"));
                }
            }
            Err(why) => self.transcript.note(format!("Update failed: {why}")),
        }
    }

    /// `/plan`: into plan mode, or back out of it to the mode it left.
    fn plan(&mut self) {
        let Some(opt) = self.transcript.option("mode") else {
            return;
        };
        let (id, what, current) = (opt.id.clone(), opt.name.clone(), opt.current.clone());
        match slash::plan_move(opt, self.before_plan.as_deref()) {
            Ok(m) => {
                if m.entering {
                    self.before_plan = current;
                }
                if !m.entering {
                    // Back to the mode that was left: it was the person's own choice.
                    self.mode_confirm = Some(m.value.clone());
                }
                self.apply_choice(&id, &what, &m.value, &m.name);
            }
            Err(why) => self.hint = Some(format!("Unavailable: {why}")),
        }
    }

    /// Shift-Tab: the next mode.
    fn cycle_mode(&mut self) {
        if let Some(why) = slash::unavailable(&self.transcript, slash::Local::Mode, false) {
            self.hint = Some(format!("Unavailable: {why}"));
            return;
        }
        let Some(opt) = self.transcript.option("mode") else {
            return;
        };
        let (id, what) = (opt.id.clone(), opt.name.clone());
        match slash::next_choice(opt) {
            Some((value, name)) => self.apply_choice(&id, &what, &value, &name),
            None => {
                self.hint = Some("No other mode without a guard · /mode picks one".to_string());
            }
        }
    }

    /// `/info`: which herdr-tui this is, and which session it shows, as notes in the conversation.
    fn info(&mut self) {
        self.transcript.note(format!(
            "herdr-tui {} · {} · session {}",
            cli::VERSION,
            self.agent,
            self.id
        ));
        self.transcript.note(format!("folder {}", self.cwd));
        self.transcript
            .note(format!("program {}", self.watch.path().display()));
        self.transcript
            .note(format!("reopen with: herdr-tui attach {}", self.id));
        if let Some(v) = &self.newer {
            self.transcript
                .note(format!("herdr-tui {v} is installed · Ctrl-R loads it"));
        }
        self.view.scroll = 0;
    }

    /// A paste that is only paths to files that exist: attaches them, and says so. `false` when
    /// it is anything else (it is then text).
    fn attach_paste(&mut self, text: &str) -> bool {
        let Some(paths) = attach::paths_in(text, &self.home.to_string_lossy()) else {
            return false;
        };
        self.attach_paths(&paths)
    }

    /// Reads the picture on the clipboard on a thread (a tool that hangs must not hold the
    /// screen), saves it in the host inbox (`~/.herdr-mobile/inbox/tui-<session>/`, owner-only)
    /// and attaches it, as a pasted path would be.
    fn paste_picture(&mut self) {
        if self.clipping {
            return;
        }
        self.clipping = true;
        self.hint = Some("Reading the clipboard…".to_string());
        let dir = self
            .home
            .join(".herdr-mobile/inbox")
            .join(format!("tui-{}", self.id));
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = clip::read(&clip::tools(), &dir).map_err(|n| n.say());
            let _ = tx.send(Ev::Clip(result));
        });
    }

    /// Attaches these paths (absolute, as pasted): `false` when one is not a file that exists (the
    /// caller then treats the paste as text).
    fn attach_paths(&mut self, paths: &[String]) -> bool {
        // A long list is no list of files to attach, and nothing on the disk is looked at for it.
        if paths.len() > attach::MAX_FILES {
            self.hint = Some(format!(
                "At most {} files go with a message",
                attach::MAX_FILES
            ));
            return true;
        }
        let pictures = self.session.accepts_pictures();
        let mut picture_bytes: u64 = self
            .files
            .iter()
            .filter(|f| f.is_picture(pictures))
            .map(|f| f.size)
            .sum();
        let mut found: Vec<attach::Attachment> = Vec::new();
        let mut twice = 0;
        for p in paths {
            let Ok(abs) = std::fs::canonicalize(p) else {
                return false;
            };
            let Some(abs) = abs.to_str().filter(|_| abs.is_file()) else {
                return false;
            };
            let mut a = attach::attachment(abs, &self.cwd);
            a.size = std::fs::metadata(abs).map_or(0, |m| m.len());
            if self.files.iter().chain(&found).any(|f| f.uri == a.uri) {
                twice += 1;
                continue;
            }
            if a.is_picture(pictures) {
                if picture_bytes + a.size > attach::MAX_PICTURES_TOTAL {
                    a.link = true;
                } else {
                    picture_bytes += a.size;
                }
            }
            found.push(a);
        }
        let room = attach::MAX_FILES.saturating_sub(self.files.len());
        let left_out = found.len().saturating_sub(room);
        found.truncate(room);
        self.hint = Some(match found.as_slice() {
            [] if left_out > 0 => format!("At most {} files go with a message", attach::MAX_FILES),
            [] if twice > 0 => "Already attached".to_string(),
            [] => return true,
            _ if left_out > 0 => format!(
                "Attached {} of {} files · at most {} go with a message",
                found.len(),
                found.len() + left_out,
                attach::MAX_FILES
            ),
            [one] => {
                let how = if one.is_picture(pictures) {
                    " as a picture"
                } else if one.picture.is_some() && !pictures {
                    " as a link (this agent takes no pictures)"
                } else if one.link {
                    " as a link (this message's pictures are over 20 MB)"
                } else if one.picture.is_some() {
                    " as a link (over 5 MB)"
                } else {
                    ""
                };
                format!(
                    "Attached {}{how} · Backspace takes it off · /files picks",
                    one.short()
                )
            }
            many => format!(
                "Attached {} files · Backspace takes the last off · /files picks",
                many.len()
            ),
        });
        // A numbered picture leaves its placeholder in the text, at the cursor, for the person
        // to point at it: "the button in [Image #2] is wrong".
        for a in &mut found {
            if a.picture.is_some() {
                self.next_picture += 1;
                a.number = self.next_picture;
                self.composer
                    .insert_str(&format!("{} ", attach::placeholder(a.number)));
            }
        }
        self.files.extend(found);
        true
    }

    /// Takes file `i` off, and its placeholders out of the text; numbering starts again when
    /// none is left.
    fn take_file(&mut self, i: usize) -> attach::Attachment {
        let f = self.files.remove(i);
        if f.number > 0 {
            for (a, b) in attach::spans_of(&self.composer.text.clone(), f.number) {
                self.composer.delete_range(a, b);
            }
        }
        if self.files.is_empty() {
            self.next_picture = 0;
        }
        f
    }

    fn take_all_files(&mut self) {
        while !self.files.is_empty() {
            self.take_file(0);
        }
        self.hint = Some("Took the files off".to_string());
    }

    /// Backspace right after a placeholder (or the space after it): the placeholder goes whole,
    /// and the picture it stands for with it. `false` when the cursor is not after one.
    fn take_placeholder(&mut self) -> bool {
        let Some((start, end, n)) = attach::token_before(&self.composer.text, self.composer.cursor)
        else {
            return false;
        };
        self.composer.delete_range(start, end);
        if let Some(i) = self.files.iter().position(|f| f.number == n) {
            let f = self.take_file(i);
            self.hint = Some(format!("Took off {}", f.short()));
        }
        true
    }

    /// Reads the files that go as pictures into the prompt (see [`load_files`]).
    fn load_pictures(&mut self) -> Result<(), String> {
        load_files(&mut self.files, self.session.accepts_pictures())
    }

    /// A mode that lowers the guard (`risk::assess`, the phone's rules) is chosen on purpose: the
    /// first choice says what it does and waits for the same choice again. `true` while it waits.
    fn needs_mode_confirm(&mut self, id: &str, value: &str, name: &str) -> bool {
        if !self.transcript.option(id).is_some_and(|o| o.is("mode")) {
            return false;
        }
        let risk = risk::assess(value, name);
        if risk == risk::Risk::None || self.mode_confirm.as_deref() == Some(value) {
            return false;
        }
        self.mode_confirm = Some(value.to_string());
        self.hint = Some(format!(
            "{name} {} · choose it again to confirm",
            risk::why(risk)
        ));
        true
    }

    /// Asks the agent to change option `id` to `value`. Choosing what is already chosen sends
    /// nothing.
    fn apply_choice(&mut self, id: &str, what: &str, value: &str, name: &str) {
        if self
            .transcript
            .option(id)
            .and_then(|o| o.current.as_deref())
            == Some(value)
        {
            self.hint = Some(format!("{what} is already {name}"));
            return;
        }
        if self.needs_mode_confirm(id, value, name) {
            return;
        }
        self.mode_confirm = None;
        match self
            .session
            .set_config(id, value, what, name, &self.transcript)
        {
            Ok(fx) => {
                self.view.scroll = 0;
                self.run(fx);
            }
            Err(Refused::NotReady) => self.hint = Some("The session is not open yet".to_string()),
            Err(Refused::Busy) => {
                self.hint = Some("The agent is working; change it when the turn ends".to_string());
            }
            Err(_) => {}
        }
    }
}

/// Reads the files that go as pictures into the prompt. A picture that has grown past the
/// limit since it was pasted goes as a link instead.
fn load_files(files: &mut [attach::Attachment], takes: bool) -> Result<(), String> {
    for f in files {
        if f.is_picture(takes) && f.data.is_none() {
            match attach::read_picture(&f.path) {
                Ok(Some(bytes)) => f.data = Some(attach::base64(&bytes)),
                // No longer a regular file, or grown past the limit: it goes as a link.
                Ok(None) => f.link = true,
                Err(e) => return Err(format!("Could not read {}: {e}", f.short())),
            }
        }
    }
    Ok(())
}
