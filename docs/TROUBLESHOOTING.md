# Troubleshooting

Start with **Doctor**: right-click the tray icon > Doctor, or `redrive.cmd doctor -Report`.
Each line ends with a fix. The report is copied to the clipboard for you to paste into an email.

## The tray icon

| Colour | Meaning | What to do |
|---|---|---|
| grey | no tablet on the cable | plug it in with a data-capable cable |
| yellow | tablet asleep | tap the screen; sync resumes within seconds |
| blue | syncing | wait; hover for progress |
| green | up to date | nothing |
| orange | sync keeps failing | Doctor |
| red | the tablet refused the key | run Install.cmd again (after a factory reset or some updates) |

## Doctor lines and their fixes

- **Windows OpenSSH client** missing: Settings > Apps > Optional features > add "OpenSSH
  Client". Install.cmd offers to do it with an admin prompt.
- **USB network adapter** missing: charging-only cable, loose plug, or the tablet is asleep.
  If Device Manager shows an unknown "RNDIS" or "USB Ethernet" device with a warning: right-click
  > Update driver > Browse my computer > Let me pick > Network adapters > Microsoft >
  "USB Ethernet/RNDIS Gadget".
- **Tablet answers on 10.11.99.1**: fails while the tablet sleeps. Tap it.
- **Known host key**: after a tablet software update the tablet has a new identity; redrive
  forgets the old one by itself. If it did not: `redrive.cmd doctor -ForgetHostKey`.
- **Key login**: "NeedsSetup" means the tablet no longer has redrive's key (factory reset, or
  Developer mode was turned off and on). Run Install.cmd again.
- **USB web interface**: Install.cmd turns it on; you can also enable it on the tablet under
  Settings > Storage. Without it, documents still sync but without handwriting.
- **Tablet restart budget**: informational. redrive waits before restarting the tablet app again;
  queued changes are applied at the next quiet moment.
- **Drive R: shows the mirror** failing because the letter is in use: edit
  `%LOCALAPPDATA%\redrive\config.json`, change `DriveLetter`, then Exit and restart the tray.
- **OneNote desktop**: OneNote must be the desktop app and must be able to open. Close any dialog
  OneNote is showing. Do not run redrive as administrator if OneNote is not (or vice versa).
- **Traffic to the tablet uses the USB link** warning: a VPN captures 10.11.99.x. Disconnect the
  VPN, or ask IT for a split-tunnel exception for 10.11.99.0/24.

## Common situations

**The drive is empty.** The first sync copies every document, one every couple of seconds; a
full tablet takes a few minutes. Hover the tray icon for progress. If it stays empty, Doctor.

**A file I dropped in R: did not appear on the tablet.** It is uploaded only while the tablet is
awake and plugged in (the tray nudges you). It also has to be a PDF or EPUB. Files in folders
starting with `_` (except `_Inbox`) are ignored on purpose.

**My document is at the tablet's top level instead of its folder.** Current tablet software puts
every upload at the top level; redrive files it into the folder at the next device window (a
quiet moment when the tablet app restarts). Leave the tablet plugged in and idle for a couple
of minutes, or run `redrive.cmd window -Force` while nobody is using it.

**OneNote pages do not show up on the tablet.** The section may be password-protected (those are
skipped), a sensitivity label or a company data-loss policy may block PDF export, or the
notebook is not fully downloaded yet (open it in OneNote and let it sync). `redrive.cmd logs`
shows the reason per page.

**Handwriting did not come back into OneNote.** Harvesting needs the web interface (Doctor line
"Web interface"), the tablet plugged in and awake, and OneNote free of dialogs. Pages in
password-protected sections are skipped entirely, and a page in a read-only section cannot be
updated; `redrive.cmd logs` shows the reason per page.

**The tablet restarted its app by itself.** That is the device window. It happens at most twice in
ten minutes and only while the tablet is idle. Set `AllowRestart` to `false` in `config.json` to
forbid it entirely; folder filing and trashing then stay queued until you run
`redrive.cmd window -Force`.

**After a tablet software update nothing syncs.** Doctor. Usually the new host key is accepted
automatically; if the key login fails, run Install.cmd again.

## Switches in config.json

`%LOCALAPPDATA%\redrive\config.json` (the tray's *Settings file* menu item opens it):

| Key | Default | Meaning |
|---|---|---|
| `DriveLetter` | `R` | drive letter for the mirror; empty = folder only |
| `MirrorRoot` | `%USERPROFILE%\reMarkable` | where the copies live |
| `SyncIntervalMinutes` | 5 | how often to sync while the tablet is awake |
| `AllowRestart` | true | allow the device window (tablet app restart) |
| `MaxRestartsPer10Min` / `MinMinutesBetweenRestarts` | 2 / 5 | restart budget |
| `DownloadFormats` | `["pdf","placeholder"]` | render paths to try; older firmware may need `placeholder` first |
| `PushStrategy` | `["web","scp"]` | upload through the web interface, else copy over ssh |
| `ReplacePolicy` | `NewCopyRetireOld` | or `InPlace` |
| `RetireMode` | `Trash` | or `Archive` (kept under `OneNote/_Archive`) or `Keep` |
| `ScpLegacyProtocol` | `auto` | force `true` if copies over ssh fail with an sftp error |
| `OneNote.Enabled` | true | the OneNote bridge |
| `OneNote.Include` / `Exclude` | `[]` | notebook or `Notebook/Section` patterns, `*` allowed |
| `OneNote.FromRemarkableNotebook` / `FromRemarkableSection` | first notebook / `From reMarkable` | where tablet notebooks land |
| `Log.Level` | `Info` | `Debug` shows every command |

Restart the tray (Exit, then it starts again at logon or with `redrive.cmd tray`) after editing.

## Where things are

- Log: `%LOCALAPPDATA%\redrive\logs\redrive.log` (`redrive.cmd logs`)
- Doctor reports: `%LOCALAPPDATA%\redrive\logs\doctor-*.txt`
- State: `%LOCALAPPDATA%\redrive\state\`
- Backups: `%LOCALAPPDATA%\redrive\backup\` (`redrive.cmd backup`)
- Kept renderings of replaced documents: `<mirror>\_Archive`
