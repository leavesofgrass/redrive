#requires -Version 5.1
<#
.SYNOPSIS
  Stops and removes the fake tablet container. Data and host-key volumes are kept
  (use Reset-FakeTablet.ps1 to wipe them).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$harness = $PSScriptRoot
if (-not $env:REDRIVE_FAKE_HOME -and -not (Test-Path (Join-Path $harness ".env"))) {
    # compose needs the variable to parse the file even for "down"
    $env:REDRIVE_FAKE_HOME = (Join-Path $env:LOCALAPPDATA "redrive-fake") -replace "\\", "/"
}
& docker compose --project-directory $harness -f (Join-Path $harness "docker-compose.yml") down
if ($LASTEXITCODE -ne 0) { throw "docker compose down failed with exit code $LASTEXITCODE" }
Write-Host "fake tablet stopped (volumes kept)"
