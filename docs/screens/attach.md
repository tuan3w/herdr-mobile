# Attach sheet

The one sheet for everything that can go with a message.

The design system (tokens, kit, motion, words) is `docs/DESIGN.md`; this file holds what this screen does and why.


One bottom sheet for everything that can go with a message, modelled on
Telegram's: a grabber, a scrim, a content area and a floating pill of tabs at
the bottom. `showAttachSheet` (agent_session/attach_sheet.dart) pushes
`AttachSheetRoute` on the frame of the tap (nothing awaited before it); the
tabs draw what they have (the bars, the camera tile) while the library answers.

- **Frame** (`sheet_frame.dart`). Not a Material bottom sheet, which resizes
  its content while dragged: the content is laid out ONCE at full height and
  moved with transforms. `SheetPosition.offset` is the translation from full
  height (0 = full, `restHalf` = half, ~55% of the screen, `full` = away). The
  surface follows the finger 1:1, the bars (action bar, tab bar) keep to the
  screen's bottom while the sheet is between half and full height, a release
  hands the finger's velocity to a spring (`SpringDescription.withDampingRatio`,
  stiffness 420, ratio 0.88) and picks the stop from where the sheet would end
  up (`velocity * 0.25`): between full and half the choice is one of those two
  (a hard flick down from full lands on half, the next one closes), below half
  it goes away or comes back. The grid scrolls only at full height (at half a
  drag on it moves the sheet: `SheetScroll`); at full, a pull down from the top
  hands over to the sheet. The scrim ignores taps until the sheet has come up
  (the second tap of a double tap on the paperclip). The keyboard lifts the
  sheet to full height and the tab bar steps aside. Under reduced motion the
  sheet appears and every release lands at once. Tabs keep their bottom end
  clear with `SheetScope.bottomClearance` (the half-height shift that hangs
  below the screen plus the bars) and are top-aligned, never centred, for the
  same reason.
- **Tabs** (`attach_bars.dart`, `attach_sheet_view.dart`): Gallery | Files |
  Machine, each an icon and a label, the selected one in `ds.accentText` on a
  `ds.accentWash` capsule, the app's selection look (`Segmented`), in the
  floating pill (`FloatingBarPill`). The third tab is `Machine` (the vocabulary's word for
  the computer the agent runs on), never `Host`.
  Built the first time they are shown, kept alive and out of layout while
  hidden (scroll position and state survive), cross-faded over `Motion.fade`
  (120 ms; nothing is wrapped in an opacity layer at rest). The last tab is
  remembered for the app run (`AttachKit.tab`).
- **One tray** (`tray.dart`). Every tab puts picks in the same `AttachTray`;
  the numbers on the circles are places in it, `Attach (3)` and `3 / 5` count
  every tab, `Clear` empties it. The action bar is a bottom-stack lane
  (`BottomStackTransition`: up from `Motion.travel` with a fade, `sheetIn`)
  as soon as one thing is picked. Tiles and rows do not own
  notifiers: each listens to the tray and rebuilds only when its own number
  changed (`attach:tile` builds are counted in tests; the grid itself is never
  rebuilt by a selection, a page arriving or a tab switch).
- **Gallery** (`gallery_tab.dart`, `gallery_model.dart`,
  `data/services/phone_gallery.dart`). `photo_manager` over MediaStore (the
  maintained plugin with paged queries, albums, MediaStore's own thumbnail
  cache and limited access; it builds for Android, its Kotlin plugin is
  flagged by Flutter's built-in-Kotlin warning). A 3-column grid (more columns
  on a wide window), newest first, the camera as tile 0, a 24 dp ring in each
  tile's corner (44 dp to hit): empty on a dark wash, filled with the accent
  and the pick's number when picked (a 0.9 -> 1 pop over `Motion.press` and
  `Haptics.tick` on the change; the picture shrinks to 0.88). A tap on the
  circle toggles, a long press on the tile toggles (`Haptics.hold`), a tap on
  the tile opens the one photo viewer with a `Select` pill over the picture
  (`PhotoViewer.overlay`). The `Recent` chip lists the albums; with Android 14's
  partial access a `Manage` chip re-opens the system selector. An agent that
  takes no images gets the line `This agent does not take images. Photos go up
  as files.` and its photos upload as files.
- **Permission.** Read (never asked) when the tab is shown. Undetermined: a
  panel with the one-line reason (`Photos stay on your phone until you attach
  them.`) and `Allow photo access`: the system dialog comes only from that tap.
  Refused: `Open settings` (the access is read again on resume). Plugin
  failure: only the fallbacks. `Open the system picker` (image_picker) and
  `Take a photo` are on every one of those panels; a panel too tall for half
  height lifts the sheet to full. Manifest: `READ_MEDIA_IMAGES`,
  `READ_MEDIA_VISUAL_USER_SELECTED` (the plugin adds `READ_EXTERNAL_STORAGE`
  up to API 32).
