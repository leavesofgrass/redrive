# Tray.ps1 - the notification-area icon (ASCII only). Started with: redrive.ps1 tray (STA, hidden window)

function New-RedriveTrayIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $Color
    $g.FillEllipse($brush, 2, 2, 12, 12)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(90, 0, 0, 0)), 1
    $g.DrawEllipse($pen, 2, 2, 11, 11)
    $g.Dispose(); $brush.Dispose(); $pen.Dispose()
    $h = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($h)
    $bmp.Dispose()
    return $icon
}

function Get-RedriveTrayColor([string]$State) {
    switch ($State) {
        'Unplugged' { [System.Drawing.Color]::FromArgb(150, 150, 150) }
        'Asleep' { [System.Drawing.Color]::FromArgb(230, 190, 40) }
        'Connected' { [System.Drawing.Color]::FromArgb(70, 140, 220) }
        'Syncing' { [System.Drawing.Color]::FromArgb(40, 110, 220) }
        'Synced' { [System.Drawing.Color]::FromArgb(60, 170, 80) }
        'Attention' { [System.Drawing.Color]::FromArgb(230, 120, 30) }
        'NeedsSetup' { [System.Drawing.Color]::FromArgb(210, 50, 50) }
        'Paused' { [System.Drawing.Color]::FromArgb(120, 120, 140) }
        default { [System.Drawing.Color]::FromArgb(150, 150, 150) }
    }
}

