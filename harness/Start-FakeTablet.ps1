#requires -Version 5.1
<#
.SYNOPSIS
  Builds and starts the redrive fake tablet (Docker) and writes the "fake" profile config.

.DESCRIPTION
  - creates %LOCALAPPDATA%\redrive-fake\keys\id_redrive (RSA 4096, no passphrase) once
  - writes %LOCALAPPDATA%\redrive-fake\authorized_keys from the public key
  - writes harness\.env (REDRIVE_FAKE_HOME with forward slashes, FAKE_PROFILE)
  - fetches the .rm fixtures (best effort), runs "docker compose up -d --build"
  - waits for TCP 2222 and 8080, then writes %LOCALAPPDATA%\redrive-fake\config.json

  Run redrive against it with:  $env:REDRIVE_HOME = "$env:LOCALAPPDATA\redrive-fake"

.PARAMETER Profile
  paperpro-3.27 (default) or rm2-3.11. Only affects the system files unless the data
  volume is empty (use Reset-FakeTablet.ps1 to regenerate the sample data).
#>
[CmdletBinding()]
param(
    [ValidateSet("paperpro-3.27", "rm2-3.11")]
    [string]$Profile = "paperpro-3.27",
    [switch]$NoBuild,
    [int]$TimeoutSec = 180
)

$ErrorActionPreference = "Stop"
$harness = $PSScriptRoot
$fakeHome = Join-Path $env:LOCALAPPDATA "redrive-fake"
$keyDir = Join-Path $fakeHome "keys"
$mirror = Join-Path $fakeHome "mirror"
$keyPath = Join-Path $keyDir "id_redrive"
$pubPath = "$keyPath.pub"
$akPath = Join-Path $fakeHome "authorized_keys"
$cfgPath = Join-Path $fakeHome "config.json"
$envPath = Join-Path $harness ".env"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Wait-TcpPort {
    param([string]$HostName, [int]$Port, [int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $ar = $client.BeginConnect($HostName, $Port, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(1500) -and $client.Connected) {
                $client.Close()
                return $true
            }
        } catch {
        } finally {
            $client.Close()
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

foreach ($d in @($fakeHome, $keyDir, $mirror)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# 1. ssh key (RSA 4096 works with old and new Dropbear). ssh-keygen is called through
#    Start-Process because PowerShell 5.1 drops the empty -N "" argument when using &.
if (-not (Test-Path $keyPath)) {
    $keygen = Join-Path $env:SystemRoot "System32\OpenSSH\ssh-keygen.exe"
    if (-not (Test-Path $keygen)) { throw "Windows OpenSSH client not found: $keygen" }
    $argLine = "-q -t rsa -b 4096 -N `"`" -C redrive-fake -f `"$keyPath`""
    $p = Start-Process -FilePath $keygen -ArgumentList $argLine -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0 -or -not (Test-Path $pubPath)) { throw "ssh-keygen failed (exit $($p.ExitCode))" }
    Write-Host "generated ssh key: $keyPath"
} else {
    Write-Host "using existing ssh key: $keyPath"
}

# 2. authorized_keys for the container (LF, no BOM)
$pub = (Get-Content -Path $pubPath -Raw).Trim()
[System.IO.File]::WriteAllText($akPath, $pub + "`n", $utf8NoBom)

# 3. harness\.env for docker compose (Windows path with forward slashes). The public key
#    also travels in FAKE_AUTHORIZED_KEYS because Docker Desktop's view of a freshly
#    created Windows file can be stale, which turns a single-file bind into an empty dir.
$fakeHomeFwd = $fakeHome -replace "\\", "/"
$envText = "REDRIVE_FAKE_HOME=$fakeHomeFwd`nFAKE_PROFILE=$Profile`nFAKE_AUTHORIZED_KEYS=`"$pub`"`n"
[System.IO.File]::WriteAllText($envPath, $envText, $utf8NoBom)
Write-Host "wrote $envPath"

# 4. fixtures (best effort; the container synthesizes placeholders if they are missing)
try {
    & (Join-Path $harness "Get-Fixtures.ps1") | Out-Null
} catch {
    Write-Warning "Get-Fixtures.ps1 failed: $($_.Exception.Message)"
}

# 5. build + start
$composeArgs = @("compose", "--project-directory", $harness, "-f", (Join-Path $harness "docker-compose.yml"), "up", "-d")
if (-not $NoBuild) { $composeArgs += "--build" }
Write-Host ("docker " + ($composeArgs -join " "))
& docker @composeArgs
if ($LASTEXITCODE -ne 0) { throw "docker compose up failed with exit code $LASTEXITCODE" }

# 6. wait for ssh and the web interface
Write-Host "waiting for tcp 2222 (ssh) ..."
if (-not (Wait-TcpPort -HostName "127.0.0.1" -Port 2222 -Seconds $TimeoutSec)) {
    & docker logs redrive-fake-tablet
    throw "port 2222 did not open within $TimeoutSec s"
}
Write-Host "waiting for tcp 8080 (web ui) ..."
if (-not (Wait-TcpPort -HostName "127.0.0.1" -Port 8080 -Seconds 30)) {
    Write-Warning "port 8080 is not answering yet (the mock web ui may still be starting)"
}

# 7. config for redrive's "fake" profile
$cfg = [ordered]@{
    Profile           = "fake"
    Host              = "127.0.0.1"
    SshPort           = 2222
    User              = "root"
    WebBase           = "http://127.0.0.1:8080"
    DataDir           = "/home/root/.local/share/remarkable/xochitl"
    KeyPath           = $keyPath
    MirrorRoot        = $mirror
    DriveLetter       = ""
    UsbSubnet         = ""
    ScpLegacyProtocol = $true
    Harness           = $true
}
$json = $cfg | ConvertTo-Json
[System.IO.File]::WriteAllText($cfgPath, $json + "`n", $utf8NoBom)
Write-Host "wrote $cfgPath"
Write-Host ""
Write-Host "fake tablet is up:  ssh -i `"$keyPath`" -p 2222 root@127.0.0.1   (password login: fake)"
Write-Host "web interface:      http://127.0.0.1:8080/documents/"
Write-Host "redrive:            `$env:REDRIVE_HOME = `"$fakeHome`""
