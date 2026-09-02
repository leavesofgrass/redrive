# Config.ps1 - paths, defaults and configuration for redrive (Windows PowerShell 5.1, ASCII only)

$script:RedriveDefaults = @{
    SchemaVersion             = 1
    Profile                   = 'default'
    Host                      = '10.11.99.1'
    SshPort                   = 22
    User                      = 'root'
    WebBase                   = 'http://10.11.99.1'
    DataDir                   = '/home/root/.local/share/remarkable/xochitl'
    StagingDir                = '/home/root/redrive-staging'
    DriveLetter               = 'R'
    MirrorRoot                = ''            # resolved to %USERPROFILE%\reMarkable when empty
    KeyPath                   = ''            # resolved to <home>\keys\id_redrive when empty
    UsbSubnet                 = '10.11.99.'   # empty string disables the adapter check (harness)
    Harness                   = $false
    Probe                     = @{ TimeoutMs = 1500; FastSeconds = 3; SlowSeconds = 10; FastWindowSeconds = 120; ConnectedSeconds = 5 }
    SyncIntervalMinutes       = 5
    NudgeAfterMinutes         = 30
    Log                       = @{ Level = 'Info'; MaxBytes = 2000000; Keep = 3 }
    AllowRestart              = $true
    MaxRestartsPer10Min       = 2
    MinMinutesBetweenRestarts = 5
    IdleSecondsBeforeRestart  = 120
    RenderPacingSeconds       = 2
    DownloadFormats           = @('pdf', 'placeholder')
    PushStrategy              = @('web', 'scp')
    ReplacePolicy             = 'NewCopyRetireOld'   # or InPlace
    RetireMode                = 'Trash'              # or Archive, Keep
    ScpLegacyProtocol         = 'auto'               # auto | true | false
    InboxFolder               = '_Inbox'
    ArchiveFolder             = 'OneNote/_Archive'
    OneNote                   = @{
        Enabled                = $true
        PollMinutes            = 5
        Include                = @()
        Exclude                = @()
        TabletRoot             = 'OneNote'
        FromRemarkableNotebook = ''              # empty = first notebook found
        FromRemarkableSection  = 'From reMarkable'
        HarvestDpi             = 150
        MaxExportsPerRun       = 40
        MaxPdfMB               = 50
    }
}

function Get-RedriveHome {
    if ($env:REDRIVE_HOME) { return $env:REDRIVE_HOME }
    return (Join-Path $env:LOCALAPPDATA 'redrive')
}

function Get-RedrivePaths {
    $root = Get-RedriveHome
    $src = $script:RedriveSourceRoot
    if (-not $src) { $src = $PSScriptRoot }
    [pscustomobject]@{
        Home         = $root
        App          = Join-Path $root 'app'
        Bin          = Join-Path $root 'bin'
        Keys         = Join-Path $root 'keys'
        Logs         = Join-Path $root 'logs'
        State        = Join-Path $root 'state'
        Incoming     = Join-Path $root 'state\incoming'
        Harvest      = Join-Path $root 'state\harvest'
        Backup       = Join-Path $root 'backup'
        Config       = Join-Path $root 'config.json'
        SshConfig    = Join-Path $root 'ssh_config'
        KnownHosts   = Join-Path $root 'known_hosts'
        StateFile    = Join-Path $root 'state\state.json'
        OneNoteState = Join-Path $root 'state\onenote-state.json'
        StatusFile   = Join-Path $root 'state\status.json'
        LogFile      = Join-Path $root 'logs\redrive.log'
        TrayPid      = Join-Path $root 'state\tray.pid'
        SyncLock     = Join-Path $root 'state\sync.lock'
        PauseFlag    = Join-Path $root 'state\pause'
        OpenSsh      = Join-Path $env:SystemRoot 'System32\OpenSSH'
        Source       = $src
    }
}

