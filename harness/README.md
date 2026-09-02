# redrive fake tablet (development harness)

A Docker container that imitates a reMarkable tablet closely enough to develop redrive
against without a device: Dropbear SSH (root, key or password `fake`, **no SFTP**), a
BusyBox userland in front of every remote command, a `systemctl` shim that models
`xochitl.service` including the Paper Pro start-rate limit, a mock of the USB web
interface as measured on firmware 3.27, and a realistic 3.x `xochitl` data directory.

Everything here is ASCII, stdlib-only and reproducible with `docker compose`.

## Start / stop / reset (Windows PowerShell 5.1, Docker Desktop)

```powershell
.\harness\Start-FakeTablet.ps1                  # build + start, default profile paperpro-3.27
.\harness\Start-FakeTablet.ps1 -Profile rm2-3.11
.\harness\Stop-FakeTablet.ps1                   # compose down, volumes kept
.\harness\Reset-FakeTablet.ps1                  # compose down -v (data + host keys wiped), start again
.\harness\Get-Fixtures.ps1                      # (re)download the v6 .rm fixtures (Start does this)
```

`Start-FakeTablet.ps1`:

1. creates `%LOCALAPPDATA%\redrive-fake\keys\id_redrive` (RSA 4096, no passphrase) once,
   via `C:\Windows\System32\OpenSSH\ssh-keygen.exe` called through `Start-Process`
   (PowerShell 5.1 drops the empty `-N ""` argument when using `&`);
