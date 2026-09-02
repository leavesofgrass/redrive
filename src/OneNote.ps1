# OneNote.ps1 - OneNote desktop bridge: pages to the tablet, handwriting back into OneNote (ASCII only)

$script:OneNoteNs = 'http://schemas.microsoft.com/office/onenote/2013/onenote'
$script:OneNoteApp = $null

function Get-RedriveOneNoteState {
    $p = Get-RedrivePaths
    $s = ConvertTo-RedriveHashtable (Read-RedriveJsonFile -Path $p.OneNoteState -Default $null)
    if (-not $s) { $s = @{} }
    foreach ($k in @('Pages', 'Native')) { if (-not $s.ContainsKey($k) -or -not ($s[$k] -is [hashtable])) { $s[$k] = @{} } }
    return $s
}

function Save-RedriveOneNoteState([hashtable]$State) {
    $p = Initialize-RedriveHome
    Write-RedriveJsonFile -Path $p.OneNoteState -Object (ConvertTo-RedriveJsonReady $State) -Depth 10
}

function Test-RedriveOneNote {
    <# @{ Ok; Detail; Fix } - cheap checks first, then a real COM call. #>
    if (-not (Test-Path 'Registry::HKEY_CLASSES_ROOT\OneNote.Application')) {
        return @{ Ok = $false; Detail = 'OneNote desktop (Microsoft 365 / 2016+) is not installed'; Fix = 'Install the OneNote desktop app. The Microsoft Store "OneNote for Windows 10" has no automation and is retired.' }
    }
    $proc = Get-Process -Name ONENOTE -ErrorAction SilentlyContinue
    try {
        $app = Connect-RedriveOneNote
        [string]$xml = ''
        $app.GetHierarchy('', 2, [ref]$xml, 2)
        $doc = New-Object Xml.XmlDocument; $doc.LoadXml($xml)
        $ns = New-Object Xml.XmlNamespaceManager($doc.NameTable); $ns.AddNamespace('one', $script:OneNoteNs)
        $n = $doc.SelectNodes('//one:Notebook', $ns).Count
        return @{ Ok = $true; Detail = ("{0} notebook(s) open{1}" -f $n, $(if ($proc) { '' } else { ' (OneNote was started by redrive)' })); Fix = '' }
    }
    catch { return @{ Ok = $false; Detail = "OneNote automation failed: $($_.Exception.Message)"; Fix = 'Open OneNote (desktop) normally, close any dialog it shows, and make sure redrive runs as the same user without administrator rights.' } }
}

function Connect-RedriveOneNote {
    <# Returns the OneNote.Application COM object, starting OneNote if it is not running. #>
    if ($script:OneNoteApp) { return $script:OneNoteApp }
    if (-not (Get-Process -Name ONENOTE -ErrorAction SilentlyContinue)) {
        $exe = $null
        try { $exe = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\onenote.exe' -ErrorAction Stop).'(default)' } catch { }
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            Write-RedriveLog -Level Info -Component 'onenote' -Message 'starting OneNote'
            Start-Process -FilePath $exe -WindowStyle Minimized | Out-Null
            for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Seconds 1; if (Get-Process -Name ONENOTE -ErrorAction SilentlyContinue) { break } }
            Start-Sleep -Seconds 5
        }
    }
    $last = $null
    for ($try = 1; $try -le 4; $try++) {
        try { $script:OneNoteApp = New-Object -ComObject OneNote.Application; return $script:OneNoteApp }
        catch {
            $last = $_
            $h = 0; try { $h = $_.Exception.InnerException.HResult } catch { }
            if (-not $h) { try { $h = $_.Exception.HResult } catch { } }
            if ($h -eq -2147221164) { throw "OneNote automation class not registered (0x80040154): run Office Quick Repair or install OneNote desktop" }
            Start-Sleep -Seconds (5 * $try)
        }
    }
    throw "OneNote did not answer: $($last.Exception.Message) (if OneNote runs as administrator, run redrive the same way, or vice versa)"
}

function Disconnect-RedriveOneNote {
    if ($script:OneNoteApp) {
        try { [Runtime.InteropServices.Marshal]::ReleaseComObject($script:OneNoteApp) | Out-Null } catch { }
        $script:OneNoteApp = $null
    }
}

