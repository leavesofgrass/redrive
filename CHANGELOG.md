# Changelog

## 0.1.0 - 2026-09-02

First working version, built against a simulated tablet (see harness/) and OneNote on the
development PC. Needs its first run on a real reMarkable: docs/FIELD-TEST.md.

- One-time setup: key install with the tablet password typed once, private ssh config,
  drive letter, console-less tray launcher, logon task with Startup-folder fallback.
- Mirror folder shown as a drive letter: tablet folders and documents as tablet-rendered PDFs
  (handwriting included), renames and trash followed, dropped PDF/EPUB files uploaded.
- Device window: staged metadata edits, folder creation and copies applied in one short
  restart of the tablet app, idle-gated and budgeted against the Paper Pro restart limit.
- OneNote bridge: changed pages exported per page and pushed under OneNote/<notebook>/<section>;
  handwriting harvested back onto the source page (replacing the previous harvest) with the
  annotated PDF attached; tablet notebooks land in a "From reMarkable" section.
- Tray icon with state colours, balloon notifications, end-of-day nudge, pause.
- Doctor with a fix per line and a clipboard report; backup verb; optional raw mount.
- docs/QUICK-START.md: a step-by-step guide for people who have never used any of this.
- Tray: a refused key shows "The tablet refused the key - run Setup again", retries on its own
  every ten minutes and on "Sync now". Closing a notebook in OneNote no longer trashes its
  tablet copies (only deleting a page does).
