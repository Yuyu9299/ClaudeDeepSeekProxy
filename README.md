# ClaudeDeepSeekProxy

> ⚠️ **临时解决方案**：这是一个社区自制的桥接工具，用于在官方适配之前让 Claude Code 与 DeepSeek API 正常通信。如果你不想折腾，可以选择等待 Claude Code 或 DeepSeek 官方的后续更新。喜欢动手的话，往下看 👇

让 [Claude Code](https://claude.ai/code) 通过 [DeepSeek API](https://platform.deepseek.com/) 的 Anthropic 兼容接口工作，附带自动启停管理器。

## 背景

Claude Code v2.1.156 + DeepSeek v4 Pro 无法直接对话，原因是：

- **DeepSeek 的 Anthropic 兼容 API 只接受第一条消息为 `system` 角色**
- Claude Code 会在对话中穿插 `<system-reminder>` 类型的 system 消息
- 直接请求会报错

## 项目结构

```
ClaudeDeepSeekProxy/           ← 代理服务（.NET 10 ASP.NET Core）
ClaudeDeepSeekProxyManager/    ← 自动启停管理器（PowerShell + Claude Code Hooks）
```

## 快速开始

### 1. 配置 Claude Code

在 Claude Code 设置中添加 DeepSeek API Key 和代理地址：

```
/claude config
```

选择 **Custom API Provider**，填入：
- API Base URL: `http://localhost:5000`
- API Key: 你的 DeepSeek API Key（`sk-...`）

### 2. 安装自动启停

```powershell
cd ClaudeDeepSeekProxyManager
.\setup-hooks.ps1
```

之后每次启动 Claude Code，代理会自动在后台运行（隐藏窗口），无需手动操作。

### 3. 卸载

```powershell
cd ClaudeDeepSeekProxyManager
.\setup-hooks.ps1 -Uninstall
```

然后删掉整个文件夹即可，无残留。

## 原理

### 代理做了什么

```
Claude Code → localhost:5000 → 清洗请求 → DeepSeek API
                                    ↓
              非首条 system → 强转为 user
              包裹 [System Note]: 前缀
```

关键代码（`Program.cs`）：

```csharp
for (int i = 1; i < messages.Count; i++)
{
    if (messages[i]?["role"]?.ToString() == "system")
    {
        messages[i]!["role"] = "user";
        messages[i]!["content"] = $"[System Note]: {oldContent}";
    }
}
```

### 自动启停原理

利用 Claude Code 的 `SessionStart` Hook：

```
启动 Claude Code → SessionStart Hook 触发
→ 健康检查 http://localhost:5000/health
→ 已存活：跳过
→ 未存活：隐藏窗口启动代理 → 等待就绪
```

## 依赖

- Windows + PowerShell 5.1+
- .NET SDK 10.0
- Claude Code v2.x
- DeepSeek API Key

## License

MIT
