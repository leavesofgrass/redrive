#requires -Version 5.1
<#
.SYNOPSIS
  Wipes the fake tablet (container, sample data volume, dropbear host keys) and starts
  it again with freshly generated sample data. The host key changes, which is what a
  real firmware update does too.
#>
[CmdletBinding()]
param(
    [ValidateSet("paperpro-3.27", "rm2-3.11")]
    [string]$Profile = "paperpro-3.27"
)

$ErrorActionPreference = "Stop"
$harness = $PSScriptRoot
if (-not $env:REDRIVE_FAKE_HOME -and -not (Test-Path (Join-Path $harness ".env"))) {
    $env:REDRIVE_FAKE_HOME = (Join-Path $env:LOCALAPPDATA "redrive-fake") -replace "\\", "/"
}
& docker compose --project-directory $harness -f (Join-Path $harness "docker-compose.yml") down -v
if ($LASTEXITCODE -ne 0) { throw "docker compose down -v failed with exit code $LASTEXITCODE" }
Write-Host "fake tablet removed (data + host keys wiped); starting again ..."
& (Join-Path $harness "Start-FakeTablet.ps1") -Profile $Profile
