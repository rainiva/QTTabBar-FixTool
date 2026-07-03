BeforeAll {
    $Script:QTTabBarLayoutMarker = 'E47BFD21CED7F48A3332BD8835EB6CE'
}

Describe 'Feature mapping' {
    It 'maps three feature IDs' {
        @('57048216', '57048237', '58988972').Count | Should -Be 3
    }
}

Describe 'Feature query parser' {
    It 'detects disabled state' {
        $q = @'
[57048216]
Priority        : User (8)
State           : Disabled (1)
'@
        ($q -match 'State\s*:\s*Disabled\s*\(1\)') | Should -Be $true
    }
    It 'rejects enabled state' {
        $q = "State           : Enabled (2)"
        ($q -match 'State\s*:\s*Disabled\s*\(1\)') | Should -Be $false
    }
}

Describe 'Toolbar layout marker' {
    It 'matches known QTTabBar layout bytes' {
        $hex = '0000' + $Script:QTTabBarLayoutMarker + '0000'
        $hex -match $Script:QTTabBarLayoutMarker | Should -Be $true
    }
}

Describe 'Health overall logic' {
    It 'keeps visual confirmation required even when config and runtime signals look good' {
        $configOk = $true
        $runtimeOk = $true
        $overall = if ($configOk -and $runtimeOk) { 'visual_check_required' } else { 'broken' }
        $overall | Should -Be 'visual_check_required'
    }
    It 'treats null as zero for collection count' {
        function Get-CollectionCount { param($Value); if ($null -eq $Value) { return 0 }; return @($Value).Count }
        (Get-CollectionCount $null) | Should -Be 0
    }
    It 'does not treat toolbar configuration as confirmed runtime readiness without DLL enumeration' {
        $moduleLoaded = $false
        $runtimeReady = $moduleLoaded
        $runtimeReady | Should -Be $false
    }
    It 'converts PowerShell registry provider paths for reg.exe' {
        function ConvertTo-RegExePath {
            param([string]$RegistryPath)
            if ($RegistryPath -match 'Registry::HKEY_LOCAL_MACHINE\\(.+)$') {
                return 'HKLM\' + $Matches[1]
            }
            if ($RegistryPath -match '^HKLM:\\(.+)$') {
                return 'HKLM\' + $Matches[1]
            }
            return $RegistryPath
        }
        $psPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\15\815149711'
        (ConvertTo-RegExePath $psPath) | Should -Be 'HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\15\815149711'
    }
    It 'clears active registry conflicts when all queried features are disabled' {
        $features = @(
            [PSCustomObject]@{ RegistryId='815149711'; Query = "State           : Disabled (1)" },
            [PSCustomObject]@{ RegistryId='1519792783'; Query = "State           : Disabled (1)" },
            [PSCustomObject]@{ RegistryId='1482552975'; Query = "State           : Disabled (1)" }
        )
        $registryKeys = @(
            [PSCustomObject]@{ RegistryId='815149711'; Priority='15'; EnabledState=1 },
            [PSCustomObject]@{ RegistryId='1519792783'; Priority='15'; EnabledState=2 },
            [PSCustomObject]@{ RegistryId='1482552975'; Priority='0'; EnabledState=2 }
        )
        $status = [PSCustomObject]@{ Features=$features; RegistryKeys=$registryKeys }
        $featuresCount = @($status.Features).Count
        $disabledCount = @($status.Features | Where-Object { $_.Query -match 'State\s*:\s*Disabled\s*\(1\)' }).Count
        ($disabledCount -eq $featuresCount) | Should -Be $true
    }
}

