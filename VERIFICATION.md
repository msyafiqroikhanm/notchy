# Verification

## Current refinement, final user direction (2026-11-06)

The below-camera apron was implemented and checked, then rejected by the user because it extended too far downward. Final idle returns to camera-level left/right status, with shorter wings and no idle media icon. Expanded content-specific widths and page/action refinements remain.

### Final geometry and native rendering

- Actual built-in screen: 1470 × 956 pt, camera gap 179 pt, safe-area top 32 pt, backing scale 2.
- Final actual NotchPanel idle bounds after clock-spacing feedback: **267 × 32 pt**. Each usable wing is 40 pt: ring at left, 12 pt semibold 24-hour clock at right with 4 pt trailing padding. Native pixel assertions found status only outside the camera footprint and a 5.5 pt ink-to-body-right gap in the captured time. Previous 259 × 32 pt rendering verified resting did not grow downward and explicit minimal remained **179 × 32 pt**; the spacing patch changes neither height nor minimal geometry.
- Clock fitting sizes including 4 pt trailing padding: en_US 40 × 15 pt, id_ID 40 × 15 pt, ar_SA 37 × 15 pt, all within the 40 pt wing. These are native fitting checks, not three localized desktop captures.
- Final idle cache: `dist/verification/refinement/idle-final-wings.png`. Earlier `compact-*.png` caches in that directory show the superseded apron and are not the final idle design.
- Observed expanded window widths, including shoulders: Musik/Shelf/Clipboard/Tugas 476 pt, Fokus 396 pt, Air/Sholat 516 pt, Widgets 436 pt. Lyrics retain their 716 pt window; the task editor uses a 440 pt body and header + 204 pt height.
- All eight views were rendered with actual ShellContainer/NSHostingView at normal width, body width 348 and total height 150. No-notch full-header rendering and menu-bar-offset model assertions passed. `matrix/final-clamped-*.png` supersedes the early clamped captures.
- Matrix evidence found a mounted Music minimum-height overflow that displaced every page's header/footer. Music now uses a local controls-only overflow viewport; the final matrix preserved header/footer. Lyrics keep a separate viewport, not a nested outer lyric scroll.
- Height-clamped Focus puts primary controls first. Duplicate shared storage errors were removed only on pages already displaying the same error locally. Latest Focus/Water errors retain header/footer and controls; actual NSScrollView scrolling reaches remaining error content. Failed task persistence retains draft/editor, with complete Save/Cancel at normal height and reachable actions when clamped.
- Current error-state captures: `matrix/latest-focus-error-normal*.png`, `matrix/latest-water-error-normal*.png`, `matrix/latest-task-failed-normal.png`, and `matrix/final-task-failed-clamped-scrolled.png`. Superseded error caches are findings, not final acceptance.

### Exercised native actions

These were isolated in-process AppKit event dispatch and controller scenarios, not physical desktop clicks:

| Scenario | Observed result |
| --- | --- |
| Side arrows and Command-Option arrows | All eight pages traversed; both ends stopped without wrapping |
| Synthetic precise scroll gestures | One change on gesture end; none during began/changed; strict 40 pt / 1.5:1 threshold; vertical, cancellation, momentum and nonprecise rejection |
| Editing/interaction/file drag guards | Native NSTextView, interaction hold and active drag blocked swipe; drag cancellation restored page |
| Short hover scheduling | Enter scheduled work; exit after 70 ms cancelled it; shell stayed closed |
| Shared-path input | Mask/highlight paths matched; hitTest and real-file NSDraggingInfo fixture rejected transparent notice wings, accepted the apron and forwarded the unchanged original file URL |
| Keyboard/file-drag entry | Expanded immediately and cancelled pending hover |
| Header hide button | Collapsed the shell without terminating; same instance reopened |
| Status menu | Actual menu contained `Keluar dari Notchy` with the existing quit selector; Quit was not invoked against the production instance |
| Focus | Native Start, Pause and Reset clicks changed the real isolated session correctly |
| Water | Native Drink and Undo clicks added/removed the actual isolated record |
| Prayer | Native disclosure click opened a real popover; page change dismissed it and released only its interaction ownership |
| Task Add | Native Add opened a composer; new draft survived page changes; Escape cancelled UI without storing it |
| Task edit/notice/error | Edit draft survived page changes and notice arrival/expiry; native failed Save retained editor; actual atomic-write failure also retained draft; Escape preserved stored tasks |
| Shelf | Real temporary file reference rendered; original bytes stayed intact; native missing-file Remove cleared only the reference |
| Clipboard | Native Activate, Copy and Disable used a named pasteboard; copied confirmation rendered; disable emptied memory history |

