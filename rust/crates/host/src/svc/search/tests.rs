use super::*;
use std::cell::{Cell, RefCell};
use std::os::unix::fs::{symlink, PermissionsExt};
use std::time::SystemTime;

fn args(root: &Path) -> SearchArgs {
    SearchArgs {
        root: root.to_string_lossy().into_owned(),
        query: None,
        kind: KindFilter::Any,
        modified_within_s: None,
        max_results: None,
        max_depth: None,
        hidden: false,
        ignore: None,
    }
}

struct Run {
    batches: Vec<Vec<Value>>,
    summary: Result<Summary, WireError>,
}

impl Run {
    fn entries(&self) -> Vec<&Value> {
        self.batches.iter().flatten().collect()
    }

    fn names(&self) -> Vec<String> {
        self.entries()
            .iter()
            .map(|e| e["name"].as_str().expect("name").to_string())
            .collect()
    }

    fn summary(&self) -> &Summary {
        self.summary.as_ref().expect("the walk ends well")
    }
}

/// Runs a walk with a clock that advances `tick` per look, never cancelled.
fn run_with(a: &SearchArgs, now_ms: i64, tick: Duration, tweak: impl FnOnce(&mut Options)) -> Run {
    let mut opts = Options::from_args(a, now_ms);
    tweak(&mut opts);
    let at = Cell::new(Duration::ZERO);
    let mut batches = Vec::new();
    let summary = walk(
        Path::new(&a.root),
        &a.root,
        &opts,
        &mut || {
            at.set(at.get() + tick);
            at.get()
        },
        &|| false,
        &mut |b| {
            batches.push(b);
            Ok(())
        },
    );
    Run { batches, summary }
}

fn run(a: &SearchArgs) -> Run {
    run_with(a, 0, Duration::ZERO, |_| {})
}

fn touch(path: &Path) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("dirs");
    }
    fs::write(path, b"x").expect("file");
}

fn set_mtime(path: &Path, at: SystemTime) {
    fs::File::options()
        .write(true)
        .open(path)
        .expect("open")
        .set_modified(at)
        .expect("mtime");
}

fn now_ms() -> i64 {
    i64::try_from(
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("after the epoch")
            .as_millis(),
    )
    .expect("fits")
}

#[test]
fn matching_is_a_case_insensitive_part_of_the_name_not_the_path() {
    let dir = tempfile::tempdir().expect("tempdir");
    touch(&dir.path().join("README.md"));
    touch(&dir.path().join("notes/readme.txt"));
    touch(&dir.path().join("readme-dir/other.txt"));
    touch(&dir.path().join("src/ReadMe"));
    touch(&dir.path().join("src/main.rs"));
    let mut a = args(dir.path());
    a.query = Some("ReAdMe".into());
    let r = run(&a);
    let mut names = r.names();
    names.sort();
    assert_eq!(names, ["README.md", "ReadMe", "readme-dir", "readme.txt"]);
    assert!(!r.summary().truncated);

    // The path above the root never matches: only names do.
    let mut a = args(&dir.path().join("src"));
    a.query = Some("tmp".into());
    assert!(run(&a).names().is_empty());

    // Empty and absent queries match everything.
    for q in [None, Some(String::new())] {
        let mut a = args(dir.path());
        a.query = q;
        assert_eq!(run(&a).names().len(), 8);
    }
}

#[test]
fn non_ascii_names_are_matched_without_regard_to_case() {
    let dir = tempfile::tempdir().expect("tempdir");
    touch(&dir.path().join("Über-Cafe.txt"));
    touch(&dir.path().join("plain.txt"));
    let mut a = args(dir.path());
    a.query = Some("ÜBER".into());
    assert_eq!(run(&a).names(), ["Über-Cafe.txt"]);
    a.query = Some("über".into());
    assert_eq!(run(&a).names(), ["Über-Cafe.txt"]);
}

#[test]
fn kind_keeps_files_or_folders() {
    let dir = tempfile::tempdir().expect("tempdir");
    touch(&dir.path().join("a-file"));
    fs::create_dir(dir.path().join("a-dir")).expect("dir");
    symlink(dir.path().join("a-dir"), dir.path().join("a-link")).expect("link");
    let mut a = args(dir.path());
    a.kind = KindFilter::File;
    assert_eq!(run(&a).names(), ["a-file"]);
    a.kind = KindFilter::Dir;
    assert_eq!(run(&a).names(), ["a-dir"]);
    a.kind = KindFilter::Any;
    let r = run(&a);
    let kinds: std::collections::BTreeMap<String, String> = r
        .entries()
        .iter()
        .map(|e| {
            (
                e["name"].as_str().expect("name").to_string(),
                e["kind"].as_str().expect("kind").to_string(),
            )
        })
        .collect();
    assert_eq!(kinds["a-link"], "link");
    assert_eq!(kinds["a-dir"], "dir");
    assert_eq!(kinds["a-file"], "file");
}

