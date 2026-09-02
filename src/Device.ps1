# Device.ps1 - the tablet's document store: index, tree, metadata synthesis, device-ops window (ASCII only)

$script:RedriveIndexCache = $null

function ConvertTo-RedriveSafeName {
    <# Makes a tablet title safe for NTFS. #>
    param([AllowEmptyString()][string]$Name, [int]$MaxLength = 120)
    $n = [string]$Name
    if ($null -eq $n) { $n = '' }
    $n = $n -replace '[\x00-\x1f\\/:*?"<>|]', '_'
    $n = ($n -replace '\s+', ' ').Trim().TrimEnd('.', ' ')
    if ($n -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { $n = "_$n" }
    if ($n -eq '') { $n = 'Untitled' }
    if ($n.Length -gt $MaxLength) {
        $si = New-Object System.Globalization.StringInfo($n)
        if ($si.LengthInTextElements -gt $MaxLength) { $n = $si.SubstringByTextElements(0, $MaxLength).TrimEnd('.', ' ') }
    }
    return $n
}

function Get-RedriveIndexScript {
    $cfg = Get-RedriveConfig
    $d = [string]$cfg.DataDir
    return @"
D='$d'
cd "`$D" || { echo NO_DATADIR; exit 2; }
for f in *.metadata; do
  [ -f "`$f" ] || continue
  u="`${f%.metadata}"
  printf '\036M %s\n' "`$u"; cat "`$f"; printf '\n'
  if [ -f "`$u.content" ]; then printf '\036C %s\n' "`$u"; cat "`$u.content"; printf '\n'; fi
  if [ -d "`$u" ]; then
    n=0; s=''
    for r in "`$u"/*.rm; do
      [ -f "`$r" ] || continue
      sz=`$(wc -c < "`$r" 2>/dev/null | tr -d ' ')
      [ "`${sz:-0}" -gt 0 ] || continue
      n=`$((n+1)); mt=`$(stat -c %Y "`$r" 2>/dev/null || echo 0); s="`$s`${r##*/}:`$sz:`$mt;"
    done
    h=`$(printf '%s' "`$s" | md5sum | cut -c1-32)
    printf '\036R %s %s %s\n' "`$u" "`$n" "`$h"
  fi
done
printf '\036E\n'
"@
}

