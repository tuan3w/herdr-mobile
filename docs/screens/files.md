# Files

The file browser and viewer.

The design system (tokens, kit, motion, words) is `docs/DESIGN.md`; this file holds what this screen does and why.


The question while supervising an agent is "what did it just touch?", so the
browser is built to be reached fast, scanned and not lost in.

- **Reached at once.** `openFileBrowser`, `openRemoteFile` and
  `pickRemoteDirectory` push the screen on the same frame and ask the host
  inside it: the browser works out its start folder (`FileBrowserViewModel`
  with `startDir`), a tapped path shows `FileResolvingPage` (Back, the name)
  and swaps in the viewer or the browser with a 120 ms cross-fade, or shows
  why it failed (Not found, No permission, Not reachable) with what to do. The
  skeleton (`DelayedSkeleton`) draws only after `Dwell.spinnerDelay` (120 ms), so a
  fast link never flashes grey. The same path (or the browser) is opened once
  while it is being found (`_opening`). Entry points: the pane bar's Files
  (pane's cwd), the machine screen (home), a path in output or chat, and
  Session options > Files (the agent session's folder).
- **A path the agent names is found where its work is.** An agent names a file
  from the folder it works in, not from the folder the session started in
  (52% of the names in 140 of the owner's own sessions were written while the
  two differed), and it hands work to subagents that write in sibling git
  worktrees. After the first attempts (folder, two parents, git's `a/` `b/`;
  one `stat`, unchanged) `resolveRemotePath` goes down a ladder, cheapest first,
  and the first step with an answer wins:
  1. **What the session's own tool calls say** (`PathHints`,
     `data/acp/path_hints.dart`, read from the transcript when the path is
     looked up, never kept, nothing asked of the host to build it): the name
     against a folder a call ran in (its `cwd`, or a `cd`); a path a call
     touched that ends with the name; the name against the folder of a touched
     file (a message that names `theme.dart` and `motion.dart` means one
     folder). Only the newest 400 calls are read, each step asks at most 12 to
     24 places, 6 at a time, and a place that fails is skipped. Callers pass
     `session.pathHints` (chat Markdown, Made rows); a pane or a viewer has no
     transcript and passes none.
  2. `PathFinder` (`data/repositories/path_finder.dart`, SFTP only: `stat`,
     `list`, 4 KB reads of `gitdir` files, no shell, links never entered): the
     same relative path in the other worktrees of the session's repository
     (`.git/worktrees/*/gitdir`, or the main repo's list when the folder is
     itself a worktree; at most 12, 4 calls at a time, 3 s, lists remembered
     60 s per machine and folder).
  3. For a distinctive name (not `README.md`/`main.dart`) or after the Search
     button, an exact-name search below the folder (breadth first, depth 6, 400
     folders, 2 s, no hidden/`node_modules`/`build`/`.dart_tool`/`target`/`dist`).
     Depth 3 missed `app/lib/ui/core/motion.dart` from the repo root; the folder
     and time bounds stay, because every listing is a round trip on a phone's link.

  Malformed `gitdir` files and permission errors are ignored; leaving the
  screen cancels (no call after). One hit opens with a toast naming its source
  (`From worktree herdr-mobile-ux`, `Found in app/lib/ui/core`); several open
  `showPathChoices` (path below its root, root name, modified; transcript hits
  in the order the agent touched them, the rest newest first; dismissing goes
  back). The wait is the viewer's skeleton with a line (`Looking in other
  checkouts…`). A miss is the Not found page and names the path and where it
  looked: `docs/X.md isn't in herdr-mobile (also looked in 3 worktrees and
  searched by name)` (path cut in the middle; Search offered only when the name
  search did not run). When a tool call of the session used the file and it is
  not there, the page says that instead: `/tmp/run/out.log isn't there any more
  (the agent used it earlier)`, because "isn't in herdr-mobile" would blame the
  wrong place. Terminal links, Markdown paths and chat content links all go
  through `openRemoteFile`, so all get the ladder (the transcript steps only
  where a session is known).
- **One stack, never deeper than the folder.** A walk down is one route per
  folder, all sharing one `FileBrowserSession`. A breadcrumb POPS to the
  ancestor that is on the stack (it keeps its listing and scroll; nothing is
  read again); an ancestor above where the session began points the first
  browser at it in place (`retarget`). Back goes up one level. A picker still
  answers down the whole stack.
- **What you chose stays** for the session (`FileBrowserOptions`, shared by every
  folder): hidden files, sort (Name A-Z, Modified newest first, Size largest
  first, Type), folders first, and the `Changed in the last hour` chip, which
  also sorts newest first with folders among the files (and restores the order
  when switched off, unless it was changed by hand). The filter covers THIS
  folder's listing only (SFTP lists one folder at a time): the empty state says
  so.
- **Rows** (`FileRow`) are on the `ListRow` grid: a 32 px glyph (a small picture
  for a raster image of at most 512 KB, `FileThumb`/`ThumbLoader`: only rows on
  screen, three reads at a time, 6 MB kept), the name cut in the MIDDLE so the
  extension stays (`middleEllipsize`), and one muted line `12 KB · 3m ago`.
  An entry nobody can read (no read bit) or the host refused is dimmed and says
  `No permission`; it still opens to explain. Folders are never hidden by
  permissions.
- **Find in folder** (`foldForSearch`: lowercase, no diacritics, `đ` mapped by
  hand) filters the loaded listing as you type, from 8 entries up; no remote
  search, no shell.
- **The viewer notices the file changing.** While it is the screen in front
  (and the app resumed) it stats the file (no body read) when it comes back and
  every 15 s (`_DiskWatch`: `TickerMode` + app lifecycle, the timer is
  cancelled otherwise); a newer modified time shows the quiet `Changed on disk ·
  Reload` pill. A tap, or pulling the text down (`AppRefresh`), reads the file
  again with `FileViewerViewModel.refresh`: the old text stays on screen and in
  place (the line at the top is kept) until the new text replaces it, and stays
  with a `Couldn't refresh · Retry` strip if the read fails.