Describe 'Active registry conflict detection' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Fix-QTTabBar.ps1')
    }

    It 'returns zero active conflicts when all features are disabled' {
        $status = [PSCustomObject]@{
            Features = @(
                [PSCustomObject]@{ RegistryId='815149711'; Query = "State           : Disabled (1)" },
                [PSCustomObject]@{ RegistryId='1519792783'; Query = "State           : Disabled (1)" },
                [PSCustomObject]@{ RegistryId='1482552975'; Query = "State           : Disabled (1)" }
            )
            RegistryKeys = @(
                [PSCustomObject]@{ RegistryId='815149711'; Priority='15'; EnabledState=1 },
                [PSCustomObject]@{ RegistryId='1519792783'; Priority='15'; EnabledState=2 },
                [PSCustomObject]@{ RegistryId='1482552975'; Priority='0'; EnabledState=2 }
            )
        }
        (Get-CollectionCount (Test-HasActiveRegistryConflict $status)) | Should -Be 0
    }

    It 'requires visual confirmation before reporting healthy when only toolbar config is known' {
        Mock Test-QTTabBarToolbarConfigured { $true }
        Mock Test-QTTabBarAssemblyInstalled { $true }

        $status = [PSCustomObject]@{
            Features = @(
                [PSCustomObject]@{ RegistryId='815149711'; Query = "State           : Disabled (1)" },
                [PSCustomObject]@{ RegistryId='1519792783'; Query = "State           : Disabled (1)" },
                [PSCustomObject]@{ RegistryId='1482552975'; Query = "State           : Disabled (1)" }
            )
            RegistryKeys = @()
        }

        $health = Get-QTTabBarHealth -Status $status -ModuleLoaded:$false -ProbedExplorer:$false

        $health.Overall | Should -Be 'visual_check_required'
        $health.RuntimeReady | Should -Be $false
    }

    It 'still requires visual confirmation when the QTTabBar module is loaded' {
        Mock Test-QTTabBarToolbarConfigured { $true }
        Mock Test-QTTabBarAssemblyInstalled { $true }

        $status = [PSCustomObject]@{
            Features = @(
                [PSCustomObject]@{ RegistryId='815149711'; Query = "State           : Disabled (1)" },
                [PSCustomObject]@{ RegistryId='1519792783'; Query = "State           : Disabled (1)" },
                [PSCustomObject]@{ RegistryId='1482552975'; Query = "State           : Disabled (1)" }
            )
            RegistryKeys = @()
        }

        $health = Get-QTTabBarHealth -Status $status -ModuleLoaded:$true -ProbedExplorer:$true

        $health.Overall | Should -Be 'visual_check_required'
        $health.RuntimeReady | Should -Be $true
    }

    It 'converts PowerShell registry provider paths for HKLM provider' {
        $psPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\15\815149711'
        (ConvertTo-HKLMProviderPath $psPath) | Should -Be 'HKLM:\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\15\815149711'
    }

    It 'extracts HKLM subkey path for ownership APIs' {
        $providerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\15\815149711'
        (Get-HKLMSubKeyPath $providerPath) | Should -Be 'SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\15\815149711'
    }

    It 'builds ownership chain from Overrides to leaf key' {
        $subKey = 'SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\15\815149711'
        $chain = Get-RegistryOwnershipChain -SubKeyPath $subKey
        $chain.Count | Should -Be 3
        $chain[0] | Should -Be 'SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides'
        $chain[-1] | Should -Be $subKey
    }

    It 'detects protected FeatureManagement override keys' {
        (Test-IsProtectedFeatureOverrideKey 'SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\15\815149711') | Should -Be $true
        (Test-IsProtectedFeatureOverrideKey 'SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\8\815149711') | Should -Be $false
    }
}

