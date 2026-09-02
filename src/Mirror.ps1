# Mirror.ps1 - keeps the local folder (the R: drive) in step with the tablet (ASCII only)
#
# Pull:  tablet index -> folder tree -> tablet-rendered PDFs (read-only files) in the mirror.
# Push:  new PDF/EPUB files the user drops into the mirror -> uploaded to the tablet.
# Both run inside Invoke-RedriveSync, which the tray starts as a separate process.

$script:RedriveTempFiles = @()

function Write-RedriveStatus {
    <# status.json is what the tray shows in its tooltip while a sync runs. #>
    param([string]$Phase = '', [string]$Message = '', [string]$Progress = '', [bool]$Running = $true, [string]$Error = '', [bool]$Ok = $true, [bool]$Changes = $false)
    $p = Initialize-RedriveHome
    $o = [ordered]@{ Running = $Running; Phase = $Phase; Message = $Message; Progress = $Progress; Error = $Error; Ok = $Ok; Changes = $Changes; Pid = $PID; Updated = (Get-Date).ToString('o') }
    try { Write-RedriveJsonFile -Path $p.StatusFile -Object $o } catch { }
}

function Get-RedriveStatus {
    $p = Get-RedrivePaths
    return (Read-RedriveJsonFile -Path $p.StatusFile -Default $null)
}

function Get-RedriveMirrorRoot {
    $cfg = Get-RedriveConfig
    $root = [string]$cfg.MirrorRoot
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $inbox = Join-Path $root ([string]$cfg.InboxFolder)
    if (-not (Test-Path -LiteralPath $inbox)) { New-Item -ItemType Directory -Path $inbox -Force | Out-Null }
    return $root.TrimEnd('\')
}

function Get-RedriveFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function Set-RedriveReadOnly {
    param([Parameter(Mandatory)][string]$Path, [bool]$ReadOnly = $true)
    try {
        $attr = [IO.File]::GetAttributes($Path)
        if ($ReadOnly) { $attr = $attr -bor [IO.FileAttributes]::ReadOnly } else { $attr = $attr -band (-bnot [IO.FileAttributes]::ReadOnly) }
        [IO.File]::SetAttributes($Path, $attr)
    }
    catch { }
}

function Test-RedriveReadOnly {
    param([Parameter(Mandatory)][string]$Path)
    try { return (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReadOnly) -ne 0) } catch { return $false }
}

function Move-RedriveToRecycleBin {
    param([Parameter(Mandatory)][string]$Path)
    try {
        Set-RedriveReadOnly -Path $Path -ReadOnly $false
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        return $true
    }
    catch {
        try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop; return $true } catch { return $false }
    }
}

function Test-RedriveFileReady {
    <# A dropped file counts only when it is at least 2 s old and can be opened exclusively. #>
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    if (((Get-Date) - $File.LastWriteTime).TotalSeconds -lt 2) { return $false }
    try { $fs = [IO.File]::Open($File.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None); $fs.Close(); return $true } catch { return $false }
}

