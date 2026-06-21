#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('1', '2', 'All')][string] $Phase = 'All',
    [switch] $QueryOnly,
    [switch] $VerifyOnly,
    [switch] $NoRestart,
    [switch] $SkipProbe,
    [switch] $SkipStatusReport,
    [string] $ViVeToolPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Script:ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:LogDir = Join-Path $ToolRoot 'Logs'
$Script:BackupDir = Join-Path $ToolRoot 'Backup'
$Script:LogFile = Join-Path $LogDir ('fix-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
$Script:QTTabBarToolbarClsid = '{D2BF470E-ED1C-487F-A333-2BD8835EB6CE}'
$Script:QTTabBarLayoutMarker = 'E47BFD21CED7F48A3332BD8835EB6CE'
$Script:FeatureMap = @(
    [PSCustomObject]@{ FeatureId='57048216'; RegistryId='815149711'; Label='2025-08 功能包 (KB5062660)' }
    [PSCustomObject]@{ FeatureId='57048237'; RegistryId='1519792783'; Label='2025-12 功能包 (KB5072033)' }
    [PSCustomObject]@{ FeatureId='58988972'; RegistryId='1482552975'; Label='2026-02 功能包 (KB5074105)' }
)
$Script:OverridesRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides'

function Write-Log {
    param([string]$Message,[ValidateSet('INFO','WARN','ERROR','OK')][string]$Level='INFO')
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}
function Test-IsAdministrator {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Resolve-ViVeToolPath {
    param([string]$ExplicitPath)
    $candidates = @()
    if ($ExplicitPath) { $candidates += $ExplicitPath }
    $candidates += @(
        (Join-Path $Script:ToolRoot 'ViVeTool.exe')
        (Join-Path $Script:ToolRoot '..\ViVeTool-v0.3.4-QTTabBarFixTool-OneKey\ViVeTool.exe')
        'C:\ViVeTool\ViVeTool.exe'
        'C:\vivetools\ViVeTool.exe'
    )
    foreach ($path in $candidates) {
        try { return (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path } catch {}
    }
    throw '未找到 ViVeTool.exe，请将 ViVeTool.exe 放到工具目录或通过 -ViVeToolPath 指定。'
}
function Get-FeatureOverrideKeys {
    param([string]$RegistryId)
    if (-not (Test-Path $Script:OverridesRoot)) { return @() }
    $results = @()
    Get-ChildItem -Path $Script:OverridesRoot -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -eq $RegistryId } |
        ForEach-Object {
            $priority = Split-Path (Split-Path $_.PSPath -Parent) -Leaf
            $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            $results += [PSCustomObject]@{
                RegistryId=$RegistryId; Priority=$priority; Path=(ConvertTo-HKLMProviderPath $_.PSPath); EnabledState=$props.EnabledState
            }
        }
    return $results
}
function Test-FeatureQueryDisabled {
    param([string]$QueryText)
    return ($QueryText -match 'State\s*:\s*Disabled\s*\(?\s*1\s*\)?')
}
function Get-CollectionCount {
    param($Value)
    if ($null -eq $Value) { return 0 }
    return @($Value).Count
}
function Test-HasRegistryConflict {
    param($RegistryKeys)
    $conflicts = $RegistryKeys | Where-Object {
        $_.Priority -in @('15', '0') -and $_.EnabledState -in @(1, 2)
    }
    return ,@($conflicts)
}
function Test-HasActiveRegistryConflict {
    param($Status)
    $features = @($Status.Features)
    if ((Get-CollectionCount $features) -eq 0) {
        return Test-HasRegistryConflict $Status.RegistryKeys
    }
    $disabledCount = Get-CollectionCount ($features | Where-Object { Test-FeatureQueryDisabled $_.Query })
    if ($disabledCount -eq (Get-CollectionCount $features)) {
        return ,@()
    }
    $active = @()
    foreach ($feature in $features) {
        if (Test-FeatureQueryDisabled $feature.Query) { continue }
        $keys = @($Status.RegistryKeys | Where-Object { $_.RegistryId -eq $feature.RegistryId })
        $active += @(Test-HasRegistryConflict $keys)
    }
    return ,@($active)
}
function Test-QTTabBarToolbarConfigured {
    $toolbarKey = 'HKCU:\Software\Microsoft\Internet Explorer\Toolbar\ShellBrowser'
    if (-not (Test-Path $toolbarKey)) { return $false }
    $props = Get-ItemProperty $toolbarKey
    foreach ($name in $props.PSObject.Properties.Name) {
        if ($name -ieq $Script:QTTabBarToolbarClsid) { return $true }
    }
    if ($props.ITBar7Layout) {
        $hex = ($props.ITBar7Layout | ForEach-Object { '{0:X2}' -f $_ }) -join ''
        if ($hex -match $Script:QTTabBarLayoutMarker) { return $true }
    }
    return $false
}
function Test-QTTabBarModuleLoaded {
    $loaded = $false
    Get-Process explorer -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $_.Modules | Where-Object { $_.FileName -match 'QTTabBar' } | ForEach-Object { $loaded = $true }
        } catch {}
    }
    return $loaded
}
function Test-QTTabBarRuntimeReady {
    param([bool]$ModuleLoaded)
    if ($ModuleLoaded) { return $true }
    return Test-QTTabBarToolbarConfigured
}
function Test-QTTabBarAssemblyInstalled {
    $gac = 'C:\Windows\Microsoft.Net\assembly\GAC_MSIL\QTTabBar'
    return Test-Path $gac
}
function Get-QTTabBarFixStatus {
    param([string]$ViVeExe)
    $ver = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $status = [PSCustomObject]@{
        OSBuild=$ver.CurrentBuild; OSUBR=$ver.UBR; ViVeTool=$ViVeExe; Features=@(); RegistryKeys=@()
    }
    foreach ($item in $Script:FeatureMap) {
        $query = & $ViVeExe /query ("/id:{0}" -f $item.FeatureId) 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log ('ViVeTool /query id:{0} 退出码 {1}，输出: {2}' -f $item.FeatureId, $LASTEXITCODE, $query.Trim()) 'WARN'
        }
        $status.Features += [PSCustomObject]@{
            FeatureId=$item.FeatureId; RegistryId=$item.RegistryId; Label=$item.Label; Query=$query.Trim()
        }
        $status.RegistryKeys += @(Get-FeatureOverrideKeys -RegistryId $item.RegistryId)
    }
    return $status
}
function Get-QTTabBarHealth {
    param(
        $Status,
        [bool]$ModuleLoaded,
        [bool]$ProbedExplorer
    )
    $disabledCount = Get-CollectionCount ($Status.Features | Where-Object { Test-FeatureQueryDisabled $_.Query })
    $leftoverKeys = @($Status.RegistryKeys | Where-Object { $_.Priority -in @('15', '0') })
    $activeConflicts = Test-HasActiveRegistryConflict $Status
    $toolbarConfigured = Test-QTTabBarToolbarConfigured
    $assemblyInstalled = Test-QTTabBarAssemblyInstalled
    $runtimeReady = Test-QTTabBarRuntimeReady -ModuleLoaded $ModuleLoaded
    $featureTotal = Get-CollectionCount $Status.Features
    if ($featureTotal -eq 0) { $featureTotal = Get-CollectionCount $Script:FeatureMap }

    $configOk = ($disabledCount -eq $featureTotal) -and ((Get-CollectionCount $activeConflicts) -eq 0) -and ((Get-CollectionCount $leftoverKeys) -eq 0) -and $toolbarConfigured -and $assemblyInstalled

    $overall = 'unknown'
    $summary = ''
    if ($configOk -and $runtimeReady) {
        $overall = 'healthy'
        if ($ModuleLoaded) {
            $summary = 'QTTabBar 配置与运行状态正常，标签栏应可正常使用。'
        } else {
            $summary = 'QTTabBar 配置正常，工具栏已启用。标签栏应可正常使用。（.NET 插件通常无法通过 DLL 枚举检测）'
        }
    } elseif ($configOk -and -not $runtimeReady) {
        $overall = 'config_only'
        $summary = '配置层面正常，但工具栏未启用。请打开资源管理器 → 查看 → 选项 → 勾选 QTTabBar。'
    } elseif (-not $configOk -and $runtimeReady) {
        $overall = 'runtime_only'
        $summary = '检测到 QTTabBar 工具栏已配置，但仍有配置项未就绪（可能是残留注册表键干扰），建议执行阶段二清理。'
    } else {
        $overall = 'broken'
        $summary = 'QTTabBar 尚未就绪。建议执行完整修复（阶段一+阶段二）并重启电脑。'
    }

    return [PSCustomObject]@{
        Overall=$overall
        Summary=$summary
        FeatureFlagsDisabled=$disabledCount
        FeatureFlagsTotal=$featureTotal
        RegistryConflicts=(Get-CollectionCount $activeConflicts)
        RegistryLeftoverKeys=(Get-CollectionCount $leftoverKeys)
        ToolbarConfigured=$toolbarConfigured
        AssemblyInstalled=$assemblyInstalled
        ModuleLoaded=$ModuleLoaded
        RuntimeReady=$runtimeReady
        ProbedExplorer=$ProbedExplorer
        ConfigOk=$configOk
        RuntimeOk=$runtimeReady
    }
}
function Show-StatusReport {
    param($Status)
    Write-Host ''
    Write-Host '========== QTTabBar 修复状态 ==========' -ForegroundColor Cyan
    Write-Host ('系统版本: {0}.{1}' -f $Status.OSBuild, $Status.OSUBR)
    Write-Host ('ViVeTool: {0}' -f $Status.ViVeTool)
    Write-Host ''
    foreach ($feature in $Status.Features) {
        Write-Host ('--- 功能包 {0} ({1}) ---' -f $feature.FeatureId, $feature.Label) -ForegroundColor Yellow
        Write-Host $feature.Query
        Write-Host ''
    }
    if ((Get-CollectionCount $Status.RegistryKeys) -eq 0) {
        Write-Host '注册表 Overrides: 未发现相关键' -ForegroundColor Green
    } else {
        Write-Host '注册表 Overrides:' -ForegroundColor Yellow
        $Status.RegistryKeys | Sort-Object RegistryId, Priority |
            Format-Table RegistryId, Priority, EnabledState, Path -AutoSize |
            Out-String | ForEach-Object { Write-Host $_ }
    }
}
function Show-HealthReport {
    param($Health)
    Write-Host ''
    Write-Host '========== QTTabBar 健康检测 ==========' -ForegroundColor Cyan
    $color = switch ($Health.Overall) {
        'healthy' { 'Green' }
        'config_only' { 'Yellow' }
        'runtime_only' { 'Yellow' }
        default { 'Red' }
    }
    Write-Host $Health.Summary -ForegroundColor $color
    Write-Host ''
    Write-Host ('  ViVeTool 功能包已禁用: {0}/{1}' -f $Health.FeatureFlagsDisabled, $Health.FeatureFlagsTotal)
    Write-Host ('  注册表有效冲突: {0}' -f $Health.RegistryConflicts)
    if ($Health.RegistryLeftoverKeys -gt 0 -and $Health.RegistryConflicts -eq 0) {
        Write-Host ('  注册表残留键 (建议清理): {0}' -f $Health.RegistryLeftoverKeys) -ForegroundColor Yellow
    }
    Write-Host ('  工具栏布局已配置 QTTabBar: {0}' -f $(if ($Health.ToolbarConfigured) { '是' } else { '否' }))
    Write-Host ('  QTTabBar 程序集已安装: {0}' -f $(if ($Health.AssemblyInstalled) { '是' } else { '否' }))
    Write-Host ('  运行状态就绪 (工具栏/DLL): {0}' -f $(if ($Health.RuntimeReady) { '是' } else { '否' }))
    if (-not $Health.ModuleLoaded) {
        Write-Host '  Explorer DLL 枚举: 未检出（.NET 插件常见，不代表未运行）' -ForegroundColor DarkGray
    } else {
        Write-Host '  Explorer DLL 枚举: 已检出 QTTabBar.dll'
    }
    if ($Health.ProbedExplorer) {
        Write-Host '  已自动打开资源管理器进行探测' -ForegroundColor DarkGray
    }
    Write-Host ''
    switch ($Health.Overall) {
        'healthy' { Write-Host '结论: 通过' -ForegroundColor Green }
        'config_only' { Write-Host '结论: 部分通过（需手动启用工具栏或重启电脑）' -ForegroundColor Yellow }
        'runtime_only' { Write-Host '结论: 部分通过（建议继续修复或重启）' -ForegroundColor Yellow }
        default { Write-Host '结论: 未通过' -ForegroundColor Red }
    }
}
function Invoke-QTTabBarProbe {
    Write-Log '正在打开资源管理器以探测 QTTabBar 加载状态...'
    $shell = New-Object -ComObject Shell.Application
    $null = $shell.Windows()
    Start-Process explorer.exe
    Start-Sleep -Seconds 4
    return (Test-QTTabBarModuleLoaded)
}
function Invoke-Phase1 {
    param([string]$ViVeExe)
    Write-Log '开始阶段一：ViVeTool 禁用冲突功能包'
    $allOk = $true
    foreach ($item in $Script:FeatureMap) {
        $viveArgs = @('/disable', ("/id:{0}" -f $item.FeatureId))
        Write-Log ('执行: ViVeTool {0}' -f ($viveArgs -join ' '))
        if ($PSCmdlet.ShouldProcess($item.FeatureId, 'ViVeTool Disable')) {
            $output = & $ViVeExe @viveArgs 2>&1 | Out-String
            Write-Log $output.Trim()
            if ($output -notmatch 'Successfully set feature configuration') {
                Write-Log ('阶段一警告: Feature {0} 可能未成功禁用' -f $item.FeatureId) 'WARN'
                $allOk = $false
            } else {
                Write-Log ('阶段一完成: Feature {0}' -f $item.FeatureId) 'OK'
            }
        }
    }
    return $allOk
}
function ConvertTo-HKLMProviderPath {
    param([string]$RegistryPath)
    if ($RegistryPath -match 'Registry::HKEY_LOCAL_MACHINE\\(.+)$') {
        return 'HKLM:\' + $Matches[1]
    }
    if ($RegistryPath -match '^HKLM:\\(.+)$') {
        return 'HKLM:\' + $Matches[1]
    }
    if ($RegistryPath -match '^HKEY_LOCAL_MACHINE\\(.+)$') {
        return 'HKLM:\' + $Matches[1]
    }
    return $RegistryPath
}
function ConvertTo-RegExePath {
    param([string]$RegistryPath)
    $providerPath = ConvertTo-HKLMProviderPath $RegistryPath
    if ($providerPath -match '^HKLM:\\(.+)$') {
        return 'HKLM\' + $Matches[1]
    }
    return $RegistryPath
}
function Export-RegistryBackup {
    param([string]$RegistryPath)
    $providerPath = ConvertTo-HKLMProviderPath $RegistryPath
    if (-not (Test-Path -LiteralPath $providerPath)) { return $null }
    $name = (ConvertTo-RegExePath $providerPath) -replace '[\\:]', '_'
    $backupFile = Join-Path $Script:BackupDir ('{0}-{1:yyyyMMdd-HHmmss}.reg' -f $name, (Get-Date))
    $regPath = ConvertTo-RegExePath $providerPath
    $proc = Start-Process reg.exe -ArgumentList @('export', $regPath, $backupFile, '/y') -Wait -PassThru -WindowStyle Hidden
    if ($proc.ExitCode -ne 0) { throw "注册表备份失败: $RegistryPath" }
    Write-Log ('已备份: {0}' -f $backupFile)
    return $backupFile
}
function Get-HKLMSubKeyPath {
    param([string]$RegistryPath)
    $providerPath = ConvertTo-HKLMProviderPath $RegistryPath
    if ($providerPath -notmatch '^HKLM:\\(.+)$') {
        throw "无效的 HKLM 路径: $RegistryPath"
    }
    return $Matches[1]
}
function Enable-TokenPrivilege {
    param([Parameter(Mandatory)][string]$Privilege)
    if (-not ([System.Management.Automation.PSTypeName]'Win32.RegistryToken').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out long lpLuid);
    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr hObject);
    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES {
        public int PrivilegeCount;
        public long Luid;
        public int Attributes;
    }
    public const int SE_PRIVILEGE_ENABLED = 0x00000002;
    public const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    public const uint TOKEN_QUERY = 0x0008;
}
'@
    }
    $tokenHandle = [IntPtr]::Zero
    if (-not [Win32]::OpenProcessToken([Diagnostics.Process]::GetCurrentProcess().Handle, [Win32]::TOKEN_ADJUST_PRIVILEGES -bor [Win32]::TOKEN_QUERY, [ref]$tokenHandle)) {
        throw 'OpenProcessToken failed'
    }
    $luid = [long]0
    if (-not [Win32]::LookupPrivilegeValue($null, $Privilege, [ref]$luid)) {
        throw "LookupPrivilegeValue failed for $Privilege"
    }
    $tp = New-Object Win32+TOKEN_PRIVILEGES
    $tp.PrivilegeCount = 1
    $tp.Luid = $luid
    $tp.Attributes = [Win32]::SE_PRIVILEGE_ENABLED
    [Win32]::AdjustTokenPrivileges($tokenHandle, $false, [ref]$tp, [System.Runtime.InteropServices.Marshal]::SizeOf($tp), [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    [Win32]::CloseHandle($tokenHandle) | Out-Null
}
function Get-RegistryOwnershipChain {
    param([Parameter(Mandatory)][string]$SubKeyPath)
    $marker = 'FeatureManagement\Overrides'
    $idx = $SubKeyPath.IndexOf($marker)
    if ($idx -lt 0) { return @($SubKeyPath) }
    $base = $SubKeyPath.Substring(0, $idx + $marker.Length).TrimEnd('\')
    $chain = @($base)
    $relative = $SubKeyPath.Substring($idx + $marker.Length).TrimStart('\')
    if ($relative) {
        $current = $base
        foreach ($part in ($relative -split '\\')) {
            if ([string]::IsNullOrWhiteSpace($part)) { continue }
            $current = "$current\$part"
            $chain += $current
        }
    }
    return $chain
}
function Open-HKLMSubKey {
    param(
        [Parameter(Mandatory)][string]$SubKeyPath,
        [Parameter(Mandatory)][System.Security.AccessControl.RegistryRights]$Rights
    )
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    return $baseKey.OpenSubKey(
        $SubKeyPath,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        $Rights)
}
function Enable-RegistryDeletePrivileges {
    Enable-TokenPrivilege -Privilege SeTakeOwnershipPrivilege
    Enable-TokenPrivilege -Privilege SeRestorePrivilege
    Enable-TokenPrivilege -Privilege SeBackupPrivilege
    Enable-TokenPrivilege -Privilege SeSecurityPrivilege
}
function Set-RegistryKeyOwnershipSingle {
    param(
        [Parameter(Mandatory)][string]$SubKeyPath,
        [System.Security.Principal.NTAccount]$Owner
    )
    if (-not $Owner) {
        $Owner = New-Object System.Security.Principal.NTAccount('BUILTIN\Administrators')
    }
    $key = Open-HKLMSubKey -SubKeyPath $SubKeyPath -Rights ([System.Security.AccessControl.RegistryRights]::TakeOwnership)
    if ($null -eq $key) { throw "无法打开注册表项 TakeOwnership: $SubKeyPath" }
    try {
        $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
        $acl.SetOwner($Owner)
        $key.SetAccessControl($acl)
    } finally {
        $key.Close()
    }
    $key = Open-HKLMSubKey -SubKeyPath $SubKeyPath -Rights ([System.Security.AccessControl.RegistryRights]::ChangePermissions)
    if ($null -eq $key) { throw "无法打开注册表项 ChangePermissions: $SubKeyPath" }
    try {
        $acl = $key.GetAccessControl()
        foreach ($account in @(
            $Owner,
            (New-Object System.Security.Principal.NTAccount([System.Security.Principal.WindowsIdentity]::GetCurrent().Name))
        )) {
            $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
                $account,
                [System.Security.AccessControl.RegistryRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)
            $acl.AddAccessRule($rule)
        }
        $key.SetAccessControl($acl)
    } finally {
        $key.Close()
    }
}
function Set-RegistryKeyOwnershipChain {
    param([Parameter(Mandatory)][string]$SubKeyPath)
    Enable-RegistryDeletePrivileges
    $chain = Get-RegistryOwnershipChain -SubKeyPath $SubKeyPath
    Write-Log ('取得注册表所有权链 ({0} 级): {1}' -f (Get-CollectionCount $chain), $SubKeyPath)
    foreach ($path in $chain) {
        Set-RegistryKeyOwnershipSingle -SubKeyPath $path
    }
}
function Test-IsProtectedFeatureOverrideKey {
    param([string]$SubKeyPath)
    return ($SubKeyPath -match 'FeatureManagement\\Overrides\\(15|0)\\')
}
function Find-NSudoExecutable {
    $candidates = @('NSudo.exe', 'NSudoLC.exe', 'NSudoLG.exe')
    foreach ($name in $candidates) {
        $path = Join-Path $Script:ToolRoot $name
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}
function Invoke-RegDeleteAsSystem {
    param(
        [Parameter(Mandatory)][string]$RegPath,
        [Parameter(Mandatory)][string]$ProviderPath
    )
    $nsudoExe = Find-NSudoExecutable
    if (-not $nsudoExe) {
        throw @"
未找到 NSudo.exe — 删除 TrustedInstaller 保护的注册表键需要此工具。

下载地址: https://github.com/M2TeamArchived/NSudo/releases
  1. 下载 NSudo 压缩包 (如 NSudo_9.x.x.x.zip)
  2. 解压后将 NSudo.exe (或 NSudoLC.exe) 放入:
     $Script:ToolRoot
  3. 重新运行本工具的「快速清理」选项
"@
    }
    $helperScript = Join-Path $Script:ToolRoot 'Scripts\System-DeleteRegistryKey.ps1'
    if (-not (Test-Path -LiteralPath $helperScript)) {
        throw "未找到删除脚本: $helperScript"
    }
    $workDir = Join-Path $env:TEMP 'QTTabBarFixTool'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $localHelper = Join-Path $workDir 'System-DeleteRegistryKey.ps1'
    Copy-Item -LiteralPath $helperScript -Destination $localHelper -Force
    $logFile = Join-Path $workDir ('ti-delete-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ProviderPath "{1}" -RegPath "{2}" -LogFile "{3}"' -f $localHelper, $ProviderPath, $RegPath, $logFile
    $nsudoArgs = '-U:T -P:E -Wait "{0}" {1}' -f $psExe, $scriptArgs
    Write-Log ('使用 NSudo 以 TrustedInstaller 身份删除: {0}' -f $RegPath)
    $proc = Start-Process -FilePath $nsudoExe -ArgumentList $nsudoArgs -PassThru -NoNewWindow -Wait
    if ($proc.ExitCode -ne 0) {
        Write-Log ('NSudo 退出码: {0}' -f $proc.ExitCode) 'WARN'
    }
    if (Test-Path -LiteralPath $logFile) {
        Get-Content -LiteralPath $logFile | ForEach-Object { Write-Log $_ }
        $archiveLog = Join-Path $Script:LogDir (Split-Path $logFile -Leaf)
        Copy-Item -LiteralPath $logFile -Destination $archiveLog -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}
function Invoke-RegDeleteKey {
    param([string]$RegPath)
    $output = & reg.exe delete $RegPath /f 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw ("reg.exe delete 失败 (exit {0}): {1} - {2}" -f $LASTEXITCODE, $RegPath, $output.Trim())
    }
}
function Remove-RegistryKeyForce {
    param([string]$KeyPath)
    $providerPath = ConvertTo-HKLMProviderPath $KeyPath
    if (-not (Test-Path -LiteralPath $providerPath)) { return $false }
    $subKeyPath = Get-HKLMSubKeyPath $KeyPath
    $regPath = ConvertTo-RegExePath $providerPath

    if (Test-IsProtectedFeatureOverrideKey -SubKeyPath $subKeyPath) {
        Write-Log '检测到 TrustedInstaller 保护键，将通过 NSudo 以 TI 身份删除' 'INFO'
        Invoke-RegDeleteAsSystem -RegPath $regPath -ProviderPath $providerPath
    } else {
        try {
            Set-RegistryKeyOwnershipChain -SubKeyPath $subKeyPath
            Remove-Item -LiteralPath $providerPath -Recurse -Force
        } catch {
            Write-Log ('PowerShell 删除失败: {0}' -f $_.Exception.Message) 'WARN'
        }
        if (Test-Path -LiteralPath $providerPath) {
            try {
                Invoke-RegDeleteKey -RegPath $regPath
            } catch {
                Write-Log ('reg.exe 删除失败: {0}' -f $_.Exception.Message) 'WARN'
            }
        }
        if (Test-Path -LiteralPath $providerPath) {
            Write-Log '改用 NSudo (TrustedInstaller) 删除...' 'WARN'
            Invoke-RegDeleteAsSystem -RegPath $regPath -ProviderPath $providerPath
        }
    }

    if (Test-Path -LiteralPath $providerPath) {
        throw "注册表删除失败: $providerPath"
    }
    return $true
}
function Invoke-Phase2 {
    Write-Log '开始阶段二：清理 FeatureManagement 冲突注册表键'
    $targets = @()
    foreach ($item in $Script:FeatureMap) { $targets += @(Get-FeatureOverrideKeys -RegistryId $item.RegistryId) }
    if ((Get-CollectionCount $targets) -eq 0) { Write-Log '未发现需要清理的注册表键' 'OK'; return $true }
    $toRemove = $targets | Where-Object { $_.Priority -in @('15', '0') }
    $skipped = $targets | Where-Object { $_.Priority -eq '8' }
    foreach ($key in $skipped) { Write-Log ('保留 User 优先级键: {0}' -f $key.Path) }
    if ((Get-CollectionCount $toRemove) -eq 0) {
        Write-Log '未发现 Priority 15/0 冲突键' 'WARN'
        return $true
    }
    $removed = 0
    $failed = 0
    foreach ($key in $toRemove) {
        Write-Log ('准备删除: {0} (Priority {1})' -f $key.Path, $key.Priority)
        if ($PSCmdlet.ShouldProcess($key.Path, 'Delete Registry Key')) {
            try {
                Export-RegistryBackup -RegistryPath $key.Path | Out-Null
                Remove-RegistryKeyForce -KeyPath $key.Path | Out-Null
                $removed++
                Write-Log ('已删除: {0}' -f $key.Path) 'OK'
            } catch {
                $failed++
                Write-Log ('删除失败: {0} - {1}' -f $key.Path, $_.Exception.Message) 'ERROR'
            }
        }
    }
    if ($failed -gt 0 -and $removed -eq 0) {
        throw ('阶段二失败：{0} 个键均未删除（ViVeTool 已禁用时残留键通常可忽略，可重启后观察 QTTabBar）' -f $failed)
    }
    if ($failed -gt 0) {
        Write-Log ('阶段二部分完成：删除 {0} 个，失败 {1} 个' -f $removed, $failed) 'WARN'
    } else {
        Write-Log ('阶段二完成，共删除 {0} 个键' -f $removed) 'OK'
    }
    return ($failed -eq 0)
}
function Restart-ExplorerShell {
    Write-Log '正在重启 Windows 资源管理器...'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Process explorer.exe
    Write-Log '资源管理器已重启' 'OK'
}
function Invoke-QTTabBarVerification {
    param(
        [string]$ViVeExe,
        [bool]$ProbeExplorer = $true,
        $Status
    )
    $probed = $false
    $moduleLoaded = Test-QTTabBarModuleLoaded
    if (-not $moduleLoaded -and $ProbeExplorer -and -not $WhatIfPreference) {
        $moduleLoaded = Invoke-QTTabBarProbe
        $probed = $true
    }
    if (-not $Status) {
        $Status = Get-QTTabBarFixStatus -ViVeExe $ViVeExe
    }
    $health = Get-QTTabBarHealth -Status $Status -ModuleLoaded $moduleLoaded -ProbedExplorer $probed
    Show-HealthReport -Health $health
    Write-Log ('健康检测结论: {0} - {1}' -f $health.Overall, $health.Summary)
    return $health
}
function Show-PostFixGuide {
    param($Health)
    $ver = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $buildLabel = '{0}.{1}' -f $ver.CurrentBuild, $ver.UBR
    Write-Host ''
    Write-Host '========== 修复后操作指引 ==========' -ForegroundColor Cyan
    if ($Health.Overall -ne 'healthy') {
        Write-Host ('1. 建议重启电脑（当前 Build {0} 通常需要完整重启）' -f $buildLabel)
        Write-Host '2. 打开资源管理器 → 查看 → 选项 → 勾选 QTTabBar'
        Write-Host '3. 若标签栏空白：按 F11 两次 重置 UI'
        Write-Host '4. 可在菜单选 [6] 再次运行健康检测'
    } else {
        Write-Host '1. 若标签栏仍不可见，按 F11 两次 或重启电脑'
        Write-Host '2. 可在菜单选 [6] 再次运行健康检测'
        Write-Host ('3. 可选：运行 [7] 快速清理残留注册表键（当前 {0} 个，非必须）' -f $Health.RegistryLeftoverKeys)
    }
    Write-Host ('5. 日志: {0}' -f $Script:LogFile)
    Write-Host ('6. 备份: {0}' -f $Script:BackupDir)
    Write-Host '参考: https://github.com/indiff/qttabbar/issues/429'
}

function Invoke-QTTabBarFixCore {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateSet('1', '2', 'All')][string] $Phase = 'All',
        [switch] $QueryOnly,
        [switch] $VerifyOnly,
        [switch] $NoRestart,
        [switch] $SkipProbe,
        [switch] $SkipStatusReport,
        [string] $ViVeToolPath
    )

    if (-not (Test-IsAdministrator)) {
        Write-Host '请以管理员身份运行（双击 Run-QTTabBarFix.bat 或 启动修复工具.vbs）' -ForegroundColor Red
        throw '需要管理员权限'
    }
    New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
    New-Item -ItemType Directory -Path $Script:BackupDir -Force | Out-Null
    Write-Log 'QTTabBar 两阶段修复工具启动'
    $viveExe = Resolve-ViVeToolPath -ExplicitPath $ViVeToolPath
    Write-Log ('ViVeTool 路径: {0}' -f $viveExe)
    $status = Get-QTTabBarFixStatus -ViVeExe $viveExe
    $skipInitialStatus = $SkipStatusReport -or $VerifyOnly
    if (-not $skipInitialStatus) {
        Show-StatusReport -Status $status
    }

    if ($VerifyOnly) {
        Write-Log '仅健康检测模式' 'INFO'
        $null = Invoke-QTTabBarVerification -ViVeExe $viveExe -ProbeExplorer:(-not $SkipProbe) -Status $status
        return
    }

    if ($QueryOnly) {
        Write-Log '仅查询模式，退出' 'INFO'
        return
    }

    $didFix = $false
    if ($Phase -in @('1','All')) {
        $p1ok = Invoke-Phase1 -ViVeExe $viveExe
        if (-not $p1ok) { Write-Log '阶段一存在失败项，请检查上方日志' 'WARN' }
        $didFix = $true
    }
    if ($Phase -in @('2','All')) { Invoke-Phase2 | Out-Null; $didFix = $true }

    if ($didFix -and -not $NoRestart -and -not $WhatIfPreference) {
        $choice = Read-Host '是否现在重启资源管理器？(Y/n)'
        if ($choice -eq '' -or $choice -match '^[Yy]') { Restart-ExplorerShell }
    }

    Write-Log '修复流程结束' 'OK'
    if ($didFix) {
        $status = Get-QTTabBarFixStatus -ViVeExe $viveExe
    }
    if (-not $SkipStatusReport) {
        Show-StatusReport -Status $status
    }

    if ($didFix -and -not $WhatIfPreference) {
        Write-Host ''
        Write-Host '正在自动检测 QTTabBar 是否可用...' -ForegroundColor Cyan
        $health = Invoke-QTTabBarVerification -ViVeExe $viveExe -ProbeExplorer:(-not $SkipProbe) -Status $status
    } else {
        $health = Get-QTTabBarHealth -Status $status -ModuleLoaded:(Test-QTTabBarModuleLoaded) -ProbedExplorer:$false
    }

    Show-PostFixGuide -Health $health
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-QTTabBarFixCore @PSBoundParameters
    } catch {
        if ($_.Exception.Message -ne '需要管理员权限') {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }
        exit 1
    }
}
