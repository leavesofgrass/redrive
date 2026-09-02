# Connection.ps1 - reachability, SSH, scp and the tablet's web interface (ASCII only)

$script:RedriveDeviceMutex = $null
$script:RedriveSshVersion = $null

function Get-RedriveOpenSshExe {
    param([Parameter(Mandatory)][string]$Name)
    $p = Get-RedrivePaths
    $exe = Join-Path $p.OpenSsh "$Name.exe"
    if (Test-Path -LiteralPath $exe) { return $exe }
    $cmd = Get-Command "$Name.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "Windows OpenSSH program $Name.exe was not found (expected in $($p.OpenSsh)). Install 'OpenSSH Client' under Settings > Apps > Optional features."
}

function Get-RedriveSshVersion {
    if ($script:RedriveSshVersion) { return $script:RedriveSshVersion }
    $v = [version]'0.0'
    try {
        $r = Invoke-RedriveNative -FilePath (Get-RedriveOpenSshExe 'ssh') -Arguments @('-V') -TimeoutSec 10 -Quiet
        $text = $r.StdErr + $r.StdOut
        if ($text -match 'OpenSSH[_a-zA-Z ]*?(\d+)\.(\d+)') { $v = [version]("$($Matches[1]).$($Matches[2])") }
    }
    catch { }
    $script:RedriveSshVersion = $v
    return $v
}

function ConvertTo-RedriveSshPath { param([string]$WindowsPath) return ($WindowsPath -replace '\\', '/') }

function Update-RedriveSshConfig {
    # (Re)writes the private ssh_config from the current configuration. Returns its path.
    $cfg = Get-RedriveConfig
    $p = Initialize-RedriveHome
    $lines = @(
        'Host remarkable',
        "    HostName $($cfg.Host)",
        "    Port $($cfg.SshPort)",
        "    User $($cfg.User)",
        ('    IdentityFile "{0}"' -f (ConvertTo-RedriveSshPath $cfg.KeyPath)),
        '    IdentitiesOnly yes',
        ('    UserKnownHostsFile "{0}"' -f (ConvertTo-RedriveSshPath $p.KnownHosts)),
        '    StrictHostKeyChecking accept-new',
        '    ServerAliveInterval 5',
        '    ServerAliveCountMax 3',
        '    ConnectTimeout 5',
        '    HostKeyAlgorithms +ssh-rsa',
        '    PubkeyAcceptedKeyTypes +ssh-rsa',
        '    LogLevel ERROR'
    )
    Write-RedriveTextFile -Path $p.SshConfig -Content (($lines -join "`n") + "`n")
    return $p.SshConfig
}

function Get-RedriveSshBaseArgs {
    $p = Get-RedrivePaths
    if (-not (Test-Path -LiteralPath $p.SshConfig)) { Update-RedriveSshConfig | Out-Null }
    return @('-F', $p.SshConfig, '-o', 'BatchMode=yes')
}

function Enter-RedriveDeviceLock {
    param([int]$TimeoutSec = 180)
    if (-not $script:RedriveDeviceMutex) { $script:RedriveDeviceMutex = New-Object System.Threading.Mutex($false, 'Local\redrive-device') }
    try { return $script:RedriveDeviceMutex.WaitOne($TimeoutSec * 1000) }
    catch [System.Threading.AbandonedMutexException] { return $true }
}

function Exit-RedriveDeviceLock {
    if ($script:RedriveDeviceMutex) { try { $script:RedriveDeviceMutex.ReleaseMutex() } catch { } }
}

function Reset-RedriveKnownHosts {
    param([string]$Reason = 'requested')
    $p = Get-RedrivePaths
    if (Test-Path -LiteralPath $p.KnownHosts) { Remove-Item -LiteralPath $p.KnownHosts -Force -ErrorAction SilentlyContinue }
    Write-RedriveLog -Level Warn -Component 'ssh' -Message "known_hosts reset ($Reason); the tablet's host key will be accepted again on the next connection"
}