function ConvertFrom-RedriveIndexText {
    <# Parses the record-separated index dump into a hashtable uuid -> entry. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $index = @{}
    if ($Text -match 'NO_DATADIR') { throw 'the tablet data directory does not exist' }
    $records = $Text -split [string][char]30
    foreach ($rec in $records) {
        if (-not $rec) { continue }
        $nl = $rec.IndexOf("`n")
        $head = if ($nl -ge 0) { $rec.Substring(0, $nl).Trim() } else { $rec.Trim() }
        $body = if ($nl -ge 0) { $rec.Substring($nl + 1) } else { '' }
        if ($head.Length -lt 1) { continue }
        $kind = $head.Substring(0, 1)
        $rest = if ($head.Length -gt 2) { $head.Substring(2).Trim() } else { '' }
        switch ($kind) {
            'M' {
                $u = $rest
                if (-not $index.ContainsKey($u)) { $index[$u] = New-RedriveIndexEntry $u }
                try {
                    $m = $body | ConvertFrom-Json
                    $e = $index[$u]
                    $e.Name = [string]$m.visibleName
                    $e.Parent = if ($m.PSObject.Properties['parent']) { [string]$m.parent } else { '' }
                    $e.Type = [string]$m.type
                    $e.Deleted = ($m.PSObject.Properties['deleted'] -and [bool]$m.deleted)
                    $e.Pinned = ($m.PSObject.Properties['pinned'] -and [bool]$m.pinned)
                    $lm = 0L; if ($m.PSObject.Properties['lastModified']) { [long]::TryParse([string]$m.lastModified, [ref]$lm) | Out-Null }
                    $e.LastModified = $lm
                    $e.Metadata = ConvertTo-RedriveHashtable $m
                }
                catch { $index[$u].ParseError = "metadata: $($_.Exception.Message)" }
            }
            'C' {
                $u = $rest
                if (-not $index.ContainsKey($u)) { $index[$u] = New-RedriveIndexEntry $u }
                try {
                    $c = $body | ConvertFrom-Json
                    $e = $index[$u]
                    if ($c.PSObject.Properties['fileType']) { $e.FileType = [string]$c.fileType }
                    if ($c.PSObject.Properties['pageCount']) { $e.PageCount = [int]$c.pageCount }
                    $pages = @()
                    if ($c.PSObject.Properties['cPages'] -and $c.cPages -and $c.cPages.PSObject.Properties['pages']) {
                        $pl = @($c.cPages.pages | Where-Object { $_ -and -not ($_.PSObject.Properties['deleted'] -and $_.deleted) })
                        $pl = @($pl | Sort-Object { if ($_.idx -and $_.idx.PSObject.Properties['value']) { [string]$_.idx.value } else { '' } }, { [string]$_.id })
                        $pages = @($pl | ForEach-Object { [string]$_.id })
                    }
                    elseif ($c.PSObject.Properties['pages'] -and $c.pages) { $pages = @($c.pages | ForEach-Object { [string]$_ }) }
                    $e.Pages = $pages
                    if (-not $e.PageCount -and $pages.Count) { $e.PageCount = $pages.Count }
                }
                catch { $index[$u].ParseError = "content: $($_.Exception.Message)" }
            }
            'R' {
                $parts = $rest -split '\s+'
                if ($parts.Count -ge 3) {
                    $u = $parts[0]
                    if (-not $index.ContainsKey($u)) { $index[$u] = New-RedriveIndexEntry $u }
                    $index[$u].RmCount = [int]$parts[1]
                    $index[$u].RmSig = $parts[2]
                }
            }
            'E' { }
        }
    }
    foreach ($u in @($index.Keys)) {
        $e = $index[$u]
        $e.IsFolder = ($e.Type -eq 'CollectionType')
        $e.InTrash = ($e.Parent -eq 'trash') -or $e.Deleted
        if (-not $e.FileType -and -not $e.IsFolder) { $e.FileType = 'notebook' }
    }
    return $index
}

function New-RedriveIndexEntry([string]$Id) {
    return [pscustomobject]@{
        Id = $Id; Name = ''; Parent = ''; Type = ''; Deleted = $false; Pinned = $false; LastModified = 0L
        FileType = ''; PageCount = 0; Pages = @(); RmCount = 0; RmSig = ''; IsFolder = $false; InTrash = $false
        Metadata = $null; ParseError = $null
    }
}

function Get-RedriveIndex {
    <# Fetches and parses the whole document index in one SSH round trip. #>
    param([switch]$Cached)
    if ($Cached -and $script:RedriveIndexCache -and ((Get-Date) - $script:RedriveIndexCache.Time).TotalSeconds -lt 20) { return $script:RedriveIndexCache.Index }
    $r = Invoke-RedriveSshScript -Script (Get-RedriveIndexScript) -TimeoutSec 120
    if ($r.ExitCode -ne 0 -and -not $r.StdOut) { throw "index failed (exit $($r.ExitCode)): $($r.StdErr.Trim())" }
    $index = ConvertFrom-RedriveIndexText -Text $r.StdOut
    $script:RedriveIndexCache = @{ Time = Get-Date; Index = $index }
    Write-RedriveLog -Level Debug -Component 'device' -Message ("index: {0} entries" -f $index.Count)
    return $index
}

