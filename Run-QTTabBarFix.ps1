#Requires -Version 5.1
param([string]$AutoChoice)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LauncherRoot = $PSScriptRoot
Set-Location -LiteralPath $LauncherRoot
$WorkerScript = Join-Path $LauncherRoot 'Fix-QTTabBar.ps1'
$Script:WorkerScriptHash = $null

function Get-WorkerScriptHash {
    if (-not (Test-Path -LiteralPath $WorkerScript)) { return $null }
    return (Get-FileHash -LiteralPath $WorkerScript -Algorithm SHA256).Hash
}
function Test-WorkerCoreLoaded {
    return $null -ne (Get-Command Invoke-QTTabBarFixCore -ErrorAction SilentlyContinue)
}
function Test-IsAdministrator {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Request-Administrator {
    if (Test-IsAdministrator) { return }
    Write-Host ''
    Write-Host '需要管理员权限。' -ForegroundColor Yellow
    Write-Host '请在 UAC 提示中点击「是」，随后会在新窗口中打开菜单。' -ForegroundColor Yellow
    Write-Host ''
    $argList = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', $PSCommandPath
    )
    if ($AutoChoice) {
        $argList += '-AutoChoice'
        $argList += $AutoChoice
    }
    $proc = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -WorkingDirectory $LauncherRoot -PassThru -Wait
    exit $(if ($null -ne $proc.ExitCode) { [int]$proc.ExitCode } else { 0 })
}
function Show-Menu {
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '  QTTabBar 两阶段全面修复工具' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  [1] 完整修复（阶段一 + 阶段二）推荐'
    Write-Host '  [2] 仅阶段一（ViVeTool 禁用功能包）'
    Write-Host '  [3] 仅阶段二（清理冲突注册表键）'
    Write-Host '  [4] 仅查询当前状态'
    Write-Host '  [5] 模拟运行（不实际修改）'
    Write-Host '  [6] 健康检测（检测 QTTabBar 是否可用）'
    Write-Host '  [7] 快速清理残留注册表键（不重启资源管理器）'
    Write-Host '  [0] 退出'
    Write-Host ''
}
function ConvertTo-WorkerParams {
    param([string[]]$WorkerArgs)
    $result = @{
        Phase = 'All'
        QueryOnly = $false
        VerifyOnly = $false
        NoRestart = $false
        SkipProbe = $false
        SkipStatusReport = $false
        WhatIf = $false
        ViVeToolPath = $null
    }
    for ($i = 0; $i -lt $WorkerArgs.Count; $i++) {
        switch ($WorkerArgs[$i]) {
            '-Phase' { $result.Phase = $WorkerArgs[++$i]; break }
            '-QueryOnly' { $result.QueryOnly = $true; break }
            '-VerifyOnly' { $result.VerifyOnly = $true; break }
            '-NoRestart' { $result.NoRestart = $true; break }
            '-SkipProbe' { $result.SkipProbe = $true; break }
            '-SkipStatusReport' { $result.SkipStatusReport = $true; break }
            '-WhatIf' { $result.WhatIf = $true; break }
            '-ViVeToolPath' { $result.ViVeToolPath = $WorkerArgs[++$i]; break }
        }
    }
    return $result
}
function Invoke-Worker {
    param([string[]]$WorkerArgs)
    if (-not (Test-WorkerCoreLoaded)) {
        throw '修复核心未加载，请重新启动修复工具。'
    }
    $parsed = ConvertTo-WorkerParams -WorkerArgs $WorkerArgs
    $splat = @{
        Phase = [string]$parsed.Phase
        QueryOnly = [bool]$parsed.QueryOnly
        VerifyOnly = [bool]$parsed.VerifyOnly
        NoRestart = [bool]$parsed.NoRestart
        SkipProbe = [bool]$parsed.SkipProbe
        SkipStatusReport = [bool]$parsed.SkipStatusReport
    }
    if ($parsed.ViVeToolPath) { $splat.ViVeToolPath = [string]$parsed.ViVeToolPath }
    if ($parsed.WhatIf) {
        Invoke-QTTabBarFixCore @splat -WhatIf
    } else {
        Invoke-QTTabBarFixCore @splat
    }
}
function Invoke-MenuChoice {
    param([string]$Choice)
    switch ($Choice) {
        '1' { Invoke-Worker -WorkerArgs @('-Phase', 'All') }
        '2' { Invoke-Worker -WorkerArgs @('-Phase', '1') }
        '3' { Invoke-Worker -WorkerArgs @('-Phase', '2') }
        '4' { Invoke-Worker -WorkerArgs @('-QueryOnly') }
        '5' { Invoke-Worker -WorkerArgs @('-Phase', 'All', '-WhatIf') }
        '6' { Invoke-Worker -WorkerArgs @('-VerifyOnly', '-SkipProbe') }
        '7' { Invoke-Worker -WorkerArgs @('-Phase', '2', '-NoRestart', '-SkipStatusReport', '-SkipProbe') }
        '0' { return $false }
        default {
            Write-Host '无效选项，请重新输入。' -ForegroundColor Yellow
        }
    }
    return $true
}
function Wait-ReturnToMenu {
    Write-Host ''
    Read-Host '按 Enter 键返回菜单'
}

trap {
    Write-Host ''
    Write-Host ('发生错误: {0}' -f $_.Exception.Message) -ForegroundColor Red
    if ($AutoChoice) { exit 1 }
    Wait-ReturnToMenu
    continue
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

Request-Administrator

if (-not (Test-Path -LiteralPath $WorkerScript)) {
    Write-Host '错误: 未找到 Fix-QTTabBar.ps1' -ForegroundColor Red
    Read-Host '按 Enter 键退出'
    exit 1
}

# 必须在脚本顶层 dot-source，函数内 dot-source 会导致菜单找不到 Invoke-QTTabBarFixCore
. $WorkerScript
if (-not (Test-WorkerCoreLoaded)) {
    Write-Host '错误: Fix-QTTabBar.ps1 未正确加载 Invoke-QTTabBarFixCore' -ForegroundColor Red
    Read-Host '按 Enter 键退出'
    exit 1
}
$Script:WorkerScriptHash = Get-WorkerScriptHash

if ($AutoChoice) {
    try {
        if ($AutoChoice -ne '0') { [void](Invoke-MenuChoice -Choice $AutoChoice) }
    } catch {
        Write-Host ('执行失败: {0}' -f $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
    exit 0
}

do {
    $currentHash = Get-WorkerScriptHash
    if ($Script:WorkerScriptHash -ne $currentHash) {
        . $WorkerScript
        if (-not (Test-WorkerCoreLoaded)) {
            Write-Host '加载失败: Fix-QTTabBar.ps1 未正确加载' -ForegroundColor Red
            Wait-ReturnToMenu
            continue
        }
        $Script:WorkerScriptHash = $currentHash
    }
    Show-Menu
    $choice = Read-Host '请选择 [0-7]'
    if ($choice -eq '0') { break }
    try {
        [void](Invoke-MenuChoice -Choice $choice)
    } catch {
        Write-Host ('执行失败: {0}' -f $_.Exception.Message) -ForegroundColor Red
    }
    Wait-ReturnToMenu
} while ($true)

Write-Host ''
Write-Host '已退出。' -ForegroundColor Green
exit 0