- **Speed** (`thumb_cache.dart`). The paperclip's pointer-down and the screen's
  first frame call `GalleryModel.warm`: when the permission is already given
  and the app is in front, the first page (120 pictures) and the first 24
  thumbnails load, so the sheet opens onto pictures (never before the
  permission, never in the background, never asks). Thumbnails are JPEGs of
  <= 240 px from MediaStore's cache, decoded by the engine off the UI thread
  (`ResizeImage` at 240); `ThumbCache` is an LRU of ~200 entries / 60 MB whose
  evictions also evict the decoded bitmap, at most 4 loads at once, newest
  request first, scrolled-away tiles cancel before they start, prefetch of one
  screenful ahead in the direction of travel only when nothing on screen waits,
  the queue held during a fast fling (> 2400 dp/s), cleared on memory
  pressure. A tile is a flat tint until its bytes arrive (no spinner), then
  fades in over `Motion.fade` unless it was already in memory or motion is
  reduced. The grid is a fixed-extent `SliverGrid` (a screenful built beyond
  the edge, a `RepaintBoundary` per tile, no shadows, blur or opacity at rest)
  and loads pages of 120 as indexes are asked for. A pick is read and encoded
  at once (two at a time, `ComposerAttachments.speculate`) and abandoned if
  undone, so `Attach` has nothing left to wait for; the chips appear in the
  frame the sheet starts to leave, and uploads start when its animation is over.
- **Fresh** (`GalleryModel._refresh`). The model lives for the app run, so what
  it loaded is a saved copy: the paperclip's pointer-down, the composer's first
  show, the Gallery tab being shown and the app coming back to the front each
  read the album again (its count and its first page: two queries). The grid
  paints what it has at once and is corrected when the answer differs; a
  library that did not change notifies nobody and decodes nothing. A change
  keeps the first page, drops the pages below it (their indexes moved; they are
  asked for again as the grid scrolls there; thumbnails are keyed by picture and
  stay), and an album that disappeared falls back to `Recent`. Why: it used to
  read once per app run, so a screenshot taken while herdr was open was not on
  the grid until the app was killed. Android 14's partial access still hides
  pictures the person did not share: the `Manage` chip is the way to add them.
- **Files** (`files_tab.dart`, `data/services/phone_files.dart`). `Choose
  files…` opens the system document picker (`file_picker`, multi-select; the
  plugin streams the document into the app's cache, so nothing large passes
  through Dart memory), and picks join the tray as rows. `Recent` lists the
  last 10 phone files attached (`RecentPhoneFiles`, prefs `attach.recentFiles.v1`:
  name, size, and the host copy's path for that machine, never content or a
  phone path); a recent whose host copy still exists is attached again without
  sending it again. Over 25 MB: attached with a warning; over 200 MB: refused
  with `name is 312 MB. Files up to 200 MB can be attached.`
- **Machine** (`host_tab.dart`). The file browser's own pieces inline:
  `FileBrowserViewModel` per folder (one stack, shared `FileBrowserOptions`),
  `FileRow` with a `SelectionCircle` in its trailing slot, `FileBreadcrumbs`,
  `EmptyFolderState`; opens on `Changed recently` in the session's folder, a
  find field, folders navigate in place, `Browse all…` pushes the full browser
  in pick mode as before.
- **Uploads** (`ComposerAttachments`, `data/repositories/attach_upload.dart`).
  A file of the phone (or a photo for an agent without images, or a picture
  over the encoder's 25 MB) goes to `<home>/.herdr-mobile/inbox/…` over
  SFTP (`reserveInboxPath` + `RemoteFiles.upload`) and is attached as a
  resource link to that path. The chip shows a ring over its thumbnail and
  `Uploading 42% · 48 MB`; the cross cancels, a failure shows `Retry`.
- **One rule for a picture, whatever its source.** The gallery, the camera
  tile, `Take a photo`, `Open the system picker` and an image chosen in Files
  all decide the same way (`ComposerAttachments._startPicture`, the gallery's
  `_beginGallery`): an image block when the agent takes images and the
  picture is at most 25 MB, else the original uploaded as a file, its chip
  saying `Sent as a file · this agent takes no images` from the start. The
  pickers hand over a path and a size (`PickedPhoto`), never bytes, so the
  composer chooses. Why: the camera and the system picker used to send a JPEG
  image block to an agent that takes none; the chip said ready and the send
  failed afterwards.
