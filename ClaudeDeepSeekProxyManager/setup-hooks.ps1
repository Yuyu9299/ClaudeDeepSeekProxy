# ============================================================
# setup-hooks.ps1 — 安装/卸载 Claude Code 代理自启 hooks
# 用法:
#   安装: .\setup-hooks.ps1
#   卸载: .\setup-hooks.ps1 -Uninstall
# 兼容 PowerShell 5.1+
# ============================================================
param(
    [switch]$Uninstall,

    [string]$SettingsPath = "$env:USERPROFILE\.claude\settings.json",
    [string]$CtlScriptPath = 'D:\MyAgent\ClaudeDeepSeekProxyManager\proxy-ctl.ps1'
)

$ErrorActionPreference = 'Stop'

# ============================================================
# 辅助函数：将 PSCustomObject 递归转换为 Hashtable
# ============================================================
function ConvertTo-Hashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject }
    if ($InputObject -is [Array]) {
        $result = @()
        foreach ($item in $InputObject) {
            $result += ConvertTo-Hashtable $item
        }
        return $result
    }
    if ($InputObject -is [PSCustomObject]) {
        $hash = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $hash[$prop.Name] = ConvertTo-Hashtable $prop.Value
        }
        return $hash
    }
    # 基本类型直接返回
    return $InputObject
}

# ============================================================
# 钩子命令（核心：powershell 调用 proxy-ctl.ps1）
# ============================================================

$startCmd      = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$CtlScriptPath`" -Action start"
$precompactCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$CtlScriptPath`" -Action precompact"
$stopCmd       = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$CtlScriptPath`" -Action stop"

$startHookEntry = @{
    hooks = @(
        @{
            type          = 'command'
            command       = $startCmd
            timeout       = 20
            shell         = 'powershell'
            statusMessage = 'Starting DeepSeek proxy...'
        }
    )
}

$stopHookEntry = @{
    hooks = @(
        @{
            type          = 'command'
            command       = $stopCmd
            timeout       = 10
            shell         = 'powershell'
            statusMessage = 'Stopping DeepSeek proxy...'
        }
    )
}

$precompactHookEntry = @{
    matcher = 'auto'
    hooks   = @(
        @{
            type          = 'command'
            command       = $precompactCmd
            timeout       = 5
            shell         = 'powershell'
            statusMessage = 'Protecting proxy during compaction...'
        }
    )
}

# ============================================================
# 安装
# ============================================================

function Install-Hooks {
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '  Claude DeepSeek Proxy Manager - Install' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ''

    # 验证控制脚本存在
    if (-not (Test-Path $CtlScriptPath)) {
        Write-Host "[ERROR] Control script not found: $CtlScriptPath" -ForegroundColor Red
        exit 1
    }
    Write-Host "[OK] Control script: $CtlScriptPath" -ForegroundColor Green

    # 读取现有配置
    $settings = @{}
    if (Test-Path $SettingsPath) {
        Write-Host "[OK] Existing settings: $SettingsPath" -ForegroundColor Green
        $raw = Get-Content $SettingsPath -Raw -Encoding UTF8
        if ($raw.Trim()) {
            $settings = ConvertTo-Hashtable ($raw | ConvertFrom-Json)
        }
    }
    else {
        Write-Host "[NEW] Creating settings: $SettingsPath" -ForegroundColor Yellow
    }

    # 确保 hooks 节点存在
    if (-not $settings.ContainsKey('hooks')) {
        $settings['hooks'] = @{}
    }

    $hooks = $settings['hooks']

    # 检查是否已安装
    if ($hooks.ContainsKey('SessionStart')) {
        Write-Host ''
        Write-Host '[WARN] Hook already installed, updating...' -ForegroundColor Yellow
    }

    # 只写 SessionStart（Stop 和 PreCompact 会导致误杀代理，已移除）
    $hooks['SessionStart'] = @($startHookEntry)

    # 清理可能残留的旧 hook
    foreach ($key in @('PreCompact', 'Stop')) {
        if ($hooks.ContainsKey($key)) {
            $hooks.Remove($key)
            Write-Host "[CLEAN] Removed legacy $key hook" -ForegroundColor Yellow
        }
    }

    $settings['hooks'] = $hooks

    # 保存
    $json = $settings | ConvertTo-Json -Depth 10
    $json | Set-Content $SettingsPath -Encoding UTF8 -Force

    Write-Host ''
    Write-Host '========================================' -ForegroundColor Green
    Write-Host '  Install Complete!' -ForegroundColor Green
    Write-Host '========================================' -ForegroundColor Green
    Write-Host ''
    Write-Host 'From now on, every time you start Claude Code:' -ForegroundColor White
    Write-Host '  -> Proxy auto-starts (hidden window)' -ForegroundColor Gray
    Write-Host '  -> Proxy keeps running after CC exits (safe)' -ForegroundColor Gray
    Write-Host ''
    Write-Host "Settings file: $SettingsPath" -ForegroundColor Gray
    Write-Host "To uninstall: .\setup-hooks.ps1 -Uninstall" -ForegroundColor Gray
}

# ============================================================
# 卸载
# ============================================================

function Uninstall-Hooks {
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '  Claude DeepSeek Proxy Manager - Uninstall' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-Path $SettingsPath)) {
        Write-Host 'No settings file found, nothing to uninstall' -ForegroundColor Yellow
        exit 0
    }

    $raw = Get-Content $SettingsPath -Raw -Encoding UTF8
    if (-not $raw.Trim()) {
        Write-Host 'Settings file is empty, nothing to uninstall' -ForegroundColor Yellow
        exit 0
    }

    $settings = ConvertTo-Hashtable ($raw | ConvertFrom-Json)

    if (-not $settings.ContainsKey('hooks')) {
        Write-Host 'No hooks in settings, nothing to uninstall' -ForegroundColor Yellow
        exit 0
    }

    $hooks = $settings['hooks']
    $removed = $false

    foreach ($key in @('SessionStart')) {
        if ($hooks.ContainsKey($key)) {
            $hooks.Remove($key)
            Write-Host "[OK] Removed $key hook" -ForegroundColor Green
            $removed = $true
        }
    }

    if (-not $removed) {
        Write-Host 'No DeepSeek proxy hooks found' -ForegroundColor Yellow
        exit 0
    }

    # 如果 hooks 为空，移除整个节点
    if ($hooks.Count -eq 0) {
        $settings.Remove('hooks')
    }

    # 保存
    $json = $settings | ConvertTo-Json -Depth 10
    $json | Set-Content $SettingsPath -Encoding UTF8 -Force

    Write-Host ''
    Write-Host '========================================' -ForegroundColor Green
    Write-Host '  Uninstall Complete!' -ForegroundColor Green
    Write-Host '========================================' -ForegroundColor Green
    Write-Host ''
    Write-Host "Settings cleaned: $SettingsPath" -ForegroundColor Gray
}

# ============================================================
# 入口
# ============================================================

if ($Uninstall) {
    Uninstall-Hooks
}
else {
    Install-Hooks
}
