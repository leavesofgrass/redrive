# Contributing

redrive is Windows PowerShell 5.1 by design: it has to run on a stock office PC with nothing
installed. Keep it that way.

## Rules of the road

- Sources under `src\` are ASCII only. PowerShell 5.1 reads a BOM-less file as ANSI, so a
  stray non-ASCII character silently corrupts a string. CI fails on non-ASCII bytes there.
- Every external program (ssh, scp, curl, subst, ...) goes through `Invoke-RedriveNative`.
  Never call them with `&` and never read their stderr as a success signal.
- Anything that changes the tablet's document store goes through the staging directory and
  `Invoke-RedriveDeviceWindow`; never stop or restart xochitl anywhere else. The Paper Pro
  reboots itself after four starts in ten minutes.
- No jargon in user-facing text. The reader of a tray message or a Doctor line is an office
  worker; see docs/QUICK-START.md for the tone.

## Developing without a tablet

1. Start the fake tablet: `harness\Start-FakeTablet.ps1` (needs Docker Desktop). It writes a
   profile to `%LOCALAPPDATA%\redrive-fake`.
2. Point redrive at it: `redrive.cmd status -Profile fake` (or set `REDRIVE_HOME` to that
   folder).
3. Run the end-to-end script:
   `powershell -NoProfile -ExecutionPolicy Bypass -File tests\e2e-harness.ps1 -SkipOneNote`. Drop
   `-SkipOneNote` to include the OneNote bridge; restrict it to a throwaway notebook first by
   adding `"OneNote": {"Include": ["redrive-test"]}` to the fake profile's `config.json`.
4. Unit tests: `Invoke-Pester -Path tests` (Pester 5 or newer, `Install-Module Pester`).

See `harness\README.md` for the flags that make the fake tablet behave like older firmware.

## Before you open a pull request

- `tests\Redrive.Tests.ps1` passes and the parse check in `.github\workflows\ci.yml` is green.
- If you changed anything a user sees, update docs/QUICK-START.md or docs/TROUBLESHOOTING.md.
- If you touched device behaviour, add the line to docs/FIELD-TEST.md so it gets checked on a
  real tablet.

## Testing on a real tablet

Nothing here has been run on a real tablet yet. docs/FIELD-TEST.md is the checklist; please
attach its results table to your pull request or issue.