function Invoke-RedriveOneNoteCall {
    <# Retries a COM call while OneNote is busy; aborts on a modal dialog. #>
    param([Parameter(Mandatory)][scriptblock]$Call, [int]$Tries = 5)
    $delay = 2
    for ($i = 1; $i -le $Tries; $i++) {
        try { return (& $Call) }
        catch {
            $h = 0; try { $h = $_.Exception.HResult } catch { }
            if ($h -eq -2147418111 -or $h -eq -2147417846) { if ($i -eq $Tries) { throw }; Start-Sleep -Seconds $delay; $delay = [math]::Min(30, $delay * 2); continue }   # RPC_E_CALL_REJECTED / RETRYLATER
            if ($h -eq -2147213264) { throw 'a dialog is open in OneNote; close it and try again (0x80042030)' }
            throw
        }
    }
}

function Get-RedriveOneNoteHierarchy {
    <# All pages of all open notebooks as flat objects. #>
    param($App)
    if (-not $App) { $App = Connect-RedriveOneNote }
    [string]$xml = ''
    Invoke-RedriveOneNoteCall { $App.GetHierarchy('', 4, [ref]$xml, 2) } | Out-Null
    $doc = New-Object Xml.XmlDocument; $doc.LoadXml($xml)
    $ns = New-Object Xml.XmlNamespaceManager($doc.NameTable); $ns.AddNamespace('one', $script:OneNoteNs)
    $pages = @()
    $notebooks = @()
    foreach ($nb in $doc.SelectNodes('//one:Notebook', $ns)) {
        $notebooks += [pscustomobject]@{ Id = $nb.GetAttribute('ID'); Name = $nb.GetAttribute('name') }
        foreach ($sec in $nb.SelectNodes('.//one:Section', $ns)) {
            if ($sec.GetAttribute('isInRecycleBin') -eq 'true' -or $sec.GetAttribute('isDeletedPages') -eq 'true') { continue }
            $locked = ($sec.GetAttribute('locked') -eq 'true') -or ($sec.GetAttribute('encrypted') -eq 'true')
            $groups = @(); $node = $sec.ParentNode; $inBin = $false
            while ($node -and $node.LocalName -eq 'SectionGroup') { if ($node.GetAttribute('isRecycleBin') -eq 'true') { $inBin = $true }; $groups = @($node.GetAttribute('name')) + $groups; $node = $node.ParentNode }
            if ($inBin) { continue }
            $sectionPath = (($groups + @($sec.GetAttribute('name'))) -join '/')
            foreach ($pg in $sec.SelectNodes('one:Page', $ns)) {
                if ($pg.GetAttribute('isInRecycleBin') -eq 'true') { continue }
                $lm = [DateTime]::MinValue
                try { $lm = [DateTime]::Parse($pg.GetAttribute('lastModifiedTime')).ToUniversalTime() } catch { }
                $pages += [pscustomobject]@{
                    Id = $pg.GetAttribute('ID'); Name = $pg.GetAttribute('name'); Notebook = $nb.GetAttribute('name'); NotebookId = $nb.GetAttribute('ID')
                    SectionPath = $sectionPath; SectionId = $sec.GetAttribute('ID'); SectionReadOnly = ($sec.GetAttribute('readOnly') -eq 'true'); SectionLocked = $locked
                    LastModified = $lm; Created = $pg.GetAttribute('dateTime'); Level = $pg.GetAttribute('pageLevel')
                }
            }
        }
    }
    return @{ Pages = $pages; Notebooks = $notebooks }
}

function Test-RedriveOneNoteIncluded {
    <# Include/Exclude entries are 'Notebook' or 'Notebook/Section path' with wildcards. #>
    param([string]$Notebook, [string]$SectionPath)
    $cfg = Get-RedriveConfig
    $full = "$Notebook/$SectionPath"
    # pages redrive itself creates from tablet notebooks never travel back to the tablet
    $fromSection = [string]$cfg.OneNote.FromRemarkableSection
    if ($fromSection -and (($SectionPath -split '/')[-1] -eq $fromSection)) { return $false }
    $inc = @($cfg.OneNote.Include); $exc = @($cfg.OneNote.Exclude)
    foreach ($e in $exc) { if ($e -and (($Notebook -like $e) -or ($full -like $e) -or ($full -like "$e/*"))) { return $false } }
    if ($inc.Count -eq 0) { return $true }
    foreach ($e in $inc) { if ($e -and (($Notebook -like $e) -or ($full -like $e) -or ($full -like "$e/*"))) { return $true } }
    return $false
}

