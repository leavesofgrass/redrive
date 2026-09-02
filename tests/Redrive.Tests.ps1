# Redrive.Tests.ps1 - unit tests for the pure parts (Pester 5). Run: Invoke-Pester -Path tests
# Nothing here touches a tablet, OneNote or the network.

BeforeAll {
    $env:REDRIVE_HOME = Join-Path $env:TEMP ('redrive-tests-' + [guid]::NewGuid().ToString('n'))
    Import-Module (Join-Path $PSScriptRoot '..\src\Redrive.psd1') -Force
    $script:cfg = Get-RedriveConfig
}

AfterAll {
    if ($env:REDRIVE_HOME -and (Test-Path $env:REDRIVE_HOME)) { Remove-Item $env:REDRIVE_HOME -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Configuration' {
    It 'merges file values over defaults, including nested keys' {
        $merged = Merge-RedriveConfig $script:cfg ([pscustomobject]@{ Host = '127.0.0.1'; Probe = [pscustomobject]@{ TimeoutMs = 42 }; OneNote = [pscustomobject]@{ Exclude = @('Quick Notes') } })
        $merged.Host | Should -Be '127.0.0.1'
        $merged.Probe.TimeoutMs | Should -Be 42
        $merged.Probe.FastSeconds | Should -Be 3
        $merged.OneNote.Exclude | Should -Be @('Quick Notes')
        $merged.OneNote.PollMinutes | Should -Be 5
    }
    It 'round-trips through save and load' {
        $c = Get-RedriveConfig
        $c.DriveLetter = 'q'
        Save-RedriveConfig $c
        (Get-RedriveConfig -Reload).DriveLetter | Should -Be 'Q'
    }
}

Describe 'Argument quoting' {
    It 'quotes spaces, quotes and trailing backslashes the MSVCRT way' {
        ConvertTo-RedriveArgument 'plain' | Should -Be 'plain'
        ConvertTo-RedriveArgument '' | Should -Be '""'
        ConvertTo-RedriveArgument 'a b' | Should -Be '"a b"'
        ConvertTo-RedriveArgument 'say "hi"' | Should -Be '"say \"hi\""'
        ConvertTo-RedriveArgument 'dir\' | Should -Be 'dir\'
        ConvertTo-RedriveArgument 'a b\' | Should -Be '"a b\\"'
    }
}

Describe 'Safe names' {
    It 'strips characters NTFS refuses and guards reserved names' {
        ConvertTo-RedriveSafeName 'Quarterly: Report?' | Should -Be 'Quarterly_ Report_'
        ConvertTo-RedriveSafeName '  ends with dot. ' | Should -Be 'ends with dot'
        ConvertTo-RedriveSafeName 'CON' | Should -Be '_CON'
        ConvertTo-RedriveSafeName '' | Should -Be 'Untitled'
        (ConvertTo-RedriveSafeName ('x' * 300) 120).Length | Should -Be 120
    }
}

Describe 'Index parsing and tree building' {
    BeforeAll {
        $rs = [char]30
        $script:sample = "${rs}M f1`n{`"visibleName`":`"Work`",`"parent`":`"`",`"type`":`"CollectionType`",`"lastModified`":`"1756742400000`"}`n" +
            "${rs}C f1`n{`"tags`":[]}`n" +
            "${rs}M f2`n{`"visibleName`":`"Projects`",`"parent`":`"f1`",`"type`":`"CollectionType`"}`n" +
            "${rs}M d1`n{`"visibleName`":`"Report`",`"parent`":`"f2`",`"type`":`"DocumentType`",`"lastModified`":`"1756742401000`"}`n" +
            "${rs}C d1`n{`"fileType`":`"pdf`",`"pageCount`":3,`"cPages`":{`"pages`":[{`"id`":`"p1`",`"idx`":{`"value`":`"ba`"}},{`"id`":`"p3`",`"idx`":{`"value`":`"bc`"}},{`"id`":`"p2`",`"idx`":{`"value`":`"bb`"}}]}}`n" +
            "${rs}R d1 2 abcdef0123`n" +
            "${rs}M d2`n{`"visibleName`":`"Report`",`"parent`":`"f2`",`"type`":`"DocumentType`"}`n" +
            "${rs}M t1`n{`"visibleName`":`"Old`",`"parent`":`"trash`",`"type`":`"DocumentType`"}`n" +
            "${rs}M n1`n{`"visibleName`":`"Notes`",`"parent`":`"`",`"type`":`"DocumentType`"}`n" +
            "${rs}E`n"
        $script:index = ConvertFrom-RedriveIndexText -Text $script:sample
        $script:tree = Get-RedriveTree -Index $script:index
    }
    It 'parses metadata, content and stroke records' {
        $script:index.Count | Should -Be 6
        $script:index['d1'].Pages | Should -Be @('p1', 'p2', 'p3')
        $script:index['d1'].RmCount | Should -Be 2
        $script:index['d1'].RmSig | Should -Be 'abcdef0123'
        $script:index['d1'].FileType | Should -Be 'pdf'
        $script:index['n1'].FileType | Should -Be 'notebook'
        $script:index['t1'].InTrash | Should -BeTrue
    }
    It 'builds nested paths and de-duplicates siblings' {
        $script:tree['f2'].Path | Should -Be 'Work\Projects'
        $script:tree['d1'].Path | Should -Be 'Work\Projects\Report.pdf'
        $script:tree['d2'].Path | Should -Be 'Work\Projects\Report (2).pdf'
        $script:tree['n1'].Path | Should -Be 'Notes.pdf'
        $script:tree.ContainsKey('t1') | Should -BeFalse
    }
    It 'finds folders by path' {
        Find-RedriveFolder -Index $script:index -Path 'Work/Projects' | Should -Be 'f2'
        Find-RedriveFolder -Index $script:index -Path 'Nope' | Should -BeNullOrEmpty
    }
}

Describe 'Metadata synthesis' {
    It 'writes the fields xochitl expects' {
        $m = New-RedriveMetadataJson -Name 'Doc' -Parent 'abc' | ConvertFrom-Json
        $m.type | Should -Be 'DocumentType'
        $m.parent | Should -Be 'abc'
        $m.visibleName | Should -Be 'Doc'
        $m.lastModified | Should -Match '^\d{13}$'
        $f = New-RedriveMetadataJson -Name 'Dir' -Type CollectionType | ConvertFrom-Json
        $f.PSObject.Properties['lastOpened'] | Should -BeNullOrEmpty
        (New-RedriveContentJson -FileType pdf | ConvertFrom-Json).fileType | Should -Be 'pdf'
        New-RedriveContentJson -FileType folder | Should -Be '{"tags": []}'
    }
}

Describe 'Watchdog' {
    BeforeEach {
        $script:t0 = Get-Date '2026-09-01 09:00:00'
        $script:s = New-RedriveWatchdogState -Now $script:t0
        $script:s.StartedAt = $script:t0.AddMinutes(-5)
        $script:up = [pscustomobject]@{ AdapterUp = $true; Port22 = $true }
        $script:down = [pscustomobject]@{ AdapterUp = $true; Port22 = $false }
        $script:gone = [pscustomobject]@{ AdapterUp = $false; Port22 = $false }
    }
    It 'syncs as soon as the tablet appears' {
        $r = Step-RedriveWatchdog -State $script:s -Probe $script:up -Now $script:t0 -Config $script:cfg
        $r.State.State | Should -Be 'Syncing'
        $r.Actions | Should -Contain 'Sync'
    }
    It 'needs two failed probes before calling the tablet asleep' {
        $r = Step-RedriveWatchdog -State $script:s -Probe $script:up -Now $script:t0 -Config $script:cfg
        $r = Step-RedriveWatchdog -State $r.State -Probe $null -Now $script:t0.AddSeconds(1) -Config $script:cfg -SyncResult @{ Ok = $true; Message = 'x'; Changes = $false }
        $r = Step-RedriveWatchdog -State $r.State -Probe $script:down -Now $script:t0.AddSeconds(10) -Config $script:cfg
        $r.State.State | Should -Be 'Synced'
        $r.State.PendingLoss | Should -BeTrue
        $r = Step-RedriveWatchdog -State $r.State -Probe $script:down -Now $script:t0.AddSeconds(13) -Config $script:cfg
        $r.State.State | Should -Be 'Asleep'
    }
    It 'goes to Attention after three sync failures and rate-limits the notice' {
        $r = Step-RedriveWatchdog -State $script:s -Probe $script:up -Now $script:t0 -Config $script:cfg
        foreach ($i in 1..3) { $r = Step-RedriveWatchdog -State $r.State -Probe $null -Now $script:t0.AddMinutes($i) -Config $script:cfg -SyncResult @{ Ok = $false; Message = 'boom' } }
        $r.State.State | Should -Be 'Attention'
        ($r.Actions | Where-Object { $_ -like 'Notify:attention*' }).Count | Should -Be 1
    }
    It 'nudges once when work is waiting and the tablet is away' {
        $r = Step-RedriveWatchdog -State $script:s -Probe $script:up -Now $script:t0 -Config $script:cfg
        $r = Step-RedriveWatchdog -State $r.State -Probe $script:gone -Now $script:t0.AddMinutes(1) -Config $script:cfg
        $r.State.PendingPushes = 3
        $r = Step-RedriveWatchdog -State $r.State -Probe $script:gone -Now $script:t0.AddMinutes(40) -Config $script:cfg
        ($r.Actions | Where-Object { $_ -like 'Notify:nudge*' }).Count | Should -Be 1
        $r = Step-RedriveWatchdog -State $r.State -Probe $script:gone -Now $script:t0.AddMinutes(50) -Config $script:cfg
        ($r.Actions | Where-Object { $_ -like 'Notify:nudge*' }).Count | Should -Be 0
    }
    It 'pauses and resumes' {
        $r = Step-RedriveWatchdog -State $script:s -Probe $script:up -Now $script:t0 -Config $script:cfg -Paused $true
        $r.State.State | Should -Be 'Paused'
        $r = Step-RedriveWatchdog -State $r.State -Probe $script:up -Now $script:t0.AddSeconds(5) -Config $script:cfg
        $r.State.State | Should -Be 'Syncing'
    }
}

Describe 'Restart budget' {
    It 'blocks a third restart inside ten minutes' {
        $state = Get-RedriveState
        $state.RestartTimes = @((Get-Date).AddMinutes(-8).ToUniversalTime().ToString('o'), (Get-Date).AddMinutes(-6).ToUniversalTime().ToString('o'))
        Save-RedriveState $state
        (Test-RedriveRestartBudget).Allowed | Should -BeFalse
        $state.RestartTimes = @((Get-Date).AddMinutes(-20).ToUniversalTime().ToString('o'))
        Save-RedriveState $state
        (Test-RedriveRestartBudget).Allowed | Should -BeTrue
        $state.RestartTimes = @((Get-Date).AddMinutes(-2).ToUniversalTime().ToString('o'))
        Save-RedriveState $state
        (Test-RedriveRestartBudget).Allowed | Should -BeFalse
    }
}

Describe 'Log rotation' {
    It 'rotates when the file grows past the limit' {
        $c = Get-RedriveConfig -Reload
        $c.Log.MaxBytes = 200
        Save-RedriveConfig $c
        Get-RedriveConfig -Reload | Out-Null
        1..20 | ForEach-Object { Write-RedriveLog -Message ('line ' + ('x' * 40)) }
        $p = Get-RedrivePaths
        (Test-Path "$($p.LogFile).1") | Should -BeTrue
    }
}