function Get-RedriveTree {
    <#
      Resolves folder chains into relative Windows paths with safe, de-duplicated names.
      Returns hashtable uuid -> @{ Path; Dir; Name; IsFolder; Entry } for live (non-trashed) entries only.
    #>
    param([Parameter(Mandatory)][hashtable]$Index)
    $tree = @{}
    $pathCache = @{}
    function Resolve-Dir([string]$id, [int]$depth) {
        if ($id -eq '' -or $id -eq 'trash') { return '' }
        if ($pathCache.ContainsKey($id)) { return $pathCache[$id] }
        if ($depth -gt 32 -or -not $Index.ContainsKey($id)) { return $null }
        $e = $Index[$id]
        if ($e.InTrash -or -not $e.IsFolder) { return $null }
        $parentDir = Resolve-Dir $e.Parent ($depth + 1)
        if ($null -eq $parentDir) { return $null }
        $name = ConvertTo-RedriveSafeName $e.Name
        $dir = if ($parentDir) { "$parentDir\$name" } else { $name }
        $pathCache[$id] = $dir
        return $dir
    }
    # group live entries by parent to de-duplicate sibling names deterministically
    $byParent = @{}
    foreach ($e in $Index.Values) {
        if ($e.InTrash -or -not $e.Name) { continue }
        if (-not $byParent.ContainsKey($e.Parent)) { $byParent[$e.Parent] = @() }
        $byParent[$e.Parent] += $e
    }
    $chosen = @{}   # uuid -> final safe name
    foreach ($parent in $byParent.Keys) {
        $seen = @{}
        foreach ($e in ($byParent[$parent] | Sort-Object { $_.Id })) {
            $base = ConvertTo-RedriveSafeName $e.Name
            $key = ($base + '|' + [string]$e.IsFolder).ToLower()
            $name = $base
            $i = 2
            while ($seen.ContainsKey($key)) { $name = "$base ($i)"; $key = ($name + '|' + [string]$e.IsFolder).ToLower(); $i++ }
            $seen[$key] = $true
            $chosen[$e.Id] = $name
        }
    }
    # folder paths use the chosen names too
    $pathCache = @{}
    function Resolve-Dir2([string]$id, [int]$depth) {
        if ($id -eq '' -or $id -eq 'trash') { return '' }
        if ($pathCache.ContainsKey($id)) { return $pathCache[$id] }
        if ($depth -gt 32 -or -not $Index.ContainsKey($id)) { return $null }
        $e = $Index[$id]
        if ($e.InTrash -or -not $e.IsFolder) { return $null }
        $parentDir = Resolve-Dir2 $e.Parent ($depth + 1)
        if ($null -eq $parentDir) { return $null }
        $name = $chosen[$id]
        $dir = if ($parentDir) { "$parentDir\$name" } else { $name }
        $pathCache[$id] = $dir
        return $dir
    }
    foreach ($e in $Index.Values) {
        if ($e.InTrash -or -not $e.Name) { continue }
        $dir = Resolve-Dir2 $e.Parent 0
        if ($null -eq $dir) { continue }      # parent chain broken or trashed
        $name = $chosen[$e.Id]
        $rel = if ($e.IsFolder) { if ($dir) { "$dir\$name" } else { $name } } else { if ($dir) { "$dir\$name.pdf" } else { "$name.pdf" } }
        $tree[$e.Id] = @{ Path = $rel; Dir = $dir; Name = $name; IsFolder = $e.IsFolder; Entry = $e }
    }
    return $tree
}

function Find-RedriveFolder {
    <# Finds the uuid of a tablet folder by relative path (segments separated by / or \), matching on visible names. #>
    param([Parameter(Mandatory)][hashtable]$Index, [Parameter(Mandatory)][string]$Path)
    $segments = @($Path -split '[\\/]+' | Where-Object { $_ -ne '' })
    $parent = ''
    foreach ($seg in $segments) {
        $match = $null
        foreach ($e in $Index.Values) {
            if ($e.IsFolder -and -not $e.InTrash -and $e.Parent -eq $parent -and ((ConvertTo-RedriveSafeName $e.Name) -eq (ConvertTo-RedriveSafeName $seg))) { $match = $e; break }
        }
        if (-not $match) { return $null }
        $parent = $match.Id
    }
    return $parent
}

