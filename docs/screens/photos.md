# Photo viewer

The one full-screen viewer for every picture.

The design system (tokens, kit, motion, words) is `docs/DESIGN.md`; this file holds what this screen does and why.


ONE full-screen viewer for every picture: a file (the browser, a tapped path,
the folder grid), a picture in the chat (inline, tool result) and the picture
chips of the composer. `openPhotoViewer` / `photoViewerRoute` push a
transparent route (the chat shows through the backdrop while a photo is
dragged away); `fileViewerRoute` (`files/photo_files.dart`) picks it for a file
whose name is a picture, and `FileViewerScreen` hands over (replaces itself)
when the bytes of a differently named file turn out to be one. A `.png` whose
bytes are text offers `Show as text`. The viewer is always dark (`AppTheme.dark`
inside, light icons in the bars, black backdrop) whatever the app theme is; its
sheets are dark too.

- **Chrome.** One tap toggles it (fade, `Motion.standard`; nothing wraps it
  while fully shown, nothing in the tree is composited at rest): back, `Photo 3
  of 12` (the file name for a lone photo), info, and one `Save or share` button
  (sheet: `Save to phone`, `Share…`, `Copy path`). A one-line caption under the
  picture, shown with the bars: `name · 4,032 × 3,024` (middle-ellipsis, the
  extension and the end of the name stay; the size while loading). A drag that
  dismisses fades the bars out within a third of the way.
- **Info sheet** (`photo_info.dart`, rows from `photoInfoRows`, tested): name,
  full path (mono, copy button), `From` (a chat picture: `Tool result · Read
  screenshot.png`, `Sent by omp · date`, `You attached it`; strings through
  `visibleText`), dimensions and megapixels, size, format, modified, EXIF taken
  / camera / lens / exposure, `Turned upright (EXIF 6)`, and a note while only
  the screen-size bitmap is held.
- **Gestures** (`photo_stage.dart`, arithmetic in `photo_math.dart`). Scale is
  relative to fit (1 = the whole picture, never smaller at rest); everything is
  a spring (`Springs.carry`) started from the
  live value with the finger's release velocity; there are no timed tweens.
  A finger landing stops what is moving the picture (`Listener.onPointerDown`),
  a second finger or a lifted one re-bases the gesture, nothing locks input.
  Pinch zooms around the fingers' centroid, rubber-banded in ratios past fit
  and past `maxScale` (3x actual size, 4x..16x) and springs back on release;
  double tap goes fit <-> 2.5x at the tapped point (the recogniser exists only
  on a loaded picture, or every button of a failure panel would wait 300 ms);
  a pan hands its velocity to `BouncingScrollSimulation` (momentum, rubber band
  at the edges); at an edge a further drag turns the page (rubber band at the
  first/last photo, 40 % of the width at most); a vertical drag at fit
  dismisses (the picture follows and shrinks 30 %, the backdrop fades; the
  decision uses the projected end `dy + project(vy)`, with 22 % of the height, and
  a drag taken back against its direction never closes). Detents: `Haptics.tick`
  as the picture crosses fit and as it reaches its largest size. Reduced
  motion: every spring lands at once (no slide, no travel); fades stay.
- **Pixels.** The first bitmap is decoded to fit 1.5x the screen's pixels
  (`photoBaseFactor`; never above that until the person zooms); when the
  picture is stretched past it (`wantsSharper`) one sharper decode up to
  4096 px a side (`photoSharpSide`, <= 48 MB) joins it and is given back 2 s
  after zooming out or when the photo is left. Only the open photo and its two
  neighbours hold anything (`PhotoViewerViewModel`: read the open one, then
  the one in the direction of travel, then the other, one read at a time,
  neighbours over 12 MB wait, moving on cancels a stale read). EXIF
  orientation is applied by the engine's codec (the descriptor reports the
  rotated size; checked in `photo_viewer_model_test.dart`). A picture shown past
  2 device pixels per bitmap pixel uses the nearest neighbour; a PNG / WebP /
  GIF that may be see-through (`mayHaveTransparency`, header only) sits on a
  checkerboard.
- **Loading and limits.** The thumbnail the folder grid or the chat preview
  already made stands in (`PhotoItem.placeholder`), and a quiet badge says the
  wait: the one spinner and `4.2 MB of 11 MB` with a thin progress bar; both go
  when the picture is there. The badge waits before it shows: `Dwell.spinnerDelay`
  (120 ms) for a photo with nothing on screen, `Dwell.standInWait` (800 ms) for one
  that already shows its stand-in. Why: a picture opened from the chat is
  already on screen, and `Preparing…` over it for the fraction of a second its
  full size took to come back from the cache read as loading something that
  was cached (owner, 2026-11-24: "always show loading even it cached"). A wait
  that is real still says so, and a screen reader hears nothing for one that
  is not.
  Files are read over SFTP in 2 MB pieces (`photoReadChunk`, `RemoteFiles.readAll`
  with progress and a `ReadCancel`), up to 40 MB (`photoReadCap`); over it
  nothing is read and the panel says `This photo is 52 MB. The viewer opens
  photos up to 40 MB.` with `Share…`, which copies the file to the cache
  directory in pieces (memory stays flat) and opens the share sheet
  (`PhotoExport.shareLarge`). Save and share use `gal` (MediaStore, album
  `herdr`, no permission from Android 10) and `share_plus`.
- **Folder grid** (`files/photo_grid.dart`, `photo_thumbs.dart`): a folder with
  6 or more pictures gets a `Photos` header toggle that swaps the list for a
  3-column grid; at most 3 thumbnail reads at once, smallest first, files over
  2 MB are never read for a thumbnail (a glyph and the size), scrolled-away
  tiles cancel their read.