#[test]
fn shallow_matches_come_before_deep_ones() {
    let dir = tempfile::tempdir().expect("tempdir");
    touch(&dir.path().join("a/b/c/d/hit-4"));
    touch(&dir.path().join("a/b/c/hit-3"));
    touch(&dir.path().join("a/b/hit-2"));
    touch(&dir.path().join("a/hit-1"));
    touch(&dir.path().join("hit-0"));
    touch(&dir.path().join("z/hit-1b"));
    let mut a = args(dir.path());
    a.query = Some("hit".into());
    let names = run(&a).names();
    assert_eq!(names.len(), 6);
    let depth = |n: &str| -> usize {
        match n {
            "hit-0" => 0,
            "hit-1" | "hit-1b" => 1,
            "hit-2" => 2,
            "hit-3" => 3,
            _ => 4,
        }
    };
    let depths: Vec<usize> = names.iter().map(|n| depth(n)).collect();
    let mut sorted = depths.clone();
    sorted.sort_unstable();
    assert_eq!(depths, sorted, "{names:?}");
}

#[test]
fn the_ignore_list_skips_folders_and_does_not_report_them() {
    let dir = tempfile::tempdir().expect("tempdir");
    touch(&dir.path().join("node_modules/pkg/index.js"));
    touch(&dir.path().join("src/node_modules/deep/x.js"));
    touch(&dir.path().join("src/target/debug/out"));
    touch(&dir.path().join("src/lib.rs"));
    touch(&dir.path().join("build"));
    touch(&dir.path().join("keep/index.js"));
    let all = |a: &SearchArgs| {
        let mut n = run(a).names();
        n.sort();
        n
    };
    // Defaults: the folders go, a plain FILE called `build` stays.
    assert_eq!(
        all(&args(dir.path())),
        ["build", "index.js", "keep", "lib.rs", "src"]
    );
    // An explicit list replaces the defaults.
    let mut a = args(dir.path());
    a.ignore = Some(vec!["src".into()]);
    assert!(!all(&a).contains(&"lib.rs".to_string()));
    assert!(all(&a).contains(&"node_modules".to_string()));
    // [] searches everything.
    let mut a = args(dir.path());
    a.ignore = Some(vec![]);
    let n = all(&a);
    assert!(n.contains(&"node_modules".to_string()) && n.contains(&"debug".to_string()));
    // The root itself is never ignored, whatever its name.
    let mut a = args(&dir.path().join("node_modules"));
    a.query = Some("index".into());
    assert_eq!(run(&a).names(), ["index.js"]);
}

#[test]
fn hidden_names_are_skipped_unless_asked_for_and_never_descended() {
    let dir = tempfile::tempdir().expect("tempdir");
    touch(&dir.path().join(".secret/inside.txt"));
    touch(&dir.path().join(".dotfile"));
    touch(&dir.path().join("shown.txt"));
    let mut a = args(dir.path());
    assert_eq!(run(&a).names(), ["shown.txt"]);
    a.hidden = true;
    let mut n = run(&a).names();
    n.sort();
    assert_eq!(n, [".dotfile", ".secret", "inside.txt", "shown.txt"]);
}

#[test]
fn a_symlink_loop_terminates_and_is_reported_as_a_link() {
    let dir = tempfile::tempdir().expect("tempdir");
    fs::create_dir(dir.path().join("real")).expect("dir");
    touch(&dir.path().join("real/file"));
    symlink(dir.path(), dir.path().join("real/up")).expect("loop up");
    symlink(dir.path().join("real"), dir.path().join("again")).expect("again");
    symlink(dir.path().join("nowhere"), dir.path().join("dangling")).expect("dangling");
    let r = run(&args(dir.path()));
    let s = r.summary();
    assert_eq!(s.scanned, 5, "real, file, up, again, dangling: each once");
    let links: Vec<_> = r
        .entries()
        .into_iter()
        .filter(|e| e["kind"] == "link")
        .map(|e| e["name"].as_str().expect("name").to_string())
        .collect();
    assert_eq!(links.len(), 3, "{links:?}");
}

#[test]
fn max_depth_stops_the_descent() {
    let dir = tempfile::tempdir().expect("tempdir");
    touch(&dir.path().join("one"));
    touch(&dir.path().join("a/two"));
    touch(&dir.path().join("a/b/three"));
    let mut a = args(dir.path());
    a.max_depth = Some(1);
    let mut n = run(&a).names();
    n.sort();
    assert_eq!(n, ["a", "one"], "only the entries of the root");
    a.max_depth = Some(2);
    let mut n = run(&a).names();
    n.sort();
    assert_eq!(n, ["a", "b", "one", "two"]);
    a.max_depth = Some(0);
    assert_eq!(run(&a).names().len(), 2, "0 is read as 1");
    a.max_depth = Some(1000);
    assert_eq!(run(&a).names().len(), 5, "capped, not refused");
    assert_eq!(Options::from_args(&a, 0).max_depth, 32);
}

