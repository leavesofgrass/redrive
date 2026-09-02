# How redrive works

## The pieces

| Piece | Where | What it does |
|---|---|---|
| Tray icon | `redrive.ps1 tray`, started at logon | Probes the tablet every few seconds, starts sync cycles, shows state, nudges you when things wait for the tablet. |
| Sync cycle | `redrive.ps1 sync` (a separate hidden process started by the tray) | Pull, OneNote, push, then the device window. |
| Mirror folder | `%USERPROFILE%\reMarkable`, mapped to `R:` with `subst` | A normal folder on your disk. Always there, even when the tablet is not. |
| State and logs | `%LOCALAPPDATA%\redrive` | `config.json`, `state\state.json`, `state\onenote-state.json`, `logs\redrive.log`, the SSH key and the tablet's known host key. |

## One sync cycle

1. **Reachable?** A TCP connect to 10.11.99.1:22 with a 1.5 s cap. The tablet drops its USB
   network whenever it sleeps, so nothing is kept alive; every cycle is a short burst of fresh
   connections.
2. **Harvest.** For every OneNote page that has a tablet copy with new handwriting (and every
   notebook written on the tablet), fetch the tablet-rendered PDF, turn the handwritten pages into
   PNG images with Windows' own PDF engine, and put them at the bottom of the OneNote page with the
   PDF attached. A previous harvest on the same page is replaced, not stacked.
3. **Pull.** One SSH command dumps every document's metadata; from it redrive rebuilds the
   folder tree, renames or moves local files that moved on the tablet, sends local copies of
   trashed documents to the Recycle Bin, and downloads the PDF of every new or changed document
   from the tablet's web interface (`/download/<id>/pdf`). Mirror files are marked read-only.
4. **OneNote export.** Pages whose `lastModifiedTime` is newer than the last export are published
   to PDF through OneNote's automation interface and uploaded under
   `OneNote/<notebook>/<section>`. A page that already has a tablet copy gets a new copy; the
   old one is retired to the tablet's trash (its handwriting was harvested in step 2). Pages in
   the "From reMarkable" section, password-protected sections and empty pages are skipped.
   OneNote must be running (redrive starts it if it is not); if it shows a dialog, the export
   waits for the next cycle.
5. **Push.** Any writable PDF/EPUB under the mirror is uploaded through the web interface. On
   current firmware uploads always land in the tablet's root folder, so filing into the right
   folder is queued for the device window.
6. **Device window.** If anything is queued (folder moves, new folders, renames, trashing, files
   copied over ssh), redrive stops the tablet app, moves the staged files into place, and starts
   it again. About ten seconds. It only does this when the tablet has been idle for two minutes,
   at most twice in ten minutes and never within five minutes of the last time, because the
   tablet reboots itself if its app is restarted more than four times in ten minutes.

## Why a copy instead of a live network drive

The tablet stores documents as files named by random IDs; a live mount shows those IDs, not
titles. And the tablet sleeps after 20 idle minutes and disconnects, so a live drive would hang
Explorer for most of the day. A local copy with real names is always available and survives
sleep; the tablet renders the handwriting for us, so nothing needs to be installed on the PC.

## Safety rules

- Deleting a file in the mirror never deletes it on the tablet.
- Before a document is replaced, its last rendering (with handwriting) is kept in `_Archive`.
- Replaced OneNote pages are trashed on the tablet, not erased; the tablet's Trash keeps them.
- `redrive.cmd backup` keeps a raw, incremental copy of the tablet's document store.
- The tablet's password is typed once into ssh itself and never stored. The key that replaces it
  lives in `%LOCALAPPDATA%\redrive\keys`, readable only by you.

## Files on the tablet

Everything lives under `/home/root/.local/share/remarkable/xochitl/`. redrive creates only two
things outside it: `~/.ssh/authorized_keys` (the key) and `/home/root/redrive-staging/` (files
waiting for a device window). Both survive tablet software updates.