Actual battery was 80%, AC connected, not actively charging. Nil hardware state was not injected through private setters; the existing device/model checks cover unavailable data, not a new nil-hardware UI capture. Injected-fetch lyric captures are explicitly `FIXTURE` states: synced parser, plain, HTTP 404/not-found and thrown error. Long metadata fixtures are isolated, not claims of live playback.

### Real media integration

The adapter reported `KELANA BENTALA - Eps. 3  Lembah Lohe, Negeri Dongeng Sulawesi`, artist Arsal Bahtiar, playing. A real toggle paused, the next toggle resumed; command error remained nil. Original playing state was restored, then seek restored the captured position: 1511.997214 s requested, 1512.355271 s observed after the wait. Real opt-in LRCLIB lookup returned `notFound`; `music-real-playing.png`, `music-real-paused.png` and `lyrics-real-result.png` record that integration. No live synced result was invented.

### Motion, privacy and unavailable acceptance

Both mouse-only monitor registrations returned nonnil tokens; shutdown cleared both tokens, pending hover work and animator. No Accessibility/Input Monitoring request, event tap or global keyboard monitor was added. A visible permission-dialog absence cannot be verified from this session.

The native input runner was occluded and correctly used direct targets. Its settled driver stopped, ring/media content updates did not restart it, and sampling across an actual minute boundary observed no restart. Runtime animated reversals numbered zero in that runner. Six-component spring continuity and exact settling passed deterministic checks; visible motion, frame pacing and FPS remain unaccepted.

Desktop capture still fails with `could not create image from display`. Sustained physical hover, inside-pointer dismiss suppression, moving-boundary reconciliation, Chrome menu visibility/click-through, physical trackpad input, focus traversal/VoiceOver, Finder, Reduce Motion visuals, Spaces and transition recording remain blocked or unexercised. Final status wings still consume menu-bar space. Native own-view caches and programmatic events do not overrule those limits.

### Final checks and artifacts

`./build.sh selftest` passed all eleven existing groups against final source. `./build.sh dmg` rebuilt the ad-hoc signed app and DMG. App verification (`codesign --verify --deep --strict`) and disk-image checksum verification passed. The DMG was additionally ad-hoc signed and its signature verified; this is not notarization.

The production instance (PID 92145, adapter child 92161) remained running throughout. It was not force-quit because its unsaved state could not be safely established. The updated app is at `dist/Notchy.app`, disk image at `dist/Notchy.dmg`; the existing instance must be quit normally and reopened to use the new binary.

### Design gate evidence

- Purpose/identity: native black camera-level silhouette, existing palette/system type and per-mode action hierarchy retained; no copied assets, dependency, schema or permission added.
- Rendering/resilience: final idle, all eight pages, narrower/clamped compositions, disclosure and genuine error paths exercised in native caches.
- Functional checks: action-by-action results above; live media state restored and fixture storage isolated.
- Accessibility/physical-input gate: incomplete, not reported as PASS. Source guards/focus styles are retained, but hidden-page accessibility traversal and physical menu routing are not proven.

## Historical evidence below

The following sections describe earlier builds. The 279 × 32 pt compact revision did not solve the user's menu-bar complaint.

## Compact idle adjustment

After the redesign, the user reported that the closed shell covered too much menu-bar space. The running window measured 295 × 32 pt. Closed geometry now uses camera + 88 pt body width and 6 pt shoulders: the native window measured 279 × 32 pt, with 44 pt wings outside the unchanged 179 pt camera footprint. No-notch body width is 160 pt; expanded, resting and minimal geometry is unchanged.

