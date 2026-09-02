# Doctor.ps1 - ordered health checks with a fix for every failure (ASCII only)

function New-RedriveCheck {
    param([string]$Id, [string]$Name, [ValidateSet('PASS', 'FAIL', 'WARN', 'SKIP', 'INFO')][string]$Status, [string]$Detail = '', [string]$Fix = '')
    return [pscustomobject]@{ Id = $Id; Name = $Name; Status = $Status; Detail = $Detail; Fix = $Fix }
}

function Invoke-RedriveDoctor {
    <# Runs every check and returns the list. Use Format-RedriveDoctor to print it. #>
    param([switch]$ForgetHostKey, [scriptblock]$Progress = $null)
    $checks = New-Object System.Collections.ArrayList
    $cfg = $null
    $add = { param($c) [void]$checks.Add($c); if ($Progress) { & $Progress $c } }
    $p = Get-RedrivePaths

    # 1 environment
    $psv = $PSVersionTable.PSVersion
    if ($psv.Major -eq 5 -and $psv.Minor -ge 1) { & $add (New-RedriveCheck 'ps' 'Windows PowerShell 5.1' 'PASS' "$psv") }
    else { & $add (New-RedriveCheck 'ps' 'Windows PowerShell 5.1' 'WARN' "$psv" 'redrive is built for Windows PowerShell 5.1 (powershell.exe); other versions are untested') }
    if (Test-RedriveElevated) { & $add (New-RedriveCheck 'elev' 'Not running as administrator' 'WARN' 'this console is elevated' 'Drives created by an elevated process are invisible to Explorer and OneNote. Run redrive from a normal (non-admin) window.') }
    else { & $add (New-RedriveCheck 'elev' 'Not running as administrator' 'PASS') }

    # 2 OpenSSH client
    try {
        $ssh = Get-RedriveOpenSshExe 'ssh'
        $v = Get-RedriveSshVersion
        & $add (New-RedriveCheck 'ssh' 'Windows OpenSSH client' 'PASS' "$ssh (OpenSSH $v)")
    }
    catch { & $add (New-RedriveCheck 'ssh' 'Windows OpenSSH client' 'FAIL' $_.Exception.Message 'Settings > Apps > Optional features > add "OpenSSH Client", or run Setup again (it can install it with an admin prompt).'); return @($checks) }

    # 3 config, folders, key
    try {
        $cfg = Get-RedriveConfig -Reload
        & $add (New-RedriveCheck 'cfg' 'Configuration' 'PASS' $p.Config)
    }
    catch { & $add (New-RedriveCheck 'cfg' 'Configuration' 'FAIL' $_.Exception.Message "Fix or delete $($p.Config) and run Setup again."); return @($checks) }
    if (Test-Path -LiteralPath $cfg.MirrorRoot) {
        $free = ''
        try { $di = New-Object IO.DriveInfo(([IO.Path]::GetPathRoot($cfg.MirrorRoot))); $free = ('{0:N1} GB free' -f ($di.AvailableFreeSpace / 1GB)) } catch { }
        & $add (New-RedriveCheck 'mirror' 'Mirror folder' 'PASS' "$($cfg.MirrorRoot) ($free)")
    }
    else { & $add (New-RedriveCheck 'mirror' 'Mirror folder' 'FAIL' "$($cfg.MirrorRoot) does not exist" 'Run Setup again (it creates the folder), or create it yourself.') }
    if ((Test-Path -LiteralPath $cfg.KeyPath) -and (Test-Path -LiteralPath "$($cfg.KeyPath).pub")) { & $add (New-RedriveCheck 'key' 'SSH key pair' 'PASS' $cfg.KeyPath) }
    else { & $add (New-RedriveCheck 'key' 'SSH key pair' 'FAIL' "$($cfg.KeyPath) missing" 'Run Setup again to create the key and install it on the tablet.') }

    # 4 USB adapter and port
    $probe = Test-RedriveDevice
    if (-not $cfg.UsbSubnet) { & $add (New-RedriveCheck 'usb' 'USB network adapter' 'SKIP' 'adapter check disabled (harness or custom host)') }
    elseif ($probe.AdapterUp) { & $add (New-RedriveCheck 'usb' 'USB network adapter' 'PASS' "this PC has $($probe.LocalIp) on the tablet link") }
    else { & $add (New-RedriveCheck 'usb' 'USB network adapter' 'FAIL' 'no network adapter with a 10.11.99.x address' 'Plug the tablet in with a data-capable USB cable and wake it (tap the screen). If Device Manager shows an unknown "RNDIS" or "USB Ethernet" device, update its driver: Browse > Let me pick > Network adapters > Microsoft > USB Ethernet/RNDIS Gadget.') }
    if ($probe.Reachable) { & $add (New-RedriveCheck 'port' "Tablet answers on $($cfg.Host):$($cfg.SshPort)" 'PASS' "$($probe.LatencyMs) ms") }
    else {
        $why = if ($probe.AdapterUp) { 'the link is up but the tablet does not answer: it is probably asleep' } else { 'no link' }
        & $add (New-RedriveCheck 'port' "Tablet answers on $($cfg.Host):$($cfg.SshPort)" 'FAIL' $why 'Tap the tablet to wake it (it drops the USB network while asleep), or unplug and re-plug the cable. Then run Doctor again.')
        return @($checks)
    }

    # 5 host key and login
    if ($ForgetHostKey) { Reset-RedriveKnownHosts -Reason 'doctor -ForgetHostKey'; & $add (New-RedriveCheck 'hostkey' 'Known host key' 'INFO' 'forgotten; it will be accepted again on the next connection') }
    $auth = Test-RedriveSshAuth
    if ($auth.Ok) { & $add (New-RedriveCheck 'auth' 'Key login (ssh)' 'PASS') }
    else {
        $fix = switch ($auth.Reason) {
            'NeedsSetup' { 'The tablet does not accept the key (it was reset, or the key was never installed). Run Setup again and paste the tablet password once.' }
            'HostKey' { 'The tablet identity changed (firmware update or reset). Run: redrive doctor -ForgetHostKey' }
            'Unreachable' { 'Tap the tablet to wake it and try again.' }
            default { 'See the log (redrive logs) for the ssh error text.' }
        }
        & $add (New-RedriveCheck 'auth' 'Key login (ssh)' 'FAIL' "$($auth.Reason): $($auth.Detail)" $fix)
        return @($checks)
    }

    # 6 device information
    $info = Get-RedriveDeviceInfo
    if ($info.ok) {
        & $add (New-RedriveCheck 'fw' 'Tablet software' 'INFO' ("firmware {0}, {1}, {2}" -f $(if ($info.firmware) { $info.firmware } else { 'unknown' }), $info.arch, $(if ($info.model) { $info.model } else { 'model unknown' })))
        if ($cfg.ContainsKey('DeviceFirmware') -and $cfg.DeviceFirmware -and ($cfg.DeviceFirmware -ne $info.firmware)) { & $add (New-RedriveCheck 'fwchg' 'Firmware changed since Setup' 'WARN' "$($cfg.DeviceFirmware) -> $($info.firmware)" 'Expected after an update. If something stopped working, run Setup again.') }
        if ($info.datadir_ok -eq '1') { & $add (New-RedriveCheck 'data' 'Document store' 'PASS' ("{0} documents, {1:N0} MB free" -f $info.docs, ([double]$info.free_kb / 1024))) }
        else { & $add (New-RedriveCheck 'data' 'Document store' 'FAIL' "$($cfg.DataDir) not found" 'Unexpected firmware layout; please report it with this Doctor output.') }
        if ($info.xochitl -eq 'active') { & $add (New-RedriveCheck 'xochitl' 'Tablet app (xochitl) running' 'PASS') }
        else { & $add (New-RedriveCheck 'xochitl' 'Tablet app (xochitl) running' 'WARN' "state: $($info.xochitl)" 'If the tablet screen is stuck, hold the power button to restart it.') }
        if ($info.web_enabled -match '^[1-9]') { & $add (New-RedriveCheck 'webcfg' 'USB web interface enabled' 'PASS') }
        else { & $add (New-RedriveCheck 'webcfg' 'USB web interface enabled' 'WARN' 'WebInterfaceEnabled is not true' 'Run Setup again (it turns it on), or enable it on the tablet under Settings > Storage.') }
        if ($info.sftp_server) { & $add (New-RedriveCheck 'sftp' 'SFTP server on the tablet' 'INFO' "$($info.sftp_server) (raw mount possible)") }
        else { & $add (New-RedriveCheck 'sftp' 'SFTP server on the tablet' 'INFO' 'none (normal; scp is used instead)') }
        if ([int]$info.staged -gt 0) { & $add (New-RedriveCheck 'staged' 'Changes waiting on the tablet' 'INFO' "$($info.staged) file(s) staged; they are applied at the next quiet moment (needs a restart of the tablet app)") }
    }
    else { & $add (New-RedriveCheck 'fw' 'Tablet software' 'WARN' $info.error 'Could not read tablet details over ssh; see the log.') }

    # 7 web interface reachable
    if (Test-RedriveWeb) { & $add (New-RedriveCheck 'web' "Web interface at $($cfg.WebBase)" 'PASS') }
    else { & $add (New-RedriveCheck 'web' "Web interface at $($cfg.WebBase)" 'WARN' 'not answering' 'Handwriting cannot be copied without it. Run Setup again to enable it, then unplug and re-plug the cable.') }

    # 8 restart budget
    $b = Test-RedriveRestartBudget
    if ($b.Allowed) { & $add (New-RedriveCheck 'budget' 'Tablet restart budget' 'PASS' 'a restart of the tablet app is allowed right now') }
    else { & $add (New-RedriveCheck 'budget' 'Tablet restart budget' 'INFO' $b.Reason 'Waiting protects the tablet: it reboots itself when its app restarts too often. Nothing to do.') }

    # 9 drive and state
    $d = Test-RedriveDrive
    if (-not $d.Letter) { & $add (New-RedriveCheck 'drive' 'Drive letter' 'SKIP' 'no drive letter configured') }
    elseif ($d.Present -and $d.IsMirror) {
        $count = 0; try { $count = @(Get-ChildItem -LiteralPath "$($d.Letter):\" -Recurse -File -ErrorAction Stop | Where-Object { $_.Extension -eq '.pdf' }).Count } catch { }
        & $add (New-RedriveCheck 'drive' "Drive $($d.Letter): shows the mirror" 'PASS' "$count PDF file(s)")
    }
    elseif ($d.Present) { & $add (New-RedriveCheck 'drive' "Drive $($d.Letter): shows the mirror" 'FAIL' "$($d.Letter): is in use by $($d.Target)" 'Choose another letter in config.json (DriveLetter) and restart redrive.') }
    else { & $add (New-RedriveCheck 'drive' "Drive $($d.Letter): shows the mirror" 'WARN' 'not mapped' 'Start redrive (the tray icon maps it), or run: redrive mount') }
    $state = Get-RedriveState
    if ($state.ContainsKey('LastSync') -and $state.LastSync) {
        $age = (Get-Date) - [DateTime]::Parse([string]$state.LastSync)
        $st = if ($age.TotalHours -gt 24) { 'WARN' } else { 'PASS' }
        & $add (New-RedriveCheck 'sync' 'Last sync' $st ("{0:N0} min ago: {1}" -f $age.TotalMinutes, $state.LastSyncMessage) $(if ($st -eq 'WARN') { 'The tablet has not been synced for a day. Plug it in and tap it, or click Sync now.' } else { '' }))
    }
    else { & $add (New-RedriveCheck 'sync' 'Last sync' 'INFO' 'never') }
    if ($state.ContainsKey('LastError') -and $state.LastError) { & $add (New-RedriveCheck 'err' 'Last error' 'INFO' "$($state.LastErrorAt): $($state.LastError)") }

    # 10 OneNote
    if ([bool]$cfg.OneNote.Enabled -and (Get-Command Test-RedriveOneNote -ErrorAction SilentlyContinue)) {
        $on = Test-RedriveOneNote
        if ($on.Ok) { & $add (New-RedriveCheck 'onenote' 'OneNote desktop' 'PASS' $on.Detail) }
        else { & $add (New-RedriveCheck 'onenote' 'OneNote desktop' 'WARN' $on.Detail $on.Fix) }
    }

    # 11 tray and autostart
    $trayRunning = $false
    try { $m = $null; $trayRunning = [System.Threading.Mutex]::TryOpenExisting('Local\redrive.tray', [ref]$m); if ($m) { $m.Dispose() } } catch { $trayRunning = $false }
    if ($trayRunning) { & $add (New-RedriveCheck 'tray' 'Tray icon running' 'PASS') } else { & $add (New-RedriveCheck 'tray' 'Tray icon running' 'WARN' 'not running' 'Start it with: redrive tray (or log off and on again).') }
    $auto = $false
    try { if (Get-ScheduledTask -TaskName 'redrive tray' -ErrorAction Stop) { $auto = $true } } catch { }
    if (-not $auto -and (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('Startup')) 'redrive.lnk'))) { $auto = $true }
    if ($auto) { & $add (New-RedriveCheck 'auto' 'Starts at logon' 'PASS') } else { & $add (New-RedriveCheck 'auto' 'Starts at logon' 'WARN' 'no logon task or Startup shortcut' 'Run Setup again to register it.') }

    # 12 interference hints
    if ($cfg.UsbSubnet -and $probe.AdapterUp) {
        try {
            $route = Find-NetRoute -RemoteIPAddress $cfg.Host -ErrorAction Stop | Select-Object -First 1
            $ifIndex = $route.InterfaceIndex
            $ifOk = $false
            foreach ($ip in (Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)) { if ($ip.IPAddress.StartsWith([string]$cfg.UsbSubnet)) { $ifOk = $true } }
            if ($ifOk) { & $add (New-RedriveCheck 'route' 'Traffic to the tablet uses the USB link' 'PASS') }
            else { & $add (New-RedriveCheck 'route' 'Traffic to the tablet uses the USB link' 'WARN' "route goes through interface $ifIndex" 'A VPN or another adapter captures 10.11.99.1. Disconnect the VPN or ask IT for a split-tunnel exception for 10.11.99.0/24.') }
        }
        catch { }
        try {
            $fw = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName FirewallProduct -ErrorAction Stop | Where-Object { $_.displayName -notmatch 'Windows' })
            if ($fw.Count) { & $add (New-RedriveCheck 'fwall' 'Third-party firewall' 'INFO' (($fw | ForEach-Object { $_.displayName }) -join ', ') 'If syncing fails, allow ssh.exe and curl.exe to reach 10.11.99.1 in that firewall.') }
        }
        catch { }
    }
    return @($checks)
}

