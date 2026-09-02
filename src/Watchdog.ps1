# Watchdog.ps1 - the pure state machine behind the tray icon (ASCII only)
#
# Step-RedriveWatchdog takes the current state, a probe result and the time, and returns
# the new state plus a list of actions for the caller (the tray) to perform. No I/O here,
# so the whole thing is unit-testable.
#
# States: Unplugged, Asleep, Connected, Syncing, Synced, Attention, Paused, NeedsSetup

function New-RedriveWatchdogState {
    param([datetime]$Now = (Get-Date))
    return @{
        State          = 'Unplugged'
        Since          = $Now
        LastSeen       = $null
        LastProbe      = $null
        NextProbe      = $Now
        LastSync       = $null
        NextSync       = $null
        LostAt         = $null
        FailStreak     = 0
        PendingLoss    = $false
        LastNotify     = @{}
        Message        = 'Waiting for the tablet (USB)'
        Progress       = ''
        PendingPushes  = 0
        LastNudge      = $null
        AuthChecked    = $false
        StartedAt      = $Now
    }
}

function Test-RedriveNotifyAllowed {
    param([hashtable]$S, [string]$Kind, [datetime]$Now, [int]$MinMinutes = 10)
    if (($Now - $S.StartedAt).TotalSeconds -lt 20) { return $false }
    if ($S.LastNotify.ContainsKey($Kind)) { if (($Now - $S.LastNotify[$Kind]).TotalMinutes -lt $MinMinutes) { return $false } }
    $S.LastNotify[$Kind] = $Now
    return $true
}