function Invoke-RedriveSsh {
    <# Runs one remote command over ssh.exe in batch mode. Returns the native result hashtable. #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSec = 30,
        $StdIn = $null,
        [switch]$NoRetry
    )
    $ssh = Get-RedriveOpenSshExe 'ssh'
    $sshArgs = (Get-RedriveSshBaseArgs) + @('remarkable', $Command)
    $locked = Enter-RedriveDeviceLock
    try {
        $r = Invoke-RedriveNative -FilePath $ssh -Arguments $sshArgs -TimeoutSec $TimeoutSec -StdIn $StdIn
        if ($r.ExitCode -ne 0 -and -not $NoRetry -and ($r.StdErr -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed')) {
            Reset-RedriveKnownHosts -Reason 'host key changed (firmware update or factory reset?)'
            $r = Invoke-RedriveNative -FilePath $ssh -Arguments $sshArgs -TimeoutSec $TimeoutSec -StdIn $StdIn
        }
        return $r
    }
    finally { if ($locked) { Exit-RedriveDeviceLock } }
}

function Invoke-RedriveSshScript {
    <# Runs a multi-line BusyBox sh script on the tablet (fed through stdin, so quoting is never an issue). #>
    param([Parameter(Mandatory)][string]$Script, [int]$TimeoutSec = 60)
    $text = ($Script -replace "`r`n", "`n")
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    # a leading newline keeps the first statement intact even if a stray BOM ever reaches the shell
    return (Invoke-RedriveSsh -Command 'sh -s' -TimeoutSec $TimeoutSec -StdIn ("`n" + $text))
}

function Get-RedriveScpLegacyFlag {
    $cfg = Get-RedriveConfig
    $mode = [string]$cfg.ScpLegacyProtocol
    if ($mode -eq 'auto' -or $mode -eq '') { return ((Get-RedriveSshVersion) -ge [version]'9.0') }
    return ($mode -match '^(true|1|yes)$')
}

function ConvertTo-RedriveRemoteArg {
    param([string]$RemotePath)
    if ($RemotePath -match '[\s''"]') { return ("'" + ($RemotePath -replace "'", "'\''") + "'") }
    return $RemotePath
}

function Copy-RedriveToDevice {
    <# scp local file(s) to a remote directory or file path. #>
    param([Parameter(Mandatory)][string[]]$Path, [Parameter(Mandatory)][string]$Destination, [int]$TimeoutSec = 600, [switch]$Recurse)
    $scp = Get-RedriveOpenSshExe 'scp'
    $p = Get-RedrivePaths
    if (-not (Test-Path -LiteralPath $p.SshConfig)) { Update-RedriveSshConfig | Out-Null }
    $a = @('-F', $p.SshConfig, '-o', 'BatchMode=yes', '-q')
    if (Get-RedriveScpLegacyFlag) { $a += '-O' }
    if ($Recurse) { $a += '-r' }
    $a += $Path
    $a += ('remarkable:' + (ConvertTo-RedriveRemoteArg $Destination))
    $locked = Enter-RedriveDeviceLock
    try { return (Invoke-RedriveNative -FilePath $scp -Arguments $a -TimeoutSec $TimeoutSec) }
    finally { if ($locked) { Exit-RedriveDeviceLock } }
}

function Copy-RedriveFromDevice {
    <# scp a remote file (or directory with -Recurse) to a local path. #>
    param([Parameter(Mandatory)][string]$RemotePath, [Parameter(Mandatory)][string]$Destination, [int]$TimeoutSec = 600, [switch]$Recurse)
    $scp = Get-RedriveOpenSshExe 'scp'
    $p = Get-RedrivePaths
    if (-not (Test-Path -LiteralPath $p.SshConfig)) { Update-RedriveSshConfig | Out-Null }
    $a = @('-F', $p.SshConfig, '-o', 'BatchMode=yes', '-q')
    if (Get-RedriveScpLegacyFlag) { $a += '-O' }
    if ($Recurse) { $a += '-r' }
    $a += ('remarkable:' + (ConvertTo-RedriveRemoteArg $RemotePath))
    $a += $Destination
    $locked = Enter-RedriveDeviceLock
    try { return (Invoke-RedriveNative -FilePath $scp -Arguments $a -TimeoutSec $TimeoutSec) }
    finally { if ($locked) { Exit-RedriveDeviceLock } }
}

