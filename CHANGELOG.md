# Changelog

## Native UX refinement (2026-11-06)

- Evaluated a below-camera status apron, then returned to camera-level status after the user rejected its downward extension. Final idle has the ring at left, 12 pt clock at right with 4 pt trailing padding and no media icon: 267 × 32 pt on the observed screen, versus the rejected 279 × 32 pt revision. It still uses menu-bar space; physical menu-click acceptance remains incomplete.
- Narrowed expanded bodies to match content: Fokus 360, Widgets 400, Musik/Shelf/Clipboard/Tugas 440, Air/Sholat 480 pt; lyrics remain 680 pt. Minimal preference is unchanged. Standalone notices retain the camera-width neck.
- Added mouse-only path-based event routing, cancellable 150 ms hover intent, explicit-hide suppression and immediate keyboard/file-drag override. Preserved the existing interruptible spring and motion/privacy policies.
- Retained the eight-page carousel with 12 pt directional translation/160 ms fade, opacity-only Reduce Motion, mounted page state and bounded navigation.
- Replaced duplicate expanded status with `Sembunyikan panel`; clarified the separate status-menu action as `Keluar dari Notchy`.
- Centered primary activity controls, replaced Prayer's schedule-swapping disclosure with a native popover, compacted utility summaries, reduced task editor height and retained drafts/save-failure behavior.
- Native isolated click scenarios, real media state restoration and genuine lyrics-not-found exercised. Physical Chrome menu clicks, motion recording and full accessibility/Spaces/Finder acceptance remain blocked or unverified; see VERIFICATION.md.

## Compact idle adjustment (2026-11-06)

- Reduced closed-mode width from camera + 100 to camera + 88, with 6 pt shoulders; no-notch body reduced from 188 to 160 pt.
- Increased compact clock from 11 to 12 pt; bounded 24-hour display prevents an AM/PM suffix from overflowing the camera-safe wing. Kept the battery ring and real play/pause state.
- Native closed renders and clock fitting checks passed for en_US, id_ID and ar_SA; all eleven selftest groups passed.

## Native visual redesign (2026-11-06)

- Connected concave-shoulder silhouette, compact mode-specific layouts, camera-safe header/menu, bounded page arrows and footer position indicators.
- One interruptible spring presentation owner with continuous position/velocity, direct occluded/Reduce Motion targets and no whole-window alpha dip.
- Separate Clipboard page, taller inline task composer with successful-save lifecycle, and local week/task/battery Widgets without calendar access or schema changes.
- Typed device/prayer events and compact notices appended below expanded content; IOKit charging flag separates AC connection from charging.
- Eleven deterministic groups pass; native own-view renders and programmatic interaction smoke pass. Physical desktop motion, focus, transparent-corner event routing and Finder/Spaces acceptance remain unverified.

## 1.0.0 (2026-11-06)

- Independent macOS 13+ accessory application with camera-aware notch geometry, hover/keyboard access, settings, optional idle mascot and status ring.
- System now-playing music control through pinned MediaRemote Adapter v0.7.7; opt-in LRCLIB synced/plain lyrics.
- Persisted focus deadlines, daily water records, file-bookmark Shelf, tasks and due reminders. Optional text-only clipboard history stays in memory.
- Local Kemenag-angle prayer calculations with manual location confirmation and opt-in reminders/music pause; power and Bluetooth output transition notices.
- Atomic local JSON storage with corrupt-file write protection, deterministic selftests, ad-hoc app signing and DMG packaging.
- Build, adapter runtime, data/action smoke paths, disk-image contents and graceful Quit verified. Native physical interaction, live synced lyrics and hardware-transition acceptance remain incomplete; see VERIFICATION.md.