The compact clock increased from 11 to 12 pt and uses a bounded 24-hour format. Native NSHostingView fitting widths were 35 pt (en_US), 35 pt (id_ID), and 33 pt (ar_SA), each leaving room for the 3 pt gap and 5 pt media icon inside the 44 pt wing. Both paused/playing renders were inspected from own-view caches; this does not prove that every menu arrangement is unobstructed on the physical desktop. All eleven selftest groups passed after the change.

Current compact caches: `dist/verification/redesign/compact-paused.png` and `compact-playing.png`. Measurements in the earlier redesign section below refer to the preceding build.

## Native redesign, 2026-11-06

The redesigned implementation builds and passes deterministic and in-process native smoke checks. Physical desktop acceptance is incomplete. Own-view cache renders and programmatic event dispatch are not proof of transparent click-through, physical focus traversal, Finder drag routing or smoothness.

## Deterministic checks

`./build.sh selftest` passed all eleven groups before NSApplication startup. Tests use temporary JSON/UserDefaults storage; no production JSON, settings or clipboard mutations.

| Group | Checked behavior |
| --- | --- |
| Shell geometry/motion | Native profiles, no-notch header, minimal camera coverage, screen-edge clamping, exact settled endpoint, ten mid-flight position/velocity-continuous reversals, visible camera clearance, Reduce Motion/occlusion policy, points inside/outside the same concave-shoulder path |
| WidgetWeek | Year/month-crossing week, locale first weekday, DST local-midnight dates, exact incomplete due-day dots, completed/undated exclusion, overdue/upcoming ordering, empty state and local-midnight transition |
| Media | Fragmented NDJSON, diffs/null deletion, full-state reset, malformed record preservation, record size limit, elapsed interpolation/freeze/clamp, seek-zero contract |
| Lyrics | LRC timestamps/offsets, query safety, instrumental/plain/404/errors, opt-in and stale-result rejection |
| Focus/storage | Deadline pause/resume and sleep/relaunch semantics, failed saves retain state, corrupt storage protection |
| Tasks | Due ordering, completion, once-only reminder/rearm, rejected draft/edit retention, successful persistence before clearing/closing the editor |
| Water | Local midnight, undo, target/active-hour gating, coalescing and overflow rejection |
| Shelf | Bookmark references, deduplication, missing files and original-file preservation |
| Clipboard | Opt-in text policy, secret/transient/autogenerated exclusion, distinct memory-only cap |
| Prayer | Jakarta reference tolerance, undefined solar events, boundaries, gate and wake rules, typed prayer/time/prealert assertions with delivery markers preserved |
| Devices | First-observation silence, duplicate suppression, typed power/Bluetooth events, unavailable battery, true charging vs AC/unknown flag/unplugged wording |

No old `showPill`, `pillDestination`, `shell.pill`, `onPill` or `targetSize` API remains under Sources/Notchy.

## Native baseline and composition

The baseline app launched through `./build.sh run`. CoreGraphics/AppKit reported the built-in screen as 1470 × 956 pt, scale 2, safe-area top 32 pt, auxiliary areas 646 and 645 pt wide (camera gap 179 pt). The previous closed window was 299 × 32 pt. A second unnotched screen was present, but the app intentionally prefers the built-in screen.

A temporary, assertion-enabled native runner compiled the actual application sources with Swift's macOS 13 deployment target. It created NSApplication, NotchPanel, NSHostingView and the real controllers with isolated storage. It captured each of the eight pages plus resting/closed, task composer + prayer notice, long task, real temporary file tile, power notice and live lyrics-not-found. Captures are in `dist/verification/redesign/`. Task/notice/file fixtures are isolated test data; the media/battery observations below are real integration data.

Observed panel frames:

| State | Actual window bounds size |
| --- | --- |
| Resting | 219 × 50 pt |
| Closed | 295 × 32 pt |
| Expanded | 556 × 196 pt |
| Lyrics | 716 × 252 pt |
| Task editor + notice | 556 × 320 pt |
| Standalone power notice | 364 × 92 pt |

These sizes include both shoulders; body dimensions are smaller by twice the shoulder radius. Native cache composition was also inspected for a 520 pt no-notch body and a 348 pt narrow body using isolated ShellState layouts, not a claim of actual display switching. Narrow fixed pages use vertical overflow scrolling. Full-desktop capture failed with `could not create image from display`; System Events rejected Apple Events with -1743. Cached view images do not establish native transparent-corner event routing.