function Step-RedriveWatchdog {
    <#
      Inputs:
        -State  hashtable from New-RedriveWatchdogState (mutated and returned)
        -Probe  object with AdapterUp/Port22 (from Test-RedriveDevice) or $null when no probe was due
        -Now    current time
        -Config the redrive config hashtable
        -Paused $true when the user paused syncing
        -SyncResult optional: @{ Ok; Message; Changes } from a sync that just finished
        -AuthResult optional: @{ Ok; Reason } from Test-RedriveSshAuth
      Output: @{ State = <hashtable>; Actions = @('Probe','Sync','CheckAuth','Notify:<kind>:<text>','Nudge') }
    #>
    param([hashtable]$State, $Probe, [datetime]$Now, [hashtable]$Config, [bool]$Paused = $false, $SyncResult = $null, $AuthResult = $null, [bool]$WakeEvent = $false)
    $S = $State
    $actions = New-Object System.Collections.ArrayList
    $fast = [int]$Config.Probe.FastSeconds; $slow = [int]$Config.Probe.SlowSeconds; $window = [int]$Config.Probe.FastWindowSeconds; $connected = [int]$Config.Probe.ConnectedSeconds
    $syncEvery = [int]$Config.SyncIntervalMinutes

    if ($Paused) {
        if ($S.State -ne 'Paused') { $S.State = 'Paused'; $S.Since = $Now; $S.Message = 'Syncing paused' }
        $S.NextProbe = $Now.AddSeconds($slow)
        return @{ State = $S; Actions = @($actions) }
    }
    if ($S.State -eq 'Paused') { $S.State = 'Unplugged'; $S.Since = $Now; $S.Message = 'Waiting for the tablet (USB)'; $S.NextProbe = $Now }

    if ($WakeEvent) { $S.NextProbe = $Now }

    if ($AuthResult) {
        if ($AuthResult.Ok) { $S.AuthChecked = $true; if ($S.State -eq 'NeedsSetup') { $S.State = 'Connected'; $S.Since = $Now } }
        elseif ($AuthResult.Reason -eq 'NeedsSetup') {
            $S.State = 'NeedsSetup'; $S.Since = $Now; $S.Message = 'The tablet refused the key - run Setup again'
            if (Test-RedriveNotifyAllowed $S 'setup' $Now 30) { [void]$actions.Add('Notify:setup:The tablet refused the key. Run Setup again (double-click Install).') }
        }
    }

    if ($SyncResult) {
        if ($SyncResult.Ok) {
            $S.LastSync = $Now; $S.FailStreak = 0; $S.NextSync = $Now.AddMinutes($syncEvery)
            if ($S.State -in @('Syncing', 'Connected', 'Attention')) { $S.State = 'Synced'; $S.Since = $Now }
            $S.Message = "Up to date - last sync $($Now.ToString('HH:mm'))"
            if ($SyncResult.Changes -and (Test-RedriveNotifyAllowed $S 'synced' $Now 10)) { [void]$actions.Add("Notify:synced:$($SyncResult.Message)") }
        }
        else {
            $S.FailStreak++
            $back = [math]::Min(60, 5 * [math]::Pow(2, [math]::Max(0, $S.FailStreak - 1)))
            $S.NextSync = $Now.AddSeconds($back)
            $S.Message = "Sync problem: $($SyncResult.Message)"
            if ($S.FailStreak -ge 3 -and $S.State -ne 'Attention') { $S.State = 'Attention'; $S.Since = $Now; if (Test-RedriveNotifyAllowed $S 'attention' $Now 10) { [void]$actions.Add('Notify:attention:Sync keeps failing - open Doctor from the redrive icon.') } }
            elseif ($S.State -eq 'Syncing') { $S.State = 'Connected' }
        }
        $S.Progress = ''
    }

    if ($Probe) {
        $S.LastProbe = $Now
        $reachable = [bool]$Probe.Port22
        $adapter = [bool]$Probe.AdapterUp
        if ($reachable) {
            $S.LastSeen = $Now; $S.PendingLoss = $false; $S.LostAt = $null
            if ($S.State -in @('Unplugged', 'Asleep')) {
                $S.State = 'Connected'; $S.Since = $Now; $S.Message = 'Tablet connected'
                $S.NextSync = $Now
                if (-not $S.AuthChecked) { [void]$actions.Add('CheckAuth') }
            }
            elseif ($S.State -eq 'NeedsSetup' -and ($Now - $S.Since).TotalMinutes -ge 10) {
                # the user may have run Setup again in the meantime: retry quietly every ten minutes
                $S.State = 'Connected'; $S.Since = $Now; $S.Message = 'Tablet connected'; $S.NextSync = $Now
            }
            $S.NextProbe = $Now.AddSeconds($connected)
        }
        else {
            if ($S.State -in @('Connected', 'Syncing', 'Synced', 'Attention', 'NeedsSetup')) {
                if (-not $adapter) {
                    $where = if ($Config.DriveLetter) { "$($Config.DriveLetter): shows" } else { 'the reMarkable folder shows' }
                    $S.PendingLoss = $false; $S.State = 'Unplugged'; $S.Since = $Now; $S.LostAt = $Now; $S.Message = "Tablet unplugged - $where the last copy"
                }
                elseif (-not $S.PendingLoss) { $S.PendingLoss = $true; $S.NextProbe = $Now.AddSeconds(2); return @{ State = $S; Actions = @($actions) } }
                else { $S.PendingLoss = $false; $S.State = 'Asleep'; $S.Since = $Now; $S.LostAt = $Now; $S.Message = 'Tablet asleep - tap it to wake it' }
            }
            elseif ($S.State -eq 'Unplugged' -and $adapter) { $S.State = 'Asleep'; $S.Since = $Now; $S.Message = 'Tablet asleep - tap it to wake it' }
            elseif ($S.State -eq 'Asleep' -and -not $adapter) { $S.State = 'Unplugged'; $S.Since = $Now; $S.Message = 'Waiting for the tablet (USB)' }
            $lostFor = if ($S.LostAt) { ($Now - $S.LostAt).TotalSeconds } else { 1e9 }
            $S.NextProbe = if ($lostFor -lt $window) { $Now.AddSeconds($fast) } else { $Now.AddSeconds($slow) }
        }
    }

    if ($S.State -in @('Connected', 'Synced', 'Attention') -and $S.NextSync -and $Now -ge $S.NextSync -and -not $S.PendingLoss) {
        $S.State = 'Syncing'; $S.Since = $Now; $S.Message = 'Syncing...'
        $S.NextSync = $Now.AddMinutes($syncEvery)
        [void]$actions.Add('Sync')
    }
    if ($Now -ge $S.NextProbe) { [void]$actions.Add('Probe') }

    if ($S.State -in @('Asleep', 'Unplugged') -and $S.PendingPushes -gt 0 -and $S.LostAt) {
        $nudgeAfter = [int]$Config.NudgeAfterMinutes
        if (($Now - $S.LostAt).TotalMinutes -ge $nudgeAfter -and (-not $S.LastNudge -or ($Now - $S.LastNudge).TotalMinutes -ge 60)) {
            $S.LastNudge = $Now
            [void]$actions.Add("Notify:nudge:$($S.PendingPushes) item(s) are waiting for the tablet - plug it in and tap it to wake it.")
        }
    }
    return @{ State = $S; Actions = @($actions) }
}