function Get-RedriveRelativePath {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$FullPath)
    $r = $Root.TrimEnd('\') + '\'
    if ($FullPath.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { return $FullPath.Substring($r.Length) }
    return $FullPath
}

function New-RedriveTempFile {
    param([string]$Extension = '.tmp')
    $p = Initialize-RedriveHome
    $f = Join-Path $p.Incoming ([guid]::NewGuid().ToString('n') + $Extension)
    $script:RedriveTempFiles += $f
    return $f
}

# ---------------------------------------------------------------- pull

function Sync-RedrivePull {
    <#
      Brings the mirror folder in line with the tablet. Returns a summary hashtable.
      -MaxRenders caps the tablet renders per call so pushes still get their turn.
    #>
    param([int]$MaxRenders = 60, [switch]$NoRender, [scriptblock]$Progress = $null)
    $cfg = Get-RedriveConfig
    $root = Get-RedriveMirrorRoot
    $state = Get-RedriveState
    $summary = @{ Rendered = 0; Moved = 0; Removed = 0; Pending = 0; Errors = 0; Folders = 0; Messages = @() }
    Write-RedriveStatus -Phase 'pull' -Message 'Reading the tablet index'
    $index = Get-RedriveIndex
    $tree = Get-RedriveTree -Index $index
    $docs = $state.Documents
    if (-not ($docs -is [hashtable])) { $docs = @{}; $state.Documents = $docs }

    # 1. folders
    foreach ($id in $tree.Keys) {
        $t = $tree[$id]
        if (-not $t.IsFolder) { continue }
        $dir = Join-Path $root $t.Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null; $summary.Folders++ }
        $state.Folders[$t.Path.ToLower()] = $id
    }

    # 2. documents: moves and the render queue
    $queue = @()
    foreach ($id in $tree.Keys) {
        $t = $tree[$id]
        if ($t.IsFolder) { continue }
        $e = $t.Entry
        $local = Join-Path $root $t.Path
        $known = $null
        if ($docs.ContainsKey($id)) { $known = $docs[$id] }
        if ($known -and $known.Path -and ($known.Path -ne $t.Path)) {
            $old = Join-Path $root $known.Path
            if ((Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $local)) {
                $dir = Split-Path -Parent $local
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                try { Move-Item -LiteralPath $old -Destination $local -Force; $summary.Moved++; Write-RedriveLog -Level Info -Component 'mirror' -Message "moved '$($known.Path)' -> '$($t.Path)'" } catch { $summary.Errors++ }
            }
            $known.Path = $t.Path
        }
        $need = $false
        if (-not $known) { $need = $true }
        elseif (-not (Test-Path -LiteralPath $local)) { $need = $true }
        elseif ([string]$known.RenderedLastModified -ne [string]$e.LastModified) { $need = $true }
        elseif ([string]$known.RenderedRmSig -ne [string]$e.RmSig) { $need = $true }
        if (-not $known) {
            $known = @{ Path = $t.Path; Name = $e.Name; Parent = $e.Parent; LastModified = $e.LastModified; RmSig = $e.RmSig; RmCount = $e.RmCount; FileType = $e.FileType; RenderedAt = $null; RenderedLastModified = $null; RenderedRmSig = $null; RenderedHash = $null }
            $docs[$id] = $known
        }
        else {
            $known.Name = $e.Name; $known.Parent = $e.Parent; $known.LastModified = $e.LastModified; $known.RmSig = $e.RmSig; $known.RmCount = $e.RmCount; $known.FileType = $e.FileType; $known.Path = $t.Path
        }
        if ($need) { $queue += @{ Id = $id; Local = $local; Entry = $e; Known = $known; Rel = $t.Path } }
    }

    # 3. gone from the tablet (trashed, deleted, or lost): recycle the local copy
    foreach ($id in @($docs.Keys)) {
        if ($tree.ContainsKey($id)) { continue }
        $known = $docs[$id]
        $local = if ($known.Path) { Join-Path $root $known.Path } else { $null }
        if ($local -and (Test-Path -LiteralPath $local) -and (Test-RedriveReadOnly -Path $local)) {
            if (Move-RedriveToRecycleBin -Path $local) { $summary.Removed++; Write-RedriveLog -Level Info -Component 'mirror' -Message "removed '$($known.Path)' (gone from the tablet; sent to the Recycle Bin)" }
        }
        $docs.Remove($id)
    }
    # folders gone from the tablet: remove local dir only when empty
    foreach ($k in @($state.Folders.Keys)) {
        $fid = $state.Folders[$k]
        if ($tree.ContainsKey($fid)) { continue }
        $dir = Join-Path $root $k
        if ((Test-Path -LiteralPath $dir) -and -not (Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue }
        $state.Folders.Remove($k)
    }
    Save-RedriveState $state

    # 4. renders (newest first)
    $queue = @($queue | Sort-Object { -[long]$_.Entry.LastModified })
    $summary.Pending = $queue.Count
    if ($NoRender -or $queue.Count -eq 0) { $state.LastPull = (Get-Date).ToString('o'); Save-RedriveState $state; return $summary }
    $webOk = Test-RedriveWeb
    if (-not $webOk) { Write-RedriveLog -Level Warn -Component 'mirror' -Message 'web interface not reachable: falling back to raw PDFs without handwriting' }
    $n = 0
    foreach ($q in $queue) {
        if ($n -ge $MaxRenders) { break }
        $n++
        $msg = "Copying {0}/{1}: {2}" -f $n, [math]::Min($queue.Count, $MaxRenders), $q.Entry.Name
        Write-RedriveStatus -Phase 'pull' -Message $msg -Progress "$n/$($queue.Count)"
        if ($Progress) { & $Progress $msg }
        if (-not (Test-RedriveDevice).Reachable) { Write-RedriveLog -Level Warn -Component 'mirror' -Message 'tablet went away during pull'; break }
        $tmp = New-RedriveTempFile -Extension '.pdf'
        $ok = $false
        try {
            if ($webOk) {
                $r = Get-RedriveWebRender -Id $q.Id -OutFile $tmp
                $ok = $r.Ok
                if (-not $ok) { Write-RedriveLog -Level Warn -Component 'mirror' -Message ("render failed for '{0}': {1} {2}" -f $q.Entry.Name, $r.StatusCode, $r.Error) }
            }
            if (-not $ok -and $q.Entry.FileType -eq 'pdf') {
                $r2 = Copy-RedriveFromDevice -RemotePath "$($cfg.DataDir)/$($q.Id).pdf" -Destination $tmp -TimeoutSec 300
                $ok = ($r2.ExitCode -eq 0 -and (Test-Path -LiteralPath $tmp))
            }
            if ($ok) {
                $dir = Split-Path -Parent $q.Local
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                if (Test-Path -LiteralPath $q.Local) { Set-RedriveReadOnly -Path $q.Local -ReadOnly $false; Remove-Item -LiteralPath $q.Local -Force }
                Move-Item -LiteralPath $tmp -Destination $q.Local -Force
                try { if ($q.Entry.LastModified -gt 0) { [IO.File]::SetLastWriteTimeUtc($q.Local, [DateTimeOffset]::FromUnixTimeMilliseconds($q.Entry.LastModified).UtcDateTime) } } catch { }
                Set-RedriveReadOnly -Path $q.Local -ReadOnly $true
                $q.Known.RenderedAt = (Get-Date).ToString('o')
                $q.Known.RenderedLastModified = $q.Entry.LastModified
                $q.Known.RenderedRmSig = $q.Entry.RmSig
                $q.Known.RenderedHash = Get-RedriveFileSha256 -Path $q.Local
                # a file the user dropped and we pushed is now absorbed by the mirror copy
                foreach ($pk in @($state.Pushed.Keys)) {
                    $pu = $state.Pushed[$pk]
                    if ($pu.Uuid -eq $q.Id) {
                        $src = Join-Path $root $pk
                        if (($pk -ne $q.Rel) -and (Test-Path -LiteralPath $src) -and -not (Test-RedriveReadOnly -Path $src)) { Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue }
                        $state.Pushed.Remove($pk)
                    }
                }
                $summary.Rendered++
                Save-RedriveState $state
            }
            else { $summary.Errors++ }
        }
        catch { $summary.Errors++; Write-RedriveLog -Level Error -Component 'mirror' -Message ("render of '{0}' failed: {1}" -f $q.Entry.Name, $_.Exception.Message) }
        finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
        if ([int]$cfg.RenderPacingSeconds -gt 0) { Start-Sleep -Seconds ([int]$cfg.RenderPacingSeconds) }
    }
    $summary.Pending = [math]::Max(0, $queue.Count - $summary.Rendered - $summary.Errors)
    $state.LastPull = (Get-Date).ToString('o')
    Save-RedriveState $state
    return $summary
}

# ---------------------------------------------------------------- push

function Get-RedrivePushCandidates {
    <# Files the user put into the mirror that are not (yet) mirror copies. #>
    $cfg = Get-RedriveConfig
    $root = Get-RedriveMirrorRoot
    $state = Get-RedriveState
    $byPath = @{}
    foreach ($id in $state.Documents.Keys) { $d = $state.Documents[$id]; if ($d.Path) { $byPath[([string]$d.Path).ToLower()] = @{ Id = $id; Doc = $d } } }
    $list = @()
    foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue)) {
        $ext = $f.Extension.ToLower()
        if ($ext -notin @('.pdf', '.epub')) { continue }
        if ($f.Name -match '^(~\$|\.)' -or $f.Name -match '\.(tmp|part|crdownload)$') { continue }
        $rel = Get-RedriveRelativePath -Root $root -FullPath $f.FullName
        $top = ($rel -split '\\')[0]
        if ($top -like '_*' -and $top -ne [string]$cfg.InboxFolder) { continue }     # _Archive and friends are local only
        if (Test-RedriveReadOnly -Path $f.FullName) { continue }                        # mirror copies are read-only
        if (-not (Test-RedriveFileReady -File $f)) { continue }
        $hash = Get-RedriveFileSha256 -Path $f.FullName
        $key = $rel.ToLower()
        if ($state.Pushed.ContainsKey($rel) -and ([string]$state.Pushed[$rel].Hash -eq $hash)) { continue }   # already uploaded, waiting for its mirror copy
        $kind = 'new'; $docId = $null
        if ($byPath.ContainsKey($key)) {
            $known = $byPath[$key]
            if ([string]$known.Doc.RenderedHash -eq $hash) { continue }   # someone cleared the read-only bit but did not change it
            $kind = 'replace'; $docId = $known.Id
        }
        $list += @{ File = $f; Rel = $rel; Hash = $hash; Kind = $kind; DocId = $docId }
    }
    return $list
}

