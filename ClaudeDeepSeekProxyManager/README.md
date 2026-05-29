# Claude DeepSeek Proxy Manager

> 让 DeepSeek 代理随 Claude Code 自动启停，零感知。

## 这玩意儿是干啥的

每次启动 Claude Code 时，自动在后台拉起 DeepSeek 代理；关掉最后一个 CC 窗口时，自动把代理也关了。不用手动 `dotnet run` 了。

## 怎么装的（复习）

就一句话：

```powershell
.\setup-hooks.ps1
```

它往 `C:\Users\你的用户名\.claude\settings.json` 里加了两个 hook：`SessionStart`（启动代理）和 `Stop`（关闭代理）。原来的配置不动。

---

## 怎么卸载（详细版，给以后的自己看）

如果你忘了当时都干了什么，按下面的做就行，每一步都可以复制粘贴。

### 第 1 步：打开 PowerShell

`Win + R` → 输入 `powershell` → 回车

### 第 2 步：进入管理器目录

```powershell
cd D:\MyAgent\ClaudeDeepSeekProxyManager
```

### 第 3 步：运行卸载脚本

```powershell
.\setup-hooks.ps1 -Uninstall
```

这会把 `settings.json` 里我们加的那两个 hook（`SessionStart` 和 `Stop`）删掉。你原来的其他配置（比如 `theme`）不受影响。

看到 `Uninstall Complete!` 就说明清理完了。

### 第 4 步：删掉两个文件夹

```powershell
# 先回到上级目录
cd D:\MyAgent

# 删管理器（就是你现在看的这个文件夹）
Remove-Item -Recurse -Force ClaudeDeepSeekProxyManager

# 删代理本身（如果官方已经适配了 DeepSeek，不再需要的话）
Remove-Item -Recurse -Force ClaudeDeepSeekProxy
```

### 第 5 步（可选）：确认 settings.json 没事

```powershell
code $env:USERPROFILE\.claude\settings.json
```

或者用记事本打开：

```powershell
notepad $env:USERPROFILE\.claude\settings.json
```

看一眼，里面应该已经没有 `SessionStart` 和 `Stop` 了，只有你原来的配置（比如 `"theme": "dark"`）。

---

## 卸载后残留了什么

| 残留 | 在哪 | 要不要管 |
|---|---|---|
| `settings.json` 里的 hook 配置 | `~\.claude\settings.json` | 第 3 步已清理 |
| 管理器脚本 | `D:\MyAgent\ClaudeDeepSeekProxyManager\` | 第 4 步已删除 |
| 代理项目 | `D:\MyAgent\ClaudeDeepSeekProxy\` | 第 4 步已删除 |
| 临时 PID 文件 | `%TEMP%\claude-deepseek-proxy.pid` | 下次重启自动清，不管也行 |
| 临时引用计数文件 | `%TEMP%\claude-deepseek-proxy.refcount` | 同上 |

**没有注册表、没有 Windows 服务、没有开机启动项、没有环境变量。** 纯粹的文件层面改动。

---

## 文件说明

| 文件 | 作用 |
|---|---|
| `proxy-ctl.ps1` | 核心控制脚本——启动/停止代理，引用计数管理，多窗口保护 |
| `setup-hooks.ps1` | 安装/卸载工具——往 settings.json 里写入或移除 hooks |
| `README.md` | 你现在看的这个 |

## 工作原理

```
┌─────────────────────────────────────────────┐
│  SessionStart Hook（CC 启动时触发）           │
│  ├── 引用计数 +1                             │
│  ├── 健康检查 http://localhost:5000/health   │
│  ├── 已存活 → 跳过                           │
│  └── 未存活 → 隐藏窗口启动 dotnet run         │
├─────────────────────────────────────────────┤
│  Stop Hook（CC 停止时触发）                    │
│  ├── 引用计数 -1                             │
│  ├── 计数 > 0 → 还有其他 CC 窗口，保留代理     │
│  └── 计数 = 0 → 最后一个窗口，关闭代理         │
└─────────────────────────────────────────────┘
```

**多窗口安全**：用 Windows 互斥锁（Mutex）+ 引用计数文件，精确追踪有几个 CC 实例在跑。关掉一个窗口不会影响另一个。

## 依赖

- Windows PowerShell 5.1+
- .NET SDK（`dotnet run`）
- Claude Code v2.x
