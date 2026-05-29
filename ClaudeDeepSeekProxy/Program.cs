using System.Text;
using System.Text.Json.Nodes;
using System.Net.Http.Headers;

var builder = WebApplication.CreateBuilder(args);

// ========== 静默模式 ==========
var isSilent = args.Contains("--silent") || Environment.GetEnvironmentVariable("PROXY_SILENT") == "1";
var log = isSilent ? TextWriter.Null : Console.Out;

// 从配置文件或环境变量读取上游地址
var upstreamUrl = builder.Configuration.GetValue<string>("UpstreamUrl")
                  ?? Environment.GetEnvironmentVariable("PROXY_UPSTREAM_URL")
                  ?? "https://api.deepseek.com/anthropic/v1/messages";

builder.Services.AddHttpClient("deepseek", client =>
{
    client.Timeout = TimeSpan.FromMinutes(10);
});

var app = builder.Build();

// 启动横幅（静默模式也打一行，总得知道起没起）
app.Lifetime.ApplicationStarted.Register(() =>
{
    log.WriteLine($"Claude ↔ DeepSeek 代理已启动 | 上游: {upstreamUrl} | 模式: {(isSilent ? "静默" : "详细")}");
});

// 健康检查
app.MapGet("/health", () => Results.Ok(new { status = "ok", timestamp = DateTime.UtcNow }));

// 核心代理
app.MapPost("{*path}", async (string path, HttpContext context, IHttpClientFactory httpFactory) =>
{
    log.WriteLine($"📥 请求 | 路径: /{path}");
    try
    {
        using var reader = new StreamReader(context.Request.Body);
        var body = await reader.ReadToEndAsync();

        if (string.IsNullOrWhiteSpace(body))
        {
            context.Response.StatusCode = 400;
            await context.Response.WriteAsync("{\"error\": \"请求体为空\"}");
            return;
        }

        var json = JsonNode.Parse(body);
        if (json == null)
        {
            context.Response.StatusCode = 400;
            await context.Response.WriteAsync("{\"error\": \"JSON 解析失败\"}");
            return;
        }

        // 核心清洗：将非首位 system 角色强转为 user
        var messages = json["messages"]?.AsArray();
        int modifiedCount = 0;
        if (messages != null)
        {
            for (int i = 1; i < messages.Count; i++)
            {
                if (messages[i]?["role"]?.ToString() == "system")
                {
                    var oldContent = messages[i]?["content"]?.ToString() ?? "";
                    messages[i]!["role"] = "user";
                    messages[i]!["content"] = $"[System Note]: {oldContent}";
                    modifiedCount++;
                }
            }
        }
        if (modifiedCount > 0)
            log.WriteLine($"⚡ 清洗了 {modifiedCount} 个 system 角色");

        var forwardReq = new HttpRequestMessage(HttpMethod.Post, upstreamUrl);

        foreach (var header in context.Request.Headers)
        {
            var key = header.Key.ToLower();
            if (key is "host" or "content-length" or "content-type" or "accept-encoding")
                continue;
            forwardReq.Headers.TryAddWithoutValidation(header.Key, header.Value.ToArray());
        }

        var stringContent = new StringContent(json.ToJsonString(), Encoding.UTF8);
        stringContent.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        forwardReq.Content = stringContent;

        using var httpClient = httpFactory.CreateClient("deepseek");
        var response = await httpClient.SendAsync(forwardReq, HttpCompletionOption.ResponseHeadersRead);

        log.WriteLine($"↩️ {(int)response.StatusCode} ({response.StatusCode})");

        context.Response.StatusCode = (int)response.StatusCode;

        foreach (var header in response.Headers)
        {
            if (header.Key.ToLower() == "transfer-encoding") continue;
            context.Response.Headers[header.Key] = header.Value.ToArray();
        }
        foreach (var header in response.Content.Headers)
        {
            context.Response.Headers[header.Key] = header.Value.ToArray();
        }

        context.Response.Headers["Cache-Control"] = "no-cache";
        context.Response.Headers["X-Accel-Buffering"] = "no";

        await response.Content.CopyToAsync(context.Response.Body);
    }
    catch (Exception ex)
    {
        log.WriteLine($"❌ {ex.Message}");
        context.Response.StatusCode = 500;
        await context.Response.WriteAsync($"{{\"error\": \"{ex.Message}\"}}");
    }
});

app.Run("http://localhost:5000");