#[test]
fn modified_within_keeps_only_recent_entries() {
    let dir = tempfile::tempdir().expect("tempdir");
    let now = SystemTime::now();
    for (name, age_s) in [("fresh", 10u64), ("hour", 3600), ("week", 7 * 86400)] {
        let p = dir.path().join(name);
        touch(&p);
        set_mtime(&p, now - Duration::from_secs(age_s));
    }
    let mut a = args(dir.path());
    a.modified_within_s = Some(600);
    let t = now_ms();
    let r = run_with(&a, t, Duration::ZERO, |_| {});
    assert_eq!(r.names(), ["fresh"]);
    a.modified_within_s = Some(2 * 3600);
    let mut n = run_with(&a, t, Duration::ZERO, |_| {}).names();
    n.sort();
    assert_eq!(n, ["fresh", "hour"]);
    // With a name filter on top.
    a.query = Some("ho".into());
    assert_eq!(run_with(&a, t, Duration::ZERO, |_| {}).names(), ["hour"]);
    a.modified_within_s = None;
    a.query = None;
    assert_eq!(run(&a).names().len(), 3);
}

#[test]
fn entries_carry_path_name_kind_size_and_time() {
    let dir = tempfile::tempdir().expect("tempdir");
    fs::write(dir.path().join("f.txt"), b"12345").expect("file");
    let r = run(&args(dir.path()));
    let e = r.entries()[0].clone();
    assert_eq!(e["name"], "f.txt");
    assert_eq!(e["kind"], "file");
    assert_eq!(e["size"], 5);
    assert_eq!(
        e["path"],
        dir.path().join("f.txt").to_string_lossy().as_ref()
    );
    assert!(e["mtime_ms"].as_i64().expect("mtime") > 1_000_000_000_000);
}

#[test]
fn max_results_stops_the_walk_and_says_truncated() {
    let dir = tempfile::tempdir().expect("tempdir");
    for i in 0..50 {
        touch(&dir.path().join(format!("f{i:02}")));
    }
    let mut a = args(dir.path());
    a.max_results = Some(7);
    let r = run(&a);
    assert_eq!(r.entries().len(), 7);
    assert!(r.summary().truncated);
    a.max_results = Some(50);
    let r = run(&a);
    assert_eq!(r.entries().len(), 50);
    a.max_results = Some(51);
    let r = run(&a);
    assert!(!r.summary().truncated, "more room than results");
    assert_eq!(Options::from_args(&args(dir.path()), 0).max_results, 500);
    a.max_results = Some(10_000);
    assert_eq!(Options::from_args(&a, 0).max_results, 2000);
}

#[test]
fn the_scan_cap_and_the_wall_clock_truncate_too() {
    let dir = tempfile::tempdir().expect("tempdir");
    for i in 0..40 {
        touch(&dir.path().join(format!("f{i:02}")));
    }
    let a = args(dir.path());
    let r = run_with(&a, 0, Duration::ZERO, |o| o.scan_cap = 10);
    let s = r.summary();
    assert_eq!((s.scanned, s.truncated), (10, true));
    assert_eq!(
        r.entries().len(),
        10,
        "what was found before the cap is kept"
    );

    let r = run_with(&a, 0, Duration::from_secs(1), |o| {
        o.wall_cap = Duration::from_secs(5);
    });
    assert!(r.summary().truncated);
    assert!(r.entries().len() < 40);
}

#[test]
fn the_first_entry_leaves_at_once_then_batches_of_100_or_every_150_ms() {
    let dir = tempfile::tempdir().expect("tempdir");
    for i in 0..250 {
        touch(&dir.path().join(format!("f{i:03}")));
    }
    // Time stands still: batches go out only when full, apart from the first
    // entry, which leaves alone.
    let r = run(&args(dir.path()));
    let sizes: Vec<usize> = r.batches.iter().map(Vec::len).collect();
    assert_eq!(sizes, [1, 100, 100, 49]);

    // 50 ms a look: the clock is read once per entry, so a batch is due every
    // third entry after the first one.
    let r = run_with(&args(dir.path()), 0, Duration::from_millis(50), |_| {});
    let sizes: Vec<usize> = r.batches.iter().map(Vec::len).collect();
    assert_eq!(sizes[0], 1);
    assert!(sizes.len() > 4, "{sizes:?}");
    assert!(sizes.iter().all(|&n| (1..=BATCH).contains(&n)), "{sizes:?}");
    assert_eq!(sizes.iter().sum::<usize>(), 250);
    // Never an empty batch.
    assert!(r.batches.iter().all(|b| !b.is_empty()));
}