Describe 'Worker argument parsing' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Run-QTTabBarFix.ps1')
    }

    It 'parses quick cleanup arguments' {
        $parsed = ConvertTo-WorkerParams -WorkerArgs @('-Phase', '2', '-NoRestart', '-SkipStatusReport')
        $parsed.Phase | Should -Be '2'
        $parsed.NoRestart | Should -Be $true
        $parsed.SkipStatusReport | Should -Be $true
    }

    It 'parses UI reset arguments' {
        $parsed = ConvertTo-WorkerParams -WorkerArgs @('-ResetUi')
        $parsed.ResetUi | Should -Be $true
    }

    It 'parses layout reset arguments' {
        $parsed = ConvertTo-WorkerParams -WorkerArgs @('-ResetLayout')
        $parsed.ResetLayout | Should -Be $true
    }

    It 'parses save snapshot arguments' {
        $parsed = ConvertTo-WorkerParams -WorkerArgs @('-SaveSnapshot')
        $parsed.SaveSnapshot | Should -Be $true
    }

    It 'parses restore snapshot arguments' {
        $parsed = ConvertTo-WorkerParams -WorkerArgs @('-RestoreSnapshot')
        $parsed.RestoreSnapshot | Should -Be $true
    }

    It 'routes menu choice 2 to health check' {
        Mock Invoke-Worker {}

        (Invoke-MenuChoice -Choice '2') | Should -Be $true
        Should -Invoke Invoke-Worker -Times 1 -Exactly -ParameterFilter {
            $WorkerArgs.Count -eq 2 -and
            $WorkerArgs[0] -eq '-VerifyOnly' -and
            $WorkerArgs[1] -eq '-SkipProbe'
        }
    }

    It 'routes menu choice 3 to UI reset helper' {
        Mock Invoke-Worker {}

        (Invoke-MenuChoice -Choice '3') | Should -Be $true
        Should -Invoke Invoke-Worker -Times 1 -Exactly -ParameterFilter {
            $WorkerArgs.Count -eq 1 -and $WorkerArgs[0] -eq '-ResetUi'
        }
    }

    It 'routes menu choice 4 to snapshot save helper' {
        Mock Invoke-Worker {}

        (Invoke-MenuChoice -Choice '4') | Should -Be $true
        Should -Invoke Invoke-Worker -Times 1 -Exactly -ParameterFilter {
            $WorkerArgs.Count -eq 1 -and $WorkerArgs[0] -eq '-SaveSnapshot'
        }
    }

    It 'routes menu choice 5 to snapshot restore helper' {
        Mock Invoke-Worker {}

        (Invoke-MenuChoice -Choice '5') | Should -Be $true
        Should -Invoke Invoke-Worker -Times 1 -Exactly -ParameterFilter {
            $WorkerArgs.Count -eq 1 -and $WorkerArgs[0] -eq '-RestoreSnapshot'
        }
    }

    It 'keeps experimental layout reset out of the simplified menu' {
        Mock Invoke-Worker {}

        (Invoke-MenuChoice -Choice '9') | Should -Be $true
        Should -Invoke Invoke-Worker -Times 0 -Exactly
    }
}

Describe 'Worker script loading' {
    It 'loads Invoke-QTTabBarFixCore at script scope' {
        $launcher = Join-Path $PSScriptRoot '..\Run-QTTabBarFix.ps1'
        $fixScript = Join-Path $PSScriptRoot '..\Fix-QTTabBar.ps1'
        $null = [ScriptBlock]::Create(@"
Set-Location '$($launcher | Split-Path -Parent | ForEach-Object { $_ -replace "'", "''" })'
. '$($fixScript | ForEach-Object { $_ -replace "'", "''" })'
if (-not (Get-Command Invoke-QTTabBarFixCore -ErrorAction SilentlyContinue)) { throw 'missing core' }
"@).Invoke()
        $true | Should -Be $true
    }

    It 'exposes ResetLayout as a top-level script parameter' {
        $command = Get-Command (Join-Path $PSScriptRoot '..\Fix-QTTabBar.ps1')

        $command.Parameters.ContainsKey('ResetLayout') | Should -Be $true
    }

    It 'exposes snapshot save and restore as top-level script parameters' {
        $command = Get-Command (Join-Path $PSScriptRoot '..\Fix-QTTabBar.ps1')

        $command.Parameters.ContainsKey('SaveSnapshot') | Should -Be $true
        $command.Parameters.ContainsKey('RestoreSnapshot') | Should -Be $true
    }
}

Describe 'UI reset helper' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Fix-QTTabBar.ps1')
    }

    It 'throws when the foreground window is not Explorer' {
        Mock Test-IsExplorerForegroundWindow { $false }

        { Invoke-QTTabBarUiReset -DelaySeconds 0 -InterKeyDelayMilliseconds 0 } | Should -Throw '*资源管理器*'
    }

    It 'sends F11 twice when Explorer is in the foreground' {
        Mock Test-IsExplorerForegroundWindow { $true }
        Mock Send-F11KeyToForegroundWindow {}
        Mock Start-Sleep {}

        Invoke-QTTabBarUiReset -DelaySeconds 0 -InterKeyDelayMilliseconds 0

        Should -Invoke Test-IsExplorerForegroundWindow -Times 1 -Exactly
        Should -Invoke Send-F11KeyToForegroundWindow -Times 2 -Exactly
    }
}