function Initialize-RedriveHome {
    $p = Get-RedrivePaths
    foreach ($d in @($p.Home, $p.Keys, $p.Logs, $p.State, $p.Incoming, $p.Harvest, $p.Backup)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    return $p
}

function Copy-RedriveHashtable([hashtable]$h) {
    $out = @{}
    foreach ($k in $h.Keys) {
        $v = $h[$k]
        if ($v -is [hashtable]) { $out[$k] = Copy-RedriveHashtable $v }
        elseif ($v -is [array]) { $out[$k] = @($v) }
        else { $out[$k] = $v }
    }
    return $out
}

function Merge-RedriveConfig([hashtable]$Base, $Overlay) {
    # Overlay may be a hashtable or a PSCustomObject from ConvertFrom-Json.
    $result = Copy-RedriveHashtable $Base
    if ($null -eq $Overlay) { return $result }
    $props = @()
    if ($Overlay -is [hashtable]) { $props = @($Overlay.Keys) }
    else { $props = @($Overlay.PSObject.Properties | ForEach-Object { $_.Name }) }
    foreach ($k in $props) {
        $v = if ($Overlay -is [hashtable]) { $Overlay[$k] } else { $Overlay.$k }
        $isArray = ($null -ne $v) -and ($v.GetType().IsArray)
        if ($result.ContainsKey($k) -and ($result[$k] -is [hashtable]) -and ($null -ne $v) -and ($v -isnot [string]) -and -not $isArray -and ($v -isnot [ValueType])) {
            $result[$k] = Merge-RedriveConfig $result[$k] $v
        }
        elseif ($isArray) { $result[$k] = @($v) }
        else { $result[$k] = $v }
    }
    return $result
}

function Resolve-RedriveConfig([hashtable]$cfg) {
    $p = Get-RedrivePaths
    if (-not $cfg.MirrorRoot) { $cfg.MirrorRoot = Join-Path $env:USERPROFILE 'reMarkable' }
    if (-not $cfg.KeyPath) { $cfg.KeyPath = Join-Path $p.Keys 'id_redrive' }
    $cfg.MirrorRoot = [Environment]::ExpandEnvironmentVariables([string]$cfg.MirrorRoot)
    $cfg.KeyPath = [Environment]::ExpandEnvironmentVariables([string]$cfg.KeyPath)
    if ($cfg.DriveLetter) { $cfg.DriveLetter = ([string]$cfg.DriveLetter).TrimEnd(':').ToUpper() }
    return $cfg
}

$script:RedriveConfigCache = $null

function Get-RedriveConfig {
    param([switch]$Reload)
    if ($script:RedriveConfigCache -and -not $Reload) { return $script:RedriveConfigCache }
    $p = Get-RedrivePaths
    $overlay = $null
    if (Test-Path -LiteralPath $p.Config) {
        try {
            $raw = [IO.File]::ReadAllText($p.Config, [Text.Encoding]::UTF8)
            if ($raw.Trim()) { $overlay = $raw | ConvertFrom-Json }
        }
        catch { throw "Config file $($p.Config) is not valid JSON: $($_.Exception.Message)" }
    }
    $cfg = Merge-RedriveConfig $script:RedriveDefaults $overlay
    $cfg = Resolve-RedriveConfig $cfg
    $script:RedriveConfigCache = $cfg
    return $cfg
}

function ConvertTo-RedriveJsonReady($value) {
    if ($value -is [hashtable]) {
        $o = [ordered]@{}
        foreach ($k in ($value.Keys | Sort-Object)) { $o[$k] = ConvertTo-RedriveJsonReady $value[$k] }
        return $o
    }
    if (($null -ne $value) -and $value.GetType().IsArray) { return @($value | ForEach-Object { ConvertTo-RedriveJsonReady $_ }) }
    return $value
}

function Write-RedriveTextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    # UTF-8 without BOM, atomic replace.
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($tmp, $Content, $enc)
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { Move-Item -LiteralPath $tmp -Destination $Path -Force }
}

function Save-RedriveConfig {
    param([Parameter(Mandatory)][hashtable]$Config)
    $p = Initialize-RedriveHome
    $json = (ConvertTo-RedriveJsonReady $Config) | ConvertTo-Json -Depth 10
    Write-RedriveTextFile -Path $p.Config -Content $json
    $script:RedriveConfigCache = $null
}

function Read-RedriveJsonFile {
    param([Parameter(Mandatory)][string]$Path, $Default = $null)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if (-not $raw.Trim()) { return $Default }
    return ($raw | ConvertFrom-Json)
}

function Write-RedriveJsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object, [int]$Depth = 12)
    $json = ConvertTo-Json -InputObject $Object -Depth $Depth
    Write-RedriveTextFile -Path $Path -Content $json
}

function ConvertTo-RedriveHashtable($obj) {
    # Recursively convert PSCustomObject graphs (from ConvertFrom-Json) to hashtables for easy mutation.
    if ($null -eq $obj) { return $null }
    if ($obj -is [hashtable]) { return $obj }
    if ($obj -is [string] -or $obj -is [ValueType]) { return $obj }
    if ($obj.GetType().IsArray) { return @($obj | ForEach-Object { ConvertTo-RedriveHashtable $_ }) }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($prop in $obj.PSObject.Properties) { $h[$prop.Name] = ConvertTo-RedriveHashtable $prop.Value }
        return $h
    }
    return $obj
}

function Get-RedriveState {
    # Persistent tray/sync state (restart timestamps, last sync, last error...).
    $p = Get-RedrivePaths
    $s = ConvertTo-RedriveHashtable (Read-RedriveJsonFile -Path $p.StateFile -Default $null)
    if (-not $s) { $s = @{} }
    if (-not $s.ContainsKey('RestartTimes')) { $s['RestartTimes'] = @() }
    if (-not $s.ContainsKey('Documents')) { $s['Documents'] = @{} }
    if (-not $s.ContainsKey('Pushed')) { $s['Pushed'] = @{} }
    if (-not $s.ContainsKey('PendingOps')) { $s['PendingOps'] = @() }
    if (-not $s.ContainsKey('Folders')) { $s['Folders'] = @{} }
    return $s
}

function Save-RedriveState([hashtable]$State) {
    $p = Initialize-RedriveHome
    Write-RedriveJsonFile -Path $p.StateFile -Object (ConvertTo-RedriveJsonReady $State) -Depth 12
}