function Get-RedriveNowMs { return [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }

function New-RedriveUuid { return ([guid]::NewGuid().ToString()) }

function New-RedriveMetadataJson {
    param([Parameter(Mandatory)][string]$Name, [string]$Parent = '', [ValidateSet('DocumentType', 'CollectionType')][string]$Type = 'DocumentType', [long]$NowMs = 0)
    if (-not $NowMs) { $NowMs = Get-RedriveNowMs }
    $o = [ordered]@{
        createdTime      = "$NowMs"
        deleted          = $false
        lastModified     = "$NowMs"
        lastOpened       = ''
        lastOpenedPage   = 0
        metadatamodified = $false
        modified         = $false
        parent           = $Parent
        pinned           = $false
        synced           = $false
        type             = $Type
        version          = 1
        visibleName      = $Name
    }
    if ($Type -eq 'CollectionType') { $o.Remove('lastOpened'); $o.Remove('lastOpenedPage') }
    return ($o | ConvertTo-Json -Depth 4)
}

function New-RedriveContentJson {
    param([ValidateSet('pdf', 'epub', 'folder', 'notebook')][string]$FileType = 'pdf')
    if ($FileType -eq 'folder') { return '{"tags": []}' }
    $o = [ordered]@{
        extraMetadata  = @{}
        fileType       = $FileType
        fontName       = ''
        lastOpenedPage = 0
        lineHeight     = -1
        margins        = 125
        orientation    = 'portrait'
        pageCount      = 0
        pages          = @()
        textScale      = 1
        transform      = [ordered]@{ m11 = 1; m12 = 0; m13 = 0; m21 = 0; m22 = 1; m23 = 0; m31 = 0; m32 = 0; m33 = 1 }
    }
    return ($o | ConvertTo-Json -Depth 4)
}

function Set-RedriveMetadataFromEntry {
    <# Produces a full .metadata JSON string for an existing entry with the given changes applied. #>
    param([Parameter(Mandatory)]$Entry, [hashtable]$Changes = @{})
    $m = $null
    if ($Entry.Metadata) { $m = Copy-RedriveHashtable $Entry.Metadata } else { $m = ConvertTo-RedriveHashtable (New-RedriveMetadataJson -Name $Entry.Name -Parent $Entry.Parent -Type $Entry.Type | ConvertFrom-Json) }
    foreach ($k in $Changes.Keys) { $m[$k] = $Changes[$k] }
    $m['lastModified'] = "$(Get-RedriveNowMs)"
    $m['metadatamodified'] = $true
    $m['synced'] = $false
    return ((ConvertTo-RedriveJsonReady $m) | ConvertTo-Json -Depth 6)
}

# ---------------------------------------------------------------- staging and the device-ops window

function Get-RedriveStagingLocal {
    $p = Initialize-RedriveHome
    $d = Join-Path $p.State 'staging'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

function Add-RedriveStagedFile {
    <# Copies local files into the tablet's staging directory (moved into the data dir by the next device-ops window). #>
    param([Parameter(Mandatory)][string[]]$Path)
    $cfg = Get-RedriveConfig
    $mk = Invoke-RedriveSsh -Command "mkdir -p '$($cfg.StagingDir)' && echo OK" -TimeoutSec 20
    if ($mk.StdOut -notmatch 'OK') { throw "cannot create staging dir: $($mk.StdErr.Trim())" }
    $r = Copy-RedriveToDevice -Path $Path -Destination ($cfg.StagingDir + '/') -TimeoutSec 900
    if ($r.ExitCode -ne 0) { throw "scp to staging failed: $($r.StdErr.Trim())" }
    Write-RedriveLog -Level Info -Component 'device' -Message ("staged {0} file(s) on the tablet" -f $Path.Count)
}

function Add-RedriveStagedDocument {
    <# Stages a new document (file + metadata + content) for the next device-ops window. Returns the new uuid. #>
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string]$Name, [string]$Parent = '', [string]$Uuid = $null)
    $ext = [IO.Path]::GetExtension($FilePath).ToLower().TrimStart('.')
    $ft = if ($ext -eq 'epub') { 'epub' } else { 'pdf' }
    if (-not $Uuid) { $Uuid = New-RedriveUuid }
    $local = Join-Path (Get-RedriveStagingLocal) $Uuid
    New-Item -ItemType Directory -Path $local -Force | Out-Null
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $local "$Uuid.metadata"), (New-RedriveMetadataJson -Name $Name -Parent $Parent), $enc)
    [IO.File]::WriteAllText((Join-Path $local "$Uuid.content"), (New-RedriveContentJson -FileType $ft), $enc)
    [IO.File]::WriteAllText((Join-Path $local "$Uuid.pagedata"), '', $enc)
    Copy-Item -LiteralPath $FilePath -Destination (Join-Path $local "$Uuid.$ft") -Force
    Add-RedriveStagedFile -Path @((Join-Path $local "$Uuid.metadata"), (Join-Path $local "$Uuid.content"), (Join-Path $local "$Uuid.pagedata"), (Join-Path $local "$Uuid.$ft"))
    Remove-Item -LiteralPath $local -Recurse -Force -ErrorAction SilentlyContinue
    return $Uuid
}