function Get-RedrivePendingPushCount {
    # cheap estimate: writable pdf/epub files in the mirror outside _ folders
    try {
        $cfg = Get-RedriveConfig
        $root = [string]$cfg.MirrorRoot
        if (-not (Test-Path -LiteralPath $root)) { return 0 }
        $n = 0
        foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.pdf', '*.epub' -ErrorAction SilentlyContinue)) {
            $rel = $f.FullName.Substring($root.TrimEnd('\').Length + 1)
            $top = ($rel -split '\\')[0]
            if ($top -like '_*' -and $top -ne [string]$cfg.InboxFolder) { continue }
            if (-not (Test-RedriveReadOnly -Path $f.FullName)) { $n++ }
        }
        return $n
    }
    catch { return 0 }
}

function Start-RedriveSyncProcess {
    param([switch]$Force)
    $p = Get-RedrivePaths
    $script = Join-Path $p.App 'redrive.ps1'
    if (-not (Test-Path -LiteralPath $script)) { $script = Join-Path (Get-RedriveRepoRoot) 'redrive.ps1' }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $a = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" sync -Quiet' -f $script)
    if ($env:REDRIVE_HOME) { $a += ' -HomeDir "' + $env:REDRIVE_HOME + '"' }
    if ($Force) { $a += ' -Force' }
    return (Start-Process -FilePath $ps -ArgumentList $a -WindowStyle Hidden -PassThru)
}

function Start-RedriveTrayApp {
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\redrive.tray', [ref]$created)
    if (-not $created) { Write-RedriveLog -Level Info -Component 'tray' -Message 'already running'; return }
    $p = Initialize-RedriveHome
    Set-Content -LiteralPath $p.TrayPid -Value $PID
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $cfg = Get-RedriveConfig -Reload
    Write-RedriveLog -Level Info -Component 'tray' -Message "tray started (pid $PID)"

    $icons = @{}
    foreach ($s in @('Unplugged', 'Asleep', 'Connected', 'Syncing', 'Synced', 'Attention', 'NeedsSetup', 'Paused')) { $icons[$s] = New-RedriveTrayIcon -Color (Get-RedriveTrayColor $s) }
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = $icons['Unplugged']
    $ni.Text = 'redrive - waiting for the tablet'
    $ni.Visible = $true

    $ctx = @{
        State = (New-RedriveWatchdogState)
        SyncProc = $null
        SyncForce = $false
        LastPendingCheck = [DateTime]::MinValue
        LastIcon = ''
        Exiting = $false
    }
    Mount-RedriveDrive | Out-Null

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miStatus = $menu.Items.Add('redrive'); $miStatus.Enabled = $false
    [void]$menu.Items.Add('-')
    $miOpen = $menu.Items.Add('Open the reMarkable folder')
    $miSync = $menu.Items.Add('Sync now')
    $miPause = $menu.Items.Add('Pause syncing')
    [void]$menu.Items.Add('-')
    $miDoctor = $menu.Items.Add('Doctor (check everything)')
    $miLog = $menu.Items.Add('Show log')
    $miCfg = $menu.Items.Add('Settings file')
    [void]$menu.Items.Add('-')
    $miExit = $menu.Items.Add('Exit')
    $ni.ContextMenuStrip = $menu

    $openFolder = {
        $c = Get-RedriveConfig
        $target = if ($c.DriveLetter -and (Test-RedriveDrive).IsMirror) { "$($c.DriveLetter):\" } else { [string]$c.MirrorRoot }
        Start-Process -FilePath 'explorer.exe' -ArgumentList $target | Out-Null
    }.GetNewClosure()
    $miOpen.Add_Click($openFolder)
    $ni.Add_DoubleClick($openFolder)
    $miSync.Add_Click({
        if ($ctx.SyncProc -and -not $ctx.SyncProc.HasExited) { $ni.ShowBalloonTip(3000, 'redrive', 'A sync is already running.', [System.Windows.Forms.ToolTipIcon]::Info); return }
        $pp = Get-RedrivePaths
        if (Test-Path -LiteralPath $pp.PauseFlag) { Remove-Item -LiteralPath $pp.PauseFlag -Force -ErrorAction SilentlyContinue }
        $ctx.SyncForce = $true
        if ($ctx.State.State -in @('NeedsSetup', 'Attention')) { $ctx.State.State = 'Connected'; $ctx.State.Since = Get-Date; $ctx.State.FailStreak = 0 }   # a manual retry always gets a chance
        $ctx.State.NextSync = Get-Date
        $ctx.State.NextProbe = Get-Date
    }.GetNewClosure())
    $miPause.Add_Click({
        $pp = Get-RedrivePaths
        if (Test-Path -LiteralPath $pp.PauseFlag) { Remove-Item -LiteralPath $pp.PauseFlag -Force -ErrorAction SilentlyContinue; $miPause.Text = 'Pause syncing' }
        else { Set-Content -LiteralPath $pp.PauseFlag -Value (Get-Date).ToString('o'); $miPause.Text = 'Resume syncing' }
    }.GetNewClosure())
    $miDoctor.Add_Click({
        $pp = Get-RedrivePaths
        $script = Join-Path $pp.App 'redrive.ps1'
        if (-not (Test-Path -LiteralPath $script)) { $script = Join-Path (Get-RedriveRepoRoot) 'redrive.ps1' }
        $a = ('-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}" doctor -Report' -f $script)
        if ($env:REDRIVE_HOME) { $a += ' -HomeDir "' + $env:REDRIVE_HOME + '"' }
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $a | Out-Null
    }.GetNewClosure())
    $miLog.Add_Click({ $pp = Get-RedrivePaths; if (Test-Path -LiteralPath $pp.LogFile) { Start-Process -FilePath 'notepad.exe' -ArgumentList $pp.LogFile | Out-Null } }.GetNewClosure())
    $miCfg.Add_Click({ $pp = Get-RedrivePaths; Start-Process -FilePath 'notepad.exe' -ArgumentList $pp.Config | Out-Null }.GetNewClosure())
    $miExit.Add_Click({ $ctx.Exiting = $true; [System.Windows.Forms.Application]::Exit() }.GetNewClosure())

    try {
        Register-ObjectEvent -InputObject ([System.Net.NetworkInformation.NetworkChange]) -EventName NetworkAddressChanged -SourceIdentifier 'redrive.net' | Out-Null
        Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName PowerModeChanged -SourceIdentifier 'redrive.power' | Out-Null
    }
    catch { Write-RedriveLog -Level Debug -Component 'tray' -Message "event subscription failed: $($_.Exception.Message)" }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        try {
            $now = Get-Date
            $pp = Get-RedrivePaths
            $c = Get-RedriveConfig
            $wake = $false
            $ev = @()
            foreach ($sid in @('redrive.net', 'redrive.power')) { $ev += @(Get-Event -SourceIdentifier $sid -ErrorAction SilentlyContinue) }
            if ($ev.Count) { $ev | Remove-Event -ErrorAction SilentlyContinue; $wake = $true }
            $paused = Test-Path -LiteralPath $pp.PauseFlag
            $probe = $null
            if ($wake -or ($now -ge $ctx.State.NextProbe)) { $probe = Test-RedriveDevice }
            $syncResult = $null
            $authResult = $null
            if ($ctx.SyncProc) {
                if ($ctx.SyncProc.HasExited) {
                    $st = Get-RedriveStatus
                    $ok = $true; $msg = 'done'; $changes = $false
                    $phase = ''
                    if ($st) {
                        if ($st.PSObject.Properties['Ok']) { $ok = [bool]$st.Ok }
                        if ($st.Error) { $msg = [string]$st.Error; $ok = $false } elseif ($st.Message) { $msg = [string]$st.Message }
                        if ($st.PSObject.Properties['Changes']) { $changes = [bool]$st.Changes }
                        $phase = [string]$st.Phase
                    }
                    if ($phase -like 'auth-NeedsSetup*') { $authResult = @{ Ok = $false; Reason = 'NeedsSetup' } }      # the key was refused: not a sync failure
                    elseif ($phase -eq 'unreachable') { $syncResult = $null }                                            # the probe will sort the state out
                    else { $syncResult = @{ Ok = $ok; Message = $msg; Changes = $changes } }
                    $ctx.SyncProc.Dispose(); $ctx.SyncProc = $null
                }
                else {
                    $st = Get-RedriveStatus
                    if ($st -and $st.Message) { $ctx.State.Progress = [string]$st.Message }
                }
            }
            if (($now - $ctx.LastPendingCheck).TotalSeconds -gt 60) { $ctx.State.PendingPushes = Get-RedrivePendingPushCount; $ctx.LastPendingCheck = $now }
            $step = Step-RedriveWatchdog -State $ctx.State -Probe $probe -Now $now -Config $c -Paused $paused -SyncResult $syncResult -AuthResult $authResult -WakeEvent $wake
            $ctx.State = $step.State
            foreach ($a in $step.Actions) {
                if ($a -eq 'Sync') {
                    if (-not $ctx.SyncProc) {
                        Mount-RedriveDrive | Out-Null
                        $ctx.SyncProc = Start-RedriveSyncProcess -Force:$ctx.SyncForce
                        $ctx.SyncForce = $false
                    }
                }
                elseif ($a -like 'Notify:*') {
                    $parts = $a -split ':', 3
                    $kind = $parts[1]; $text = $parts[2]
                    $iconKind = if ($kind -in @('attention', 'setup')) { [System.Windows.Forms.ToolTipIcon]::Warning } else { [System.Windows.Forms.ToolTipIcon]::Info }
                    $ni.ShowBalloonTip(6000, 'redrive', $text, $iconKind)
                }
            }
            $s = $ctx.State.State
            if ($ctx.LastIcon -ne $s) { $ni.Icon = $icons[$s]; $ctx.LastIcon = $s }
            $text = 'redrive: ' + $ctx.State.Message
            if ($s -eq 'Syncing' -and $ctx.State.Progress) { $text = 'redrive: ' + $ctx.State.Progress }
            if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + '...' }
            if ($ni.Text -ne $text) { $ni.Text = $text }
            $miStatus.Text = $ctx.State.Message
            $miPause.Text = if ($paused) { 'Resume syncing' } else { 'Pause syncing' }
        }
        catch { Write-RedriveLog -Level Error -Component 'tray' -Message ("tick failed: " + $_.Exception.Message + ' ' + $_.ScriptStackTrace) }
    }.GetNewClosure())
    $timer.Start()

    try { [System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext)) }
    finally {
        $timer.Stop(); $timer.Dispose()
        try { Unregister-Event -SourceIdentifier 'redrive.net' -ErrorAction SilentlyContinue; Unregister-Event -SourceIdentifier 'redrive.power' -ErrorAction SilentlyContinue } catch { }
        $ni.Visible = $false; $ni.Dispose()
        foreach ($i in $icons.Values) { try { $i.Dispose() } catch { } }
        try { $mutex.ReleaseMutex() } catch { }
        Remove-Item -LiteralPath $p.TrayPid -Force -ErrorAction SilentlyContinue
        Write-RedriveLog -Level Info -Component 'tray' -Message 'tray stopped'
    }
}