function Get-RedriveOneNoteExportDir {
    $p = Initialize-RedriveHome
    $d = Join-Path $p.State 'onenote'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

function Get-RedriveShortHash([string]$Text) {
    $sha = [Security.Cryptography.SHA1]::Create()
    $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    return (($b[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Export-RedriveOneNotePage {
    <# Publishes one page to PDF. Returns @{ Path; Hash; Size }. #>
    param($App, [Parameter(Mandatory)]$Page)
    $dir = Get-RedriveOneNoteExportDir
    $file = Join-Path $dir ((Get-RedriveShortHash $Page.Id) + '.pdf')
    $tmp = "$file.publish.pdf"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    Invoke-RedriveOneNoteCall { $App.Publish($Page.Id, $tmp, 3, '') } | Out-Null
    if (-not (Test-Path -LiteralPath $tmp)) { throw 'Publish produced no file' }
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    Move-Item -LiteralPath $tmp -Destination $file -Force
    return @{ Path = $file; Hash = (Get-RedriveFileSha256 -Path $file); Size = (Get-Item -LiteralPath $file).Length }
}

function Get-RedriveOneNoteTabletDir {
    param([Parameter(Mandatory)]$Page)
    $cfg = Get-RedriveConfig
    $segs = @([string]$cfg.OneNote.TabletRoot, (ConvertTo-RedriveSafeName $Page.Notebook 60))
    foreach ($s in ($Page.SectionPath -split '/')) { if ($s) { $segs += (ConvertTo-RedriveSafeName $s 60) } }
    return ($segs -join '\')
}

function Invoke-RedriveOneNoteExport {
    <# Exports changed OneNote pages and pushes them to the tablet. Returns a summary. #>
    param([scriptblock]$Progress = $null, [switch]$Force)
    $cfg = Get-RedriveConfig
    $summary = @{ Exported = 0; Skipped = 0; Errors = 0; Retired = 0; NeedsWindow = $false; Backlog = 0 }
    $state = Get-RedriveOneNoteState
    if (-not $Force -and $state.ContainsKey('LastExport') -and $state.LastExport) {
        try { if (((Get-Date) - [DateTime]::Parse([string]$state.LastExport)).TotalMinutes -lt [int]$cfg.OneNote.PollMinutes) { return $summary } } catch { }
    }
    Write-RedriveStatus -Phase 'onenote' -Message 'Reading OneNote'
    $app = Connect-RedriveOneNote
    try {
        $h = Get-RedriveOneNoteHierarchy -App $app
        $index = Get-RedriveIndex
        $stagedFolders = @{}
        $seen = @{}
        $todo = @()
        foreach ($pg in $h.Pages) {
            $seen[$pg.Id] = $true
            if ($pg.SectionLocked) { continue }
            if (-not (Test-RedriveOneNoteIncluded -Notebook $pg.Notebook -SectionPath $pg.SectionPath)) { continue }
            $known = $null; if ($state.Pages.ContainsKey($pg.Id)) { $known = $state.Pages[$pg.Id] }
            $need = $false
            if (-not $known) { $need = $true }
            else {
                $prev = [DateTime]::MinValue; try { $prev = [DateTime]::Parse([string]$known.ExportedLastModified).ToUniversalTime() } catch { }
                $wasEmpty = ($known.ContainsKey('Error') -and [string]$known.Error -like 'empty page*')
                if ($pg.LastModified -gt $prev.AddSeconds(1)) { $need = $true }
                elseif ($wasEmpty) { $need = $false }
                elseif ($known.TabletUuid -and -not $index.ContainsKey([string]$known.TabletUuid)) { $need = $true }
                elseif (-not $known.TabletUuid) { $need = $true }
            }
            if ($need) { $todo += $pg } else { $summary.Skipped++ }
        }
        $todo = @($todo | Sort-Object LastModified -Descending)
        $max = [int]$cfg.OneNote.MaxExportsPerRun
        if ($todo.Count -gt $max) { $summary.Backlog = $todo.Count - $max; $todo = @($todo[0..($max - 1)]) }
        $n = 0
        foreach ($pg in $todo) {
            $n++
            $msg = "OneNote {0}/{1}: {2}" -f $n, $todo.Count, $pg.Name
            Write-RedriveStatus -Phase 'onenote' -Message $msg -Progress "$n/$($todo.Count)"
            if ($Progress) { & $Progress $msg }
            if (-not (Test-RedriveDevice).Reachable) { Write-RedriveLog -Level Warn -Component 'onenote' -Message 'tablet went away during export'; break }
            try {
                $exp = Export-RedriveOneNotePage -App $app -Page $pg
                if ($exp.Size -gt ([int]$cfg.OneNote.MaxPdfMB * 1MB)) { Write-RedriveLog -Level Warn -Component 'onenote' -Message "page '$($pg.Name)' exports to $([int]($exp.Size / 1MB)) MB; skipped"; $summary.Skipped++; continue }
                $known = $null; if ($state.Pages.ContainsKey($pg.Id)) { $known = $state.Pages[$pg.Id] }
                if ($known -and ([string]$known.PdfHash -eq $exp.Hash) -and $known.TabletUuid -and $index.ContainsKey([string]$known.TabletUuid)) {
                    # content identical (only metadata changed): just record the new timestamp
                    $known.ExportedLastModified = $pg.LastModified.ToString('o'); $summary.Skipped++; Save-RedriveOneNoteState $state; continue
                }
                $tabletDir = Get-RedriveOneNoteTabletDir -Page $pg
                $title = ConvertTo-RedriveSafeName $pg.Name 100
                $folder = Resolve-RedriveTabletFolder -Index $index -RelativeDir $tabletDir -StagedFolders $stagedFolders
                if ($folder.Staged) { $summary.NeedsWindow = $true }
                $r = $null
                if ($known -and $known.TabletUuid -and $index.ContainsKey([string]$known.TabletUuid) -and ([string]$known.TabletDir -eq $tabletDir)) {
                    $r = Update-RedriveDocument -Uuid ([string]$known.TabletUuid) -FilePath $exp.Path -Title $title -Index $index
                }
                else {
                    if ($known -and $known.TabletUuid -and $index.ContainsKey([string]$known.TabletUuid)) {
                        Add-RedriveStagedMetadata -Entry $index[[string]$known.TabletUuid] -Changes @{ parent = 'trash' }; $summary.NeedsWindow = $true; $summary.Retired++
                    }
                    $r = Push-RedriveFile -FilePath $exp.Path -Title $title -FolderId $folder.Id -FolderIsStaged $folder.Staged -Index $index
                }
                if (-not $r.Ok) { throw $r.Message }
                if ($r.NeedsWindow) { $summary.NeedsWindow = $true }
                $state.Pages[$pg.Id] = @{
                    Notebook = $pg.Notebook; SectionPath = $pg.SectionPath; Name = $pg.Name
                    ExportedLastModified = $pg.LastModified.ToString('o'); PdfHash = $exp.Hash; PdfPath = $exp.Path
                    TabletUuid = $r.Uuid; TabletDir = $tabletDir; PushedAt = (Get-Date).ToString('o')
                    HarvestSig = $(if ($known -and $known.ContainsKey('HarvestSig')) { $known.HarvestSig } else { '' })
                    HarvestOutlineId = $(if ($known -and $known.ContainsKey('HarvestOutlineId')) { $known.HarvestOutlineId } else { '' })
                }
                $summary.Exported++
                Save-RedriveOneNoteState $state
                Write-RedriveLog -Level Info -Component 'onenote' -Message "exported '$($pg.Notebook)/$($pg.SectionPath)/$($pg.Name)' -> tablet ($($r.Message))"
            }
            catch {
                $h = 0; try { $h = $_.Exception.InnerException.HResult } catch { }
                if (-not $h) { try { $h = $_.Exception.HResult } catch { } }
                $msg = $_.Exception.Message
                $known = $null; if ($state.Pages.ContainsKey($pg.Id)) { $known = $state.Pages[$pg.Id] }
                if ($h -eq -2147213306 -or $msg -match '0x80042006') {
                    # hrFileDoesNotExist: OneNote cannot publish an empty page; remember the timestamp so it is not retried every cycle
                    $summary.Skipped++
                    if (-not $known) { $known = @{ Notebook = $pg.Notebook; SectionPath = $pg.SectionPath; Name = $pg.Name; TabletUuid = '' }; $state.Pages[$pg.Id] = $known }
                    $known.ExportedLastModified = $pg.LastModified.ToString('o'); $known.Error = 'empty page (nothing to export)'
                    Save-RedriveOneNoteState $state
                    Write-RedriveLog -Level Info -Component 'onenote' -Message "page '$($pg.Name)' is empty; nothing to export"
                }
                elseif ($msg -match '0x80042030|dialog is open') { $summary.Errors++; Write-RedriveLog -Level Warn -Component 'onenote' -Message 'a dialog is open in OneNote; export stopped for now'; break }
                else { $summary.Errors++; Write-RedriveLog -Level Error -Component 'onenote' -Message "export of '$($pg.Name)' failed: $msg" }
            }
        }
        # pages that disappeared from OneNote: retire their tablet copies.
        # A whole notebook that vanished was most likely just closed in OneNote: leave its copies alone.
        $openNotebooks = @{}
        foreach ($nb in $h.Notebooks) { $openNotebooks[[string]$nb.Name] = $true }
        foreach ($id in @($state.Pages.Keys)) {
            if ($seen.ContainsKey($id)) { continue }
            $known = $state.Pages[$id]
            if ($known.ContainsKey('Notebook') -and $known.Notebook -and -not $openNotebooks.ContainsKey([string]$known.Notebook)) { continue }
            if ($known.TabletUuid -and $index.ContainsKey([string]$known.TabletUuid)) {
                try { Add-RedriveStagedMetadata -Entry $index[[string]$known.TabletUuid] -Changes @{ parent = 'trash' }; $summary.NeedsWindow = $true; $summary.Retired++; Write-RedriveLog -Level Info -Component 'onenote' -Message "page '$($known.Name)' is gone from OneNote; its tablet copy goes to the trash" } catch { }
            }
            $state.Pages.Remove($id)
        }
        $state.LastExport = (Get-Date).ToString('o')
        Save-RedriveOneNoteState $state
    }
    finally { Disconnect-RedriveOneNote }
    return $summary
}

# ---------------------------------------------------------------- harvest: tablet handwriting -> OneNote

function ConvertTo-RedrivePngPages {
    <# Rasterizes PDF pages with the Windows-built-in engine (no installs). Returns @{ Index; Png; AspectHW } per page. #>
    param([Parameter(Mandatory)][string]$PdfPath, [int[]]$PageIndexes = $null, [int]$WidthPx = 1240)
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
    $null = [Windows.Data.Pdf.PdfPageRenderOptions, Windows.Data.Pdf, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $methods = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 }
    $asTaskOp = ($methods | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $asTaskAc = ($methods | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
    $fs = [IO.File]::OpenRead($PdfPath)
    $out = @()
    try {
        $ras = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($fs)
        $t = $asTaskOp.MakeGenericMethod([Windows.Data.Pdf.PdfDocument]).Invoke($null, @([Windows.Data.Pdf.PdfDocument]::LoadFromStreamAsync($ras)))
        $null = $t.Wait(-1)
        $doc = $t.Result
        $count = [int]$doc.PageCount
        # note: -not @(0) is $true in PowerShell (a lone page index 0 is falsy), so test the count explicitly
        if ($null -eq $PageIndexes -or @($PageIndexes).Count -eq 0) { $PageIndexes = @(0..($count - 1)) }
        foreach ($i in $PageIndexes) {
            if ($i -lt 0 -or $i -ge $count) { continue }
            $page = $doc.GetPage([uint32]$i)
            $opts = New-Object Windows.Data.Pdf.PdfPageRenderOptions
            $opts.DestinationWidth = [uint32]$WidthPx
            $ms = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
            $ta = $asTaskAc.Invoke($null, @($page.RenderToStreamAsync($ms, $opts)))
            $null = $ta.Wait(-1)
            $net = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($ms.GetInputStreamAt(0))
            $buf = New-Object IO.MemoryStream
            $net.CopyTo($buf)
            $out += @{ Index = $i; Png = $buf.ToArray(); AspectHW = ([double]$page.Size.Height / [double]$page.Size.Width) }
            $ms.Dispose(); $page.Dispose()
        }
    }
    finally { $fs.Dispose() }
    return $out    # callers wrap with @(): one page comes back as a single hashtable otherwise
}

function Get-RedriveAnnotatedPageIndexes {
    <# Which page indexes (0-based, in display order) of a tablet document carry strokes. Empty = unknown (use all). #>
    param([Parameter(Mandatory)]$Entry)
    $cfg = Get-RedriveConfig
    $r = Invoke-RedriveSsh -Command "for r in '$($cfg.DataDir)/$($Entry.Id)'/*.rm; do [ -s `"`$r`" ] && echo `"`${r##*/}`"; done" -TimeoutSec 30
    $ids = @($r.StdOut -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { $_ -replace '\.rm$', '' })
    if ($ids.Count -eq 0 -or -not $Entry.Pages -or $Entry.Pages.Count -eq 0) { return @() }
    $idx = @()
    for ($i = 0; $i -lt $Entry.Pages.Count; $i++) { if ($ids -contains [string]$Entry.Pages[$i]) { $idx += $i } }
    return $idx
}

function Get-RedriveOneNoteMaxY {
    param($App, [string]$PageId)
    [string]$xml = ''
    Invoke-RedriveOneNoteCall { $App.GetPageContent($PageId, [ref]$xml, 0, 2) } | Out-Null
    $doc = New-Object Xml.XmlDocument; $doc.LoadXml($xml)
    $ns = New-Object Xml.XmlNamespaceManager($doc.NameTable); $ns.AddNamespace('one', $script:OneNoteNs)
    $maxY = 86.0
    foreach ($n in $doc.SelectNodes('/one:Page/*[one:Position]', $ns)) {
        $y = 0.0; $h = 200.0
        try { $y = [double]$n.SelectSingleNode('one:Position', $ns).GetAttribute('y') } catch { }
        $sz = $n.SelectSingleNode('one:Size', $ns)
        if ($sz) { try { $h = [double]$sz.GetAttribute('height') } catch { } }
        if (($y + $h) -gt $maxY) { $maxY = $y + $h }
    }
    return @{ MaxY = $maxY; Xml = $doc; Ns = $ns }
}

function Add-RedriveOneNoteHarvest {
    <#
      Appends (or replaces) the redrive outline on a page: caption, one image per annotated page, the PDF attached.
      Returns the objectID of the new outline ('' when not found).
    #>
    param($App, [Parameter(Mandatory)][string]$PageId, [Parameter(Mandatory)]$Images, [string]$PdfPath, [string]$Title, [string]$DocUuid, [string]$Signature, [string]$PreviousOutlineId = '')
    $Images = @($Images)
    $info = Get-RedriveOneNoteMaxY -App $App -PageId $PageId
    if (-not $PreviousOutlineId) {
        # the page itself remembers the last harvest outline (survives a lost state file)
        try {
            $m = $info.Xml.SelectSingleNode('/one:Page/one:Meta[@name="redrive.harvestOutlineId"]', $info.Ns)
            if ($m) { $PreviousOutlineId = $m.GetAttribute('content') }
        }
        catch { }
    }
    if ($PreviousOutlineId) {
        try { Invoke-RedriveOneNoteCall { $App.DeletePageContent($PageId, $PreviousOutlineId, [DateTime]::MinValue, $false) } | Out-Null } catch { Write-RedriveLog -Level Debug -Component 'onenote' -Message "old harvest outline not removed: $($_.Exception.Message)" }
        $info = Get-RedriveOneNoteMaxY -App $App -PageId $PageId
    }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $w = 480.0
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0"?><one:Page xmlns:one="' + $script:OneNoteNs + '" ID="' + $PageId + '">')
    if ($DocUuid) { [void]$sb.Append('<one:Meta name="redrive.docUuid" content="' + [Security.SecurityElement]::Escape($DocUuid) + '"/>') }
    if ($Signature) { [void]$sb.Append('<one:Meta name="redrive.harvestSig" content="' + [Security.SecurityElement]::Escape($Signature) + '"/>') }
    [void]$sb.Append('<one:Outline><one:Position x="36.0" y="' + ([math]::Round($info.MaxY + 30, 1)).ToString([Globalization.CultureInfo]::InvariantCulture) + '" z="0"/><one:Size width="' + $w + '" height="20.0"/><one:OEChildren>')
    $caption = "redrive harvest $stamp - $($Images.Count) handwritten page(s) from '$Title'"
    [void]$sb.Append('<one:OE><one:T><![CDATA[<span style="font-size:9.0pt;color:#7F7F7F">' + [Security.SecurityElement]::Escape($caption) + '</span>]]></one:T></one:OE>')
    foreach ($img in $Images) {
        $h = [math]::Round($w * [double]$img.AspectHW, 1)
        [void]$sb.Append('<one:OE><one:Image format="png"><one:Size width="' + $w.ToString([Globalization.CultureInfo]::InvariantCulture) + '" height="' + $h.ToString([Globalization.CultureInfo]::InvariantCulture) + '" isSetByUser="true"/><one:Data>' + [Convert]::ToBase64String($img.Png) + '</one:Data></one:Image></one:OE>')
    }
    if ($PdfPath -and (Test-Path -LiteralPath $PdfPath)) {
        [void]$sb.Append('<one:OE><one:InsertedFile pathSource="' + [Security.SecurityElement]::Escape($PdfPath) + '" preferredName="' + [Security.SecurityElement]::Escape((ConvertTo-RedriveSafeName $Title 80) + ' (annotated).pdf') + '"/></one:OE>')
    }
    [void]$sb.Append('</one:OEChildren></one:Outline></one:Page>')
    Invoke-RedriveOneNoteCall { $App.UpdatePageContent($sb.ToString(), [DateTime]::MinValue, 2, $false) } | Out-Null
    # find the outline we just made so the next harvest can replace it
    $outlineId = ''
    try {
        $after = Get-RedriveOneNoteMaxY -App $App -PageId $PageId
        foreach ($ol in $after.Xml.SelectNodes('/one:Page/one:Outline', $after.Ns)) {
            $t = $ol.SelectSingleNode('.//one:T', $after.Ns)
            if ($t -and $t.InnerText -like "*redrive harvest $stamp*") { $outlineId = $ol.GetAttribute('objectID') }
        }
        if ($outlineId) {
            $meta = '<?xml version="1.0"?><one:Page xmlns:one="' + $script:OneNoteNs + '" ID="' + $PageId + '"><one:Meta name="redrive.harvestOutlineId" content="' + [Security.SecurityElement]::Escape($outlineId) + '"/></one:Page>'
            Invoke-RedriveOneNoteCall { $App.UpdatePageContent($meta, [DateTime]::MinValue, 2, $false) } | Out-Null
        }
    }
    catch { }
    return $outlineId
}

function Get-RedriveOneNoteNativeSection {
    <# The section that receives notebooks written on the tablet; created when missing. Returns the section id. #>
    param($App, $Hierarchy)
    $cfg = Get-RedriveConfig
    $nbName = [string]$cfg.OneNote.FromRemarkableNotebook
    $nb = $null
    if ($nbName) { $nb = $Hierarchy.Notebooks | Where-Object { $_.Name -eq $nbName } | Select-Object -First 1 }
    if (-not $nb) { $nb = $Hierarchy.Notebooks | Select-Object -First 1 }
    if (-not $nb) { throw 'no notebook is open in OneNote' }
    [string]$sid = ''
    $secName = [string]$cfg.OneNote.FromRemarkableSection
    Invoke-RedriveOneNoteCall { $App.OpenHierarchy("$secName.one", $nb.Id, [ref]$sid, 3) } | Out-Null
    return $sid
}

function New-RedriveOneNoteNativePage {
    param($App, [string]$SectionId, [string]$Title, [string]$DocUuid)
    [string]$pid2 = ''
    Invoke-RedriveOneNoteCall { $App.CreateNewPage($SectionId, [ref]$pid2, 0) } | Out-Null
    $xml = '<?xml version="1.0"?><one:Page xmlns:one="' + $script:OneNoteNs + '" ID="' + $pid2 + '"><one:Meta name="redrive.docUuid" content="' + [Security.SecurityElement]::Escape($DocUuid) + '"/><one:Title><one:OE><one:T><![CDATA[' + [Security.SecurityElement]::Escape($Title) + ']]></one:T></one:OE></one:Title></one:Page>'
    Invoke-RedriveOneNoteCall { $App.UpdatePageContent($xml, [DateTime]::MinValue, 2, $false) } | Out-Null
    return $pid2
}

function Get-RedriveRenderedPdf {
    <# The tablet-rendered PDF for a document: from the mirror when current, else rendered now. Returns a path or $null. #>
    param([Parameter(Mandatory)]$Entry)
    $cfg = Get-RedriveConfig
    $state = Get-RedriveState
    if ($state.Documents.ContainsKey($Entry.Id)) {
        $d = $state.Documents[$Entry.Id]
        if ($d.Path -and ([string]$d.RenderedRmSig -eq [string]$Entry.RmSig)) {
            $f = Join-Path ([string]$cfg.MirrorRoot) $d.Path
            if (Test-Path -LiteralPath $f) { return $f }
        }
    }
    $tmp = New-RedriveTempFile -Extension '.pdf'
    $r = Get-RedriveWebRender -Id $Entry.Id -OutFile $tmp
    if ($r.Ok) { return $tmp }
    return $null
}

function Invoke-RedriveOneNoteHarvest {
    <# Brings tablet handwriting into OneNote: annotated exported pages and native notebooks. #>
    param([scriptblock]$Progress = $null)
    $cfg = Get-RedriveConfig
    $summary = @{ Harvested = 0; Skipped = 0; Errors = 0 }
    $p = Initialize-RedriveHome
    $index = Get-RedriveIndex
    $state = Get-RedriveOneNoteState
    $todo = @()
    foreach ($pageId in @($state.Pages.Keys)) {
        $k = $state.Pages[$pageId]
        if (-not $k.TabletUuid -or -not $index.ContainsKey([string]$k.TabletUuid)) { continue }
        $e = $index[[string]$k.TabletUuid]
        if ($e.RmCount -le 0) { continue }
        if ([string]$k.HarvestSig -eq [string]$e.RmSig) { continue }
        $todo += @{ Kind = 'page'; PageId = $pageId; Known = $k; Entry = $e }
    }
    foreach ($e in $index.Values) {
        if ($e.InTrash -or $e.IsFolder -or $e.FileType -ne 'notebook' -or $e.RmCount -le 0) { continue }
        $n = $null; if ($state.Native.ContainsKey($e.Id)) { $n = $state.Native[$e.Id] }
        if ($n -and ([string]$n.HarvestSig -eq [string]$e.RmSig)) { continue }
        $todo += @{ Kind = 'native'; Known = $n; Entry = $e }
    }
    if ($todo.Count -eq 0) { return $summary }
    if (-not (Test-RedriveWeb)) { Write-RedriveLog -Level Warn -Component 'onenote' -Message 'web interface not reachable; handwriting cannot be harvested yet'; return $summary }
    $app = Connect-RedriveOneNote
    try {
        $hier = $null
        $sectionId = $null
        $n = 0
        foreach ($t in $todo) {
            $n++
            $e = $t.Entry
            $msg = "Bringing '{0}' into OneNote ({1}/{2})" -f $e.Name, $n, $todo.Count
            Write-RedriveStatus -Phase 'harvest' -Message $msg -Progress "$n/$($todo.Count)"
            if ($Progress) { & $Progress $msg }
            if (-not (Test-RedriveDevice).Reachable) { break }
            try {
                # skip documents still being written on
                $pdf = Get-RedriveRenderedPdf -Entry $e
                if (-not $pdf) { throw 'no rendered PDF available' }
                $pages = @(Get-RedriveAnnotatedPageIndexes -Entry $e)
                $images = @(ConvertTo-RedrivePngPages -PdfPath $pdf -PageIndexes ([int[]]$pages) -WidthPx (8 * [int]$cfg.OneNote.HarvestDpi))
                if ($images.Count -gt 30) { $images = @($images[0..29]) }
                if ($images.Count -eq 0) { throw 'no pages could be rendered' }
                $keep = Join-Path $p.Harvest ("{0}-{1}.pdf" -f $e.Id, (Get-Date -Format 'yyyyMMdd-HHmm'))
                Copy-Item -LiteralPath $pdf -Destination $keep -Force
                Set-RedriveReadOnly -Path $keep -ReadOnly $false
                $sig = [string]$e.RmSig
                if ($t.Kind -eq 'page') {
                    $prev = ''; if ($t.Known.ContainsKey('HarvestOutlineId')) { $prev = [string]$t.Known.HarvestOutlineId }
                    $oid = Add-RedriveOneNoteHarvest -App $app -PageId $t.PageId -Images $images -PdfPath $keep -Title $e.Name -DocUuid $e.Id -Signature $sig -PreviousOutlineId $prev
                    $t.Known.HarvestSig = $sig; $t.Known.HarvestOutlineId = $oid; $t.Known.HarvestedAt = (Get-Date).ToString('o')
                    # the page changed: make sure the next export refreshes the tablet copy right away
                    $t.Known.ExportedLastModified = [DateTime]::MinValue.ToString('o')
                }
                else {
                    if (-not $hier) { $hier = Get-RedriveOneNoteHierarchy -App $app }
                    if (-not $sectionId) { $sectionId = Get-RedriveOneNoteNativeSection -App $app -Hierarchy $hier }
                    $pageId = ''; $prev = ''
                    if ($t.Known) { $pageId = [string]$t.Known.PageId; $prev = [string]$t.Known.HarvestOutlineId }
                    if ($pageId -and -not ($hier.Pages | Where-Object { $_.Id -eq $pageId })) { $pageId = '' }
                    if (-not $pageId) { $pageId = New-RedriveOneNoteNativePage -App $app -SectionId $sectionId -Title $e.Name -DocUuid $e.Id; $prev = '' }
                    $oid = Add-RedriveOneNoteHarvest -App $app -PageId $pageId -Images $images -PdfPath $keep -Title $e.Name -DocUuid $e.Id -Signature $sig -PreviousOutlineId $prev
                    $state.Native[$e.Id] = @{ PageId = $pageId; HarvestSig = $sig; HarvestOutlineId = $oid; Name = $e.Name; HarvestedAt = (Get-Date).ToString('o') }
                }
                $summary.Harvested++
                Save-RedriveOneNoteState $state
                Write-RedriveLog -Level Info -Component 'onenote' -Message ("harvested '{0}' ({1} page image(s)) into OneNote" -f $e.Name, $images.Count)
                if ($pdf -like (Join-Path $p.Incoming '*')) { Remove-Item -LiteralPath $pdf -Force -ErrorAction SilentlyContinue }
            }
            catch { $summary.Errors++; Write-RedriveLog -Level Error -Component 'onenote' -Message "harvest of '$($e.Name)' failed: $($_.Exception.Message)" }
        }
        # prune old harvest PDFs (30 days)
        try { Get-ChildItem -LiteralPath $p.Harvest -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force -ErrorAction SilentlyContinue } catch { }
    }
    finally { Disconnect-RedriveOneNote }
    return $summary
}