## Exercised native scenarios

- Constructed and rendered every page while all feature trees remained mounted.
- Task edit expanded the profile; a 44 pt notice strip appeared below it; notice expiry removed the strip without losing the unsaved draft. Cancel returned to the normal task profile.
- Ten rapid programmatic open/close reversals ended expanded, with the final bounds at the target.
- Command-Option-Right dispatched through `NotchPanel.sendEvent` advanced Fokus to Air and stopped at Widgets rather than wrapping. This is not physical Tab/focus traversal proof.
- Programmatic valid-file drag entry selected Shelf; cancellation restored Fokus. A successful temporary-file drop kept Shelf selected; original bytes matched after adding the bookmark.
- An additional real-panel transition scenario changed presentation bounds 167 times over repeated requests. Its animation driver was stopped after the final target settled. Subsequent ring updates and same-size page changes did not restart it. After `orderOut`, closing applied target geometry directly with no active driver.
- The installed Time Profiler was attempted through `xctrace record --template 'Time Profiler'`; its process ended with signal 9 and no usable trace output. No FPS, frame pacing, recording or synchronous-work trace conclusion is claimed.

## Real data and media integration

The adapter reported `Separuh Aku`, artist `Noah - Topic`, initially paused. Play became true with no command error; pause became false; seek returned exactly 10.0 seconds. The original paused state and position were restored afterward (185.631175 seconds in this run).

An isolated opt-in lyrics request performed a real LRCLIB lookup and returned `notFound`; the UI rendered `Lirik tidak ditemukan`. No synced lyric match was available. Parser/highlight behavior passed deterministic fixtures, not live synced playback acceptance.

IOKit reported 80% battery, AC connected and `isCharging=false`. The Widgets page and notice used `Daya tersambung`, not charging wording. No physical charger or Bluetooth transition was manufactured or exercised.

## Accessibility and visual checks

The shared contrast checker reported secondary #A6A6AE on black 8.69:1; black on focus #B49AFF 9.01:1, water #67D7FF 12.74:1 and green #33D17A 10.54:1. Focus outlines use white. Cache inspection covered page hierarchy, fitting main actions/footer, readable disclosures and opt-in/empty states, long task/file truncation with full-text help, real music and lyrics-not-found. These checks do not constitute a full interactive accessibility audit.

The Impeccable context launcher ran successfully but misclassified native macOS as web. Native source/render checks were used; its HTML/CSS detector was not used or claimed.

## Final artifacts and lifecycle

`./build.sh dmg` produced `dist/Notchy.app` and `dist/Notchy.dmg`; `codesign --verify --deep --strict dist/Notchy.app` passed. No installation or repository initialization occurred.

The final app was launched directly with `--open`. Observed app PID 86620 and adapter child PID 86626 were running. A real Quit Apple Event returned 0; app exit was 0; the adapter child was absent afterward. No adapter processes remained after the smoke runs. No runtime log errors were emitted in that final lifecycle check.

## Still blocked or unverified

- Physical hover/reversal, halfway pause/reopen and visible frame pacing. Programmatic bounds checks are narrower evidence.
- Physical transparent shoulder/corner click-through and drop-event routing at a moving boundary.
- Physical keyboard focus outlines/traversal, VoiceOver, text-field Escape interactions and the keyboard-pinned file picker.
- Trackpad gesture thresholds and one-page-on-end on real hardware; vertical-scroll coexistence on lists/lyrics.
- Finder drag-out, actual display reconnect, no-notch screen selection, normal/fullscreen Spaces and Reduce Motion visuals.
- Live synced lyric playback, actual charger/active-charging/Bluetooth changes, exhaustive long-media-title/error-state screenshots.
- Motion recording and a usable Time Profiler/Core Animation trace. The scheduling hint of 60 Hz is not performance evidence.

## Privacy and scope

The app remains independent with AppDelegate-owned feature controllers, local atomic storage and the existing lyrics/clipboard opt-in gates. Widgets uses only local dates, Notchy tasks and the existing DeviceMonitor. No Calendar service, schema fields, permissions, notification scraping, dependencies or copied Nusa assets/source were added. mac-protection was not edited during this redesign.