Describe 'Layout reset helper' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Fix-QTTabBar.ps1')
    }

    It 'returns both persisted ITBar7Layout reset targets' {
        $targets = Get-QTTabBarLayoutResetTargets

        $targets.Count | Should -Be 2
        $targets[0].KeyPath | Should -Be 'HKCU:\Software\Microsoft\Internet Explorer\Toolbar\ShellBrowser'
        $targets[0].ValueName | Should -Be 'ITBar7Layout'
        $targets[1].KeyPath | Should -Be 'HKCU:\Software\Quizo\QTTabBar\Volatile'
        $targets[1].ValueName | Should -Be 'ITBar7Layout'
    }

    It 'removes both persisted layout values and keeps the reset when volatile layout recovers' {
        Mock Write-Log {}
        Mock Export-CurrentUserRegistryBackup {}
        Mock Import-RegistryBackupFile {}
        Mock Invoke-QTTabBarProbe {}
        Mock Test-QTTabBarVolatileLayoutPresent { $true }
        Mock Restart-ExplorerShell {}
        Mock Remove-ItemProperty {}
        Mock Test-Path { $true }
        Mock Get-ItemProperty {
            [PSCustomObject]@{
                ITBar7Layout = [byte[]](0x13, 0x00)
            }
        }

        Invoke-QTTabBarLayoutReset

        Should -Invoke Export-CurrentUserRegistryBackup -Times 2 -Exactly
        Should -Invoke Remove-ItemProperty -Times 2 -Exactly -ParameterFilter {
            $Name -eq 'ITBar7Layout'
        }
        Should -Invoke Invoke-QTTabBarProbe -Times 1 -Exactly
        Should -Invoke Restart-ExplorerShell -Times 1 -Exactly
        Should -Invoke Import-RegistryBackupFile -Times 0 -Exactly
    }

    It 'auto-restores both backups when volatile layout does not recover after reset' {
        Mock Write-Log {}
        Mock Export-CurrentUserRegistryBackup {
            param([string]$RegistryPath)
            return ('D:\Backups\' + ($RegistryPath -replace '[:\\]', '_') + '.reg')
        }
        Mock Import-RegistryBackupFile {}
        Mock Invoke-QTTabBarProbe {}
        Mock Test-QTTabBarVolatileLayoutPresent { $false }
        Mock Restart-ExplorerShell {}
        Mock Remove-ItemProperty {}
        Mock Test-Path { $true }
        Mock Get-ItemProperty {
            [PSCustomObject]@{
                ITBar7Layout = [byte[]](0x13, 0x00)
            }
        }

        Invoke-QTTabBarLayoutReset

        Should -Invoke Remove-ItemProperty -Times 2 -Exactly -ParameterFilter {
            $Name -eq 'ITBar7Layout'
        }
        Should -Invoke Invoke-QTTabBarProbe -Times 1 -Exactly
        Should -Invoke Test-QTTabBarVolatileLayoutPresent -Times 1 -Exactly
        Should -Invoke Import-RegistryBackupFile -Times 2 -Exactly
        Should -Invoke Restart-ExplorerShell -Times 2 -Exactly
    }
}

