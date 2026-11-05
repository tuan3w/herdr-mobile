# Settings, updates and the shell

The Settings page, updates, how home opens Machines and Settings, links that fail, what survives a launch.

The design system (tokens, kit, motion, words) is `docs/DESIGN.md`; this file holds what this screen does and why.


The theme is a setting (`ThemeChoice` light / dark / system, `AppSettings`),
**light by default**, including for installs that never chose. It is loaded in
`main()` before `runApp`, so the first frame is already right. `MaterialApp`
switches instantly (`themeAnimationDuration: Duration.zero`): a cross-fade
would lerp `ThemeData` per frame and rebuild every mounted screen, including
the Agents board under a page. The system bars follow the resolved brightness, so
`system` follows the phone.

Settings is a page over home, opened from the gear in the board's header
(`features/settings/`): five rows, each saying what
it is set to and opening in place (`SettingsGroup`, on `Collapse`), one at a
time. Look (theme, the terminal font size stepper 8 to 22
with a sample line, wrap, Dark terminal, and Smooth text: streaming answers at
an even pace, on by default, `AppSettings.smoothText`; the terminal ones edit
the pane's `TerminalSettings`), Agents (how agents open, and Quick phrases, a
row that opens its own page because the list grows), Notifications, Storage
(what the disk cache keeps, `DiskCache`, as `Cache · 38 MB`, and `Clear cache`: a plain tap, because
everything cleared can be downloaded again), and About (what it talks to, update
checks, source link, licences). A newer version's row
sits above them. Why five rows: the page was one long scroll of six sections
(about 1,800 dp) and each new setting made the next harder to find; five rows
fit a screen at normal text size (at 320 dp and 2x text the last one scrolls),
and a group grows without lengthening the page. A row shows values, not setting names ("Light · Auto · 11.5 pt",
"Blocked by Android"), and a closed group is not built. Two tiles are tinted,
and only two: notifications Android blocks (orange, the colour that means
"needs you") and a newer version (the accent, a suggestion). The groups start
closed on every visit: each visit is a new page, opened at its top.
The version is `lib/data/app_info.dart`; `test/app_settings_test.dart` fails
when it differs from `pubspec.yaml`. `AppSwitch` / `SwitchRow` are the kit's
(`ui/core/switch.dart`).

**Updates** (`features/settings/update_group.dart`, `AppUpdate`). A newer
version on GitHub is a suggestion, so it is quiet: a 10 dp accent dot on the
gear in home's header (`CircleButton.mark`; never a count, the loud colour is
for a question) and an `Update available` row at the top of Settings, absent
when there is nothing newer. No toast, no notification, nothing else on the
board, and no sheet that opens by itself. The row says the version and its
size; a tap opens the update sheet (`showUpdateSheet`). Each visit opens the
page at its top, so the row is in view when the dot brings the person there.
(As a tab the page kept its place and had to scroll itself back to the row;
that code went with the tab.) A version found while the page is showing does
not move it: nothing moves under the thumb.

