# Make-Release.ps1 - builds dist\redrive-<version>.zip, the file end users unzip and double-click Install in.
# Run from anywhere: powershell -NoProfile -ExecutionPolicy Bypass -File build\Make-Release.ps1
# The zip has the files at its top level, so "Extract All" produces one folder named redrive-<version>.
# Entries are written with forward slashes (Compress-Archive in PowerShell 5.1 writes backslashes,
# which unpack as flat, oddly named files on macOS and Linux).
param([string]$OutputDir = '')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $root 'dist' }
$manifest = Import-PowerShellDataFile (Join-Path $root 'src\Redrive.psd1')
$version = [string]$manifest.ModuleVersion

$files = @()
foreach ($f in @('README.md', 'LICENSE', 'CHANGELOG.md', 'CONTRIBUTING.md', 'Install.cmd', 'redrive.cmd', 'redrive.ps1')) { $files += @{ Path = (Join-Path $root $f); Entry = $f } }
foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $root 'src') -File)) { $files += @{ Path = $f.FullName; Entry = "src/$($f.Name)" } }
foreach ($d in @('QUICK-START.md', 'TABLET-SETUP.md', 'TROUBLESHOOTING.md', 'HOW-IT-WORKS.md', 'FIELD-TEST.md')) { $files += @{ Path = (Join-Path $root "docs\$d"); Entry = "docs/$d" } }

if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$zip = Join-Path $OutputDir "redrive-$version.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f.Path)) { throw "missing file: $($f.Path)" }
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.Path, $f.Entry, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
}
finally { $archive.Dispose() }
$size = [math]::Round((Get-Item -LiteralPath $zip).Length / 1KB)
Write-Host "built $zip ($($files.Count) files, $size KB)"