function Format-RedriveDoctor {
    param([Parameter(Mandatory)]$Checks, [switch]$NoColor)
    $lines = @()
    foreach ($c in $Checks) {
        $tag = '[{0}]' -f $c.Status
        $line = '{0,-6} {1}' -f $tag, $c.Name
        if ($c.Detail) { $line += "  - $($c.Detail)" }
        $lines += $line
        if ($c.Fix -and $c.Status -in @('FAIL', 'WARN')) { $lines += "       fix: $($c.Fix)" }
    }
    return $lines
}

function Write-RedriveDoctorConsole {
    param([Parameter(Mandatory)]$Checks)
    foreach ($c in $Checks) {
        $color = switch ($c.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } 'SKIP' { 'DarkGray' } 'INFO' { 'Cyan' } }
        Write-Host ('[{0}]' -f $c.Status).PadRight(7) -ForegroundColor $color -NoNewline
        Write-Host $c.Name -NoNewline
        if ($c.Detail) { Write-Host "  - $($c.Detail)" -ForegroundColor DarkGray } else { Write-Host '' }
        if ($c.Fix -and $c.Status -in @('FAIL', 'WARN')) { Write-Host "       fix: $($c.Fix)" -ForegroundColor Yellow }
    }
}

function New-RedriveDoctorReport {
    <# Writes a support report (checks, versions, config, log tail) and copies it to the clipboard. Returns the path. #>
    param([Parameter(Mandatory)]$Checks)
    $p = Initialize-RedriveHome
    $cfg = $null; try { $cfg = Get-RedriveConfig } catch { }
    $lines = @()
    $lines += "redrive doctor report - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += "windows: $([Environment]::OSVersion.VersionString)  powershell: $($PSVersionTable.PSVersion)"
    $lines += ''
    $lines += Format-RedriveDoctor -Checks $Checks
    $lines += ''
    if ($cfg) {
        $safe = Copy-RedriveHashtable $cfg
        $lines += 'config:'
        $lines += ((ConvertTo-RedriveJsonReady $safe) | ConvertTo-Json -Depth 8)
        $lines += ''
    }
    $lines += 'log tail:'
    $lines += (Get-RedriveLogTail -Lines 100)
    $text = ($lines -join [Environment]::NewLine)
    # the report is meant to be pasted into an e-mail or a public issue: keep the user's name out of it
    # (plain, forward-slash and JSON-escaped forms of the profile path, then any Users\<name> remnant)
    if ($env:USERPROFILE) {
        foreach ($form in @($env:USERPROFILE, $env:USERPROFILE.Replace('\', '/'), $env:USERPROFILE.Replace('\', '\\'))) { $text = $text.Replace($form, '~') }
    }
    if ($env:USERNAME) { $text = [regex]::Replace($text, '(?i)([\\/]{1,2})Users\1' + [regex]::Escape($env:USERNAME) + '(?=[\\/])', '$1Users$1~') }
    $file = Join-Path $p.Logs ("doctor-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-RedriveTextFile -Path $file -Content $text
    try { Set-Clipboard -Value $text } catch { }
    return $file
}