The sheet is the whole update, read before acted on. Why: Download used to be
the row's main button with `What's new` a text button beside it, and the
notes sheet had no button, so not reading was the default path (the owner:
"let people check the changelog before install, provide some trust"). Top to
bottom: `Update to <version>`; the walkthrough's poster when the notes lead
with one (`ReleaseClip`: a poster image linking to the clip, both files of that
very release; a tap plays the clip in the app (`clip_player.dart`: GitHub serves release files as downloads, so a browser saved it instead), nothing of the video loads
before; the poster is the one picture fetched from notes, any other image
stays a chip); the notes; then, pinned over a hairline, one line of what herdr
knows and the one next step. Before the download the line says where it comes
from and which version you have, and the step is `Download <size>` (`Retry`
after a failure, with the reason whole and in red above it); while bytes
arrive, the progress bar, the count and Cancel; once downloaded, `Checksum
matched: the file the release lists`, `Install <version>` and `Android asks
before it installs.` Android's signing rule is not claimed on this path:
Android applies it after Install and herdr does not know the outcome. While
bytes arrive the row carries the progress bar too, so a download stays in
sight after the sheet is put away; "Ready to install" and a failure are said
to a screen reader on the row. Nothing is lost (a stopped download continues
from its bytes). Install opens Android's own confirm dialog, so nothing is
installed silently; if Android does not yet allow herdr to install apps, its
settings page opens and the sheet says to tap Install again after allowing
it. A release without notes says so and offers its page on GitHub. About holds `Check for
updates` (the manual check, with the reason when it fails) and `Check
automatically` (on by default: at most every 12 h while the app is in front;
the request carries the app name and version, and a download comes from
GitHub's file servers). Why on by default and why About says so: the app used
to say it "sends nothing anywhere else"; github.com is now the one other place
it contacts, and the Connection line says it. The download is only ever
started by a tap (it is ~50 MB of the person's radio). Android only:
`bootApp` builds no updater elsewhere and the screen then shows nothing about
updates.


**Home and its pages.** There are no tabs: home is the Agents board, and
Machines and Settings are pages pushed over it from its header (the machines
chip, the gear) through `HomePages` (`ui/shell/home_pages.dart`), which the
app hands to the shell and to `DeepLinks`. Opening the page already in front
does nothing, so a quick second tap never stacks a second copy. Back on
Machines or Settings returns home; on home it is as before (background while
watching, else leave), and the board's selection mode still takes it first.

The summary notification (`N agents need you`, `herdr://agents`) goes back to
home. Going back is the way Back goes (`maybePop`, one route at a time), never
`popUntil`: a screen that asks before it closes (the machine form with unsaved
input) asks, and if the person keeps it, it stays; if they discard it, the
page it was opened from is in front, one Back from home (the link goes no
further on its own once a guard has the person's attention). Why: a
notification tap must not throw away a half-filled form, and the form already
has the guard.

A link that cannot be followed (unknown machine, switched off, unreachable,
agent gone, not a herdr link) moves nothing: it says why in a toast over the
screen in front, and the toast's button opens the page where the next step
can succeed: `Open Machines` for a machine to add, switch on or retry (Enable
and Retry live there), `Open Agents` (home) for an agent that is gone or a link
the app cannot read. The button goes back the same guarded way until that page
or home is in front, then opens the page over home; it is left out when that
page is already in front. Why: never a dead end, never a silent loss; a
failure used to close everything, form included, and offer nothing.

## What survives a launch

The app opens on home. (The root tab it was left on used to be remembered;
with no tabs there is nothing to remember, `app.homeTab.v1` is no longer
read, and Machines and Settings, pages now, are not put back.)

The theme, Smooth text, the terminal font and
wrap, and the agent screen in front with its view (`frontAgent.v1`): it is put
back once, at once and without the slide, as if the app never closed. A
session the phone has not listed yet is waited for, up to 8 s, while the board
is in front and untouched, then comes in with the page transition; if it never
comes, or the person moves on first, it is forgotten. Going back to the board
forgets it too. The view chosen with the toggle and the drafts last only the
app run. The tabs the app used to keep are read once, to carry
the terminal that was in front over, and deleted. Also,
in private cache files and never in preferences, the last transcript of each
agent session (`TranscriptCache`: it opens at once, as a saved copy, until the
keeper has answered).

**What's new** (`features/settings/release_history_screen.dart`, About). The release notes of every
version the installed one knows, newest first: version (`Installed` on this one), the headline of the
release and its date; a tap opens that release's notes in a sheet shaped like the update sheet (tips
and the walkthrough poster included). Why: the update sheet shows only the newest release, and the
person who updated has no way to read what the last few releases added or to find a tip they missed.
Why bundled: the notes ship in the app (`assets/CHANGELOG.md`, a link to the repository's own
`CHANGELOG.md`, so the app, GitHub and the file are one text and nothing is copied or synced), so it
opens at once, offline, with no request and no rate limit; the cost is that it only knows releases up
to the installed one (a newer one is the update sheet's). The only thing fetched is a walkthrough's
poster, when that release's notes are opened. `test/release_history_test.dart` fails when the bundled
file is not the repository's or its newest release is not `appVersion`, which is also what stops a
release without its changelog section.
