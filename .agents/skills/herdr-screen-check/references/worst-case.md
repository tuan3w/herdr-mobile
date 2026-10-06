# Worst-case catalog for herdr-mobile

Each value is something a real person, machine or agent produces. Use the rows that apply to
the values on your screen. Use `example.com` or `.test` for anything that looks
like a host or address.

## Machines and links

| Value | Breaks |
| --- | --- |
| `build-box-gpu-02.tail9f3c1.ts.net` | Long hostname with no spaces; end-truncation hides what differs |
| `fe80::1ff:fe23:4567:890a%wlan0` | IPv6 with a zone; colons, width |
| `mac` / `a` | One to three letters; empty-looking rows |
| `Máy chủ phát triển` | Vietnamese machine name |
| 0 machines | First run: what does the person do next? |
| 1 machine | Grouping by machine looks odd with one |
| 12 machines, 3 offline, 1 awaiting Tailscale approval, 1 changed host key | Every link state at once; status strip stacking |
| A machine that was disabled | Shown, dimmed, or hidden? |

## Agents, panes and sessions

| Value | Breaks |
| --- | --- |
| Labels `claude`, `codex`, `omp`, `pi`, `opencode`, unknown/none | Per-agent tables (slash commands), icons, the label slot |
| A title of 120 characters with a path in it | Two-line wrap, the leading glyph on the title line |
| `Thiết kế giao diện · Đặng Thị Ngọc Hân` | Stacked diacritics clipped by a tight height |
| `修复登录问题` / `إصلاح تسجيل الدخول` | CJK has no spaces; RTL punctuation and alignment |
| `🦊 refactor` | An emoji first: grapheme handling in initials and truncation |
| 0, 1, 40, 120 agents across machines | Empty board, a single card, a lazy list (builds < 30), section counts |
| Every status at once: blocked, working, done, idle, unknown, offline | Section order, glyph shapes without colour |
| 5 blocked at once | Triage pill count, `N need you`, the walk through them |
| A blocked agent whose prompt the detector can't read | The fallback when there are no one-tap answers |
| A session that is only a saved copy (`cachedAsOf`) | `Updating…`, nothing answerable |
| An agent that finished while you were away (unseen done) | Done section, `N new`, swipe to review |

## Commands and questions (what the person approves)

| Value | Breaks |
| --- | --- |
| `git push --force-with-lease origin feature/very-long-branch-name-for-the-payments-api-refactor` | One unbreakable line; mono wrapping |
| A 4,000-character multi-line heredoc | Three-line clamp on the card, `Read all`, the whole thing in the sheet |
| `rm -rf "$HOME/projects/old build"` | The risky-answer hold and its reason chip |
| A command with a bidi override (U+202E) or control characters | `visibleText()` must neutralise it; the text shown must equal the text run |
| An ANSI-coloured question | Escapes stripped, not shown raw |
| Options `1. Yes`, `2. Yes, and don't ask again`, `3. No, and tell Claude what to do differently (esc)` | Long option labels on 44 dp chips; a standing grant needs the hold |
| 9 options | `N more` in the dock |

## Paths and files

| Value | Breaks |
| --- | --- |
| `/home/dev/work/clients/northwind/payments-api/src/features/checkout/widgets/order_summary_card.dart:212` | Middle-truncation; a tappable link |
| `~/Tài liệu/Hợp đồng thuê nhà.pdf` | Diacritics and spaces in a path |
| `IMG_20250914_183022_HDR_portrait_edited_edited.HEIC` | An unbreakable name with an uppercase extension |
| A folder with 0, 1 and 5,000 entries | Empty, one, and a lazy list |
| A 40 MB image, a 2 GB log, a binary | Size caps, progress, the hex preview |
| A file without read permission, a dangling symlink | Error states that say what to do |

## Terminal content

| Value | Breaks |
| --- | --- |
| 200-column output, a 40-column table, box drawing `┌─┐│└┘` | Wrap mode keeps tables whole; sideways scroll |
| Truecolor pale grey text on a dark background, shown on paper | Contrast pull toward black (`TerminalPalette.recolor`) |
| CJK and emoji (double width) | Cell width (`cell_width.dart`) |
| 1,000 rows of scrollback, then 3,000 more streamed | Capped history, `N new lines`, jump to latest |
| A spinner redrawing one line 10 times a second | No motion or relayout elsewhere |

## Numbers and time

| Value | Breaks |
| --- | --- |
| 0, 1, 2 | Plurals: `1 agent`, `0 need you` (should the line show at all?) |
| 99, 100, 1,284 | `99+`, the badge width, thousands separators |
| Just now, 59 s, 12 m, 3 h, 9 d, 11 months | Relative-time steps; an absolute date after a week |
| A clock skewed 5 minutes into the future | Negative durations (`-3m`) |
| `stale · 12s` growing to `1h` | A label that changes width every second |

## Network and lifecycle

| Value | Breaks |
| --- | --- |
| Offline from launch (cached state only) | The first paint dimmed and labelled, nothing pretends to be live |
| The link drops mid-send | The text is kept, a failed banner, Retry |
| A link that flaps every 10 s | Strips that appear and vanish; no flicker loop |
| A host key that changed | A hard stop, never a silent re-trust |
| App resumed after 2 hours | The catch-up is not news (no haptic storm), the stale labels |

## Environment

| Condition | Breaks |
| --- | --- |
| 320x640 | Every overflow at once |
| 892x412 plus keyboard (compact) | The dock, the palette and the quick phrases hidden; the composer still reachable |
| Text scale 1.6 and 2.0 | Fixed heights that clip growing text; the tab bar |
| Dark, light, dark terminal on paper | Hard-coded colours, invisible hairlines |
| Reduced motion | Sheets with no animation, page fade, no settle or pop |
| TalkBack | One node per control, headers, a hold as prime-then-send |
| Keyboard open on every screen with a field | Bottom insets, the action bar riding on the keyboard |
