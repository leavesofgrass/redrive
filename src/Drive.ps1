# Drive.ps1 - the drive letter for the mirror folder (subst), plus the optional raw mount (ASCII only)

$script:RedriveDosDeviceType = $null

function Get-RedriveDosDevice {
    <# Returns the target of a DOS device name such as 'R:' (what subst points at), or $null. Never touches the network. #>
    param([Parameter(Mandatory)][string]$Letter)
    if (-not $script:RedriveDosDeviceType) {
        $script:RedriveDosDeviceType = Add-Type -Namespace Redrive -Name DosDevice -PassThru -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern uint QueryDosDeviceW(string lpDeviceName, System.Text.StringBuilder lpTargetPath, uint ucchMax);
'@
    }
    $sb = New-Object System.Text.StringBuilder 1024
    $n = [Redrive.DosDevice]::QueryDosDeviceW(($Letter.TrimEnd(':') + ':'), $sb, 1024)
    if ($n -eq 0) { return $null }
    return $sb.ToString().Split([char]0)[0]
}

function Test-RedriveDrive {
    <# @{ Present; Target; IsMirror; Letter } #>
    $cfg = Get-RedriveConfig
    $letter = [string]$cfg.DriveLetter
    if (-not $letter) { return @{ Present = $false; Target = $null; IsMirror = $false; Letter = '' } }
    $target = Get-RedriveDosDevice -Letter $letter
    $isMirror = $false
    if ($target) {
        $t = $target -replace '^\\\?\?\\', ''
        $isMirror = ($t.TrimEnd('\') -ieq ([string]$cfg.MirrorRoot).TrimEnd('\'))
    }
    return @{ Present = [bool]$target; Target = $target; IsMirror = $isMirror; Letter = $letter }
}

function Mount-RedriveDrive {
    <# subst the configured letter to the mirror folder. Idempotent. Returns @{ Ok; Letter; Message }. #>
    $cfg = Get-RedriveConfig
    $letter = [string]$cfg.DriveLetter
    if (-not $letter) { return @{ Ok = $true; Letter = ''; Message = 'no drive letter configured' } }
    if (-not (Test-Path -LiteralPath $cfg.MirrorRoot)) { New-Item -ItemType Directory -Path $cfg.MirrorRoot -Force | Out-Null }
    $t = Test-RedriveDrive
    if ($t.Present -and $t.IsMirror) { return @{ Ok = $true; Letter = $letter; Message = 'already mapped' } }
    if ($t.Present -and -not $t.IsMirror) {
        return @{ Ok = $false; Letter = $letter; Message = "drive $letter`: is already in use by $($t.Target)" }
    }
    $subst = Join-Path $env:SystemRoot 'System32\subst.exe'
    $r = Invoke-RedriveNative -FilePath $subst -Arguments @("$letter`:", ([string]$cfg.MirrorRoot).TrimEnd('\')) -TimeoutSec 15
    if ($r.ExitCode -eq 0) {
        Write-RedriveLog -Level Info -Component 'drive' -Message "mapped $letter`: to $($cfg.MirrorRoot)"
        return @{ Ok = $true; Letter = $letter; Message = 'mapped' }
    }
    return @{ Ok = $false; Letter = $letter; Message = ("subst failed: " + ($r.StdOut + $r.StdErr).Trim()) }
}

function Dismount-RedriveDrive {
    $cfg = Get-RedriveConfig
    $letter = [string]$cfg.DriveLetter
    if (-not $letter) { return @{ Ok = $true; Message = 'no drive letter configured' } }
    $t = Test-RedriveDrive
    if (-not $t.Present) { return @{ Ok = $true; Message = 'not mapped' } }
    if (-not $t.IsMirror) { return @{ Ok = $false; Message = "drive $letter`: is not the redrive mirror ($($t.Target)); left alone" } }
    $subst = Join-Path $env:SystemRoot 'System32\subst.exe'
    $r = Invoke-RedriveNative -FilePath $subst -Arguments @("$letter`:", '/D') -TimeoutSec 15
    if ($r.ExitCode -eq 0) { Write-RedriveLog -Level Info -Component 'drive' -Message "unmapped $letter`:"; return @{ Ok = $true; Message = 'unmapped' } }
    return @{ Ok = $false; Message = ("subst /D failed: " + ($r.StdOut + $r.StdErr).Trim()) }
}

function Find-RedriveFreeDriveLetter {
    param([string[]]$Preferred = @('R', 'M', 'T', 'Z', 'Q', 'W'))
    $used = @{}
    foreach ($d in [IO.DriveInfo]::GetDrives()) { $used[$d.Name.Substring(0, 1).ToUpper()] = $true }
    foreach ($l in $Preferred) { if (-not $used.ContainsKey($l) -and -not (Get-RedriveDosDevice -Letter $l)) { return $l } }
    foreach ($c in 'ZYXWVUTSRQPONMLKJIHGFE'.ToCharArray()) { $l = [string]$c; if (-not $used.ContainsKey($l) -and -not (Get-RedriveDosDevice -Letter $l)) { return $l } }
    return ''
}

function Set-RedriveDriveLabel {
    <# Cosmetic: name the drive 'reMarkable' in Explorer via the per-user DriveIcons key (harmless if ignored). #>
    $cfg = Get-RedriveConfig
    $letter = [string]$cfg.DriveLetter
    if (-not $letter) { return }
    try {
        $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$letter\DefaultLabel"
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty -Path $key -Name '(default)' -Value 'reMarkable' | Out-Null
    }
    catch { Write-RedriveLog -Level Debug -Component 'drive' -Message "drive label not set: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- optional raw mount (SSHFS-Win or rclone)

function Get-RedriveRawMountTools {
    $sshfs = 'C:\Program Files\SSHFS-Win\bin\sshfs-win.exe'
    $rclone = (Get-Command rclone.exe -ErrorAction SilentlyContinue)
    return @{
        SshfsWin = (Test-Path -LiteralPath $sshfs)
        SshfsPath = $sshfs
        Rclone = [bool]$rclone
        RclonePath = if ($rclone) { $rclone.Source } else { $null }
        WinFsp = (Test-Path -LiteralPath 'C:\Program Files (x86)\WinFsp\bin\winfsp-x64.dll') -or (Test-Path -LiteralPath 'C:\Program Files\WinFsp\bin\winfsp-x64.dll')
    }
}

function Mount-RedriveRaw {
    <# Mounts the raw xochitl directory on a second drive letter (troubleshooting only). Needs an SFTP server on the tablet. #>
    param([string]$Letter = 'S')
    $cfg = Get-RedriveConfig
    $tools = Get-RedriveRawMountTools
    $p = Get-RedrivePaths
    if (Get-RedriveDosDevice -Letter $Letter) { return @{ Ok = $false; Message = "drive $Letter`: is already in use" } }
    $remote = "$($cfg.User)@$($cfg.Host):$($cfg.DataDir)"
    if ($tools.SshfsWin -and $tools.WinFsp) {
        $key = '/cygdrive/' + ((ConvertTo-RedriveSshPath $cfg.KeyPath) -replace '^([A-Za-z]):', { $_.Groups[1].Value.ToLower() })
        $a = @('cmd', '-f', '-o', "IdentityFile=$key", '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=3',
               '-o', 'ConnectTimeout=5', '-o', 'HostKeyAlgorithms=+ssh-rsa', '-o', 'PubkeyAcceptedKeyTypes=+ssh-rsa', '-o', 'StrictHostKeyChecking=no',
               '-o', 'UserKnownHostsFile=/dev/null', '-o', "Port=$($cfg.SshPort)", '-o', 'reconnect', '-o', 'uid=-1,gid=-1', '-o', 'rellinks', '-o', 'fstypename=SSHFS',
               $remote, "$Letter`:")
        $proc = Start-Process -FilePath $tools.SshfsPath -ArgumentList (ConvertTo-RedriveArgumentString $a) -WindowStyle Hidden -PassThru
        Start-Sleep -Seconds 3
        if ($proc.HasExited) { return @{ Ok = $false; Message = "sshfs-win exited with code $($proc.ExitCode)" } }
        Set-Content -LiteralPath (Join-Path $p.State "rawmount-$Letter.pid") -Value $proc.Id
        Write-RedriveLog -Level Info -Component 'drive' -Message "raw mount started on $Letter`: (sshfs-win pid $($proc.Id))"
        return @{ Ok = $true; Message = "mounted on $Letter`: via SSHFS-Win"; Pid = $proc.Id }
    }
    if ($tools.Rclone -and $tools.WinFsp) {
        $a = @('mount', ":sftp,host=$($cfg.Host),port=$($cfg.SshPort),user=$($cfg.User),key_file=$($cfg.KeyPath),shell_type=unix:$($cfg.DataDir)", "$Letter`:",
               '--vfs-cache-mode', 'writes', '--sftp-host-key-algorithms', 'ssh-ed25519,rsa-sha2-512,rsa-sha2-256,ssh-rsa', '--volname', 'reMarkable-raw')
        $proc = Start-Process -FilePath $tools.RclonePath -ArgumentList (ConvertTo-RedriveArgumentString $a) -WindowStyle Hidden -PassThru
        Start-Sleep -Seconds 3
        if ($proc.HasExited) { return @{ Ok = $false; Message = "rclone exited with code $($proc.ExitCode)" } }
        Set-Content -LiteralPath (Join-Path $p.State "rawmount-$Letter.pid") -Value $proc.Id
        Write-RedriveLog -Level Info -Component 'drive' -Message "raw mount started on $Letter`: (rclone pid $($proc.Id))"
        return @{ Ok = $true; Message = "mounted on $Letter`: via rclone"; Pid = $proc.Id }
    }
    return @{ Ok = $false; Message = 'no mount tool found: install WinFsp plus SSHFS-Win (winget install SSHFS-Win.SSHFS-Win) or rclone (winget install Rclone.Rclone)' }
}

function Dismount-RedriveRaw {
    param([string]$Letter = 'S')
    $p = Get-RedrivePaths
    $pidFile = Join-Path $p.State "rawmount-$Letter.pid"
    if (-not (Test-Path -LiteralPath $pidFile)) { return @{ Ok = $true; Message = 'no raw mount recorded' } }
    $procId = 0; [int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$procId) | Out-Null
    try { if ($procId) { Stop-Process -Id $procId -Force -ErrorAction Stop } } catch { }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    Write-RedriveLog -Level Info -Component 'drive' -Message "raw mount on $Letter`: stopped"
    return @{ Ok = $true; Message = 'raw mount stopped' }
}
