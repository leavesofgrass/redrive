#requires -Version 5.1
<#
.SYNOPSIS
  Downloads the real v6 .rm fixtures (rmscene MIT test data) into harness\fixtures\rm\.

.DESCRIPTION
  The fake tablet needs a few genuine reMarkable v6 .lines files so that the sample
  documents carry real ink data. They are borrowed from rmscene's test suite
  (https://github.com/ricklupton/rmscene, MIT). If a download fails the container
  falls back to a 43-byte placeholder header at generation time and notes it in
  /opt/fake-tablet/manifest.json.

  Safe to run repeatedly; existing files larger than the placeholder are kept.
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$base = "https://raw.githubusercontent.com/ricklupton/rmscene/main/tests/data/"
$names = @("Normal_AB.rm", "Lines_v2.rm", "Bold_Heading_Bullet_Normal.rm", "Normal_A_stroke_2_layers.rm")
$dest = Join-Path $PSScriptRoot "fixtures\rm"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$failed = @()
foreach ($n in $names) {
    $target = Join-Path $dest $n
    if (-not $Force -and (Test-Path $target) -and ((Get-Item $target).Length -gt 43)) {
        Write-Host "fixture present: $n"
        continue
    }
    try {
        Invoke-WebRequest -Uri ($base + $n) -OutFile $target -UseBasicParsing -TimeoutSec 30
        Write-Host ("fixture downloaded: {0} ({1} bytes)" -f $n, (Get-Item $target).Length)
    } catch {
        Write-Warning ("fixture download failed: {0}: {1}" -f $n, $_.Exception.Message)
        $failed += $n
        if (Test-Path $target) { Remove-Item $target -Force }
    }
}

if ($failed.Count -gt 0) {
    Write-Warning ("{0} fixture(s) missing; the container will synthesize placeholders: {1}" -f $failed.Count, ($failed -join ", "))
    exit 1
}
exit 0