function Resolve-RedriveTabletFolder {
    <#
      Finds or stages the tablet folder for a relative mirror directory. Returns @{ Id; Staged }.
      '' and the inbox folder map to the tablet root.
    #>
    param([Parameter(Mandatory)][hashtable]$Index, [AllowEmptyString()][string]$RelativeDir, [hashtable]$StagedFolders)
    $cfg = Get-RedriveConfig
    $dir = $RelativeDir.Trim('\')
    if ($dir -eq '' -or $dir -ieq [string]$cfg.InboxFolder) { return @{ Id = ''; Staged = $false } }
    $segments = @($dir -split '\\' | Where-Object { $_ -ne '' })
    $parent = ''
    $path = ''
    $staged = $false
    foreach ($seg in $segments) {
        $path = if ($path) { "$path\$seg" } else { $seg }
        $key = $path.ToLower()
        if ($StagedFolders.ContainsKey($key)) { $parent = $StagedFolders[$key]; $staged = $true; continue }
        $found = $null
        foreach ($e in $Index.Values) {
            if ($e.IsFolder -and -not $e.InTrash -and $e.Parent -eq $parent -and ((ConvertTo-RedriveSafeName $e.Name) -ieq (ConvertTo-RedriveSafeName $seg))) { $found = $e.Id; break }
        }
        if ($found) { $parent = $found; continue }
        $newId = Add-RedriveStagedFolder -Name $seg -Parent $parent
        Write-RedriveLog -Level Info -Component 'mirror' -Message "staged new tablet folder '$path'"
        $StagedFolders[$key] = $newId
        $parent = $newId
        $staged = $true
    }
    return @{ Id = $parent; Staged = $staged }
}

function Push-RedriveFile {
    <#
      Uploads one local file as a new tablet document. Returns @{ Ok; Uuid; Strategy; NeedsWindow; Message }.
      Strategy 'web' when the web interface is up; a folder placement that the web interface cannot do is staged
      as a metadata rewrite for the device-ops window.
    #>
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string]$Title, [AllowEmptyString()][string]$FolderId = '', [bool]$FolderIsStaged = $false, [hashtable]$Index = $null)
    $cfg = Get-RedriveConfig
    $strategies = @($cfg.PushStrategy)
    $webOk = $false
    if ($strategies -contains 'web') { $webOk = Test-RedriveWeb }
    if ($webOk) {
        $listFolder = if ($FolderIsStaged) { '' } else { $FolderId }
        $r = Send-RedriveWebUpload -FilePath $FilePath -Title $Title -FolderId $listFolder
        if ($r.Ok -and $r.Entry) {
            $entry = $r.Entry
            $needsWindow = $false
            if ($FolderId -and ($entry.Parent -ne $FolderId)) {
                # landed at root: stage a metadata rewrite to file it into the folder
                if (-not $Index) { $Index = Get-RedriveIndex }
                $ie = $null
                if ($Index.ContainsKey($entry.Id)) { $ie = $Index[$entry.Id] }
                if (-not $ie) { $fresh = Get-RedriveIndex; if ($fresh.ContainsKey($entry.Id)) { $ie = $fresh[$entry.Id] } }
                if ($ie) { Add-RedriveStagedMetadata -Entry $ie -Changes @{ parent = $FolderId; visibleName = $Title }; $needsWindow = $true }
                else { Write-RedriveLog -Level Warn -Component 'mirror' -Message "uploaded '$Title' but could not find its metadata to file it into the folder" }
            }
            elseif ($entry.Name -ne $Title) {
                if (-not $Index) { $Index = Get-RedriveIndex }
                if ($Index.ContainsKey($entry.Id)) { Add-RedriveStagedMetadata -Entry $Index[$entry.Id] -Changes @{ visibleName = $Title }; $needsWindow = $true }
            }
            return @{ Ok = $true; Uuid = $entry.Id; Strategy = 'web'; NeedsWindow = $needsWindow; Message = 'uploaded' }
        }
        if ($r.Ok -and -not $r.Entry) { Write-RedriveLog -Level Warn -Component 'mirror' -Message "upload of '$Title' returned $($r.StatusCode) but the new document was not found in the listing" }
        else { Write-RedriveLog -Level Warn -Component 'mirror' -Message "web upload of '$Title' failed: $($r.StatusCode) $($r.Error)" }
    }
    if ($strategies -contains 'scp') {
        $u = Add-RedriveStagedDocument -FilePath $FilePath -Name $Title -Parent $FolderId
        return @{ Ok = $true; Uuid = $u; Strategy = 'scp'; NeedsWindow = $true; Message = 'staged (appears after the next tablet restart)' }
    }
    return @{ Ok = $false; Uuid = $null; Strategy = ''; NeedsWindow = $false; Message = 'no push strategy succeeded' }
}

