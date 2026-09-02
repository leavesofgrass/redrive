# redrive.ps1 - command-line entry point (Windows PowerShell 5.1, ASCII only)
#
#   redrive.ps1 setup            one-time setup (run Install.cmd instead)
#   redrive.ps1 status           what redrive is doing
#   redrive.ps1 sync             one sync cycle now
#   redrive.ps1 onenote-sync     just the OneNote part (harvest, export, file on the tablet)
#   redrive.ps1 doctor [-Report] health checks with fixes
#   redrive.ps1 ssh "command"    a shell on the tablet (quote commands that contain options)
#   redrive.ps1 backup           raw copy of the tablet's documents
#   redrive.ps1 mount|unmount    the drive letter
#   redrive.ps1 logs [-Tail 50]  the log
#   redrive.ps1 tray [-Stop]     the tray icon
#   redrive.ps1 window           apply staged tablet changes now (restarts the tablet app)
#   redrive.ps1 mount-raw|unmount-raw   optional raw mount (troubleshooting)
#   redrive.ps1 uninstall [-KeepData]
#
param(
    [Parameter(Position = 0)][string]$Verb = 'help',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @(),
    [string]$HomeDir = '',
    [string]$Profile = '',
    [switch]$Quiet,
    [switch]$Report,
    [switch]$ForgetHostKey,
    [switch]$Full,
    [switch]$Force,
    [switch]$SkipDevice,
    [switch]$NoAutostart,
    [switch]$NoTray,
    [switch]$WithRawMount,
    [switch]$Stop,
    [switch]$KeepData,
    [switch]$RemoveKeyFromTablet,
    [switch]$SkipOneNote,
    [int]$Tail = 50,
    [string]$Letter = 'S'
)
$ErrorActionPreference = 'Stop'
if ($HomeDir) { $env:REDRIVE_HOME = $HomeDir }
elseif ($Profile -eq 'fake') { $env:REDRIVE_HOME = Join-Path $env:LOCALAPPDATA 'redrive-fake' }
Import-Module (Join-Path $PSScriptRoot 'src\Redrive.psd1') -Force
if (-not $Quiet) { Set-RedriveConsoleLogging $false }

function Show-Help {
    Get-Content -LiteralPath $PSCommandPath -TotalCount 16 | Select-Object -Skip 2 | ForEach-Object { $_ -replace '^#\s?', '' }
}