#[test]
fn nothing_found_sends_no_batch_at_all() {
    let dir = tempfile::tempdir().expect("tempdir");
    touch(&dir.path().join("a"));
    let mut a = args(dir.path());
    a.query = Some("zzz".into());
    let r = run(&a);
    assert!(r.batches.is_empty());
    assert_eq!(r.summary().scanned, 1);
}

#[test]
fn the_root_must_be_a_folder_that_can_be_read() {
    let dir = tempfile::tempdir().expect("tempdir");
    touch(&dir.path().join("file"));
    let code = |root: &Path| run(&args(root)).summary.expect_err("an error").code;
    assert_eq!(code(&dir.path().join("missing")), ErrorCode::NotFound);
    assert_eq!(code(&dir.path().join("file")), ErrorCode::NotADirectory);
    if !rustix::process::geteuid().is_root() {
        let locked = dir.path().join("locked");
        fs::create_dir(&locked).expect("dir");
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).expect("chmod");
        let c = code(&locked);
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).expect("restore");
        assert_eq!(c, ErrorCode::Permission);
    }
    // A link to a folder is a fine root.
    symlink(dir.path(), dir.path().join("via")).expect("link");
    let r = run(&args(&dir.path().join("via")));
    assert!(r.names().contains(&"file".to_string()));
}

#[test]
fn an_unreadable_subfolder_is_skipped_and_counted() {
    if rustix::process::geteuid().is_root() {
        return;
    }
    let dir = tempfile::tempdir().expect("tempdir");
    touch(&dir.path().join("open/file"));
    touch(&dir.path().join("locked/file"));
    let locked = dir.path().join("locked");
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).expect("chmod");
    let r = run(&args(dir.path()));
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).expect("restore");
    let s = r.summary();
    assert_eq!(s.skipped_dirs, 1);
    let mut n = r.names();
    n.sort();
    assert_eq!(n, ["file", "locked", "open"]);
}

#[test]
fn cancel_stops_the_walk_between_folders_and_within_a_big_one() {
    let dir = tempfile::tempdir().expect("tempdir");
    for i in 0..600 {
        touch(&dir.path().join(format!("f{i:03}")));
    }
    for d in 0..5 {
        touch(&dir.path().join(format!("d{d}/x")));
    }
    let mut a = args(dir.path());
    a.max_results = Some(2000);
    let opts = Options::from_args(&a, 0);

    // Already cancelled: no work, an error.
    let r = walk(
        dir.path(),
        "~",
        &opts,
        &mut || Duration::ZERO,
        &|| true,
        &mut |_| Ok(()),
    );
    assert_eq!(r.expect_err("cancelled").code, ErrorCode::Cancelled);

    // Cancelled while the 605 entries of one folder are read: it stops there,
    // not after them.
    let looks = Cell::new(0u32);
    let seen = RefCell::new(0usize);
    let r = walk(
        dir.path(),
        "~",
        &opts,
        &mut || Duration::ZERO,
        &|| {
            looks.set(looks.get() + 1);
            looks.get() > 2
        },
        &mut |b| {
            *seen.borrow_mut() += b.len();
            Ok(())
        },
    );
    assert_eq!(r.expect_err("cancelled").code, ErrorCode::Cancelled);
    assert!(*seen.borrow() < 605);
}

#[test]
fn a_sink_that_fails_ends_the_walk_with_its_error() {
    let dir = tempfile::tempdir().expect("tempdir");
    touch(&dir.path().join("a"));
    let a = args(dir.path());
    let opts = Options::from_args(&a, 0);
    let r = walk(
        dir.path(),
        "~",
        &opts,
        &mut || Duration::ZERO,
        &|| false,
        &mut |_| Err(WireError::new(ErrorCode::Stalled, "gone")),
    );
    assert_eq!(r.expect_err("sink").code, ErrorCode::Stalled);
}

#[test]
fn the_defaults_are_the_ones_in_the_contract() {
    let o = Options::from_args(&args(Path::new("/")), 0);
    assert_eq!((o.max_results, o.max_depth, o.hidden), (500, 12, false));
    assert_eq!(
        o.ignore,
        [
            ".git",
            "node_modules",
            "target",
            ".cache",
            "__pycache__",
            ".venv",
            "build"
        ]
    );
    assert_eq!((o.scan_cap, o.wall_cap), (200_000, Duration::from_secs(20)));
    let a: SearchArgs = serde_json::from_str(r#"{"root":"~","kind":"dir"}"#).expect("parse");
    assert_eq!(a.kind, KindFilter::Dir);
    assert!(serde_json::from_str::<SearchArgs>(r#"{"root":"~","kind":"nope"}"#).is_err());
}