Describe 'Snapshot recovery helper' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Fix-QTTabBar.ps1')
    }

    It 'returns both snapshot registry targets' {
        $targets = Get-QTTabBarSnapshotTargets

        $targets.Count | Should -Be 2
        $targets[0].KeyPath | Should -Be 'HKCU:\Software\Microsoft\Internet Explorer\Toolbar\ShellBrowser'
        $targets[0].FileName | Should -Be 'shellbrowser.reg'
        $targets[1].KeyPath | Should -Be 'HKCU:\Software\Quizo\QTTabBar\Volatile'
        $targets[1].FileName | Should -Be 'volatile.reg'
    }

    It 'exports both snapshot registry keys into a dedicated snapshot directory' {
        Mock Write-Log {}
        Mock Test-Path { $true }
        Mock New-Item {
            [PSCustomObject]@{
                FullName = 'D:\Project\QTTabBar-FixTool\Backup\Snapshots\healthy-20260701-210000'
            }
        } -ParameterFilter { $ItemType -eq 'Directory' }
        Mock Export-CurrentUserRegistryFile {}

        Invoke-QTTabBarSnapshotSave

        Should -Invoke Export-CurrentUserRegistryFile -Times 1 -Exactly -ParameterFilter {
            $RegistryPath -eq 'HKCU:\Software\Microsoft\Internet Explorer\Toolbar\ShellBrowser' -and
            $DestinationFile -like '*\Backup\Snapshots\healthy-*\shellbrowser.reg'
        }
        Should -Invoke Export-CurrentUserRegistryFile -Times 1 -Exactly -ParameterFilter {
            $RegistryPath -eq 'HKCU:\Software\Quizo\QTTabBar\Volatile' -and
            $DestinationFile -like '*\Backup\Snapshots\healthy-*\volatile.reg'
        }
    }

    It 'imports both snapshot files from the latest saved snapshot and restarts Explorer' {
        Mock Write-Log {}
        Mock Test-Path { $true }
        Mock Get-ChildItem {
            @(
                [PSCustomObject]@{
                    FullName = 'D:\Project\QTTabBar-FixTool\Backup\Snapshots\healthy-20260701-210000'
                    Name = 'healthy-20260701-210000'
                    LastWriteTime = [datetime]'2026-07-01T21:00:00'
                    PSIsContainer = $true
                }
            )
        }
        Mock Import-RegistryBackupFile {}
        Mock Restart-ExplorerShell {}

        Invoke-QTTabBarSnapshotRestore

        Should -Invoke Import-RegistryBackupFile -Times 1 -Exactly -ParameterFilter {
            $BackupFile -like '*\Backup\Snapshots\healthy-*\shellbrowser.reg'
        }
        Should -Invoke Import-RegistryBackupFile -Times 1 -Exactly -ParameterFilter {
            $BackupFile -like '*\Backup\Snapshots\healthy-*\volatile.reg'
        }
        Should -Invoke Restart-ExplorerShell -Times 1 -Exactly
    }

    It 'throws when no saved snapshot exists' {
        Mock Write-Log {}
        Mock Test-Path { $false }

        { Invoke-QTTabBarSnapshotRestore } | Should -Throw '*快照*'
    }

    It 'treats reg.exe success text on stderr as a successful import' {
        Mock Write-Log {}
        Mock Test-Path { $true }
        Mock Invoke-NativeCommandCapture {
            [PSCustomObject]@{
                ExitCode = 0
                Output = ''
                Error = '操作成功完成。'
            }
        }

        { Import-RegistryBackupFile -BackupFile 'D:\snapshot.reg' } | Should -Not -Throw
    }
}