function Test-RedriveDevice {
    <# Cheap reachability probe: USB adapter address present, then TCP connect to the SSH port. Never blocks long. #>
    param([int]$TimeoutMs = 0)
    $cfg = Get-RedriveConfig
    if (-not $TimeoutMs) { $TimeoutMs = [int]$cfg.Probe.TimeoutMs }
    $adapterUp = $true; $localIp = $null
    if ($cfg.UsbSubnet) {
        $adapterUp = $false
        try {
            foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
                if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
                foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
                    if ($ua.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                        $ip = $ua.Address.ToString()
                        if ($ip.StartsWith([string]$cfg.UsbSubnet)) { $adapterUp = $true; $localIp = $ip }
                    }
                }
            }
        }
        catch { $adapterUp = $true }
    }
    $port = $false; $latency = $null
    if ($adapterUp) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $ar = $client.BeginConnect([string]$cfg.Host, [int]$cfg.SshPort, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { $client.EndConnect($ar); $port = $true }
        }
        catch { $port = $false }
        finally { try { $client.Close() } catch { } }
        $latency = $sw.ElapsedMilliseconds
    }
    $state = if (-not $adapterUp) { 'Unplugged' } elseif (-not $port) { 'Asleep' } else { 'Reachable' }
    return [pscustomobject]@{ AdapterUp = $adapterUp; LocalIp = $localIp; Port22 = $port; Reachable = $port; LatencyMs = $latency; State = $state }
}

function Test-RedriveTcpPort {
    param([Parameter(Mandatory)][string]$TargetHost, [Parameter(Mandatory)][int]$Port, [int]$TimeoutMs = 1500)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { $client.EndConnect($ar); return $true }
        return $false
    }
    catch { return $false }
    finally { try { $client.Close() } catch { } }
}

function Test-RedriveSshAuth {
    <# Verifies key login. Returns @{ Ok; Reason; Detail } where Reason is Ok | NeedsSetup | Unreachable | HostKey | Error #>
    $r = Invoke-RedriveSsh -Command 'echo REDRIVE_AUTH_OK' -TimeoutSec 20
    if ($r.StdOut -match 'REDRIVE_AUTH_OK') { return @{ Ok = $true; Reason = 'Ok'; Detail = '' } }
    $err = $r.StdErr.Trim()
    $reason = 'Error'
    if ($err -match 'Permission denied') { $reason = 'NeedsSetup' }
    elseif ($err -match 'timed out|No route to host|Connection refused|Network is unreachable|Could not resolve') { $reason = 'Unreachable' }
    elseif ($err -match 'IDENTIFICATION HAS CHANGED|Host key verification failed') { $reason = 'HostKey' }
    elseif ($r.TimedOut) { $reason = 'Unreachable' }
    return @{ Ok = $false; Reason = $reason; Detail = $err }
}

# ---------------------------------------------------------------- web interface (curl.exe)

