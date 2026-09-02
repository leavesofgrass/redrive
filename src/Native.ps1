# Native.ps1 - the single wrapper for external programs (ssh, scp, sftp, curl, subst, ...) (ASCII only)

function ConvertTo-RedriveArgument {
    # Quote one argument for the Windows command line (MSVCRT rules).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($c in $Value.ToCharArray()) {
        if ($c -eq '\') { $backslashes++ }
        elseif ($c -eq '"') { [void]$sb.Append('\' * ($backslashes * 2 + 1)); [void]$sb.Append('"'); $backslashes = 0 }
        else { if ($backslashes) { [void]$sb.Append('\' * $backslashes); $backslashes = 0 }; [void]$sb.Append($c) }
    }
    if ($backslashes) { [void]$sb.Append('\' * ($backslashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-RedriveArgumentString {
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments)
    return ((@($Arguments) | ForEach-Object { ConvertTo-RedriveArgument ([string]$_) }) -join ' ')
}

function Invoke-RedriveNative {
    <#
      Runs an external program without a console window, captures stdout/stderr as UTF-8,
      enforces a timeout (the process is killed), and never throws because of stderr output.
      Returns @{ ExitCode; StdOut; StdErr; TimedOut; Command }.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        $ArgumentString = $null,
        [int]$TimeoutSec = 60,
        $StdIn = $null,
        [string]$WorkingDirectory = $null,
        [switch]$Quiet
    )
    # note: a [string] parameter defaulting to $null becomes '' in PowerShell 5.1, so these two stay untyped
    if ([string]::IsNullOrEmpty($ArgumentString)) { $ArgumentString = ConvertTo-RedriveArgumentString $Arguments }
    if ($null -ne $StdIn) { $StdIn = [string]$StdIn }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $ArgumentString
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = ($null -ne $StdIn)
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $result = @{ ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $false; Command = "$FilePath $ArgumentString" }
    if (-not $Quiet) { Write-RedriveLog -Level Debug -Component 'native' -Message ("run: " + $result.Command) }
    $proc = $null
    # Process.StandardInput takes its encoding from Console.InputEncoding; a UTF-8 console encoding carries a
    # BOM that would reach the remote shell as garbage, so switch to BOM-less UTF-8 while starting the process.
    $prevIn = $null
    if ($null -ne $StdIn) { try { $prevIn = [Console]::InputEncoding; [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { $prevIn = $null } }
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
        $result.StdErr = "cannot start ${FilePath}: $($_.Exception.Message)"
        $result.ExitCode = 127
        return $result
    }
    finally { if ($prevIn) { try { [Console]::InputEncoding = $prevIn } catch { } } }
    try {
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if ($null -ne $StdIn) {
            try { $proc.StandardInput.Write($StdIn); $proc.StandardInput.Close() } catch { }
        }
        if (-not $proc.WaitForExit([int]($TimeoutSec * 1000))) {
            $result.TimedOut = $true
            try { $proc.Kill() } catch { }
            $proc.WaitForExit(5000) | Out-Null
        }
        else {
            $proc.WaitForExit()   # flush async readers
        }
        $result.StdOut = $outTask.Result
        $result.StdErr = $errTask.Result
        $result.ExitCode = if ($result.TimedOut) { 124 } else { $proc.ExitCode }
    }
    finally { if ($proc) { $proc.Dispose() } }
    if (-not $Quiet) {
        $err = $result.StdErr.Trim()
        if ($err.Length -gt 300) { $err = $err.Substring(0, 300) + '...' }
        $suffix = ''
        if ($result.TimedOut) { $suffix += ' (timeout)' }
        if ($err) { $suffix += " stderr: $err" }
        Write-RedriveLog -Level Debug -Component 'native' -Message ("exit {0}{1}" -f $result.ExitCode, $suffix)
    }
    return $result
}

function Test-RedriveElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RedriveUserSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}