function Add-RedriveStagedFolder {
    param([Parameter(Mandatory)][string]$Name, [string]$Parent = '')
    $Uuid = New-RedriveUuid
    $local = Join-Path (Get-RedriveStagingLocal) $Uuid
    New-Item -ItemType Directory -Path $local -Force | Out-Null
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $local "$Uuid.metadata"), (New-RedriveMetadataJson -Name $Name -Parent $Parent -Type CollectionType), $enc)
    [IO.File]::WriteAllText((Join-Path $local "$Uuid.content"), (New-RedriveContentJson -FileType folder), $enc)
    Add-RedriveStagedFile -Path @((Join-Path $local "$Uuid.metadata"), (Join-Path $local "$Uuid.content"))
    Remove-Item -LiteralPath $local -Recurse -Force -ErrorAction SilentlyContinue
    return $Uuid
}

function Add-RedriveStagedMetadata {
    <# Stages a rewritten .metadata for an existing document (rename, move, trash). #>
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][hashtable]$Changes)
    $json = Set-RedriveMetadataFromEntry -Entry $Entry -Changes $Changes
    $local = Join-Path (Get-RedriveStagingLocal) $Entry.Id
    New-Item -ItemType Directory -Path $local -Force | Out-Null
    $enc = New-Object System.Text.UTF8Encoding($false)
    $f = Join-Path $local "$($Entry.Id).metadata"
    [IO.File]::WriteAllText($f, $json, $enc)
    Add-RedriveStagedFile -Path @($f)
    Remove-Item -LiteralPath $local -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-RedriveStagedCount {
    $cfg = Get-RedriveConfig
    $r = Invoke-RedriveSsh -Command "ls -A '$($cfg.StagingDir)' 2>/dev/null | wc -l" -TimeoutSec 20
    $n = 0; [int]::TryParse($r.StdOut.Trim(), [ref]$n) | Out-Null
    return $n
}

function Test-RedriveRestartBudget {
    <# Says whether a xochitl restart is allowed right now. #>
    $cfg = Get-RedriveConfig
    if (-not [bool]$cfg.AllowRestart) { return @{ Allowed = $false; Reason = 'restarts disabled in config' } }
    $state = Get-RedriveState
    $now = Get-Date
    $times = @()
    foreach ($t in @($state.RestartTimes)) { try { $times += [DateTime]::Parse([string]$t).ToUniversalTime() } catch { } }
    $recent = @($times | Where-Object { ($now.ToUniversalTime() - $_).TotalMinutes -lt 10 })
    if ($recent.Count -ge [int]$cfg.MaxRestartsPer10Min) { return @{ Allowed = $false; Reason = ("{0} restarts in the last 10 minutes (limit {1})" -f $recent.Count, $cfg.MaxRestartsPer10Min) } }
    if ($times.Count) {
        $last = ($times | Sort-Object)[-1]
        $mins = ($now.ToUniversalTime() - $last).TotalMinutes
        if ($mins -lt [int]$cfg.MinMinutesBetweenRestarts) { return @{ Allowed = $false; Reason = ("last restart {0:N1} min ago (minimum {1})" -f $mins, $cfg.MinMinutesBetweenRestarts) } }
    }
    return @{ Allowed = $true; Reason = '' }
}

function Register-RedriveRestart {
    $state = Get-RedriveState
    $now = (Get-Date).ToUniversalTime()
    $keep = @()
    foreach ($t in @($state.RestartTimes)) { try { $d = [DateTime]::Parse([string]$t).ToUniversalTime(); if (($now - $d).TotalMinutes -lt 30) { $keep += $d.ToString('o') } } catch { } }
    $keep += $now.ToString('o')
    $state.RestartTimes = $keep
    Save-RedriveState $state
}

function Test-RedriveDeviceIdle {
    param([int]$Seconds = 0)
    $cfg = Get-RedriveConfig
    if (-not $Seconds) { $Seconds = [int]$cfg.IdleSecondsBeforeRestart }
    $mins = [math]::Max(1, [int][math]::Ceiling($Seconds / 60.0))
    $r = Invoke-RedriveSsh -Command "find '$($cfg.DataDir)' -name '*.rm' -mmin -$mins 2>/dev/null | head -n 1" -TimeoutSec 60
    if ($r.ExitCode -ne 0 -and -not $r.StdOut) { return $true }   # cannot tell; do not block forever
    return (-not $r.StdOut.Trim())
}

