# Pages in herdr

The screen that shows a page, so a link never takes the person out of herdr
(`ui/features/web/web_preview_screen.dart`, `WebPreviewScreen`): a page an agent
made on a machine (a dev server on the machine's `localhost`, or an HTML or
SVG file from its folder), the address an agent announced for the machine
itself, and a page of the web (`https`).

The design system (tokens, kit, motion, words) is `docs/DESIGN.md`; this file holds what this screen does and why.

The moment: an agent says "the dashboard is on http://localhost:5173" and the
person wants to see it now, from the phone, and then go back to the agent.

- **Inside herdr, not the phone's browser.** In a Custom Tab herdr went to the
  background, Android dropped the SSH connection the page is carried over, and
  the page sat on "Opening…" forever (0.1.17, Samsung, Android 14). The screen
  holds its machine's connection up while it is on the stack
  (`FleetRepository.holdAlive`, with the Watching notice that names the page:
  `docs/ALERTS.md`), so switching apps or turning the screen off does not end
  the page either. The same reason now covers the web: an `https` link that left
  for the browser put herdr in the background and the connections it held
  dropped after the grace (`Stay connected`, 90 s by default), so the person
  came back to a reconnect. One browser, in herdr, for every link (2026-11-24);
  the phone's browser stays only for what it alone can do (below).
- **Reached at once.** `openWebPreview` is the way in for a page of a machine:
  `Open page` in the link sheet (`ServerPage`), an app or page row of `Made`
  (`ServerPage` with `name`, the app's launch command; `FilePage` with the
  agent's path and folder) and `Show as page` in the file viewer
  (`FilePage.stat`). `openWebsite` is the way in for a page of the web
  (`WebsitePage`, `https`): `Open page` in the link sheet, a link row of `Made`,
  `Source code` and `Open on GitHub` in Settings, and `Open` on another site
  that a page of a machine linked to. The screen goes up on the frame of the
  tap and asks the machine for the listener inside it (`WebPreview.forwardUrl` /
  `staticUrl`); a website has no machine to ask and loads at once.
- **While nothing is shown.** The cover is never blank. It says the real stage
  under the bar, which already names the page (said once): `Asking devbox`
  while the machine is asked (a website says `Opening`), then `Waiting for the
  page` (`Waiting for the site`) until the page reports progress, then
  `Loading · 40%`. The hairline under the bar fills with the same real
  progress; nothing loops but the spinner. After `Dwell.pageSlow` (8 s) with
  nothing shown it says `Still waiting. The server may be busy or not running.`
  with `Try again`, which asks again and starts the wait over (an answer to the
  earlier ask is dropped, never shown as a second page). Why: the cover used to
  be empty while the page loaded, and a long wait with no word read as a frozen
  screen. The page storage is cleared while the machine is asked, not before
  it: one wait, not two. Unverified: not timed on a phone.
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
  A page of the web has a lock (`https`) in the globe's place and no machine
  line: the title is the site's `<title>` over its host, else the address
  alone (the host is not said twice), and it follows the page the person is
  on, as a browser's does.
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
  For a website it hands the page's address on as it is, and the line under it
  says herdr stays in the background while the browser is open (the reconnect
  the in-herdr page exists to avoid).
- **Links.** A page of a machine loads only that machine's own listeners
  (`webNavigation`, `docs/ARCHITECTURE.md` "Network traffic"). Another site
  opens nowhere by itself, whether a tap or a script asked: a toast says
  `example.org isn't from devbox.` with `Open`, which shows an `https` page in
  herdr over this one (Back returns to the page that linked it), a sign-in
  (`accounts.google.com`, `login.tailscale.com`, Microsoft, Apple:
  `needsOwnBrowser`) in the phone's browser, which is the one thing that can do
  it (`… is a sign-in. It opens in your browser.`), and plain `http` in the
  link sheet first (`… isn't encrypted.`; cleartext is refused in the view). A
  website follows its own links, redirects and frames as a browser does, over
  `https` (`siteNavigation`); never another scheme, the phone itself
  (`localhost`, a loopback address, a `.local` name) or a sign-in. Another
  `localhost` port of the machine says `localhost:8791 isn't open on this
  phone.` with `Open`, which opens it the way `Open page` would; a database-type
  port says what it is instead. A file link says herdr doesn't download files
  and that `Open in browser` can.
- **The address an agent announces for the machine.** `http://100.87.64.16:8792`
  for the machine dialled at `100.87.64.16` is the machine's own page: it opens
  through the SSH connection as `localhost:8792` (`WebPreview.ownHostLink`), as
  `Open page` for a `localhost` link does. Why not load it directly: Android
  refuses cleartext to any host but `localhost`, and the bridge also works off
  the tailnet. Exactly the machine's own host, plain `http` and a real port;
  another device's address stays a link to the web.
- **Failures** never leave a blank page: a `StatusPanel` says it once
  (`Couldn't open this page` or `Couldn't load this page`; the bar already
  names it) with the reason in plain words and `Retry`, which asks again and
  returns to the page that failed. For a machine's page the reason is the
  machine's own (herdr stopped serving it after 10 minutes unused or a new
  connection; the server closed without an answer; too slow). For a website it
  names the site that failed (`Couldn't connect to wandb.ai. Check your
  connection.`; not found; too slow; a certificate that isn't valid, which
  does not open). A page opened again starts its own history: Back leaves
  after it.
- **A dropped connection** (Android froze herdr without the notice, as on
  iOS, or the network went) is said in the warning tone, `Lost the connection
  to devbox`, and the page opens again by itself when the machine is back.
- **Edge to edge.** The page stops above the gesture bar, so a page's own
  footer is never under it.
- **What it forgets.** Cookies, web storage and the cache of every page view
  are cleared when the last page screen closes (and before the first one
  loads): an origin is the phone's `localhost:<port>`, which two machines can
  hold one after the other. A website is the same: herdr keeps no web
  session, so a private page asks for a sign-in on each visit (owner's choice,
  2026-11-24: the app never holds a third party's login). A website has no
  machine and holds no connection.