function Update-RedriveDocument {
    <#
      Replaces the content of an existing tablet document with a new PDF.
      NewCopyRetireOld (default): keep a local copy of the old render, upload the new file as a new document, retire the old one.
      InPlace: overwrite the PDF in the device-ops window and clear its strokes.
      Returns @{ Ok; Uuid (the document that now carries the content); NeedsWindow; Message }.
    #>
    param([Parameter(Mandatory)][string]$Uuid, [Parameter(Mandatory)][string]$FilePath, [string]$Title = $null, [hashtable]$Index = $null)
    $cfg = Get-RedriveConfig
    if (-not $Index) { $Index = Get-RedriveIndex }
    if (-not $Index.ContainsKey($Uuid)) { return @{ Ok = $false; Uuid = $Uuid; NeedsWindow = $false; Message = 'document no longer exists on the tablet' } }
    $e = $Index[$Uuid]
    if (-not $Title) { $Title = $e.Name }
    $root = Get-RedriveMirrorRoot
    $state = Get-RedriveState
    # keep the old render (with handwriting) locally before it is replaced
    if ($state.Documents.ContainsKey($Uuid) -and $e.RmCount -gt 0) {
        $old = Join-Path $root $state.Documents[$Uuid].Path
        if (Test-Path -LiteralPath $old) {
            $arch = Join-Path $root '_Archive'
            if (-not (Test-Path -LiteralPath $arch)) { New-Item -ItemType Directory -Path $arch -Force | Out-Null }
            $dest = Join-Path $arch ("{0} (replaced {1}).pdf" -f (ConvertTo-RedriveSafeName $e.Name 100), (Get-Date -Format 'yyyy-MM-dd HHmm'))
            try { Copy-Item -LiteralPath $old -Destination $dest -Force; Set-RedriveReadOnly -Path $dest -ReadOnly $false } catch { }
        }
    }
    if ([string]$cfg.ReplacePolicy -eq 'InPlace') {
        $ext = if ([IO.Path]::GetExtension($FilePath).ToLower() -eq '.epub') { 'epub' } else { 'pdf' }
        $local = Join-Path (Get-RedriveStagingLocal) $Uuid
        New-Item -ItemType Directory -Path $local -Force | Out-Null
        Copy-Item -LiteralPath $FilePath -Destination (Join-Path $local "$Uuid.$ext") -Force
        [IO.File]::WriteAllText((Join-Path $local "$Uuid.redrive-clear"), '', (New-Object System.Text.UTF8Encoding($false)))
        Add-RedriveStagedFile -Path @((Join-Path $local "$Uuid.$ext"), (Join-Path $local "$Uuid.redrive-clear"))
        Add-RedriveStagedMetadata -Entry $e -Changes @{ visibleName = $Title }
        Remove-Item -LiteralPath $local -Recurse -Force -ErrorAction SilentlyContinue
        return @{ Ok = $true; Uuid = $Uuid; NeedsWindow = $true; Message = 'replaced in place (after the next tablet restart)' }
    }
    # NewCopyRetireOld
    $push = Push-RedriveFile -FilePath $FilePath -Title $Title -FolderId $e.Parent -Index $Index
    if (-not $push.Ok) { return @{ Ok = $false; Uuid = $Uuid; NeedsWindow = $false; Message = "upload failed: $($push.Message)" } }
    $retire = [string]$cfg.RetireMode
    $needsWindow = [bool]$push.NeedsWindow
    if ($retire -eq 'Trash') { Add-RedriveStagedMetadata -Entry $e -Changes @{ parent = 'trash' }; $needsWindow = $true }
    elseif ($retire -eq 'Archive') {
        $stagedFolders = @{}
        $af = Resolve-RedriveTabletFolder -Index $Index -RelativeDir (([string]$cfg.ArchiveFolder) -replace '/', '\') -StagedFolders $stagedFolders
        Add-RedriveStagedMetadata -Entry $e -Changes @{ parent = $af.Id; visibleName = ("{0} (replaced {1})" -f $e.Name, (Get-Date -Format 'yyyy-MM-dd')) }
        $needsWindow = $true
    }
    if ($state.Documents.ContainsKey($Uuid)) { $state.Documents[$Uuid].Superseded = $push.Uuid; Save-RedriveState $state }
    return @{ Ok = $true; Uuid = $push.Uuid; NeedsWindow = $needsWindow; Message = "replaced (new copy uploaded; old copy $($retire.ToLower()) after the next tablet restart)" }
}

function Sync-RedrivePush {
    <# Uploads dropped files and replacements. Returns a summary. #>
    param([scriptblock]$Progress = $null)
    $cfg = Get-RedriveConfig
    $root = Get-RedriveMirrorRoot
    $summary = @{ Uploaded = 0; Replaced = 0; Errors = 0; NeedsWindow = $false; Messages = @() }
    Write-RedriveStatus -Phase 'push' -Message 'Looking for new files'
    $candidates = @(Get-RedrivePushCandidates)
    if ($candidates.Count -eq 0) { return $summary }
    $index = Get-RedriveIndex
    $state = Get-RedriveState
    $stagedFolders = @{}
    $n = 0
    foreach ($c in $candidates) {
        $n++
        $title = [IO.Path]::GetFileNameWithoutExtension($c.File.Name)
        $msg = "Sending {0}/{1}: {2}" -f $n, $candidates.Count, $title
        Write-RedriveStatus -Phase 'push' -Message $msg -Progress "$n/$($candidates.Count)"
        if ($Progress) { & $Progress $msg }
        if (-not (Test-RedriveDevice).Reachable) { Write-RedriveLog -Level Warn -Component 'mirror' -Message 'tablet went away during push'; break }
        try {
            if ($c.Kind -eq 'replace') {
                $r = Update-RedriveDocument -Uuid $c.DocId -FilePath $c.File.FullName -Title $title -Index $index
                if ($r.Ok) {
                    $summary.Replaced++
                    if ($r.NeedsWindow) { $summary.NeedsWindow = $true }
                    if ($state.Documents.ContainsKey($c.DocId)) { $state.Documents[$c.DocId].Superseded = $r.Uuid }
                    $state.Pushed[$c.Rel] = @{ Uuid = $r.Uuid; Hash = $c.Hash; PushedAt = (Get-Date).ToString('o'); Title = $title; Replace = $true }
                    Write-RedriveLog -Level Info -Component 'mirror' -Message "replaced '$($c.Rel)': $($r.Message)"
                }
                else { $summary.Errors++; Write-RedriveLog -Level Error -Component 'mirror' -Message "replace of '$($c.Rel)' failed: $($r.Message)" }
            }
            else {
                $relDir = Split-Path -Parent $c.Rel
                if ($null -eq $relDir) { $relDir = '' }
                $folder = Resolve-RedriveTabletFolder -Index $index -RelativeDir $relDir -StagedFolders $stagedFolders
                if ($folder.Staged) { $summary.NeedsWindow = $true }
                $r = Push-RedriveFile -FilePath $c.File.FullName -Title $title -FolderId $folder.Id -FolderIsStaged $folder.Staged -Index $index
                if ($r.Ok) {
                    $summary.Uploaded++
                    if ($r.NeedsWindow) { $summary.NeedsWindow = $true }
                    $state.Pushed[$c.Rel] = @{ Uuid = $r.Uuid; Hash = $c.Hash; PushedAt = (Get-Date).ToString('o'); Title = $title; Strategy = $r.Strategy }
                    Write-RedriveLog -Level Info -Component 'mirror' -Message "sent '$($c.Rel)' to the tablet ($($r.Strategy)): $($r.Message)"
                }
                else { $summary.Errors++; Write-RedriveLog -Level Error -Component 'mirror' -Message "push of '$($c.Rel)' failed: $($r.Message)" }
            }
            Save-RedriveState $state
        }
        catch { $summary.Errors++; Write-RedriveLog -Level Error -Component 'mirror' -Message "push of '$($c.Rel)' failed: $($_.Exception.Message)" }
    }
    return $summary
}

# ---------------------------------------------------------------- backup

function Backup-RedriveTablet {
    <# Incremental raw copy of every document's files into <home>\backup\xochitl (insurance; the users have no cloud). #>
    param([scriptblock]$Progress = $null)
    $cfg = Get-RedriveConfig
    $p = Initialize-RedriveHome
    $dest = Join-Path $p.Backup 'xochitl'
    if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    $state = Get-RedriveState
    if (-not $state.ContainsKey('Backup')) { $state.Backup = @{} }
    $index = Get-RedriveIndex
    $todo = @()
    foreach ($e in $index.Values) {
        $key = $e.Id
        $stamp = "$($e.LastModified)|$($e.RmSig)"
        if ($state.Backup.ContainsKey($key) -and ([string]$state.Backup[$key] -eq $stamp)) { continue }
        $todo += $e
    }
    $summary = @{ Copied = 0; Errors = 0; Total = $index.Count; Destination = $dest }
    $n = 0
    foreach ($e in $todo) {
        $n++
        $msg = "Backing up {0}/{1}: {2}" -f $n, $todo.Count, $e.Name
        Write-RedriveStatus -Phase 'backup' -Message $msg -Progress "$n/$($todo.Count)"
        if ($Progress) { & $Progress $msg }
        $r = Copy-RedriveFromDevice -RemotePath "$($cfg.DataDir)/$($e.Id)*" -Destination ($dest + '\') -Recurse -TimeoutSec 900
        if ($r.ExitCode -eq 0) { $summary.Copied++; $state.Backup[$e.Id] = "$($e.LastModified)|$($e.RmSig)"; Save-RedriveState $state }
        else { $summary.Errors++; Write-RedriveLog -Level Warn -Component 'backup' -Message "backup of '$($e.Name)' failed: $($r.StdErr.Trim())" }
    }
    $state.LastBackup = (Get-Date).ToString('o')
    Save-RedriveState $state
    Write-RedriveLog -Level Info -Component 'backup' -Message ("backup done: {0} document(s) copied, {1} error(s)" -f $summary.Copied, $summary.Errors)
    return $summary
}

# ---------------------------------------------------------------- the sync cycle

function Enter-RedriveSyncLock {
    $p = Initialize-RedriveHome
    if (Test-Path -LiteralPath $p.SyncLock) {
        try {
            $info = Get-Content -LiteralPath $p.SyncLock -Raw | ConvertFrom-Json
            $age = (Get-Date) - [DateTime]::Parse([string]$info.Started)
            $alive = $false
            try { $alive = [bool](Get-Process -Id ([int]$info.Pid) -ErrorAction Stop) } catch { }
            if ($alive -and $age.TotalMinutes -lt 45) { return $false }
        }
        catch { }
        Remove-Item -LiteralPath $p.SyncLock -Force -ErrorAction SilentlyContinue
    }
    Write-RedriveJsonFile -Path $p.SyncLock -Object ([ordered]@{ Pid = $PID; Started = (Get-Date).ToString('o') })
    return $true
}

function Exit-RedriveSyncLock {
    $p = Get-RedrivePaths
    Remove-Item -LiteralPath $p.SyncLock -Force -ErrorAction SilentlyContinue
}

function Invoke-RedriveSync {
    <#
      One full cycle: pull, push, device-ops window (if needed and allowed), then a quick pull for anything new.
      Returns @{ Ok; Message; Changes; Pull; Push; Window }.
    #>
    param([switch]$SkipOneNote, [scriptblock]$Progress = $null, [int]$MaxRenders = 60)
    $cfg = Get-RedriveConfig
    if (-not (Enter-RedriveSyncLock)) { return @{ Ok = $false; Message = 'another sync is already running'; Changes = $false } }
    $result = @{ Ok = $false; Message = ''; Changes = $false; Pull = $null; Push = $null; Window = $null; OneNote = $null }
    try {
        Write-RedriveStatus -Phase 'start' -Message 'Checking the tablet'
        $probe = Test-RedriveDevice
        if (-not $probe.Reachable) { $result.Message = "tablet not reachable ($($probe.State))"; Write-RedriveStatus -Running $false -Phase 'unreachable' -Message $result.Message -Ok $false; return $result }
        $auth = Test-RedriveSshAuth
        if (-not $auth.Ok) { $result.Message = "SSH login failed ($($auth.Reason)): $($auth.Detail)"; $result.AuthReason = $auth.Reason; Write-RedriveLog -Level Error -Component 'sync' -Message $result.Message; Write-RedriveStatus -Running $false -Phase "auth-$($auth.Reason)" -Error $result.Message -Ok $false; return $result }
        $mount = Mount-RedriveDrive
        if (-not $mount.Ok) { Write-RedriveLog -Level Warn -Component 'sync' -Message $mount.Message }

        $onenote = $null
        if (-not $SkipOneNote -and [bool]$cfg.OneNote.Enabled -and (Get-Command Invoke-RedriveOneNoteHarvest -ErrorAction SilentlyContinue)) {
            try { $onenote = @{ Harvest = (Invoke-RedriveOneNoteHarvest -Progress $Progress) } } catch { Write-RedriveLog -Level Error -Component 'onenote' -Message "harvest failed: $($_.Exception.Message)" }
        }
        $pull = Sync-RedrivePull -MaxRenders $MaxRenders -Progress $Progress
        $result.Pull = $pull
        if (-not $SkipOneNote -and [bool]$cfg.OneNote.Enabled -and (Get-Command Invoke-RedriveOneNoteExport -ErrorAction SilentlyContinue)) {
            try { if (-not $onenote) { $onenote = @{} }; $onenote.Export = Invoke-RedriveOneNoteExport -Progress $Progress } catch { Write-RedriveLog -Level Error -Component 'onenote' -Message "export failed: $($_.Exception.Message)" }
        }
        $result.OneNote = $onenote
        $push = Sync-RedrivePush -Progress $Progress
        $result.Push = $push
        $window = $null
        $stagedCount = Get-RedriveStagedCount
        if ($stagedCount -gt 0) {
            Write-RedriveStatus -Phase 'window' -Message 'Filing documents on the tablet'
            $window = Invoke-RedriveDeviceWindow -OnStatus { param($m) Write-RedriveStatus -Phase 'window' -Message $m }
            $result.Window = $window
            if ($window.Ran) {
                $pull2 = Sync-RedrivePull -MaxRenders 20 -Progress $Progress
                $pull.Rendered += $pull2.Rendered; $pull.Moved += $pull2.Moved
            }
        }
        $parts = @()
        if ($pull.Rendered) { $parts += "$($pull.Rendered) copied from the tablet" }
        if ($push.Uploaded) { $parts += "$($push.Uploaded) sent to the tablet" }
        if ($push.Replaced) { $parts += "$($push.Replaced) replaced" }
        if ($onenote -and $onenote.Export -and $onenote.Export.Exported) { $parts += "$($onenote.Export.Exported) OneNote page(s) exported" }
        if ($onenote -and $onenote.Harvest -and $onenote.Harvest.Harvested) { $parts += "$($onenote.Harvest.Harvested) note(s) brought into OneNote" }
        if ($window -and -not $window.Ran -and $stagedCount -gt 0) { $parts += "$stagedCount change(s) waiting for a quiet moment on the tablet" }
        $result.Changes = ($pull.Rendered + $pull.Moved + $pull.Removed + $push.Uploaded + $push.Replaced) -gt 0
        $result.Ok = ($pull.Errors -eq 0 -and $push.Errors -eq 0)
        $result.Message = if ($parts.Count) { $parts -join ', ' } else { 'nothing to do' }
        if (-not $result.Ok) { $result.Message += (" ({0} error(s), see the log)" -f ($pull.Errors + $push.Errors)) }
        $state = Get-RedriveState
        $state.LastSync = (Get-Date).ToString('o'); $state.LastSyncMessage = $result.Message; $state.LastSyncOk = $result.Ok
        Save-RedriveState $state
        Write-RedriveLog -Level Info -Component 'sync' -Message ("cycle done: " + $result.Message)
        Write-RedriveStatus -Running $false -Phase 'done' -Message $result.Message -Ok $result.Ok -Changes $result.Changes
        return $result
    }
    catch {
        $result.Message = $_.Exception.Message
        Write-RedriveLog -Level Error -Component 'sync' -Message ("cycle failed: " + $_.Exception.Message + ' ' + $_.ScriptStackTrace)
        Write-RedriveStatus -Running $false -Phase 'failed' -Error $result.Message
        $state = Get-RedriveState; $state.LastError = $result.Message; $state.LastErrorAt = (Get-Date).ToString('o'); Save-RedriveState $state
        return $result
    }
    finally { Exit-RedriveSyncLock }
}
