# Redrive.psm1 - module loader (ASCII only)
Set-StrictMode -Off
$script:RedriveSourceRoot = $PSScriptRoot

foreach ($name in @('Config', 'Log', 'Native', 'Connection', 'Device', 'Mirror', 'Drive', 'Watchdog', 'Doctor', 'Setup', 'OneNote', 'Tray')) {
    $file = Join-Path $PSScriptRoot "$name.ps1"
    if (Test-Path -LiteralPath $file) { . $file }
}

Export-ModuleMember -Function *
