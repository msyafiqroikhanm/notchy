# Notchy native interface

## Direction

Operate mode for a personal MacBook companion. ENERGY 2 / RHYTHM 2 / MOTION 2. The approved Nusa references establish the connected black silhouette, dense mode-specific composition and discreet page navigation. They do not supply source, assets, sample data, website controls or verified macOS point measurements. Notchy remains an independent AppKit/SwiftUI app; no corporate branding applies to this surface.

## Geometry and silhouette

`ShellProfile` derives destination geometry from interaction state and real NSScreen camera/safe-area facts. Body width excludes two shoulder extensions. `NotchShape.path(in:geometry:)` constructs one outline with a camera-width neck, concave shoulders and rounded lower corners. Container mask, drag highlight, hit test and hover/drop routing share that exact presented path. Mouse-only local/global monitors set `ignoresMouseEvents` outside it; no event tap or keyboard monitor is installed. A rendered mask is not proof of physical menu click-through.

Let C be the actual top safe area, or 0 without a camera notch. Expanded headers use C on a notched screen and 30 pt otherwise. No-notch profiles begin below the actual menu-bar height. All profiles clamp to screen bounds with 8 pt side/bottom clearance; camera coverage remains the width/height floor.

| State | Body width | Total height | Shoulder / bottom |
| --- | --- | --- | --- |
| Closed/resting, notched | camera + 80 | C | 4 / 10 |
| Closed/resting, no notch | 160 | 30 | 0 / 12 |
| Fokus | 360 | header + 164 | 18 / 28 |
| Widgets | 400 | header + 164 | 18 / 28 |
| Musik, Shelf, Clipboard, Tugas | 440 | header + 164 | 18 / 28 |
| Air, Sholat | 480 | header + 164 | 18 / 28 |
| Lyrics | 680 | header + 220 | 18 / 28 |
| Task editor | 440 | header + 204 | 18 / 28 |
| Standalone notice | max(340, camera + 24) | C + 60 | 12 / 18 |

Explicit minimal presentation is the camera-width rectangle by C, or 72 × 6 without a notch. Notices and opening exit minimal presentation without resetting the preference. Expanded notices append a 44 pt strip below the unchanged body/footer. Standalone notices use the camera-width/C-height neck; expanded profiles retain their full-width top with neck height zero.

The built-in display remains preferred. Final closed/resting status is beside the camera: a 16 pt actual ring in the left 40 pt wing and a 12 pt semibold monospaced-digit 24-hour clock in the right 40 pt wing, including 4 pt trailing padding. No idle play/pause icon or lower apron remains. The camera stays empty of content. With no room for center eyes beside a physical camera, status takes priority; no-notch idle can still show the optional mascot. The expanded header has only the page-title menu and a 24 pt `Sembunyikan panel` control.

The user rejected both the earlier 279 × 32 pt wing revision for obscuring menus and the subsequent below-camera apron for hanging too low. Returning to 36 pt wings produced a cramped clock; 40 pt wings add breathing room without shrinking type. On the observed 179 pt camera / 32 pt safe area, final idle is 267 × 32 pt. It still occupies menu-bar space; physical Chrome click-through is not accepted. Expanded widths follow content instead of a shared 520 pt body.

## Type and palette

System type preserves native reading and control behavior. Feature title: 14 pt semibold; labels: 13 pt; secondary: 11–12 pt; chart/calendar ticks: 10 pt with a textual accessibility equivalent. Monospaced digits apply to changing time/counts, not body prose.

Black merges with the camera cutout. White carries main text, #A6A6AE secondary text, #1C1C1E controls. Music progress is white; focus #B49AFF; water #67D7FF; battery/completed tasks/Shelf acceptance #33D17A. Filled accent actions use black labels. Measured normal-text contrast: secondary on black 8.69:1; black on purple 9.01:1, blue 12.74:1, green 10.54:1. Focus outlines are white. Page arrows convey direction, dots convey position, and neither is decorative navigation chrome.

## Composition and navigation

