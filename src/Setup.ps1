# Setup.ps1 - the interactive one-time setup and its pieces (ASCII only)

function Write-RedriveSetupStep { param([string]$Text) Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-RedriveSetupOk { param([string]$Text) Write-Host "    $Text" -ForegroundColor Green }
function Write-RedriveSetupWarn { param([string]$Text) Write-Host "    $Text" -ForegroundColor Yellow }

function Get-RedriveRepoRoot {
    # The folder that holds redrive.ps1 (parent of src\).
    $p = Get-RedrivePaths
    return (Split-Path -Parent $p.Source)
}

function Install-RedriveAppCopy {
    <# Copies redrive.ps1 + src\ into <home>\app so the downloaded folder can be deleted. Returns the installed redrive.ps1 path. #>
    $p = Initialize-RedriveHome
    $repo = Get-RedriveRepoRoot
    $target = $p.App
    $installed = Join-Path $target 'redrive.ps1'
    if (($repo.TrimEnd('\')) -ieq ($target.TrimEnd('\'))) { return $installed }
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
    Copy-Item -LiteralPath (Join-Path $repo 'redrive.ps1') -Destination $target -Force
    if (Test-Path -LiteralPath (Join-Path $repo 'Install.cmd')) { Copy-Item -LiteralPath (Join-Path $repo 'Install.cmd') -Destination $target -Force }
    $srcTarget = Join-Path $target 'src'
    if (-not (Test-Path -LiteralPath $srcTarget)) { New-Item -ItemType Directory -Path $srcTarget -Force | Out-Null }
    Copy-Item -Path (Join-Path $repo 'src\*') -Destination $srcTarget -Recurse -Force
    Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
    return $installed
}

function New-RedriveKeyPair {
    <# Creates the RSA-4096 key without passphrase and locks its ACL to the current user. #>
    $cfg = Get-RedriveConfig
    $key = [string]$cfg.KeyPath
    if ((Test-Path -LiteralPath $key) -and (Test-Path -LiteralPath "$key.pub")) { return $key }
    $dir = Split-Path -Parent $key
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $keygen = Get-RedriveOpenSshExe 'ssh-keygen'
    $r = Invoke-RedriveNative -FilePath $keygen -Arguments @('-q', '-t', 'rsa', '-b', '4096', '-N', '', '-C', "redrive-$env:COMPUTERNAME", '-f', $key) -TimeoutSec 60 -StdIn ''
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $key)) { throw "ssh-keygen failed: $($r.StdErr.Trim()) $($r.StdOut.Trim())" }
    Protect-RedriveKeyFile -Path $key
    Write-RedriveLog -Level Info -Component 'setup' -Message "created key $key"
    return $key
}

function Protect-RedriveKeyFile {
    param([Parameter(Mandatory)][string]$Path)
    $sid = Get-RedriveUserSid
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    $r = Invoke-RedriveNative -FilePath $icacls -Arguments @($Path, '/inheritance:r', '/grant:r', "*${sid}:F") -TimeoutSec 30
    if ($r.ExitCode -ne 0) { Write-RedriveLog -Level Warn -Component 'setup' -Message "icacls on the key failed: $($r.StdErr.Trim()) $($r.StdOut.Trim())" }
}

function Install-RedriveKeyOnTablet {
    <#
      Installs the public key with ssh.exe attached to this console so the tablet's password prompt is visible.
      Returns $true on success.
    #>
    param([int]$Attempts = 3)
    $cfg = Get-RedriveConfig
    $p = Get-RedrivePaths
    $ssh = Get-RedriveOpenSshExe 'ssh'
    Update-RedriveSshConfig | Out-Null
    $pub = (Get-Content -LiteralPath "$($cfg.KeyPath).pub" -Raw).Trim()
    $parts = $pub -split '\s+'
    $keyData = $parts[1]
    $keyLine = "$($parts[0]) $keyData redrive-$env:COMPUTERNAME"
    $remote = "mkdir -p /home/root/.ssh && chmod go-w /home/root && chmod 700 /home/root/.ssh && touch /home/root/.ssh/authorized_keys && chmod 600 /home/root/.ssh/authorized_keys && grep -qF '$keyData' /home/root/.ssh/authorized_keys || echo '$keyLine' >> /home/root/.ssh/authorized_keys; grep -qF '$keyData' /home/root/.ssh/authorized_keys && echo REDRIVE_KEY_OK"
    for ($i = 1; $i -le $Attempts; $i++) {
        Write-Host ''
        Write-Host "    Type the tablet's password and press Enter (attempt $i of $Attempts)." -ForegroundColor Yellow
        Write-Host "    On the tablet: Settings > General > Help > About > Copyrights and licenses, under 'GPLv3 Compliance'." -ForegroundColor DarkGray
        $sshArgs = @('-F', $p.SshConfig, '-o', 'BatchMode=no', '-o', 'PubkeyAuthentication=no', '-o', 'PreferredAuthentications=password', '-o', 'NumberOfPasswordPrompts=1', 'remarkable', $remote)
        $out = & $ssh @sshArgs
        if (($out -join "`n") -match 'REDRIVE_KEY_OK') { Write-RedriveLog -Level Info -Component 'setup' -Message 'public key installed on the tablet'; return $true }
        Write-RedriveSetupWarn 'That did not work (wrong password, or the tablet went to sleep). Tap the tablet and try again.'
    }
    return $false
}

function Wait-RedriveDevice {
    param([int]$TimeoutSec = 600)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $shown = $false
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $probe = Test-RedriveDevice
        if ($probe.Reachable) { return $true }
        if (-not $shown) {
            $shown = $true
            Write-Host ''
            Write-Host '    Plug the tablet into this PC with its USB cable and tap the screen so it is awake.' -ForegroundColor Yellow
            Write-Host '    Waiting... (Ctrl+C to give up)' -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function New-RedriveTrayLauncher {
    <# Compiles a console-less launcher (bin\redrive-tray.exe) with the in-box C# compiler. Returns its path or $null. #>
    $p = Initialize-RedriveHome
    if (-not (Test-Path -LiteralPath $p.Bin)) { New-Item -ItemType Directory -Path $p.Bin -Force | Out-Null }
    $exe = Join-Path $p.Bin 'redrive-tray.exe'
    $code = @'
using System;
using System.Diagnostics;
using System.IO;
static class RedriveTrayLauncher {
    static int Main(string[] args) {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.GetFullPath(Path.Combine(dir, @"..\app\redrive.ps1"));
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        string verb = args.Length > 0 ? string.Join(" ", args) : "tray";
        ProcessStartInfo psi = new ProcessStartInfo(ps, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\" " + verb);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = Path.GetDirectoryName(script);
        Process.Start(psi);
        return 0;
    }
}
'@
    try {
        if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue }
        Add-Type -TypeDefinition $code -OutputAssembly $exe -OutputType WindowsApplication -ErrorAction Stop | Out-Null
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    catch { Write-RedriveLog -Level Warn -Component 'setup' -Message "launcher build failed: $($_.Exception.Message)" }
    return $null
}

function Get-RedriveTrayCommand {
    <# The command line used to start the tray hidden: the launcher if it exists, else powershell.exe directly. #>
    $p = Get-RedrivePaths
    $exe = Join-Path $p.Bin 'redrive-tray.exe'
    $script = Join-Path $p.App 'redrive.ps1'
    if (-not (Test-Path -LiteralPath $script)) { $script = Join-Path (Get-RedriveRepoRoot) 'redrive.ps1' }
    if (Test-Path -LiteralPath $exe) { return @{ Command = $exe; Arguments = '' } }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return @{ Command = $ps; Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" tray' -f $script) }
}

function Register-RedriveAutostart {
    <# Logon Scheduled Task (preferred) or a Startup-folder shortcut. Returns 'task', 'shortcut' or ''. #>
    $cmd = Get-RedriveTrayCommand
    $sid = Get-RedriveUserSid
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $exec = "<Command>$([Security.SecurityElement]::Escape($cmd.Command))</Command>"
    if ($cmd.Arguments) { $exec += "<Arguments>$([Security.SecurityElement]::Escape($cmd.Arguments))</Arguments>" }
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>redrive tray icon: keeps the reMarkable tablet and OneNote in sync over USB</Description></RegistrationInfo>
  <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>$([Security.SecurityElement]::Escape($user))</UserId><Delay>PT20S</Delay></LogonTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure>
  </Settings>
  <Actions Context="Author"><Exec>$exec</Exec></Actions>
</Task>
"@
    try {
        Register-ScheduledTask -TaskName 'redrive tray' -Xml $xml -Force -ErrorAction Stop | Out-Null
        Write-RedriveLog -Level Info -Component 'setup' -Message 'logon task registered'
        return 'task'
    }
    catch { Write-RedriveLog -Level Warn -Component 'setup' -Message "task registration failed: $($_.Exception.Message)" }
    try {
        $startup = [Environment]::GetFolderPath('Startup')
        $lnk = Join-Path $startup 'redrive.lnk'
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        $sc.TargetPath = $cmd.Command
        $sc.Arguments = $cmd.Arguments
        $sc.WorkingDirectory = Split-Path -Parent $cmd.Command
        $sc.Description = 'redrive tray icon'
        $sc.Save()
        Write-RedriveLog -Level Info -Component 'setup' -Message 'Startup shortcut created'
        return 'shortcut'
    }
    catch { Write-RedriveLog -Level Warn -Component 'setup' -Message "Startup shortcut failed: $($_.Exception.Message)" }
    return ''
}

function Unregister-RedriveAutostart {
    try { Unregister-ScheduledTask -TaskName 'redrive tray' -Confirm:$false -ErrorAction Stop } catch { }
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'redrive.lnk'
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue }
}

function Start-RedriveTray {
    $running = $false
    try { $m = $null; $running = [System.Threading.Mutex]::TryOpenExisting('Local\redrive.tray', [ref]$m); if ($m) { $m.Dispose() } } catch { }
    if ($running) { return 'already running' }
    $cmd = Get-RedriveTrayCommand
    if ($cmd.Arguments) { Start-Process -FilePath $cmd.Command -ArgumentList $cmd.Arguments -WindowStyle Hidden | Out-Null }
    else { Start-Process -FilePath $cmd.Command | Out-Null }
    return 'started'
}

function Stop-RedriveTray {
    $p = Get-RedrivePaths
    if (Test-Path -LiteralPath $p.TrayPid) {
        $procId = 0; [int]::TryParse((Get-Content -LiteralPath $p.TrayPid -Raw).Trim(), [ref]$procId) | Out-Null
        if ($procId) { try { Stop-Process -Id $procId -Force -ErrorAction Stop; return 'stopped' } catch { } }
    }
    return 'not running'
}

function Invoke-RedriveSetup {
    <# The interactive setup. Runs in a visible console as the normal (non-admin) user. #>
    param([switch]$SkipDevice, [switch]$NoAutostart, [switch]$NoTray, [switch]$WithRawMount)
    Set-RedriveConsoleLogging $false
    Write-Host ''
    Write-Host 'redrive setup' -ForegroundColor White
    Write-Host '-------------' -ForegroundColor White
    if (Test-RedriveElevated) {
        Write-RedriveSetupWarn 'This window is running as administrator. The drive letter would be invisible to Explorer and OneNote.'
        Write-RedriveSetupWarn 'Close it and run Install.cmd from a normal window.'
        return $false
    }
    $p = Initialize-RedriveHome

    Write-RedriveSetupStep 'Checking Windows'
    try { $null = Get-RedriveOpenSshExe 'ssh'; Write-RedriveSetupOk "OpenSSH client found (version $(Get-RedriveSshVersion))" }
    catch {
        Write-RedriveSetupWarn 'The Windows OpenSSH client is missing. Asking for administrator rights to add it...'
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command "Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"' | Out-Null
            $null = Get-RedriveOpenSshExe 'ssh'
            Write-RedriveSetupOk 'OpenSSH client installed'
        }
        catch { Write-RedriveSetupWarn 'Could not install it. Settings > Apps > Optional features > add "OpenSSH Client", then run Install.cmd again.'; return $false }
    }

    Write-RedriveSetupStep 'Installing redrive for this user'
    $installed = Install-RedriveAppCopy
    Write-RedriveSetupOk "program files: $($p.App)"
    $cfg = Get-RedriveConfig -Reload
    if (-not [bool]$cfg.Harness) {
        $letter = [string]$cfg.DriveLetter
        $t = Test-RedriveDrive
        if (-not $letter -or ($t.Present -and -not $t.IsMirror)) {
            $letter = Find-RedriveFreeDriveLetter
            $cfg.DriveLetter = $letter
        }
    }
    Save-RedriveConfig $cfg
    $cfg = Get-RedriveConfig -Reload
    if (-not (Test-Path -LiteralPath $cfg.MirrorRoot)) { New-Item -ItemType Directory -Path $cfg.MirrorRoot -Force | Out-Null }
    Write-RedriveSetupOk "your tablet folder: $($cfg.MirrorRoot)$(if ($cfg.DriveLetter) { " (drive $($cfg.DriveLetter):)" })"

    Write-RedriveSetupStep 'Creating the connection key'
    $key = New-RedriveKeyPair
    Update-RedriveSshConfig | Out-Null
    Write-RedriveSetupOk "key ready: $key"

    if (-not $SkipDevice) {
        Write-RedriveSetupStep 'Connecting to the tablet'
        if (-not (Wait-RedriveDevice -TimeoutSec 900)) { Write-RedriveSetupWarn 'No tablet found. Run Install.cmd again when it is plugged in.'; return $false }
        Write-RedriveSetupOk "tablet found at $($cfg.Host)"
        $auth = Test-RedriveSshAuth
        if (-not $auth.Ok -and $auth.Reason -eq 'HostKey') { Reset-RedriveKnownHosts -Reason 'setup'; $auth = Test-RedriveSshAuth }
        if (-not $auth.Ok) {
            if (-not (Install-RedriveKeyOnTablet)) { Write-RedriveSetupWarn 'The key could not be installed. Check the password and run Install.cmd again.'; return $false }
            $auth = Test-RedriveSshAuth
            if (-not $auth.Ok) { Write-RedriveSetupWarn "Login still fails: $($auth.Reason) $($auth.Detail)"; return $false }
        }
        Write-RedriveSetupOk 'the tablet accepts the key; no password needed from now on'

        Write-RedriveSetupStep 'Reading tablet details'
        $info = Get-RedriveDeviceInfo
        if ($info.ok) {
            Write-RedriveSetupOk ("firmware {0}, {1} documents, {2:N0} MB free" -f $(if ($info.firmware) { $info.firmware } else { 'unknown' }), $info.docs, ([double]$info.free_kb / 1024))
            $cfg = Get-RedriveConfig -Reload
            $cfg.DeviceFirmware = $info.firmware; $cfg.DeviceArch = $info.arch; $cfg.DeviceModel = $info.model; $cfg.DeviceSftp = [bool]$info.sftp_server
            Save-RedriveConfig $cfg
            if ($info.web_enabled -notmatch '^[1-9]') {
                Write-Host '    Turning on the tablet web interface (the tablet app restarts once, about 10 seconds)...' -ForegroundColor DarkGray
                $w = Enable-RedriveWebInterface -Force
                if ($w.Ok) { Write-RedriveSetupOk 'web interface enabled' } else { Write-RedriveSetupWarn "could not enable the web interface: $($w.Reason) (enable it on the tablet under Settings > Storage)" }
            }
            else { Write-RedriveSetupOk 'web interface already enabled' }
        }
        else { Write-RedriveSetupWarn "could not read tablet details: $($info.error)" }
    }

    Write-RedriveSetupStep 'Setting up the drive letter'
    $m = Mount-RedriveDrive
    if ($m.Ok) { Write-RedriveSetupOk $m.Message; Set-RedriveDriveLabel } else { Write-RedriveSetupWarn $m.Message }

    if (-not $NoAutostart) {
        Write-RedriveSetupStep 'Starting with Windows'
        $launcher = New-RedriveTrayLauncher
        if ($launcher) { Write-RedriveSetupOk "launcher built: $launcher" } else { Write-RedriveSetupWarn 'launcher not built; a brief console flash at logon is possible' }
        $how = Register-RedriveAutostart
        if ($how) { Write-RedriveSetupOk "registered ($how)" } else { Write-RedriveSetupWarn 'could not register autostart; start redrive manually with: redrive tray' }
    }

    if ($WithRawMount) {
        Write-RedriveSetupStep 'Installing the optional raw-mount tools (administrator prompt)'
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command "winget install --id SSHFS-Win.SSHFS-Win -e --silent --accept-package-agreements --accept-source-agreements"' | Out-Null
            Write-RedriveSetupOk 'done (WinFsp + SSHFS-Win)'
        }
        catch { Write-RedriveSetupWarn "raw-mount tools not installed: $($_.Exception.Message)" }
    }

    if (-not $NoTray) {
        Write-RedriveSetupStep 'Starting redrive'
        $s = Start-RedriveTray
        Write-RedriveSetupOk "tray icon $s - look for the coloured dot near the clock"
    }
    Write-Host ''
    Write-Host 'Done.' -ForegroundColor Green
    Write-Host "  - Your tablet's documents will appear in $($cfg.MirrorRoot)$(if ($cfg.DriveLetter) { " (drive $($cfg.DriveLetter):)" }) whenever it is plugged in and awake."
    Write-Host '  - Drop a PDF into that folder to send it to the tablet.'
    Write-Host '  - Right-click the tray icon for Sync now, Doctor and the log.'
    Write-RedriveLog -Level Info -Component 'setup' -Message 'setup completed'
    return $true
}

function Uninstall-Redrive {
    param([switch]$KeepData, [switch]$RemoveKeyFromTablet)
    Stop-RedriveTray | Out-Null
    Unregister-RedriveAutostart
    Dismount-RedriveDrive | Out-Null
    if ($RemoveKeyFromTablet) {
        try { Invoke-RedriveSsh -Command "sed -i '/redrive-$env:COMPUTERNAME/d' /home/root/.ssh/authorized_keys" -TimeoutSec 20 | Out-Null } catch { }
    }
    $p = Get-RedrivePaths
    if (-not $KeepData) {
        foreach ($d in @($p.App, $p.Bin, $p.Keys, $p.State, $p.Logs)) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
        foreach ($f in @($p.Config, $p.SshConfig, $p.KnownHosts)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
    }
    return $true
}