2. writes `%LOCALAPPDATA%\redrive-fake\authorized_keys` from the `.pub`;
3. writes `harness\.env`: `REDRIVE_FAKE_HOME` (Windows path, forward slashes),
   `FAKE_PROFILE`, and `FAKE_AUTHORIZED_KEYS` (the public key line; see "Networking and
   mounts" for why it travels in the environment);
4. runs `docker compose up -d --build`, waits for TCP 2222 and 8080;
5. writes `%LOCALAPPDATA%\redrive-fake\config.json`:

```json
{ "Profile": "fake", "Host": "127.0.0.1", "SshPort": 2222, "User": "root",
  "WebBase": "http://127.0.0.1:8080", "DataDir": "/home/root/.local/share/remarkable/xochitl",
  "KeyPath": "C:\\Users\\<you>\\AppData\\Local\\redrive-fake\\keys\\id_redrive",
  "MirrorRoot": "C:\\Users\\<you>\\AppData\\Local\\redrive-fake\\mirror",
  "DriveLetter": "", "UsbSubnet": "", "ScpLegacyProtocol": true, "Harness": true }
```

Run redrive against it with `$env:REDRIVE_HOME = "$env:LOCALAPPDATA\redrive-fake"`.
`UsbSubnet` empty tells redrive to skip the USB adapter check.

Talk to it by hand (always use the Windows OpenSSH binaries, not the Git ones on PATH):

```powershell
$k = "$env:LOCALAPPDATA\redrive-fake\keys\id_redrive"
C:\Windows\System32\OpenSSH\ssh.exe -i $k -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL root@127.0.0.1 'systemctl is-active xochitl'
C:\Windows\System32\OpenSSH\scp.exe -O -i $k -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL .\file.pdf root@127.0.0.1:/home/root/
curl.exe -sS -D - http://127.0.0.1:8080/documents/
```

Add `-o BatchMode=yes` in scripts: if key auth ever fails, ssh otherwise falls back to a
password prompt and hangs.

## What is inside

| Piece | Where | Behaviour |
|---|---|---|
| `Dockerfile` | image | `debian:bookworm-slim` + `dropbear-bin openssh-client busybox-static python3 iproute2 ca-certificates`. `dropbear-bin` has no scp and no sftp-server; `openssh-client` only provides `/usr/bin/scp` for the remote side of `scp -O`. Root's home is `/home/root`, shell `/usr/local/bin/rmsh`, password `fake`. |
| `rmsh` | `/usr/local/bin/rmsh` | root's login shell: `PATH=/usr/local/busybox:/usr/local/bin:/usr/bin:/bin` then `exec busybox sh`, so every `ssh host 'cmd'` runs under BusyBox with BusyBox applets shadowing GNU tools (`ls --version` fails here before it fails on a tablet). |
| `entrypoint.sh` | `/opt/fake-tablet/` | adds `10.11.99.1/32` to `lo`, installs `authorized_keys` (0600), generates sample data into an empty volume, writes the per-profile system files on every boot, starts the fake xochitl, then `exec dropbear -F -E -R -p 22` (host keys generated on first connection into the `dropbear-keys` volume). |
| `systemctl` | `/usr/local/bin/systemctl` | only `xochitl`: `start`, `stop`, `restart` (stop, `FAKE_RESTART_SECONDS` gap, start), `is-active` (`active`/`inactive`, exit 0/3), `status`, `show`, `reset-failed`. Any other unit: `Unit X.service not found.` exit 5. The 5th start inside a rolling 10-minute window prints `Job for xochitl.service failed because start of the service was attempted too often.` and exits 1; `reset-failed` clears the counter. A `restart` that hits the limit leaves xochitl down (status `failed (Result: start-limit-hit)`), exactly the "stuck restart" case. Every action is logged to `/home/root/log.txt`. |
| `xochitl-fake.sh` | `/usr/local/bin/` | `start` writes `active` to `/run/fake-xochitl.state` and launches the mock web UI (new session, survives the ssh session); `stop` kills it and writes `inactive`. |
| `gen-sample-xochitl.py` | `/opt/fake-tablet/` | writes the sample `xochitl` directory, `/etc/version`, `/etc/os-release` (paperpro) or `/usr/share/remarkable/update.conf` (rm2), `xochitl.conf` and `/opt/fake-tablet/manifest.json`. |
| `mock-webui.py` | `/opt/fake-tablet/` | the USB web interface (see below). Logs every request to `/home/root/log.txt`; its own stderr goes to `/home/root/webui.log`. |

Ports: `2222 -> 22` (ssh), `8080 -> 80` (web). Volumes: `xochitl-data` (the data
directory), `dropbear-keys` (`/etc/dropbear`, so the host key stays stable until you
`Reset`, which changes it the way a firmware update does).

## Profiles and flags

Set in `harness\.env` or the shell before `docker compose up` (Start writes `FAKE_PROFILE`).

| Variable | Default | Effect |
|---|---|---|
| `FAKE_PROFILE` | `paperpro-3.27` | `paperpro-3.27`: `/etc/os-release` with `IMG_VERSION=3.27.3.5`, `MACHINE=ferrari`. `rm2-3.11`: `/usr/share/remarkable/update.conf` with `REMARKABLE_RELEASE_VERSION=3.11.2.5` plus a Codex-style `os-release` without `IMG_VERSION`. Both write `/etc/version` and add `FAKE_TABLET=1` to `os-release`. Changing the profile on an existing volume only rewrites the system files; `Reset` regenerates the data. |
| `FAKE_LIVE_SCAN` | `0` | `0`: the mock loads its catalog only when xochitl (re)starts, so files copied in over scp are invisible until `systemctl restart xochitl`. `1`: rescan on every request. |
| `FAKE_RESTART_SECONDS` | `8` | length of the restart gap during which the web UI is down and `is-active` says `inactive`. |
| `FAKE_STRIP_EXT` | `0` | `1`: an uploaded file's extension is stripped from the title (default: the filename is the title verbatim, extension included, as measured on 3.27). |
| `FAKE_UPLOAD_USES_LAST_FOLDER` | `0` | `1`: uploads land in the last folder listed via `/documents/{id}` instead of at root. |
| `FAKE_RMDOC_HONORS_PARENT` | `0` | `1`: an uploaded `.rmdoc` keeps the `parent` from its own `.metadata` (if that folder exists). |
| `FAKE_DUAL_FRAMING` | `0` | `1`: downloads send both `Content-Length` and `Transfer-Encoding: chunked` (chunked body), as the device does. |
| `FAKE_LEGACY_PLACEHOLDER` | `0` | `1`: `/download/{id}/placeholder` behaves like `/pdf` (2.x firmware) instead of returning 400. |
| `FAKE_IGNORE_CONF` | `0` | `1`: serve even if `WebInterfaceEnabled` is not `true` in `xochitl.conf`. By default the mock honours the setting: with `false` xochitl "runs" but opens no web socket, which is what a real tablet does. |
| `FAKE_AUTHORIZED_KEYS` | (from `.env`) | public key line(s) installed into `/home/root/.ssh/authorized_keys`. |

## The mock web interface (firmware 3.27 behaviour)

| Request | Response |
|---|---|
| `GET`/`POST /documents/` | JSON array of root entries |
| `GET`/`POST /documents/{id}` | children of folder `{id}`; **a non-folder id returns the root listing with 200** (quirk) |
| `POST /upload` (multipart, one part named `file`) | `201 {"status":"Upload successful"}`; missing part: `400 {"error":"No file sent"}`; not pdf/epub/rmdoc: `400 {"error":"Filetype not supported"}`. Creates uuid + `.metadata` + `.content` + file (+ `.pagedata`) and inserts it into the catalog immediately. Title = the part's filename verbatim; parent = root. A `.rmdoc` zip is imported with new uuids and the title from its own `.metadata`. |
| `GET /download/{id}/pdf` | the stored `.pdf`, or for notebooks/EPUBs a generated stand-in with one page per `.rm` (or `pageCount` pages), `Content-Type: application/pdf` |
| `GET /download/{id}/placeholder` | `400 {"error":"Filetype not supported"}` |
| `GET /download/{id}/rmdoc` | zip of `{id}.metadata`, `{id}.content`, `{id}.pagedata`, `{id}/*.rm` (+ `-metadata.json`) and the `.pdf`/`.epub`; `Content-Type: application/zip` |
| `GET /thumbnail/{id}` | a tiny PNG served as `Content-Type: image/jpeg` (the real lie) |
| `GET /log.txt` | `/home/root/log.txt` |
| anything else | `500 {"error":"Unknown file"}` |

Entry shape: documents
`{"Bookmarked":false,"CurrentPage":0,"ID":"...","ModifiedClient":"2026-09-01T14:00:00.000Z","Parent":"","Type":"DocumentType","VisibleName":"...","VissibleName":"...","fileType":"pdf"}`;
folders omit `CurrentPage`/`fileType` and have `Type: "CollectionType"`. Items with
`parent: "trash"` or `deleted: true` are omitted. Headers on every JSON reply:
`Content-Type: application/json; charset=ISO-8859-1` (the body is UTF-8) and
`Connection: close`.

## Sample data and manifest

`/opt/fake-tablet/manifest.json` maps titles to uuids (`titles`) and lists every entry
with type, parent and page ids (`entries`); it is refreshed on every boot from the data
directory, so uploaded documents appear in it too. Read it with
`docker exec redrive-fake-tablet cat /opt/fake-tablet/manifest.json`. The uuids are
deterministic for the default seed (`--seed 20260901`), so a `Reset` reproduces them:

| Title | Type | Parent | uuid | Notes |
|---|---|---|---|---|
| Work | folder | root | `d5ffead2-0555-4abc-b5f0-734ccd124d13` | `.content` = `{"tags": []}` |
| Projects | folder | Work | `895a456c-ad7f-4846-b9ed-461e8184ca63` | |
| Quarterly Report | pdf, 3 pages | Projects | `518f47a5-985c-4482-8a85-21704f0d50d2` | pages 1 and 3 carry real v6 ink (`Normal_AB.rm`, `Lines_v2.rm`), page 2 is the zero-byte `.rm` 3.x writes; `.pagedata` `Blank` per line; formatVersion-2 `cPages` `.content` |
| Sample Book | epub | root | `9e4d3acc-6194-46ac-9d1c-457c6fc9de06` | minimal valid EPUB, stored `mimetype` first; 4 paginated pages, no ink |
| Meeting notes | notebook, 2 pages | root | `01eb57ab-c958-4053-bacf-308b9cd4aac5` | real v6 ink on both pages, no PDF, `.local` = `{"contentFormatVersion": 2}` |
| Old draft | pdf | `trash` | `62f379ab-818d-452e-9400-ecf18c823717` | never listed by the web UI |
| (non-ASCII) | pdf, 1 page | root | `42ab6dbf-cb19-4dcd-8483-0a44a3ac9b56` | title is `R\u00e9sum\u00e9 \u2014 \u65e5\u672c\u8a9e \u2713` ("Resume", em dash, Japanese, check mark); no annotations |

`.metadata` uses the modern 3.x shape (`createdTime`, `lastModified`, `lastOpened` as
millisecond-epoch strings, `lastOpenedPage`, `parent`, `pinned`, `type`, `visibleName`;
folders omit `lastOpened`/`lastOpenedPage`). `--legacy` adds
`deleted/metadatamodified/modified/synced/version`.

The ink comes from rmscene's MIT test data (`Normal_AB.rm`, `Lines_v2.rm`,
`Bold_Heading_Bullet_Normal.rm`, `Normal_A_stroke_2_layers.rm`), fetched by
`Get-Fixtures.ps1` into `harness\fixtures\rm\` (git-ignored) and copied into the image;
the image build and the generator also try to download them. If every download fails the
generator writes a 43-byte placeholder (`reMarkable .lines file, version=6` padded with
spaces) and records `"placeholder"` in the manifest's `fixtures` section.

## Networking and mounts (things that differ from the original specification, and why)

- **The mock binds `10.11.99.1:80` and also the container's own interface** (e.g.
  `172.18.0.2:80`). Docker's published port `8080` connects to the container's bridge
  address, not to the loopback alias, so binding only `10.11.99.1` would make the web UI
  unreachable from Windows. Inside the container `http://10.11.99.1/documents/` answers,
  as on the real tablet. If neither bind works it falls back to `0.0.0.0:80`.