Page order: Musik, Fokus, Air, Shelf, Clipboard, Tugas, Sholat, Widgets. Header title menu selects any page and offers Settings/Hide. `Sembunyikan panel` dismisses only the panel; the status menu's `Keluar dari Notchy` terminates the app. Circular 24 pt side arrows stop at the first/last page; footer dots are information rather than tiny buttons. Command-Option-Left/Right steps pages while the panel is key. Horizontal trackpad navigation commits once at gesture end above 40 pt and a 1.5:1 horizontal ratio, ignoring editing, slider and file-drag interactions. Lists and lyrics retain vertical scroll ownership.

All feature trees stay mounted, with inactive hit-testing, disabled and accessibility guards. The former unconditional outer ScrollView is gone. Narrow fixed compositions use a single-column overflow scroll region below 480 pt body width; the task page retains its own scrolling list.

Music centers the 60 pt artwork/metadata, compact timeline and 28 pt transport as one group with 6 pt gaps. Lyrics keep a 280 pt player and their own bounded scroll region. Focus centers the intrinsic native mode menu, 36 pt countdown, real progress and primary/reset actions. Water prioritizes the serving-labelled action in a 188 pt column; empty charts show an explicit message and real hour baseline. Prayer keeps its five schedule rows visible while `Lokasi & metode` / `Konfirmasi lokasi` opens a native disclosure popover with Settings.

Tasks use a full-width completion/Add row above their single scrolling list. The top-aligned composer places Save/Cancel 12 pt after due/error fields and closes only after successful persistence. Shelf shows a dashed drop zone only when empty, hovered or acknowledging an addition; populated idle tiles are unboxed, with 24 pt removal controls. Clipboard preserves its full opt-in limitation and visibly states that disabling deletes memory history. Widgets uses a full-width week, a quiet actionable task summary, then a compact real battery line.

Widgets projects the local week using Calendar day arithmetic, locale first weekday and Notchy incomplete due tasks only. It shows actual battery, no meetings/weather/calendar account. Nil battery has no percentage or zero ring. AC means connected; charging wording requires the IOKit charging flag.

## Motion and lifetime

One main-thread `ShellAnimator` requests updates only during active visible transitions. `ShellMotion` samples monotonic elapsed time through critically damped springs (omega 26/s growing, 32/s shrinking), retaining position and velocity across reversals. Its SIMD8 carries six real components: width, height, shoulder, bottom, neck width and neck height. Settle tolerance is 0.25 pt error and 2 pt/s for all six velocities, with an uninterrupted 0.8 s cap. A long frame gap, occlusion, wake, screen change or Reduce Motion applies the latest target directly. The 60 frameRate property is a scheduling hint, not measured FPS.

Every presentation sample sets the real window frame, path and fixed-host placement together, aligned to backing scale. SwiftUI receives destination layouts, never per-frame dimensions. Opening content waits 60 ms then fades 120 ms; closing fades 80 ms. Pages crossfade with a relative-order 12 pt horizontal translation over 160 ms. Reduce Motion uses opacity only for pages, at most 100 ms, and never dips whole-window alpha.

Hover opening requires a cancellable 150 ms dwell; exit cancels it and retains the 250 ms close grace. Explicit hide suppresses reopening until pointer exit/re-entry. Keyboard open and valid file-drag entry override suppression immediately.

Mascot eyes are original white marks, static when sleeping after five minutes. Wake gets one blink and at most 0.9 s fading blue-violet underglow. No endless animation, fake amplitude bars or telemetry. Feature timelines run only for visible advancing content; clocks use minute resolution.

Valid file-drag entry remembers the prior page and expands Shelf. Cancel restores the page; success keeps Shelf. Existing file bookmarks and original-file drag-out remain. Controller drafts survive page changes. Escape cancels new/edit task UI before dismissing. Menu tracking, file chooser, editing and slider guards hold the shell open. Shutdown stops the animator, timers, observers and controller adapter children.

## Evidence and limits

Eleven deterministic groups and a temporary native AppKit runner exercised the redesign. Own-view caches cover the pages, task composer plus notice, file tile, real paused/playing media, genuine lyrics-not-found, actual power state, and isolated no-notch/narrow compositions. Programmatic reversals and keyboard dispatch are not physical-input proof. Screen capture and System Events automation remain denied. Physical hover, transparent corner click-through, focus traversal/VoiceOver, Finder routing, trackpad gestures, Reduce Motion visuals, Spaces/display reconnection and motion profiling remain outstanding. See VERIFICATION.md; no smoothness or FPS acceptance claim.
