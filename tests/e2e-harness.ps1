# e2e-harness.ps1 - end-to-end run against the fake tablet (harness\Start-FakeTablet.ps1 must be running)
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\e2e-harness.ps1 [-SkipOneNote]
param([switch]$SkipOneNote, [switch]$KeepState)

$ErrorActionPreference = 'Stop'
$env:REDRIVE_HOME = Join-Path $env:LOCALAPPDATA 'redrive-fake'
if (-not (Test-Path (Join-Path $env:REDRIVE_HOME 'config.json'))) { throw "no fake config at $env:REDRIVE_HOME - run harness\Start-FakeTablet.ps1 first" }
Import-Module (Join-Path $PSScriptRoot '..\src\Redrive.psd1') -Force
Set-RedriveConsoleLogging $true

$failures = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name $Detail" -ForegroundColor Green } else { Write-Host "[FAIL] $Name $Detail" -ForegroundColor Red; $script:failures++ }
}

$cfg = Get-RedriveConfig -Reload
Write-Host "home: $env:REDRIVE_HOME  host: $($cfg.Host):$($cfg.SshPort)  web: $($cfg.WebBase)  mirror: $($cfg.MirrorRoot)"
if (-not $KeepState) {
    $p = Get-RedrivePaths
    foreach ($f in @($p.StateFile, $p.OneNoteState, $p.StatusFile)) { if (Test-Path $f) { Remove-Item $f -Force } }
    if (Test-Path $cfg.MirrorRoot) { Get-ChildItem $cfg.MirrorRoot -Recurse -File | ForEach-Object { Set-RedriveReadOnly -Path $_.FullName -ReadOnly $false }; Remove-Item $cfg.MirrorRoot -Recurse -Force }
}
Update-RedriveSshConfig | Out-Null

# 1. reachability and login
$probe = Test-RedriveDevice
Check 'tablet reachable' $probe.Reachable $probe.State
$auth = Test-RedriveSshAuth
Check 'key login' $auth.Ok "$($auth.Reason) $($auth.Detail)"
if (-not $auth.Ok) { exit 1 }

# 2. device info and web interface
$info = Get-RedriveDeviceInfo
Check 'device info' $info.ok "firmware=$($info.firmware) arch=$($info.arch) docs=$($info.docs) web=$($info.web_enabled) sftp=[$($info.sftp_server)]"
Check 'web interface answers' (Test-RedriveWeb)

# 3. index and tree
$index = Get-RedriveIndex
$tree = Get-RedriveTree -Index $index
Check 'index has documents' ($index.Count -ge 5) "$($index.Count) entries"
$nested = $tree.Values | Where-Object { $_.Path -like 'Work\Projects\*' -and -not $_.IsFolder } | Select-Object -First 1
Check 'nested folder path resolved' ([bool]$nested) $(if ($nested) { $nested.Path } else { '' })
Check 'trashed document excluded' (-not ($tree.Values | Where-Object { $_.Name -eq 'Old draft' }))
$unicode = $tree.Values | Where-Object { $_.Name -like 'R*sum*' } | Select-Object -First 1
Check 'non-ASCII title survived' ([bool]$unicode) $(if ($unicode) { $unicode.Path } else { '' })

# 4. pull
$pull = Sync-RedrivePull -MaxRenders 50 -Progress { param($m) Write-Host "   $m" -ForegroundColor DarkGray }
Check 'pull rendered documents' ($pull.Rendered -ge 4 -and $pull.Errors -eq 0) "rendered=$($pull.Rendered) errors=$($pull.Errors)"
$pdfs = @(Get-ChildItem $cfg.MirrorRoot -Recurse -File -Filter *.pdf)
Check 'mirror has PDF files' ($pdfs.Count -ge 4) "$($pdfs.Count) files"
Check 'mirror files are read-only' (($pdfs | Where-Object { -not (Test-RedriveReadOnly -Path $_.FullName) }).Count -eq 0)
$bytes = [IO.File]::ReadAllBytes($pdfs[0].FullName)
Check 'mirror file is a PDF' ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -eq '%PDF')

# 5. push a new file into a folder
$dropDir = Join-Path $cfg.MirrorRoot 'Work'
if (-not (Test-Path $dropDir)) { New-Item -ItemType Directory -Path $dropDir | Out-Null }
$dropName = 'Dropped by e2e ' + (Get-Date -Format 'HHmmss')
$drop = Join-Path $dropDir "$dropName.pdf"
Copy-Item $pdfs[0].FullName $drop -Force
Set-RedriveReadOnly -Path $drop -ReadOnly $false     # the copy inherits the read-only bit of its source
(Get-Item $drop).LastWriteTime = (Get-Date).AddSeconds(-10)
$push = Sync-RedrivePush -Progress { param($m) Write-Host "   $m" -ForegroundColor DarkGray }
Check 'push uploaded the dropped file' ($push.Uploaded -eq 1 -and $push.Errors -eq 0) "uploaded=$($push.Uploaded) errors=$($push.Errors) needsWindow=$($push.NeedsWindow)"
$state = Get-RedriveState
$pushed = $state.Pushed["Work\$dropName.pdf"]
Check 'push recorded the tablet uuid' ([bool]$pushed -and [bool]$pushed.Uuid) $(if ($pushed) { "uuid=$($pushed.Uuid) via $($pushed.Strategy)" } else { '' })

