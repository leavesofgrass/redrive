# Log.ps1 - rotating log file plus optional console echo (ASCII only)

$script:RedriveLogLevels = @{ Debug = 0; Info = 1; Warn = 2; Error = 3 }
$script:RedriveConsole = $false      # set by the CLI so messages also reach the screen
$script:RedriveLogComponent = 'core'

function Set-RedriveConsoleLogging([bool]$Enabled) { $script:RedriveConsole = $Enabled }

function Write-RedriveLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Debug', 'Info', 'Warn', 'Error')][string]$Level = 'Info',
        [string]$Component = $script:RedriveLogComponent
    )
    $cfg = $null
    try { $cfg = Get-RedriveConfig } catch { $cfg = $script:RedriveDefaults }
    $minLevel = 'Info'
    try { $minLevel = [string]$cfg.Log.Level } catch { }
    if (-not $script:RedriveLogLevels.ContainsKey($minLevel)) { $minLevel = 'Info' }
    if ($script:RedriveLogLevels[$Level] -lt $script:RedriveLogLevels[$minLevel]) { return }

    $p = Get-RedrivePaths
    $line = '{0} [{1,-5}] [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level.ToUpper(), $Component, $Message
    try {
        if (-not (Test-Path -LiteralPath $p.Logs)) { New-Item -ItemType Directory -Path $p.Logs -Force | Out-Null }
        $maxBytes = 2000000; $keep = 3
        try { $maxBytes = [int64]$cfg.Log.MaxBytes; $keep = [int]$cfg.Log.Keep } catch { }
        if ((Test-Path -LiteralPath $p.LogFile) -and ((Get-Item -LiteralPath $p.LogFile).Length -gt $maxBytes)) {
            for ($i = $keep - 1; $i -ge 1; $i--) {
                $from = "$($p.LogFile).$i"; $to = "$($p.LogFile).$($i + 1)"
                if (Test-Path -LiteralPath $from) { Move-Item -LiteralPath $from -Destination $to -Force -ErrorAction SilentlyContinue }
            }
            Move-Item -LiteralPath $p.LogFile -Destination "$($p.LogFile).1" -Force -ErrorAction SilentlyContinue
        }
        $enc = New-Object System.Text.UTF8Encoding($false)
        for ($try = 0; $try -lt 3; $try++) {
            try { [IO.File]::AppendAllText($p.LogFile, $line + [Environment]::NewLine, $enc); break }
            catch [System.IO.IOException] { Start-Sleep -Milliseconds 50 }
        }
    }
    catch { }
    if ($script:RedriveConsole) {
        $color = switch ($Level) { 'Debug' { 'DarkGray' } 'Info' { 'Gray' } 'Warn' { 'Yellow' } 'Error' { 'Red' } }
        try { Write-Host $line -ForegroundColor $color } catch { }
    }
}

function Get-RedriveLogTail {
    param([int]$Lines = 50)
    $p = Get-RedrivePaths
    if (-not (Test-Path -LiteralPath $p.LogFile)) { return @() }
    return @(Get-Content -LiteralPath $p.LogFile -Tail $Lines -Encoding UTF8)
}
