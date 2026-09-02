# redrive

redrive keeps a reMarkable tablet and Microsoft OneNote in step over the tablet's USB cable,
with no subscription and no cloud account. Your tablet's documents appear as a drive letter on
your PC, complete with your handwriting. Drop a PDF into that drive and it is on the tablet a
few seconds later. Your OneNote pages travel to the tablet during the day; what you write on
them at night is back on the same OneNote pages in the morning.

It is a set of Windows PowerShell scripts. Nothing else needs to be installed.

New to all of this? Start with the step-by-step [Quick Start](docs/QUICK-START.md).

**Status:** version 0.1.0. Built and tested against a simulated tablet and a real OneNote; it
has not yet been run on a real reMarkable. If you have one, [docs/FIELD-TEST.md](docs/FIELD-TEST.md)
is the checklist, and the results are the most useful thing you can contribute right now.

**Download:** grab `redrive-<version>.zip` from the Releases page (or build it yourself with
`build\Make-Release.ps1`), unzip it, and follow the Quick Start.

## What you need

- A reMarkable tablet in Developer mode (Paper Pro family) or any reMarkable 1 or 2, plus its
  USB cable. See [docs/TABLET-SETUP.md](docs/TABLET-SETUP.md).
- Windows 10 or 11 with the desktop OneNote app (part of Microsoft 365 or the free OneNote
  download). The Microsoft Store "OneNote for Windows 10" does not count.
- Five minutes and the tablet's password (shown on the tablet, typed once).

## Setup in five minutes

1. Unzip redrive anywhere, for example your Documents folder.
2. Plug the tablet in and tap its screen so it is awake.
3. Double-click `Install.cmd`. Paste the tablet's password when asked.
4. Look for the coloured dot near the clock. Green means everything is in sync.

That is all. redrive starts with Windows from now on.

## Daily use

- **The reMarkable drive (R:)** shows the tablet's folders and documents as PDF files, handwriting
  included. They are read-only copies; the tablet is the original.
- **Send something to the tablet**: drop a PDF or EPUB into any folder of the drive. It is
  uploaded the next time the tablet is plugged in and awake. Files in `_Inbox` go to the
  tablet's top level.
- **OneNote**: every page in your open notebooks becomes a document on the tablet under
  `OneNote/<notebook>/<section>`. Only pages that changed are re-sent. When you write on such
  a document on the tablet, the writing is added to the bottom of the OneNote page as pictures,
  with the annotated PDF attached. Notebooks you start on the tablet itself show up in a
  "From reMarkable" section (those pages are never sent back to the tablet; the tablet has the
  original).
- **The tray icon**: grey = tablet not plugged in, yellow = tablet asleep (tap it),
  blue = syncing, green = up to date, orange = something needs attention, red = run Setup again.
  Right-click it for *Sync now*, *Doctor*, the log and *Pause*.
- **Deleting**: deleting a file from the drive does not delete it on the tablet (it comes back
  on the next sync). Delete on the tablet; the copy on the PC then moves to the Recycle Bin.

## When something is off

Right-click the tray icon and choose **Doctor**. It checks everything from the cable to
OneNote and prints the fix next to each problem. `Doctor` in the tray also copies a report to
the clipboard that you can paste into an email to whoever helps you.
More in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Command line

From the redrive folder: `redrive.cmd status`, `sync`, `doctor -Report`, `ssh`, `backup`,
`logs`, `mount`, `tray -Stop`, `uninstall`. `redrive.cmd help` lists them all.

## How it works, in one paragraph

The tablet keeps its documents as files named by random IDs plus a small index; redrive reads
that index over SSH and rebuilds the real folder names on your PC. For every document it asks
the tablet's own web interface for a PDF, which is why the handwriting looks exactly as it does
on the tablet. Uploads go through the same web interface. Anything the web interface cannot do
(filing into folders, renaming, trashing) is applied in one short "quiet moment" per sync in
which the tablet's app restarts: only when the tablet has been idle for two minutes, and at most
twice in ten minutes. Details in
[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Contributing and support

Something not working? Open an issue with the Doctor report (the issue template asks for it).
Want to help? See [CONTRIBUTING.md](CONTRIBUTING.md); the fake tablet in `harness\` lets you
develop without hardware.

## License

MIT. Not affiliated with reMarkable AS or Microsoft. The `.rm` test fixtures the harness
downloads come from the MIT-licensed [rmscene](https://github.com/ricklupton/rmscene) project.