function Invoke-RedriveDeviceWindow {
    <#
      The one place where xochitl is stopped: moves staged files into the data directory, then starts xochitl again.
      Returns @{ Ran; Reason; Seconds }.
    #>
    param([switch]$Force, [scriptblock]$OnStatus = $null)
    $cfg = Get-RedriveConfig
    $staged = Get-RedriveStagedCount
    if ($staged -le 0) { return @{ Ran = $false; Reason = 'nothing staged'; Seconds = 0 } }
    if (-not $Force) {
        $b = Test-RedriveRestartBudget
        if (-not $b.Allowed) { Write-RedriveLog -Level Info -Component 'device' -Message ("device window postponed: {0} ({1} staged)" -f $b.Reason, $staged); return @{ Ran = $false; Reason = $b.Reason; Seconds = 0 } }
        if (-not (Test-RedriveDeviceIdle)) { Write-RedriveLog -Level Info -Component 'device' -Message 'device window postponed: tablet is in use'; return @{ Ran = $false; Reason = 'tablet in use'; Seconds = 0 } }
    }
    if ($OnStatus) { & $OnStatus 'reMarkable app restarting (about 10 s)' }
    $script = @"
D='$($cfg.DataDir)'; S='$($cfg.StagingDir)'
systemctl reset-failed xochitl 2>/dev/null
systemctl stop xochitl || { echo STOP_FAILED; exit 10; }
sleep 1
moved=0
if [ -d "`$S" ]; then
  for f in "`$S"/* "`$S"/.[!.]*; do
    [ -e "`$f" ] || continue
    mv -f "`$f" "`$D"/ && moved=`$((moved+1))
  done
fi
sync
systemctl start xochitl || { echo START_FAILED; exit 11; }
i=0
while [ `$i -lt 40 ]; do
  if systemctl is-active xochitl >/dev/null 2>&1; then echo "WINDOW_OK `$moved"; exit 0; fi
  sleep 1; i=`$((i+1))
done
echo START_TIMEOUT; exit 12
"@
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Register-RedriveRestart
    $r = Invoke-RedriveSshScript -Script $script -TimeoutSec 180
    $script:RedriveIndexCache = $null
    if ($r.StdOut -match 'WINDOW_OK (\d+)') {
        Write-RedriveLog -Level Info -Component 'device' -Message ("device window done: {0} file(s) moved in {1:N0} s" -f $Matches[1], $sw.Elapsed.TotalSeconds)
        # wait for the web interface to come back too
        for ($i = 0; $i -lt 30; $i++) { if (Test-RedriveTcpPort -TargetHost $cfg.Host -Port ([uri]$cfg.WebBase).Port -TimeoutMs 1000) { break }; Start-Sleep -Seconds 1 }
        return @{ Ran = $true; Reason = ''; Seconds = [int]$sw.Elapsed.TotalSeconds }
    }
    Write-RedriveLog -Level Error -Component 'device' -Message ("device window failed: {0} {1}" -f $r.StdOut.Trim(), $r.StdErr.Trim())
    return @{ Ran = $false; Reason = ("failed: " + $r.StdOut.Trim() + ' ' + $r.StdErr.Trim()).Trim(); Seconds = [int]$sw.Elapsed.TotalSeconds }
}

# ---------------------------------------------------------------- device information

function Get-RedriveDeviceInfo {
    $cfg = Get-RedriveConfig
    $script = @"
D='$($cfg.DataDir)'
echo "model=`$(cat /sys/devices/soc0/machine 2>/dev/null)"
echo "hostname=`$(hostname 2>/dev/null)"
echo "arch=`$(uname -m 2>/dev/null)"
echo "kernel=`$(uname -r 2>/dev/null)"
echo "version_stamp=`$(cat /etc/version 2>/dev/null)"
echo "img_version=`$(grep '^IMG_VERSION=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '\"')"
echo "release_version=`$(grep '^REMARKABLE_RELEASE_VERSION=' /usr/share/remarkable/update.conf 2>/dev/null | cut -d= -f2-)"
echo "free_kb=`$(df -Pk /home/root 2>/dev/null | tail -n 1 | awk '{print `$4}')"
echo "docs=`$(ls "`$D"/*.metadata 2>/dev/null | wc -l | tr -d ' ')"
echo "datadir_ok=`$([ -d "`$D" ] && echo 1 || echo 0)"
echo "web_enabled=`$(grep -c '^WebInterfaceEnabled=true' /home/root/.config/remarkable/xochitl.conf 2>/dev/null)"
echo "sftp_server=`$(ls /usr/libexec/sftp-server /usr/lib/openssh/sftp-server /usr/lib/ssh/sftp-server 2>/dev/null | head -n 1)"
echo "xochitl=`$(systemctl is-active xochitl 2>/dev/null)"
echo "staged=`$(ls -A '$($cfg.StagingDir)' 2>/dev/null | wc -l | tr -d ' ')"
echo "port80=`$(grep -c ':0050 00000000:0000 0A' /proc/net/tcp 2>/dev/null)"
"@
    $r = Invoke-RedriveSshScript -Script $script -TimeoutSec 60
    $info = @{}
    foreach ($line in ($r.StdOut -split "`n")) {
        if ($line -match '^([a-z_0-9]+)=(.*)$') { $info[$Matches[1]] = $Matches[2].Trim() }
    }
    $fw = ''
    if ($info['img_version']) { $fw = $info['img_version'] } elseif ($info['release_version']) { $fw = $info['release_version'] }
    $info['firmware'] = $fw
    $info['ok'] = ($r.ExitCode -eq 0 -and $info.ContainsKey('arch'))
    $info['error'] = if ($r.ExitCode -ne 0) { $r.StdErr.Trim() } else { '' }
    return $info
}

function Enable-RedriveWebInterface {
    <# Turns on the USB web interface in xochitl.conf (only while xochitl is stopped). Counts as one restart. #>
    param([switch]$Force)
    $conf = '/home/root/.config/remarkable/xochitl.conf'
    $chk = Invoke-RedriveSsh -Command "grep -c '^WebInterfaceEnabled=true' $conf 2>/dev/null" -TimeoutSec 20
    if ($chk.StdOut.Trim() -match '^[1-9]') { return @{ Changed = $false; Ok = $true; Reason = 'already enabled' } }
    if (-not $Force) {
        $b = Test-RedriveRestartBudget
        if (-not $b.Allowed) { return @{ Changed = $false; Ok = $false; Reason = $b.Reason } }
    }
    $script = @"
C='$conf'
systemctl reset-failed xochitl 2>/dev/null
systemctl stop xochitl || { echo STOP_FAILED; exit 10; }
sleep 1
[ -f "`$C" ] || printf '[General]\n' > "`$C"
if grep -q '^WebInterfaceEnabled=' "`$C"; then
  sed -i 's/^WebInterfaceEnabled=.*/WebInterfaceEnabled=true/' "`$C"
elif grep -q '^\[General\]' "`$C"; then
  awk '{print} /^\[General\]/ {print "WebInterfaceEnabled=true"}' "`$C" > "`$C.new" && mv "`$C.new" "`$C"
else
  printf '\n[General]\nWebInterfaceEnabled=true\n' >> "`$C"
fi
sync
systemctl start xochitl || { echo START_FAILED; exit 11; }
i=0; while [ `$i -lt 40 ]; do systemctl is-active xochitl >/dev/null 2>&1 && { echo WEB_ENABLED; exit 0; }; sleep 1; i=`$((i+1)); done
echo START_TIMEOUT; exit 12
"@
    Register-RedriveRestart
    $r = Invoke-RedriveSshScript -Script $script -TimeoutSec 180
    if ($r.StdOut -match 'WEB_ENABLED') {
        Write-RedriveLog -Level Info -Component 'device' -Message 'USB web interface enabled in xochitl.conf'
        return @{ Changed = $true; Ok = $true; Reason = '' }
    }
    return @{ Changed = $false; Ok = $false; Reason = ($r.StdOut.Trim() + ' ' + $r.StdErr.Trim()).Trim() }
}
