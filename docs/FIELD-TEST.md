# Field test: the first real tablet

redrive was built without a tablet in hand, against a simulated one. Every fact below that was
measured on the simulator or read from other people's notes must be confirmed once on a real
device. Budget about 45 minutes. Record every result in the table at the end and keep it with
the project.

You need: the tablet (developer mode on, USB web interface can be off), its USB cable, a Windows
PC with redrive unpacked, the tablet's password (Settings > General > Help > About > Copyrights
and licenses, under "GPLv3 Compliance"), and one small PDF to play with.

Open a PowerShell window in the redrive folder for the commands below (`.\redrive.cmd ...`).

## 1. Link and login

1. Plug the tablet in and tap the screen. Run `Get-NetAdapter` and `ipconfig`: which adapter
   appeared, and does this PC have a 10.11.99.x address? Run
   `Test-NetConnection 10.11.99.1 -Port 22`.
2. Run `C:\Windows\System32\OpenSSH\ssh.exe -v root@10.11.99.1 true` and note the line
   `remote software version dropbear_...`.
3. Run `Install.cmd`. Paste the password when asked. Note whether the key was accepted on the
   first try. Afterwards run `.\redrive.cmd doctor -Report` - everything should be PASS or INFO.

## 2. Tablet facts

Run `.\redrive.cmd ssh` and, on the tablet:

```
cat /etc/os-release; cat /etc/version; cat /usr/share/remarkable/update.conf 2>/dev/null
uname -m; df -h /home; grep WebInterfaceEnabled ~/.config/remarkable/xochitl.conf
cat /proc/net/tcp | grep ' 0A '            # 01630B0A:0050 means 10.11.99.1:80 is listening
ls /usr/libexec/sftp-server /usr/lib/openssh/sftp-server /usr/lib/ssh/sftp-server 2>/dev/null
systemctl show xochitl -p StartLimitBurst -p StartLimitIntervalUSec
exit
```

## 3. scp

```
C:\Windows\System32\OpenSSH\scp.exe -O -F $env:LOCALAPPDATA\redrive\ssh_config probe.pdf remarkable:/home/root/probe.pdf
C:\Windows\System32\OpenSSH\scp.exe -F $env:LOCALAPPDATA\redrive\ssh_config probe.pdf remarkable:/home/root/probe2.pdf
```

The first must succeed. Record the exact text if the second fails (expected: sftp-server not
found). Clean up with `.\redrive.cmd ssh "rm -f /home/root/probe*.pdf"` (quote remote commands
that contain options, otherwise PowerShell tries to read `-f` as one of redrive's own switches).

## 4. Web interface

```
curl.exe -sS -D - -H "Connection: close" http://10.11.99.1/documents/
```

Record the headers (charset, chunked) and the JSON keys of one entry.

## 5. Upload semantics

Create a folder called `Probe` on the tablet (on the tablet itself). Then:

```
curl.exe -sS http://10.11.99.1/documents/          # find the Probe folder ID
curl.exe -sS http://10.11.99.1/documents/<ProbeID>
curl.exe -sS -w "\n%{http_code}\n" -F "file=@probe.pdf;filename=Redrive Probe;type=application/pdf" http://10.11.99.1/upload
curl.exe -sS http://10.11.99.1/documents/ ; curl.exe -sS http://10.11.99.1/documents/<ProbeID>
```

Record: did the document land in Probe or at the root? What title does it have (extension or
not)? What `fileType`? How many seconds until it showed on the tablet, without any restart?

## 6. rmdoc upload (optional, decides whether restarts can disappear)

Build a zip named `probe.rmdoc` containing `<u>.metadata` (with `"parent": "<ProbeID>"` and a
title), `<u>.content` (`{"fileType": "pdf"}`), `<u>.pdf` and an empty folder `<u>/`, where
`<u>` is a fresh UUID. Upload it with `-F "file=@probe.rmdoc;type=application/zip"`. Record
whether the folder, the title and the file type were honoured.

## 7. Files copied over ssh

1. `.\redrive.cmd sync` with a PDF dropped into `R:\Probe\`. Watch the log
   (`.\redrive.cmd logs`): which strategy was used, did the document appear, did a "device
   window" run, how long did the tablet app take to come back?
2. Two minutes later: `.\redrive.cmd ssh "ls -la ~/.local/share/remarkable/xochitl/<uuid>*"` and
   `cat .../<uuid>.failure` if it exists. Record whether `.content` was rewritten by the tablet.

## 8. Handwriting round trip

1. Write on page 2 of the probe document on the tablet, wait 30 s, then list `<uuid>/` over ssh:
   which page got a non-empty `.rm` file, did `lastModified` in `.metadata` change?
2. `curl.exe -sS -o out.pdf -w "%{http_code} %{content_type}" http://10.11.99.1/download/<uuid>/pdf`
   and the same with `/placeholder` and `/rmdoc`. Record the codes, whether `out.pdf` shows the
   ink (and colours on a Paper Pro), the page size, and how long the download took. Repeat for an
   EPUB and for a notebook created on the tablet.
3. `.\redrive.cmd sync` again: does the mirror copy in `R:\` now show the ink?

## 9. Trash by metadata edit

`.\redrive.cmd window -Force` after staging a trash operation (drop a replacement PDF over a
mirrored file, or delete a page in OneNote that was exported). Confirm the old document shows in
the tablet's Trash afterwards.

## 10. Sleep

Leave the tablet plugged in and idle. Every 30 s run `.\redrive.cmd status`. Record when the
tablet first stops answering, whether tapping it brings it back (and after how many seconds),
and whether Windows re-enumerates the USB adapter. Record the Battery settings on the tablet.

## 11. OneNote overnight

Let the tray run for a full evening: OneNote pages exported in their folders on the tablet,
handwriting on them, next morning the images on the pages and the tablet copies refreshed.

## Results

| # | Item | Result |
|---|------|--------|
| 1 | adapter name / PC address / port 22 | |
| 2 | Dropbear version / key accepted first try | |
| 2 | firmware / arch / free space / web enabled / port 80 listening / sftp-server | |
| 3 | scp -O ok / scp without -O error text | |
| 4 | listing headers and keys | |
| 5 | upload folder / title / fileType / seconds until visible | |
| 6 | rmdoc: folder / title / fileType honoured | |
| 7 | strategy used / window seconds / .failure present / .content rewritten | |
| 8 | .rm per page / lastModified changed / pdf,placeholder,rmdoc codes / ink visible / seconds | |
| 9 | trash by metadata works | |
| 10 | sleep after / wake after / adapter re-enumerated | |
| 11 | overnight loop | |

If something differs from what redrive assumed, the switches in `%LOCALAPPDATA%\redrive\config.json`
(`DownloadFormats`, `PushStrategy`, `ReplacePolicy`, `RetireMode`, `ScpLegacyProtocol`) are the
first things to adjust; see TROUBLESHOOTING.md.