switch ($Verb.ToLower()) {
    'help' { Show-Help }
    'setup' {
        $ok = Invoke-RedriveSetup -SkipDevice:$SkipDevice -NoAutostart:$NoAutostart -NoTray:$NoTray -WithRawMount:$WithRawMount
        if (-not $ok) { exit 1 }
    }
    'status' {
        $cfg = Get-RedriveConfig
        $probe = Test-RedriveDevice
        $state = Get-RedriveState
        $d = Test-RedriveDrive
        $st = Get-RedriveStatus
        Write-Host ("tablet:   {0} ({1}:{2})" -f $probe.State, $cfg.Host, $cfg.SshPort)
        Write-Host ("folder:   {0}{1}" -f $cfg.MirrorRoot, $(if ($d.Letter) { " - drive $($d.Letter): " + $(if ($d.IsMirror) { 'mapped' } else { 'NOT mapped' }) } else { '' }))
        Write-Host ("last sync: {0}" -f $(if ($state.ContainsKey('LastSync') -and $state.LastSync) { "$($state.LastSync) - $($state.LastSyncMessage)" } else { 'never' }))
        if ($st -and $st.Running) { Write-Host ("running:  {0} - {1}" -f $st.Phase, $st.Message) }
        if ($state.ContainsKey('LastError') -and $state.LastError) { Write-Host ("last error: {0}" -f $state.LastError) -ForegroundColor Yellow }
        $trayRunning = $false
        try { $m = $null; $trayRunning = [System.Threading.Mutex]::TryOpenExisting('Local\redrive.tray', [ref]$m); if ($m) { $m.Dispose() } } catch { }
        Write-Host ("tray:     {0}" -f $(if ($trayRunning) { 'running' } else { 'not running' }))
    }
    'sync' {
        if (-not $Quiet) { Set-RedriveConsoleLogging $true }
        $progress = $null
        if (-not $Quiet) { $progress = { param($m) Write-Host "  $m" -ForegroundColor DarkGray } }
        $r = Invoke-RedriveSync -SkipOneNote:$SkipOneNote -Progress $progress
        if (-not $Quiet) { Write-Host ($(if ($r.Ok) { 'OK: ' } else { 'PROBLEM: ' }) + $r.Message) -ForegroundColor $(if ($r.Ok) { 'Green' } else { 'Yellow' }) }
        if (-not $r.Ok) { exit 2 }
    }
    'onenote-sync' {
        if (-not $Quiet) { Set-RedriveConsoleLogging $true }
        $probe = Test-RedriveDevice
        if (-not $probe.Reachable) { Write-Host "tablet not reachable ($($probe.State))" -ForegroundColor Yellow; exit 2 }
        $h = Invoke-RedriveOneNoteHarvest -Progress { param($m) Write-Host "  $m" -ForegroundColor DarkGray }
        $e = Invoke-RedriveOneNoteExport -Force -Progress { param($m) Write-Host "  $m" -ForegroundColor DarkGray }
        $w = Invoke-RedriveDeviceWindow
        Write-Host ("harvested {0}, exported {1}, errors {2}{3}" -f $h.Harvested, $e.Exported, ($h.Errors + $e.Errors), $(if ($w.Ran) { ', tablet app restarted' } elseif ($w.Reason -and $w.Reason -ne 'nothing staged') { ", changes waiting ($($w.Reason))" } else { '' }))
    }
    'doctor' {
        $checks = Invoke-RedriveDoctor -ForgetHostKey:$ForgetHostKey -Progress { param($c) Write-RedriveDoctorConsole -Checks @($c) }
        if ($Report) {
            $file = New-RedriveDoctorReport -Checks $checks
            Write-Host ''
            Write-Host "Report saved to $file and copied to the clipboard - paste it into an email to your helper." -ForegroundColor Cyan
        }
        $bad = @($checks | Where-Object { $_.Status -eq 'FAIL' }).Count
        if ($bad) { exit 2 }
    }
    'ssh' {
        $p = Get-RedrivePaths
        if (-not (Test-Path -LiteralPath $p.SshConfig)) { Update-RedriveSshConfig | Out-Null }
        $ssh = Get-RedriveOpenSshExe 'ssh'
        $a = @('-F', $p.SshConfig, 'remarkable') + @($Rest)
        & $ssh @a
        exit $LASTEXITCODE
    }
    'backup' {
        Set-RedriveConsoleLogging $true
        $probe = Test-RedriveDevice
        if (-not $probe.Reachable) { Write-Host "tablet not reachable ($($probe.State))" -ForegroundColor Yellow; exit 2 }
        $r = Backup-RedriveTablet -Progress { param($m) Write-Host "  $m" -ForegroundColor DarkGray }
        Write-Host ("backup: {0} document(s) copied to {1}, {2} error(s)" -f $r.Copied, $r.Destination, $r.Errors)
    }
    'mount' { $r = Mount-RedriveDrive; Write-Host $r.Message; if (-not $r.Ok) { exit 2 } }
    'unmount' { $r = Dismount-RedriveDrive; Write-Host $r.Message; if (-not $r.Ok) { exit 2 } }
    'mount-raw' { $r = Mount-RedriveRaw -Letter $Letter; Write-Host $r.Message; if (-not $r.Ok) { exit 2 } }
    'unmount-raw' { $r = Dismount-RedriveRaw -Letter $Letter; Write-Host $r.Message }
    'window' {
        Set-RedriveConsoleLogging $true
        $r = Invoke-RedriveDeviceWindow -Force:$Force
        Write-Host $(if ($r.Ran) { "done in $($r.Seconds) s" } else { "not run: $($r.Reason)" })
    }
    'logs' { Get-RedriveLogTail -Lines $Tail }
    'tray' {
        if ($Stop) { Write-Host (Stop-RedriveTray); break }
        if (Test-RedriveElevated) { Write-Host 'Do not run the tray as administrator (the drive letter would be invisible to Explorer).' -ForegroundColor Yellow; exit 1 }
        if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
            # relaunch in STA for WinForms
            $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $a = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" tray' -f $PSCommandPath)
            if ($env:REDRIVE_HOME) { $a += ' -HomeDir "' + $env:REDRIVE_HOME + '"' }
            Start-Process -FilePath $ps -ArgumentList $a -WindowStyle Hidden | Out-Null
            break
        }
        Start-RedriveTrayApp
    }
    'uninstall' {
        Uninstall-Redrive -KeepData:$KeepData -RemoveKeyFromTablet:$RemoveKeyFromTablet | Out-Null
        Write-Host 'redrive removed for this user.' -ForegroundColor Green
    }
    default { Write-Host "unknown command '$Verb'" -ForegroundColor Yellow; Show-Help; exit 1 }
}