- **The public key is passed through the environment** (`FAKE_AUTHORIZED_KEYS` in
  `.env`), not only by bind-mounting `authorized_keys`. Two Docker Desktop facts forced
  this: a Windows bind mount shows up as mode `0777`, which Dropbear rejects for
  `~/.ssh/authorized_keys` (and a read-only mount cannot be `chmod`ed), and Docker
  Desktop's view of a freshly created Windows file can be stale, in which case a
  single-file bind silently becomes an empty directory. The file bind is still declared
  (`/opt/fake-tablet/authorized_keys.host:ro`) and merged in when it is a real file; the
  entrypoint logs what it used.
- `init: true` (tini) so `docker stop` terminates Dropbear promptly.

## Fidelity gaps

- **No sleep.** The tablet drops its USB network when it sleeps; the container never
  does. Simulate with `docker pause redrive-fake-tablet` / `docker unpause`.
- **A restart has no side effects on files.** Real xochitl rewrites `.content`, may
  write `{uuid}.failure` for files it does not like and updates thumbnails; the mock only
  reloads its catalog.
- **Renders contain no ink.** `/download/{id}/pdf` returns the stored PDF unchanged, or a
  text-only stand-in for notebooks and EPUBs; the `.rm` files are never rasterised.
- **No USB adapter on the Windows side.** Nothing appears in `Get-NetAdapter`, there is
  no `10.11.99.2`; redrive's config has `UsbSubnet` empty so the adapter check is skipped.
- **Debian's Dropbear is 2022.83**, newer than the 2019.78 on rM1/rM2 firmware (which
  only accepts `ssh-rsa` signatures and has no ed25519 host key). The harness host key is
  ed25519 and RSA keys are accepted with `rsa-sha2-256`, so the `+ssh-rsa` opt-ins are
  never exercised here.
- Unknown real behaviours were guessed and are easy to change in `mock-webui.py`: the
  order of listing entries (sorted by name here), the reply to an unsupported upload type,
  the `Server` header, and `Content-Disposition` on downloads.
- Wall time of `ssh ... 'systemctl restart xochitl'` from Windows is the 8 s gap plus
  ssh connection setup (about 10-13 s measured); the web UI itself is down for the gap only.