function Get-RedriveCurlExe {
    $c = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $c) { return $c }
    $cmd = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-RedriveWeb {
    <#
      Talks to the tablet's USB web interface through curl.exe.
      Returns @{ Ok; StatusCode; ContentType; Body (text, when no -OutFile); OutFile; Error }.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [string]$OutFile = $null,
        [string]$FormFile = $null,
        [string]$FormFileName = $null,
        [string]$FormType = 'application/pdf',
        [int]$TimeoutSec = 120
    )
    $cfg = Get-RedriveConfig
    $curl = Get-RedriveCurlExe
    if (-not $curl) { return @{ Ok = $false; StatusCode = 0; ContentType = ''; Body = ''; OutFile = $null; Error = 'curl.exe not found' } }
    $base = ([string]$cfg.WebBase).TrimEnd('/')
    $url = $base + $Path
    $tmpOut = if ($OutFile) { "$OutFile.part" } else { [IO.Path]::GetTempFileName() }
    $a = @('-sS', '--connect-timeout', '5', '--max-time', "$TimeoutSec", '-H', 'Connection: close', '-H', 'Expect:')
    if ($FormFile) {
        $fname = if ($FormFileName) { $FormFileName } else { [IO.Path]::GetFileName($FormFile) }
        $fname = $fname -replace '"', '\"'
        $a += @('-H', "Origin: $base", '-H', "Referer: $base/", '-F', ('file=@{0};filename="{1}";type={2}' -f $FormFile, $fname, $FormType))
    }
    elseif ($Method -eq 'POST') { $a += @('-X', 'POST') }
    $a += @('-o', $tmpOut, '-w', '%{http_code} %{content_type}', $url)
    $locked = Enter-RedriveDeviceLock
    try { $r = Invoke-RedriveNative -FilePath $curl -Arguments $a -TimeoutSec ($TimeoutSec + 15) }
    finally { if ($locked) { Exit-RedriveDeviceLock } }
    $code = 0; $ctype = ''
    if ($r.StdOut -match '^\s*(\d{3})\s*(.*)$') { $code = [int]$Matches[1]; $ctype = $Matches[2].Trim() }
    $out = @{ Ok = ($code -ge 200 -and $code -lt 300 -and $r.ExitCode -eq 0); StatusCode = $code; ContentType = $ctype; Body = ''; OutFile = $null; Error = '' }
    if ($r.ExitCode -ne 0) { $out.Error = ("curl exit {0}: {1}" -f $r.ExitCode, $r.StdErr.Trim()) }
    try {
        if ($OutFile) {
            if ($out.Ok -and (Test-Path -LiteralPath $tmpOut)) {
                if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
                Move-Item -LiteralPath $tmpOut -Destination $OutFile -Force
                $out.OutFile = $OutFile
            }
            else {
                if (Test-Path -LiteralPath $tmpOut) {
                    try { $out.Body = [IO.File]::ReadAllText($tmpOut, [Text.Encoding]::UTF8) } catch { }
                    Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
                }
            }
        }
        else {
            if (Test-Path -LiteralPath $tmpOut) {
                $out.Body = [IO.File]::ReadAllText($tmpOut, [Text.Encoding]::UTF8)
                Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch { if (-not $out.Error) { $out.Error = $_.Exception.Message } }
    return $out
}

function Test-RedriveWeb {
    $r = Invoke-RedriveWeb -Path '/documents/' -TimeoutSec 15
    return ($r.Ok -and $r.Body.TrimStart().StartsWith('['))
}

function Get-RedriveWebListing {
    <# Lists one folder of the web interface ('' = root). Returns an array of normalised entries. #>
    param([string]$FolderId = '')
    $path = if ($FolderId) { "/documents/$FolderId" } else { '/documents/' }
    $r = Invoke-RedriveWeb -Path $path -TimeoutSec 30
    if (-not $r.Ok) { throw "web interface listing failed ($($r.StatusCode)) $($r.Error)" }
    $items = @()
    # PowerShell 5.1 emits a top-level JSON array as ONE pipeline object; assign first, then wrap
    try { $parsed = $r.Body | ConvertFrom-Json; $items = @($parsed) } catch { throw "web interface returned no JSON for $path" }
    $list = @()
    foreach ($it in $items) {
        if ($null -eq $it) { continue }
        $name = $null
        foreach ($k in @('VisibleName', 'VissibleName')) { if ($it.PSObject.Properties[$k]) { $name = [string]$it.$k; break } }
        $parent = ''; if ($it.PSObject.Properties['Parent']) { $parent = [string]$it.Parent }
        $ft = ''; if ($it.PSObject.Properties['fileType']) { $ft = [string]$it.fileType }
        $mod = ''; if ($it.PSObject.Properties['ModifiedClient']) { $mod = [string]$it.ModifiedClient }
        $list += [pscustomobject]@{
            Id = [string]$it.ID; Name = $name; Type = [string]$it.Type; Parent = $parent
            IsFolder = ([string]$it.Type -eq 'CollectionType'); FileType = $ft; Modified = $mod
        }
    }
    # the tablet answers with the ROOT listing for a non-folder id: detect and refuse
    if ($FolderId -and $list.Count -gt 0 -and (@($list | Where-Object { $_.Parent -eq $FolderId }).Count -eq 0) -and (@($list | Where-Object { $_.Parent -eq '' }).Count -gt 0)) {
        throw "web interface returned the root listing for folder $FolderId (not a folder?)"
    }
    return $list
}

function Send-RedriveWebUpload {
    <# Uploads a PDF/EPUB (or .rmdoc) through the web interface. Returns the web result plus the new entry when found. #>
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string]$Title, [string]$FolderId = '', [string]$ContentType = $null)
    if (-not $ContentType) {
        $ext = [IO.Path]::GetExtension($FilePath).ToLower()
        $ContentType = switch ($ext) { '.pdf' { 'application/pdf' } '.epub' { 'application/epub+zip' } '.rmdoc' { 'application/zip' } default { 'application/octet-stream' } }
    }
    if ($FolderId) { try { Get-RedriveWebListing -FolderId $FolderId | Out-Null } catch { Write-RedriveLog -Level Debug -Component 'web' -Message "pre-listing folder failed: $($_.Exception.Message)" } }
    $before = @{}
    foreach ($e in (Get-RedriveWebListing -FolderId '')) { $before[$e.Id] = $true }
    if ($FolderId) { try { foreach ($e in (Get-RedriveWebListing -FolderId $FolderId)) { $before[$e.Id] = $true } } catch { } }
    $r = Invoke-RedriveWeb -Path '/upload' -FormFile $FilePath -FormFileName $Title -FormType $ContentType -TimeoutSec 300
    $found = $null
    if ($r.Ok) {
        $candidates = @()
        foreach ($e in (Get-RedriveWebListing -FolderId '')) { if (-not $before.ContainsKey($e.Id)) { $candidates += $e } }
        if ($FolderId) { try { foreach ($e in (Get-RedriveWebListing -FolderId $FolderId)) { if (-not $before.ContainsKey($e.Id)) { $candidates += $e } } } catch { } }
        if ($candidates.Count -eq 1) { $found = $candidates[0] }
        elseif ($candidates.Count -gt 1) {
            $byName = @($candidates | Where-Object { $_.Name -eq $Title -or $_.Name -eq ($Title + [IO.Path]::GetExtension($FilePath)) })
            $found = if ($byName.Count -ge 1) { $byName | Sort-Object Modified -Descending | Select-Object -First 1 } else { $candidates | Sort-Object Modified -Descending | Select-Object -First 1 }
        }
    }
    $r['Entry'] = $found
    return $r
}

function Get-RedriveWebRender {
    <# Downloads the tablet-rendered PDF (with handwriting) for a document. Tries every configured format. #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$OutFile, [int]$TimeoutSec = 300)
    $cfg = Get-RedriveConfig
    $last = $null
    foreach ($fmt in @($cfg.DownloadFormats)) {
        $r = Invoke-RedriveWeb -Path "/download/$Id/$fmt" -OutFile $OutFile -TimeoutSec $TimeoutSec
        $last = $r
        if ($r.Ok -and (Test-Path -LiteralPath $OutFile)) {
            $fs = [IO.File]::OpenRead($OutFile)
            try { $buf = New-Object byte[] 5; $n = $fs.Read($buf, 0, 5) } finally { $fs.Close() }
            if ($n -ge 4 -and [Text.Encoding]::ASCII.GetString($buf, 0, 4) -eq '%PDF') { $r['Format'] = $fmt; return $r }
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            $r.Ok = $false; $r.Error = 'response was not a PDF'
        }
    }
    return $last
}
