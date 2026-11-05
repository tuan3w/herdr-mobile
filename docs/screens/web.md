# Pages from a machine

The screen that shows a page an agent made on a machine: a dev server on the
machine's `localhost`, or an HTML or SVG file from its folder
(`ui/features/web/web_preview_screen.dart`, `WebPreviewScreen`).

The design system (tokens, kit, motion, words) is `docs/DESIGN.md`; this file holds what this screen does and why.

The moment: an agent says "the dashboard is on http://localhost:5173" and the
person wants to see it now, from the phone, and then go back to the agent.

- **Inside herdr, not the phone's browser.** In a Custom Tab herdr went to the
  background, Android dropped the SSH connection the page is carried over, and
  the page sat on "Opening…" forever (0.1.17, Samsung, Android 14). The screen
  holds its machine's connection up while it is on the stack
  (`FleetRepository.holdAlive`, with the Watching notice that names the page:
  `docs/ALERTS.md`), so switching apps or turning the screen off does not end
  the page either.
- **Reached at once.** `openWebPreview` is the one way in, for `Open page` in
  the link sheet (`ServerPage`), an app or page row of `Made` (`ServerPage`
  with `name`, the app's launch command; `FilePage` with the agent's path and
  folder) and `Show as page` in the file
  viewer (`FilePage.stat`). The screen goes up on the frame of the tap and
  asks the machine for the listener inside it (`WebPreview.forwardUrl` /
  `staticUrl`): `BusySpinner` (after `Dwell.spinnerDelay`) while the machine
  is asked, then the hairline under the bar fills with the page's real
  progress; nothing loops.
- **No white flash.** Until the first page (not the entry page) has finished,
  the view sits under a cover of the screen's own colour, and the view's own
  background is that colour too; a page shown gets white, the web's default
  for a page with no background of its own. In the phone's night mode the
  window theme is marked dark (`values-night-v29`), so a page's
  `prefers-color-scheme` follows the phone, as in its browser (not yet seen on
  a phone; herdr's own Dark choice with the phone in day mode leaves pages
  light).
- **The bar.** The same bar as every other screen (`AppTopBar`): a globe in
  the glyph's place (where an agent screen shows its status) says "a web
  page"; the title is the page's `<title>` (read again `Dwell.titleSettle`
  after a single-page app changes route), else its address on the machine
  (`localhost:5173/settings`; a file's name), else, for an app opened from
  `Made`, what started it (`python label_server.py --port 8765`); the second
  line is where it comes from, `localhost:5173/settings · devbox`, or just the
  machine when the title already is the address (said once). For a named app
  the machine leads (`devbox · python label_server.py…`) so a long command is
  the part an ellipsis cuts. Why the plain bar: a pill of its
  own (0.1.18) cost the page height and looked like no other screen; the
  owner chose consistency, with the globe to say "web" (a prototype of four
  bars, 2026-10-19). The leading control is `✕` (`Close page`), not Back;
  the actions are the page-back arrow and `⋯` (`Page options`), the header
  budget's two. The hairline under the bar is the edge between herdr and the
  page.
- **Not from the machine.** A page that ends up showing another site (a form
  it posted there, which Android does not ask about) shows that site's host on
  the second line and never the machine's name; Copy link then copies that
  site's address. No extra warning: the host is the honest part, and the owner
  found a `not from` label noise.
- **Leaving and going back.** `✕` leaves from any depth in one tap. Why: the
  bar's Back walked every page of the visit first, so ten links deep was ten
  presses back to the chat (owner-approved prototype, 2026-10-29). The arrow
  goes back one page and stays, dimmed, on the first page (a screen reader
  hears why). Held, it opens `Pages in this visit`: the visit's pages newest
  first (title over address, else the address), the one shown marked `Here`,
  and a last row that closes the page; a tap goes back to that page, one
  history step at a time, each after the page before it is in (a step taken
  at once cut the page's load short and its late report counted as a new
  page). The newest 50 pages are kept. A jump through a single-page app's
  routes may stop on the first of them, if Android reports no finished load
  for a route (unverified: not run on a phone). The phone's Back is
  unchanged, as in a browser: back one page, then it leaves (with nothing
  behind the page the system Back pops at once). The entry page that sets the
  cookie is never a step.
- **`⋯`.** `Reload` first (dimmed with its reason while the page is opening,
  or while a failure panel offers Retry); it moved here because the bar holds
  two actions. Its title is the whole link, wrapped (the bar's line is cut to fit,
  and the person often wants to read the full address); `Copy link` copies
  that link, the page's address on the machine
  (`http://localhost:5173/settings`: the machine's port, never the phone's
  listener port or the token); a file's page is `Copy path` with its path on
  the machine. `Open in browser` hands the page to the phone's browser with a
  fresh entry URL, for what an embedded view cannot do (Google refuses sign-in
  in one); a line under it says the browser's copy works only while this
  screen stays open.
- **Links.** Only this machine's own listeners load in the view
  (`webNavigation`, `docs/ARCHITECTURE.md` "Network traffic"). A page of the
  web opens nowhere by itself, whether a tap or a script asked: a toast says
  `accounts.google.com isn't from devbox.` with `Open`, which opens it in the
  phone's browser (`https`), or in the link sheet first (plain `http`).
  Another `localhost` port of the machine says `localhost:8791 isn't open on
  this phone.` with `Open`, which opens it the way `Open page` would (Back
  returns to the page that linked it); a database-type port says what it is
  instead. Other schemes say herdr does not open them from a page. A file
  link says herdr doesn't download files and that `Open in browser` can.
- **Failures** never leave a blank page: a `StatusPanel` says it once
  (`Couldn't open this page` or `Couldn't load this page`; the bar already
  names it) with the reason in plain words (the machine's own reason; herdr
  stopped serving it after 10 minutes unused or a new connection; the server
  closed without an answer; too slow) and `Retry`, which asks for the listener
  again and returns to the page that failed. A page opened again starts its
  own history: Back leaves after it.
- **A dropped connection** (Android froze herdr without the notice, as on
  iOS, or the network went) is said in the warning tone, `Lost the connection
  to devbox`, and the page opens again by itself when the machine is back.
- **Edge to edge.** The page stops above the gesture bar, so a page's own
  footer is never under it.
- **What it forgets.** Cookies, web storage and the cache of every page view
  are cleared when the last page screen closes (and before the first one
  loads): an origin is the phone's `localhost:<port>`, which two machines can
  hold one after the other.
