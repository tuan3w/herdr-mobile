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
- **A path the agent names is found where its work is.** Agents hand work to
  subagents that write in sibling git worktrees, so `docs/X.md` is often not
  in the session folder. After the first attempts (folder, two parents, git's
  `a/` `b/`; one `stat`, unchanged) `resolveRemotePath` asks `PathFinder`
  (`data/repositories/path_finder.dart`, file service only: `stat`, `list`, 4 KB reads
  of `gitdir` files, no shell, links never entered): (a) the same relative
  path in the other worktrees of the session's repository (`.git/worktrees/*/
  gitdir`, or the main repo's list when the folder is itself a worktree; at
  most 12, 4 calls at a time, 3 s, lists remembered 60 s per machine and
  folder); (b) for a distinctive name (not `README.md`/`main.dart`) or after
  the Search button, an exact-name search below the folder (breadth first,
  depth 3, 400 folders, 2 s, no hidden/`node_modules`/`build`/`.dart_tool`/
  `target`/`dist`). Malformed `gitdir` files and permission errors are
  ignored; leaving the screen cancels (no call after). One hit opens with a
  toast naming its source (`From worktree herdr-mobile-ux`); several open
  `showPathChoices` (path below its root, root name, modified, newest first;
  dismissing goes back). The wait is the viewer's skeleton with a line
  (`Looking in other checkouts…`). A miss is the Not found page and names the
  path and where it looked: `docs/X.md isn't in herdr-mobile (also looked in
  3 worktrees and searched by name)` (path cut in the middle; Search offered
  only when the name search did not run). Terminal links, Markdown paths and
  chat content links all go through `openRemoteFile`, so all get it.
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
  for a raster image, `FileThumb`/`ThumbLoader`: only rows on screen, three at
  a time, 6 MB kept), the name cut in the MIDDLE so the extension stays
  (`middleEllipsize`), and one muted line `12 KB · 3m ago`. Where the picture
  comes from depends on the machine. With the agent helper the machine makes it
  (`fs.thumb`: a 256 px JPEG, a few KB to tens of KB, for any picture up to
  64 MiB; kept on disk under the one key the Photos grid shares, so a row seen
  again costs nothing; a row that scrolls away cancels the work on the machine).
  A big picture the helper cannot make a thumbnail of (HEIC, RAW, SVG) is asked
  once and remembered. Without the helper (SFTP) the file itself is read, and
  only when it is at most 512 KB (`thumbMaxBytes`: reading a phone photo to
  draw 32 pixels is the wrong trade), so a bigger picture keeps its glyph. An
  entry nobody can read (no read bit) or the host refused is dimmed and says
  `No permission`; it still opens to explain. Folders are never hidden by
  permissions.
- **Find in folder** (`foldForSearch`: lowercase, no diacritics, `đ` mapped by
  hand) filters the loaded listing as you type, from 8 entries up; it never
  asks the machine. **Search** (the header's magnifier, `FileSearchScreen`,
  `FileSearchViewModel`) looks below the folder: a field (`Name in <folder>`)
  and three chips, `Any time`, `Last hour` and `Today`; the two time chips work
  with an empty field ("what changed lately, below here"). The machine does the
  looking (`fs.search`, `docs/HOST_PROTOCOL.md`), shallow matches first, and the
  matches stay in the order they arrived (never re-sorted, so a row does not
  move while it is being read). A footer says `Searched 51,000 items` and, when the
  machine stopped at a limit, that there may be more with `Narrow the search`
  (it focuses the field); a folder that could not be read is counted there too.
  Typing waits for a pause (`Dwell.typingPause`) and a new question replaces the
  old at once. The search runs only while its screen is in front: the app
  backgrounded or another screen on top stops the stream, and it carries on when
  the person is back, without moving the rows shown. A tap opens the match as a
  tap on a row does, over the search, which stays. Without the helper, or with
  an older one (`unknown_method`), the app walks the folders over SFTP instead,
  capped at 3,000 entries and 4 s and saying so when it stops
  (`file_walk_search.dart`): one folder per round trip is the cost. The two
  searches coexist because they answer different questions: the field narrows
  what is on screen, Search goes looking.
- **The viewer notices the file changing.** While it is the screen in front
  (and the app resumed) it follows the file (`_DiskWatch`: `TickerMode` + app
  lifecycle; the subscription is ended otherwise): through the agent helper the
  host looks (`fs.watch`) and the phone only hears a change; without it the
  file is statted every 15 s over SFTP. A newer modified time shows the quiet
  `Changed on disk ·
  Reload` pill. A tap, or pulling the text down (`AppRefresh`), reads the file
  again with `FileViewerViewModel.refresh`: the old text stays on screen and in
  place (the line at the top is kept) until the new text replaces it, and stays
  with a `Couldn't refresh · Retry` strip if the read fails.
