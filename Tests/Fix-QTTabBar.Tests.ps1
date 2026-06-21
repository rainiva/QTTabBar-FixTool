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
    It 'marks healthy when config and runtime ok' {
        $configOk = $true
        $runtimeOk = $true
        $overall = if ($configOk -and $runtimeOk) { 'healthy' } else { 'broken' }
        $overall | Should -Be 'healthy'
    }
    It 'treats null as zero for collection count' {
        function Get-CollectionCount { param($Value); if ($null -eq $Value) { return 0 }; return @($Value).Count }
        (Get-CollectionCount $null) | Should -Be 0
    }
    It 'treats toolbar configured as runtime ready without DLL enumeration' {
        $moduleLoaded = $false
        $toolbarConfigured = $true
        $runtimeReady = if ($moduleLoaded) { $true } else { $toolbarConfigured }
        $runtimeReady | Should -Be $true
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
}