# 6. device window (files the document into its folder on 3.27-style firmware)
$staged = Get-RedriveStagedCount
Write-Host "   staged on tablet: $staged"
if ($staged -gt 0) {
    $w = Invoke-RedriveDeviceWindow -Force
    Check 'device window ran' $w.Ran "$($w.Reason) $($w.Seconds)s"
    for ($i = 0; $i -lt 20; $i++) { if ((Test-RedriveDevice).Reachable -and (Test-RedriveWeb)) { break }; Start-Sleep -Seconds 1 }
}
$index2 = Get-RedriveIndex
$entry = $null; if ($pushed) { if ($index2.ContainsKey([string]$pushed.Uuid)) { $entry = $index2[[string]$pushed.Uuid] } }
Check 'uploaded document is in the index' ([bool]$entry) $(if ($entry) { "name='$($entry.Name)' parent=$($entry.Parent)" } else { '' })
$workId = Find-RedriveFolder -Index $index2 -Path 'Work'
Check 'uploaded document sits in the Work folder' ($entry -and $entry.Parent -eq $workId) "parent=$($entry.Parent) work=$workId"
Check 'title has no extension' ($entry -and $entry.Name -eq $dropName) "name='$($entry.Name)'"

# 7. pull again: the dropped file becomes a mirror copy
$pull2 = Sync-RedrivePull -MaxRenders 50
$mirrorCopy = Join-Path $dropDir "$dropName.pdf"
Check 'dropped file replaced by its mirror copy' ((Test-Path $mirrorCopy) -and (Test-RedriveReadOnly -Path $mirrorCopy)) "rendered=$($pull2.Rendered)"
$state = Get-RedriveState
Check 'pushed entry cleared after mirror' (-not $state.Pushed.ContainsKey("Work\$dropName.pdf"))

# 8. replace by overwriting a mirror file
$currentHash = Get-RedriveFileSha256 -Path $mirrorCopy
$other = $pdfs | Where-Object { (Get-RedriveFileSha256 -Path $_.FullName) -ne $currentHash } | Select-Object -First 1
Set-RedriveReadOnly -Path $mirrorCopy -ReadOnly $false
Copy-Item $other.FullName $mirrorCopy -Force
Set-RedriveReadOnly -Path $mirrorCopy -ReadOnly $false     # the copy inherits the read-only bit of its source
(Get-Item $mirrorCopy).LastWriteTime = (Get-Date).AddSeconds(-10)
$push2 = Sync-RedrivePush
Check 'overwrite triggers a replacement' ($push2.Replaced -eq 1 -and $push2.Errors -eq 0) "replaced=$($push2.Replaced) errors=$($push2.Errors)"
$state = Get-RedriveState
$old = $state.Documents[[string]$pushed.Uuid]
Check 'old document marked superseded' ([bool]$old -and [bool]$old.Superseded) $(if ($old) { "new uuid=$($old.Superseded)" } else { '' })
if ((Get-RedriveStagedCount) -gt 0) {
    $state.RestartTimes = @(); Save-RedriveState $state
    $w2 = Invoke-RedriveDeviceWindow -Force
    Check 'second window ran' $w2.Ran $w2.Reason
    for ($i = 0; $i -lt 20; $i++) { if ((Test-RedriveDevice).Reachable -and (Test-RedriveWeb)) { break }; Start-Sleep -Seconds 1 }
}
$index3 = Get-RedriveIndex
$oldEntry = if ($index3.ContainsKey([string]$pushed.Uuid)) { $index3[[string]$pushed.Uuid] } else { $null }
Check 'old copy went to the trash' ([bool]$oldEntry -and $oldEntry.InTrash) "parent=$($oldEntry.Parent)"
$pull3 = Sync-RedrivePull -MaxRenders 50
Check 'trashed copy left the mirror, new copy present' ((Test-Path $mirrorCopy) -and $pull3.Errors -eq 0) "rendered=$($pull3.Rendered) removed=$($pull3.Removed)"

# 9. restart budget guard
$state = Get-RedriveState
$limit = [int](Get-RedriveConfig).MaxRestartsPer10Min
$state.RestartTimes = @(1..$limit | ForEach-Object { (Get-Date).AddSeconds(-5 * $_).ToUniversalTime().ToString('o') })
Save-RedriveState $state
$b = Test-RedriveRestartBudget
Check "restart budget blocks restart number $($limit + 1)" (-not $b.Allowed) $b.Reason
$state.RestartTimes = @(); Save-RedriveState $state

# 10. backup
$bk = Backup-RedriveTablet
Check 'backup copied documents' ($bk.Copied -ge 5 -and $bk.Errors -eq 0) "copied=$($bk.Copied) errors=$($bk.Errors) -> $($bk.Destination)"

# 11. full cycle through Invoke-RedriveSync
$cycle = Invoke-RedriveSync -SkipOneNote:$SkipOneNote -MaxRenders 50
Check 'full sync cycle ok' $cycle.Ok $cycle.Message

# 12. doctor
$checks = Invoke-RedriveDoctor
$fails = @($checks | Where-Object { $_.Status -eq 'FAIL' })
Check 'doctor has no FAIL lines' ($fails.Count -eq 0) (($fails | ForEach-Object { $_.Name }) -join ', ')

Write-Host ''
if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 } else { Write-Host 'all checks passed' -ForegroundColor Green }
