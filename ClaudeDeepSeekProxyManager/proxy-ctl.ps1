# ============================================================
# proxy-ctl.ps1 — Claude DeepSeek 代理生命周期控制脚本
# 由 Claude Code hooks 自动调用（SessionStart → start, Stop → stop）
# ============================================================
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('start', 'stop', 'precompact')]
    [string]$Action,

    [string]$ProxyDir = 'D:\MyAgent\ClaudeDeepSeekProxy',
    [string]$HealthUrl = 'http://localhost:5000/health',
    [int]$StartTimeoutSec = 15
)

$ErrorActionPreference = 'Continue'

# 文件路径
$pidFile        = "$env:TEMP\claude-deepseek-proxy.pid"
$refCountFile   = "$env:TEMP\claude-deepseek-proxy.refcount"
$compactingFile = "$env:TEMP\claude-deepseek-proxy.compacting"
$mutexName      = 'Local\ClaudeDeepSeekProxyRefCount'

# ============================================================
# 工具函数
# ============================================================

function Test-ProxyAlive {
    try {
        $response = Invoke-WebRequest -Uri $HealthUrl -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        return $response.StatusCode -eq 200
    }
    catch {
        return $false
    }
}

# 原子操作：读取/写入引用计数（互斥锁保护）
function Update-RefCount {
    param([int]$Delta)  # +1 或 -1

    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, $mutexName)
        $mutex.WaitOne(5000) | Out-Null

        $count = 0
        if (Test-Path $refCountFile) {
            [int]$count = (Get-Content $refCountFile -Raw).Trim()
            if (-not $count) { $count = 0 }
        }

        $count += $Delta
        if ($count -lt 0) { $count = 0 }

        if ($count -eq 0) {
            Remove-Item $refCountFile -Force -ErrorAction SilentlyContinue
        }
        else {
            $count.ToString() | Out-File -FilePath $refCountFile -NoNewline -Force
        }

        return $count
    }
    finally {
        if ($mutex) {
            $mutex.ReleaseMutex()
            $mutex.Dispose()
        }
    }
}

# ============================================================
# PreCompact 模式（压缩前设置保护旗标，防止 Stop 误杀）
# ============================================================

function Start-PreCompact {
    # 写入压缩保护旗标（含时间戳，用于 TTL 过期检测）
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString()
    "$timestamp" | Out-File -FilePath $compactingFile -NoNewline -Force
}

# ============================================================
# Start 模式
# ============================================================

function Start-Proxy {
    # 1. 原子递增引用计数
    $refCount = Update-RefCount -Delta 1

    # 2. 幂等：代理已存活则直接返回
    if (Test-ProxyAlive) {
        return
    }

    # 3. 清理僵尸 PID 文件
    if (Test-Path $pidFile) {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }

    # 4. 以隐藏窗口启动代理
    $process = Start-Process -FilePath 'dotnet' `
        -ArgumentList 'run --no-launch-profile -- --silent' `
        -WorkingDirectory $ProxyDir `
        -WindowStyle Hidden `
        -PassThru

    # 5. 保存 PID 供 stop 时使用
    $process.Id | Out-File -FilePath $pidFile -NoNewline -Force

    # 6. 轮询等待代理就绪
    $elapsed = 0
    $pollInterval = 0.5
    while ($elapsed -lt $StartTimeoutSec) {
        if (Test-ProxyAlive) {
            return
        }
        Start-Sleep -Seconds $pollInterval
        $elapsed += $pollInterval
    }

    # 超时但进程仍在运行，继续（不阻塞 CC 启动）
}

# ============================================================
# Stop 模式
# ============================================================

function Stop-Proxy {
    # 1. 检查压缩保护旗标
    $isCompacting = $false
    if (Test-Path $compactingFile) {
        try {
            $rawStamp = (Get-Content $compactingFile -Raw).Trim()
            $flagTime = [long]$rawStamp
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            # 旗标在 60 秒内有效，超时视为僵尸旗标
            if (($now - $flagTime) -lt 60) {
                $isCompacting = $true
            }
        }
        catch { }
        Remove-Item $compactingFile -Force -ErrorAction SilentlyContinue
    }

    # 2. 压缩场景：只减引用计数，不杀代理
    if ($isCompacting) {
        Update-RefCount -Delta (-1) | Out-Null
        return
    }

    # 3. 正常退出：引用计数归零则关闭代理
    $refCount = Update-RefCount -Delta (-1)

    if ($refCount -gt 0) {
        return
    }

    # 4. 引用计数归零 → 关闭代理
    $killed = $false

    # 方法1: 通过 PID 文件
    if (Test-Path $pidFile) {
        $savedPid = (Get-Content $pidFile -Raw).Trim()
        try {
            $proc = Get-Process -Id ([int]$savedPid) -ErrorAction SilentlyContinue
            if ($proc) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                $killed = $true
            }
        }
        catch { }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }

    # 方法2: 通过端口（兜底）
    if (-not $killed) {
        $portResult = netstat -ano 2>$null | Select-String ':5000\s+.*LISTENING'
        if ($portResult) {
            $line = $portResult -replace '\s+', ' ' -split ' '
            $portPid = $line[-1]
            try {
                Stop-Process -Id ([int]$portPid) -Force -ErrorAction SilentlyContinue
                $killed = $true
            }
            catch { }
        }
    }
}

# ============================================================
# 入口
# ============================================================

try {
    switch ($Action) {
        'start'      { Start-Proxy }
        'stop'       { Stop-Proxy }
        'precompact' { Start-PreCompact }
    }
}
catch {
    # 静默失败，不阻塞 CC 正常启停
    exit 0
}
