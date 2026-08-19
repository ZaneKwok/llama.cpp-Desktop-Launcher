#requires -version 5.1
<#
  ============================================================
  llama.cpp 启动客户端（Windows 桌面版）
  ============================================================
  功能：
    1. 选取 llama.cpp 目录（自动检测 llama-server.exe）
    2. 选取模型目录 / mmproj 目录（自动列出 .gguf 文件）
    3. 设置 llama-server 常用启动参数 + 附加参数
    4. 实时生成最终启动命令 → 用户确认后启动 llama-server，
       可查看启动命令与实时日志，可随时停止
    5. 自动使用 llama.cpp 自带的 webui（--path 托管）：
       - 优先使用 <llama.cpp目录>/webui（官方自带）
       - 否则使用客户端内置的 webui（webui\index.html）
       服务就绪后自动在默认浏览器中打开

  运行方式：双击 启动客户端.bat
  命令行参数：
    -SelfTest  运行无界面自检（用于验证安装与核心逻辑）
    -AutoStart 界面加载后自动启动（供自动化测试）
    -LlamaDir / -Model / -Mmproj / -Port 自检或自动启动时指定路径
  ============================================================
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$AutoStart,
    [string]$LlamaDir = '',
    [string]$Model    = '',
    [string]$Mmproj   = '',
    [int]$Port        = 18100,
    [string]$AppDirOverride = ''   # 打包为 exe 时由启动器传入 exe 所在目录
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
[System.Windows.Forms.Application]::EnableVisualStyles()

# ------------------------------------------------------------
# 脚本级状态
# ------------------------------------------------------------
$script:AppDir        = if ($AppDirOverride) { $AppDirOverride } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script:ConfigPath    = Join-Path $script:AppDir 'config.json'
$script:LogDir        = Join-Path $script:AppDir 'logs'
$script:OutLogPath    = Join-Path $script:LogDir 'server-out.log'
$script:ErrLogPath    = Join-Path $script:LogDir 'server-err.log'

$script:logOffsets    = @{}
$script:serverProc    = $null
$script:state         = 'idle'        # idle | starting | ready | stopping
$script:healthTimer   = $null
$script:logTimer      = $null
$script:healthAttempts = 0
$script:healthHost    = '127.0.0.1'
$script:portNow       = 8080
$script:lastCommand   = ''
$script:argError      = ''
$script:autoOpenedWebui = $false
$script:startedAt     = $null
$script:testFail      = $false

# WebView2 内嵌 / 客户端日志
$script:ClientLogPath = Join-Path $script:LogDir 'client.log'
$script:wvLibDir      = Join-Path $script:AppDir 'lib'
$script:wvUserData    = Join-Path $script:wvLibDir 'wv2data'
$script:wvReady       = $false
$script:wvEnv         = $null
$script:wvController  = $null
$script:wvCore        = $null
$script:wvInitTimer   = $null
$script:tabs          = $null

# ------------------------------------------------------------
# 基础工具函数
# ------------------------------------------------------------
function ConvertTo-CommandLine {
    param([string[]]$Items)
    # 按 CommandLineToArgvW 规则拼接命令行：含空格/引号的参数加双引号，内部引号转义
    $sb = New-Object System.Text.StringBuilder
    foreach ($it in $Items) {
        if ($sb.Length -gt 0) { [void]$sb.Append(' ') }
        $s = [string]$it
        if ($s -match '[\s"]') {
            $esc = $s -replace '"', '\"'
            [void]$sb.Append('"').Append($esc).Append('"')
        } else {
            [void]$sb.Append($s)
        }
    }
    return $sb.ToString()
}

function Split-ArgsText {
    param([string]$Text)
    # 把附加参数字符串拆成数组，支持双引号包裹带空格的参数
    $result = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Text)) { return ,@($result.ToArray()) }
    $i = 0
    while ($i -lt $Text.Length) {
        while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
        if ($i -ge $Text.Length) { break }
        $cur = New-Object System.Text.StringBuilder
        $inQuote = $false
        while ($i -lt $Text.Length) {
            $ch = $Text[$i]
            if ($ch -eq '"') { $inQuote = -not $inQuote; $i++; continue }
            if ($ch -eq ' ' -or $ch -eq "`t") {
                if ($inQuote) { [void]$cur.Append($ch); $i++ } else { break }
            } else {
                [void]$cur.Append($ch); $i++
            }
        }
        $result.Add($cur.ToString()) | Out-Null
    }
    return ,@($result.ToArray())
}

function Find-LlamaServerExe {
    param([string]$LlamaDir)
    if (-not $LlamaDir) { return $null }
    foreach ($cand in @((Join-Path $LlamaDir 'llama-server.exe'), (Join-Path $LlamaDir 'bin\llama-server.exe'))) {
        if (Test-Path $cand -PathType Leaf) { return $cand }
    }
    return $null
}

function Resolve-SelectedFile {
    param([string]$Path)
    # 校验用户选择的文件路径存在，返回绝对路径；空返回 $null
    $p = ($Path -as [string]).Trim()
    if (-not $p) { return $null }
    if (Test-Path $p -PathType Leaf) { return [System.IO.Path]::GetFullPath($p) }
    return $null
}

function Get-ArgsFromSettings {
    param($s)
    $items = New-Object System.Collections.Generic.List[string]
    if ($s.model)  { $items.Add('-m');        $items.Add($s.model) }
    if ($s.mmproj) { $items.Add('--mmproj');  $items.Add($s.mmproj) }
    if ($s.host)   { $items.Add('--host');    $items.Add($s.host) }
    if ($s.port)   { $items.Add('--port');    $items.Add($s.port) }
    if ($s.ctx)    { $items.Add('-c');        $items.Add($s.ctx) }
    if ($s.threads){ $items.Add('-t');        $items.Add($s.threads) }
    if ($s.gpu)    { $items.Add('-ngl');      $items.Add($s.gpu) }
    if ($s.temp)   { $items.Add('--temp');    $items.Add($s.temp) }
    if ($s.mlock)  { $items.Add('--mlock') }
    if ($s.noMmap) { $items.Add('--no-mmap') }
    if ($s.extra)  { foreach ($t in (Split-ArgsText $s.extra)) { $items.Add($t) } }
    return $items
}

# ------------------------------------------------------------
# 服务生命周期（与界面无关，自检复用）
# ------------------------------------------------------------
function Start-LlamaServerProcess {
    param($s, [string]$OutFile, [string]$ErrFile, [ref]$ProcRef)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
    Remove-Item $OutFile, $ErrFile -Force -ErrorAction SilentlyContinue
    $items  = Get-ArgsFromSettings $s
    $argStr = ConvertTo-CommandLine $items
    $exe    = Find-LlamaServerExe $s.llamaDir
    if (-not $exe) { throw "未找到 llama-server.exe：$($s.llamaDir)" }
    $proc = Start-Process -FilePath $exe -ArgumentList $argStr `
                          -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile `
                          -WindowStyle Hidden -PassThru
    $ProcRef.Value = $proc
    return @{ Proc = $proc; Command = "$exe $argStr"; Args = $items }
}

function Wait-ServerHealthy {
    param([string]$HostAddr, [int]$Port, [int]$TimeoutSec = 240)
    $url = "http://$($HostAddr):$($Port)/health"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $h = Invoke-RestMethod -Uri $url -TimeoutSec 2
            if ($h.status -eq 'ok') { return $true }
        } catch { }
        Start-Sleep -Milliseconds 800
    }
    return $false
}

function Stop-LlamaServerProcess {
    param($Proc)
    if (-not $Proc) { return }
    # 先尝试 taskkill 杀进程树（cmd /c 静默，避免 PS 5.1 下原生 stderr 触发终止错误）
    cmd /c "taskkill /PID $($Proc.Id) /T /F >nul 2>&1"
    Start-Sleep -Milliseconds 600
    try { $Proc.Refresh() } catch { }
    if (-not $Proc.HasExited) {
        # 兜底：Stop-Process（部分受限环境 taskkill 无权限时有效）
        try { Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        try { $Proc.WaitForExit(8000) | Out-Null } catch { }
    }
}

# ------------------------------------------------------------
# 客户端日志 & WebView2 内嵌（在窗口内渲染 WebUI）
# ------------------------------------------------------------
function Write-ClientLog {
    param([string]$Text)
    try {
        New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
        $line = ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text)
        Add-Content -Path $script:ClientLogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

function Wait-Task {
    # 在 UI 线程上等待异步 Task 完成（边等边泵消息，避免死锁）
    param([System.Threading.Tasks.Task]$Task, [int]$TimeoutMs = 45000)
    $deadline = [Environment]::TickCount + $TimeoutMs
    while (-not $Task.IsCompleted) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 15
        if ([Environment]::TickCount -gt $deadline) { return $false }
    }
    return $true
}

function Test-WebView2Lib {
    $core = Join-Path $script:wvLibDir 'Microsoft.Web.WebView2.Core.dll'
    $ldr  = Join-Path $script:wvLibDir 'WebView2Loader.dll'
    return ((Test-Path $core) -and (Test-Path $ldr))
}

function Init-WebView2 {
    # 加载 WebView2 托管组件并设置 DPI（幂等），返回 $true/$false
    if ($script:wvReady) { return $true }
    if (-not (Test-WebView2Lib)) {
        Write-ClientLog 'WebView2 组件缺失（lib\Microsoft.Web.WebView2.Core.dll 或 WebView2Loader.dll）'
        return $false
    }
    try {
        if (-not ('Microsoft.Web.WebView2.Core.CoreWebView2Environment' -as [type])) {
            $env:PATH = "$($script:wvLibDir);$env:PATH"
            Add-Type -Path (Join-Path $script:wvLibDir 'Microsoft.Web.WebView2.Core.dll')
        }
        try {
            if (-not ('DpiUtil' -as [type])) {
                Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class DpiUtil { [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v); }'
            }
            [DpiUtil]::SetProcessDpiAwareness(2) | Out-Null
        } catch { }
        $script:wvReady = $true
        Write-ClientLog 'WebView2 组件加载成功'
        return $true
    } catch {
        Write-ClientLog ('WebView2 组件加载失败: ' + $_.Exception.Message)
        return $false
    }
}

function New-WebView2Controller {
    # 在指定窗口句柄上创建 WebView2 控制器（失败抛异常）
    param([IntPtr]$Hwnd, [string]$UserDataDir)
    $t = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($null, $UserDataDir, $null)
    [void](Wait-Task $t)
    if ($t.IsFaulted) { throw ('创建 WebView2 环境失败: ' + $t.Exception.GetBaseException().Message) }
    $env = $t.GetAwaiter().GetResult()
    $script:wvEnv = $env
    $t2 = $env.CreateCoreWebView2ControllerAsync($Hwnd)
    [void](Wait-Task $t2)
    if ($t2.IsFaulted) { throw ('创建 WebView2 控制器失败: ' + $t2.Exception.GetBaseException().Message) }
    return $t2.GetAwaiter().GetResult()
}

function Close-WebView2Controller {
    if ($script:wvController) {
        try { $script:wvController.Close() } catch { }
        try { $script:wvController.Dispose() } catch { }
        $script:wvController = $null
        $script:wvCore = $null
        $script:wvEnv = $null
    }
}

# ------------------------------------------------------------
# 配置持久化
# ------------------------------------------------------------
function Get-ConfigDefaults {
    return @{
        llamaDir = ''; modelFile = ''; mmprojFile = ''
        host = '127.0.0.1'; port = '8080'; ctx = '8192'; threads = ''; gpu = ''; temp = '0.8'
        extra = ''; autoOpen = $true; mlock = $false; noMmap = $false
    }
}

function Load-Config {
    if (Test-Path $script:ConfigPath) {
        try {
            $cfg = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            return $cfg
        } catch { }
    }
    return Get-ConfigDefaults
}

function Save-Config {
    try {
        $cfg = @{
            llamaDir   = $script:txtLlamaDir.Text.Trim()
            modelFile  = $script:txtModelFile.Text.Trim()
            mmprojFile = $script:txtMmprojFile.Text.Trim()
            host       = $script:txtHost.Text.Trim()
            port       = $script:txtPort.Text.Trim()
            ctx        = $script:txtCtx.Text.Trim()
            threads    = $script:txtThreads.Text.Trim()
            gpu        = $script:txtGpu.Text.Trim()
            temp       = $script:txtTemp.Text.Trim()
            extra      = $script:txtExtra.Text
            autoOpen   = [bool]$script:chkAutoOpen.Checked
            mlock      = [bool]$script:chkMlock.Checked
            noMmap     = [bool]$script:chkNoMmap.Checked
        }
        $cfg | ConvertTo-Json -Depth 3 | Set-Content -Path $script:ConfigPath -Encoding UTF8
    } catch { }
}

# ------------------------------------------------------------
# 自检模式（无界面，供验证）
# ------------------------------------------------------------
function Write-Test {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $mark = if ($Ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1}  {2}" -f $mark, $Name, $Detail)
    if (-not $Ok) { $script:testFail = $true }
}

function Test-Phase {
    param([string]$Name, [hashtable]$s, [string]$OutFile, [string]$ErrFile, [int]$TimeoutSec = 240)
    Write-Host ("--- {0} ---" -f $Name)
    $procRef = $null
    try {
        $r = Start-LlamaServerProcess -s $s -OutFile $OutFile -ErrFile $ErrFile -ProcRef ([ref]$procRef)
        Write-Host ("    命令: " + $r.Command)
        Write-Test "启动 llama-server (PID=$($r.Proc.Id))" $true
        $ok = Wait-ServerHealthy -HostAddr $s.healthHost -Port ([int]$s.port) -TimeoutSec $TimeoutSec
        Write-Test "服务健康检查 /health" $ok ("http://$($s.healthHost):$($s.port)/health")
        if (-not $ok) {
            Write-Host "    ---- 错误日志尾部 ----"
            if (Test-Path $ErrFile) { Get-Content $ErrFile -Tail 20 -Encoding UTF8 | ForEach-Object { Write-Host ("    " + $_) } }
            return $r
        }
        # WebUI 探测（HttpClient 自动解压 gzip：llama-server 内置 WebUI 要求客户端支持 gzip）
        try {
            $handler = New-Object System.Net.Http.HttpClientHandler
            $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
            $client = New-Object System.Net.Http.HttpClient($handler)
            $client.Timeout = [TimeSpan]::FromSeconds(10)
            $resp2 = $client.GetAsync("http://$($s.healthHost):$($s.port)/").GetAwaiter().GetResult()
            $body2 = $resp2.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $ok2 = ([int]$resp2.StatusCode -eq 200) -and ($body2 -match 'html') -and ($body2.Length -gt 200)
            Write-Test "WebUI 托管 (/)" $ok2 ("HTTP " + [int]$resp2.StatusCode + ", len=" + $body2.Length)
            $client.Dispose(); $handler.Dispose()
        } catch {
            Write-Test "WebUI 托管 (/)" $false $_.Exception.Message
        }
        # 对话接口（非流式）
        try {
            $body = '{"messages":[{"role":"user","content":"Reply with exactly: OK"}],"stream":false,"n_predict":80,"temperature":0.2}'
            $raw = Invoke-WebRequest -Uri "http://$($s.healthHost):$($s.port)/chat/completions" -Method Post `
                                     -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 120
            $j = $raw.Content | ConvertFrom-Json
            $msg = $j.choices[0].message
            $has = -not [string]::IsNullOrWhiteSpace($msg.content) -or -not [string]::IsNullOrWhiteSpace($msg.reasoning_content)
            Write-Test "/chat/completions 生成" $has ("content=" + [string]$msg.content + " reasoning=" + [string]$msg.reasoning_content)
        } catch {
            Write-Test "/chat/completions 生成" $false $_.Exception.Message
        }
        return $r
    } catch {
        Write-Test ("阶段失败: " + $Name) $false $_.Exception.Message
        return $null
    }
}

function Run-SelfTest {
    Write-Host "=================================================="
    Write-Host " llama.cpp 启动客户端 - 自检"
    Write-Host "=================================================="
    $llamaDir = if ($LlamaDir) { $LlamaDir } else { 'F:\AI\llama-b10472-bin-win-vulkan-x64' }
    $model    = if ($Model)    { $Model    } else { 'F:\AI\models\Qwen3.5-4B\Qwen3.5-4B-Q4_K_M.gguf' }

    Write-Test 'llama.cpp 目录存在' (Test-Path $llamaDir) $llamaDir
    Write-Test 'llama-server.exe 存在' (Test-Path (Find-LlamaServerExe $llamaDir)) (Find-LlamaServerExe $llamaDir)
    Write-Test '模型文件存在' (Test-Path $model) $model
    if ($Mmproj) { Write-Test 'mmproj 文件存在' (Test-Path $Mmproj) $Mmproj }

    # 基础阶段（不带 mmproj）
    $s = @{
        llamaDir = $llamaDir; model = $model; mmproj = ''
        host = '127.0.0.1'; port = [string]$Port; ctx = '4096'; threads = ''; gpu = ''
        temp = '0.5'; mlock = $false; noMmap = $false
        extra = ''
    }
    $s.healthHost = '127.0.0.1'
    Write-Host '    WebUI: llama-server 内置 WebUI'

    $out1 = Join-Path $script:LogDir 'selftest-out.log'
    $err1 = Join-Path $script:LogDir 'selftest-err.log'
    $r1 = Test-Phase '基础对话测试' $s $out1 $err1
    if ($r1) {
        Stop-LlamaServerProcess $r1.Proc
        try { $r1.Proc.Refresh() } catch { }
        Write-Test "停止服务 (PID=$($r1.Proc.Id))" $r1.Proc.HasExited
    }

    # mmproj 阶段（若提供，使用独立端口；同样使用内置 WebUI）
    if ($Mmproj) {
        Start-Sleep -Seconds 2   # 等待端口释放
        $s2 = @{} ; foreach ($k in $s.Keys) { $s2[$k] = $s[$k] }
        $s2.mmproj = $Mmproj
        $s2.port = [string]($Port + 1)
        $out2 = Join-Path $script:LogDir 'selftest-mmproj-out.log'
        $err2 = Join-Path $script:LogDir 'selftest-mmproj-err.log'
        $r2 = Test-Phase '多模态 (mmproj) 测试' $s2 $out2 $err2
        if ($r2) {
            Stop-LlamaServerProcess $r2.Proc
            try { $r2.Proc.Refresh() } catch { }
            Write-Test "停止服务 (PID=$($r2.Proc.Id))" $r2.Proc.HasExited
        }
    }

    # WebView2 内嵌组件探测（报告环境创建是否可用）
    [void](Init-WebView2)
    if ($script:wvReady) {
        try {
            $probeData = Join-Path $script:LogDir 'wv2-probe-data'
            Remove-Item $probeData -Recurse -Force -ErrorAction SilentlyContinue
            $t = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($null, $probeData, $null)
            $t.Wait(30000) | Out-Null
            if ($t.IsCompleted -and -not $t.IsFaulted) {
                $env = $t.GetAwaiter().GetResult()
                Write-Test 'WebView2 运行时检测' $true ('版本 ' + $env.BrowserVersionString)
            } else {
                Write-Test 'WebView2 运行时检测' $false $t.Exception.GetBaseException().Message
            }
        } catch {
            Write-Test 'WebView2 运行时检测' $false $_.Exception.Message
        }
    } else {
        Write-Test 'WebView2 运行时检测' $false '组件缺失（lib 目录缺少 Core.dll / WebView2Loader.dll）'
    }

    Write-Host "=================================================="
    if ($script:testFail) {
        Write-Host " 自检结果: 存在失败项 (见上方 FAIL)"
        exit 1
    }
    Write-Host " 自检结果: 全部通过 ✓"
    exit 0
}

# ------------------------------------------------------------
# GUI
# ------------------------------------------------------------
function New-Lbl {
    param([string]$Text, [int]$W = 0)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.AutoSize = $true
    $l.TextAlign = 'MiddleLeft'
    $l.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)
    if ($W) { $l.Width = $W; $l.AutoSize = $false }
    return $l
}

function New-Tlp {
    param([int]$Cols, [int]$Rows)
    $t = New-Object System.Windows.Forms.TableLayoutPanel
    $t.ColumnCount = $Cols
    $t.RowCount = $Rows
    $t.Dock = 'Fill'
    $t.AutoSize = $true
    $t.AutoSizeMode = 'GrowAndShrink'
    $t.Padding = New-Object System.Windows.Forms.Padding(10)
    $t.Margin = New-Object System.Windows.Forms.Padding(0)
    for ($c = 0; $c -lt $Cols; $c++) {
        $st = New-Object System.Windows.Forms.ColumnStyle
        $st.SizeType = 'AutoSize'
        $t.ColumnStyles.Add($st) | Out-Null
    }
    for ($r = 0; $r -lt $Rows; $r++) {
        $st = New-Object System.Windows.Forms.RowStyle
        $st.SizeType = 'AutoSize'
        $t.RowStyles.Add($st) | Out-Null
    }
    return $t
}

function Set-ColPercent {
    param($Tlp, [int]$Col)
    $Tlp.ColumnStyles[$Col].SizeType = 'Percent'
    $Tlp.ColumnStyles[$Col].Width = 100
}

function Show-MainWindow {
    # 初始化 WebView2 组件（加载类型 + DPI 感知；必须在创建任何窗口之前调用）
    [void](Init-WebView2)

    # ---------------- 创建窗体 ----------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'llama.cpp 启动客户端'
    $form.ClientSize = New-Object System.Drawing.Size(980, 780)
    $form.MinimumSize = New-Object System.Drawing.Size(860, 660)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    # ---------------- ① llama.cpp 与模型 ----------------
    $grp1 = New-Object System.Windows.Forms.GroupBox
    $grp1.Text = ' ① llama.cpp 与模型 '
    $grp1.Dock = 'Fill'
    $grp1.AutoSize = $true
    $grp1.AutoSizeMode = 'GrowAndShrink'
    $tlp1 = New-Tlp 4 3

    $script:txtLlamaDir = New-Object System.Windows.Forms.TextBox
    $script:txtLlamaDir.Dock = 'Fill'
    $btnBrowseLlama = New-Object System.Windows.Forms.Button
    $btnBrowseLlama.Text = '浏览…'
    $btnBrowseLlama.Width = 64
    $script:lblExeStatus = New-Object System.Windows.Forms.Label
    $script:lblExeStatus.AutoSize = $true
    $script:lblExeStatus.ForeColor = [System.Drawing.Color]::Gray
    $script:lblExeStatus.Text = ''

    $tlp1.Controls.Add((New-Lbl 'llama.cpp 目录'), 0, 0)
    $tlp1.Controls.Add($script:txtLlamaDir, 1, 0)
    $tlp1.Controls.Add($btnBrowseLlama, 2, 0)
    $tlp1.Controls.Add($script:lblExeStatus, 3, 0)

    $script:txtModelFile = New-Object System.Windows.Forms.TextBox
    $script:txtModelFile.Dock = 'Fill'
    $btnPickModel = New-Object System.Windows.Forms.Button
    $btnPickModel.Text = '选择文件…'
    $btnPickModel.Width = 84

    $tlp1.Controls.Add((New-Lbl '模型文件'), 0, 1)
    $tlp1.Controls.Add($script:txtModelFile, 1, 1)
    $tlp1.Controls.Add($btnPickModel, 2, 1)

    $script:txtMmprojFile = New-Object System.Windows.Forms.TextBox
    $script:txtMmprojFile.Dock = 'Fill'
    $btnPickMmproj = New-Object System.Windows.Forms.Button
    $btnPickMmproj.Text = '选择文件…'
    $btnPickMmproj.Width = 84

    $tlp1.Controls.Add((New-Lbl 'mmproj 文件'), 0, 2)
    $tlp1.Controls.Add($script:txtMmprojFile, 1, 2)
    $tlp1.Controls.Add($btnPickMmproj, 2, 2)

    Set-ColPercent $tlp1 1
    $grp1.Controls.Add($tlp1)

    # ---------------- ② 启动参数 ----------------
    $grp2 = New-Object System.Windows.Forms.GroupBox
    $grp2.Text = ' ② 启动参数 '
    $grp2.Dock = 'Fill'
    $grp2.AutoSize = $true
    $grp2.AutoSizeMode = 'GrowAndShrink'
    $tlp2 = New-Tlp 4 6

    $script:txtPort = New-Object System.Windows.Forms.TextBox
    $script:txtHost = New-Object System.Windows.Forms.TextBox
    $script:txtCtx  = New-Object System.Windows.Forms.TextBox
    $script:txtThreads = New-Object System.Windows.Forms.TextBox
    $script:txtGpu  = New-Object System.Windows.Forms.TextBox
    $script:txtTemp = New-Object System.Windows.Forms.TextBox
    foreach ($tb in @($script:txtPort, $script:txtHost, $script:txtCtx, $script:txtThreads, $script:txtGpu, $script:txtTemp)) {
        $tb.Dock = 'Fill'
    }
    $tt = New-Object System.Windows.Forms.ToolTip
    $tt.SetToolTip($script:txtCtx, '-c 上下文长度（tokens），越大占显存/内存越多')
    $tt.SetToolTip($script:txtThreads, '-t CPU 线程数，留空使用默认')
    $tt.SetToolTip($script:txtGpu, '-ngl GPU 层数，如 999 表示全部放 GPU（需 GPU 版 llama.cpp）')
    $tt.SetToolTip($script:txtTemp, '--temp 采样温度，0~2')

    $tlp2.Controls.Add((New-Lbl '端口 --port'), 0, 0)
    $tlp2.Controls.Add($script:txtPort, 1, 0)
    $tlp2.Controls.Add((New-Lbl '监听地址 --host'), 2, 0)
    $tlp2.Controls.Add($script:txtHost, 3, 0)

    $tlp2.Controls.Add((New-Lbl '上下文长度 -c'), 0, 1)
    $tlp2.Controls.Add($script:txtCtx, 1, 1)
    $tlp2.Controls.Add((New-Lbl '线程数 -t'), 2, 1)
    $tlp2.Controls.Add($script:txtThreads, 3, 1)

    $tlp2.Controls.Add((New-Lbl 'GPU 层数 -ngl'), 0, 2)
    $tlp2.Controls.Add($script:txtGpu, 1, 2)
    $tlp2.Controls.Add((New-Lbl '温度 --temp'), 2, 2)
    $tlp2.Controls.Add($script:txtTemp, 3, 2)

    $script:chkAutoOpen = New-Object System.Windows.Forms.CheckBox
    $script:chkAutoOpen.Text = '服务就绪后自动打开 WebUI（嵌入窗口）'
    $script:chkAutoOpen.AutoSize = $true
    $script:chkAutoOpen.Checked = $true
    $script:chkAutoOpen.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)
    $script:chkMlock = New-Object System.Windows.Forms.CheckBox
    $script:chkMlock.Text = '--mlock（锁内存）'
    $script:chkMlock.AutoSize = $true
    $script:chkMlock.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)
    $script:chkNoMmap = New-Object System.Windows.Forms.CheckBox
    $script:chkNoMmap.Text = '--no-mmap（禁用内存映射）'
    $script:chkNoMmap.AutoSize = $true
    $script:chkNoMmap.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)

    # 复选框独占整行/半行，避免文字换行显示不全
    $tlp2.Controls.Add($script:chkAutoOpen, 0, 3)
    $tlp2.SetColumnSpan($script:chkAutoOpen, 4)
    $tlp2.Controls.Add($script:chkMlock, 0, 4)
    $tlp2.SetColumnSpan($script:chkMlock, 2)
    $tlp2.Controls.Add($script:chkNoMmap, 2, 4)
    $tlp2.SetColumnSpan($script:chkNoMmap, 2)

    $script:txtExtra = New-Object System.Windows.Forms.TextBox
    $script:txtExtra.Dock = 'Fill'
    $script:txtExtra.Text = ''
    $tt.SetToolTip($script:txtExtra, '其它任意 llama-server 参数，如: --no-warmup --cache-prompt --n-predict 2048')

    $tlp2.Controls.Add((New-Lbl '附加参数'), 0, 5)
    $tlp2.Controls.Add($script:txtExtra, 1, 5)
    $tlp2.SetColumnSpan($script:txtExtra, 3)

    Set-ColPercent $tlp2 1
    Set-ColPercent $tlp2 3
    $grp2.Controls.Add($tlp2)

    # ---------------- ③ 最终启动命令 ----------------
    $grp3 = New-Object System.Windows.Forms.GroupBox
    $grp3.Text = ' ③ 最终启动命令（确认无误后点下方"启动服务"） '
    $grp3.Dock = 'Fill'
    $grp3.AutoSize = $true
    $grp3.AutoSizeMode = 'GrowAndShrink'
    $tlp3 = New-Tlp 2 2

    $script:txtPreview = New-Object System.Windows.Forms.TextBox
    $script:txtPreview.Multiline = $true
    $script:txtPreview.ReadOnly = $true
    $script:txtPreview.ScrollBars = 'Both'
    $script:txtPreview.WordWrap = $false
    $script:txtPreview.Height = 76
    $script:txtPreview.Dock = 'Fill'
    $script:txtPreview.Font = New-Object System.Drawing.Font('Consolas', 9)
    $script:txtPreview.Text = '（设置完成后此处自动生成启动命令）'
    $script:txtPreview.ForeColor = [System.Drawing.Color]::DimGray

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = '复制命令'
    $btnCopy.Width = 88
    $script:lblCmdInfo = New-Object System.Windows.Forms.Label
    $script:lblCmdInfo.AutoSize = $true
    $script:lblCmdInfo.ForeColor = [System.Drawing.Color]::DimGray

    $tlp3.Controls.Add($script:txtPreview, 0, 0)
    $tlp3.SetColumnSpan($script:txtPreview, 2)
    $tlp3.Controls.Add($btnCopy, 0, 1)
    $tlp3.Controls.Add($script:lblCmdInfo, 1, 1)
    $tlp3.ColumnStyles[1].SizeType = 'Percent'
    $tlp3.ColumnStyles[1].Width = 100
    $grp3.Controls.Add($tlp3)

    # ---------------- 设置区组合 ----------------
    $settingsPanel = New-Object System.Windows.Forms.Panel
    $settingsPanel.Dock = 'Fill'
    $settingsPanel.AutoScroll = $true
    $settingsTlp = New-Tlp 1 3
    $settingsTlp.Controls.Add($grp1, 0, 0)
    $settingsTlp.Controls.Add($grp2, 0, 1)
    $settingsTlp.Controls.Add($grp3, 0, 2)
    $settingsPanel.Controls.Add($settingsTlp)

    # ---------------- 运行日志 ----------------
    $tabLogs = New-Object System.Windows.Forms.TabControl
    $tabLogs.Dock = 'Fill'
    $tabPage = New-Object System.Windows.Forms.TabPage
    $tabPage.Text = '运行日志'
    $tabLogs.TabPages.Add($tabPage)

    $logTlp = New-Tlp 2 2
    $logTlp.RowStyles[1].SizeType = 'Percent'
    $logTlp.RowStyles[1].Height = 100

    $btnClearLog = New-Object System.Windows.Forms.Button
    $btnClearLog.Text = '清空日志'
    $btnClearLog.Width = 84
    $btnClearLog.Margin = New-Object System.Windows.Forms.Padding(8, 6, 3, 4)
    $btnExportLog = New-Object System.Windows.Forms.Button
    $btnExportLog.Text = '导出日志'
    $btnExportLog.Width = 84
    $btnExportLog.Margin = New-Object System.Windows.Forms.Padding(3, 6, 8, 4)

    $script:txtLog = New-Object System.Windows.Forms.TextBox
    $script:txtLog.Multiline = $true
    $script:txtLog.ReadOnly = $true
    $script:txtLog.ScrollBars = 'Vertical'
    $script:txtLog.WordWrap = $false
    $script:txtLog.Dock = 'Fill'
    $script:txtLog.Margin = New-Object System.Windows.Forms.Padding(8, 4, 8, 8)
    $script:txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
    $script:txtLog.BackColor = [System.Drawing.Color]::FromArgb(13, 15, 19)
    $script:txtLog.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)

    # 日志黑框直接从按钮下方开始（第 1 行 = 按钮，第 2 行 = 日志框）
    $logTlp.Controls.Add($btnClearLog, 0, 0)
    $logTlp.Controls.Add($btnExportLog, 1, 0)
    $logTlp.Controls.Add($script:txtLog, 0, 1)
    $logTlp.SetColumnSpan($script:txtLog, 2)
    $tabPage.Controls.Add($logTlp)

    # ---------------- 主布局: 三个标签页 ----------------
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $script:tabs = $tabs

    # Tab ① 设置
    $tabSettings = New-Object System.Windows.Forms.TabPage
    $tabSettings.Text = '① 设置与启动命令'
    $tabSettings.Controls.Add($settingsPanel)

    # Tab ② 运行日志
    $tabLogsPage = New-Object System.Windows.Forms.TabPage
    $tabLogsPage.Text = '② 运行日志'
    $tabLogsPage.Controls.Add($tabLogs)

    # Tab ③ WebUI（嵌入窗口）
    $tabWeb = New-Object System.Windows.Forms.TabPage
    $tabWeb.Text = '③ WebUI（嵌入窗口）'
    $webTlp = New-Tlp 1 2
    $webTlp.RowStyles[0].SizeType = 'Absolute'
    $webTlp.RowStyles[0].Height = 44
    $webTlp.RowStyles[1].SizeType = 'Percent'
    $webTlp.RowStyles[1].Height = 100

    $webTop = New-Object System.Windows.Forms.Panel
    $webTop.Dock = 'Fill'
    $webTopTlp = New-Tlp 3 1
    $script:lblWvStatus = New-Object System.Windows.Forms.Label
    $script:lblWvStatus.AutoSize = $true
    $script:lblWvStatus.Text = 'WebUI 未加载（服务就绪后自动嵌入本窗口）'
    $script:lblWvStatus.ForeColor = [System.Drawing.Color]::DimGray
    $script:lblWvStatus.Margin = New-Object System.Windows.Forms.Padding(6, 12, 3, 3)
    $btnWvLoad = New-Object System.Windows.Forms.Button
    $btnWvLoad.Text = '加载到窗口'
    $btnWvLoad.Width = 100
    $btnWvLoad.Margin = New-Object System.Windows.Forms.Padding(6, 6, 3, 3)
    $btnWvBrowser = New-Object System.Windows.Forms.Button
    $btnWvBrowser.Text = '在浏览器中打开'
    $btnWvBrowser.Width = 122
    $btnWvBrowser.Margin = New-Object System.Windows.Forms.Padding(3, 6, 6, 3)

    $webTopTlp.Controls.Add($script:lblWvStatus, 0, 0)
    $webTopTlp.Controls.Add($btnWvLoad, 1, 0)
    $webTopTlp.Controls.Add($btnWvBrowser, 2, 0)
    $webTopTlp.ColumnStyles[0].SizeType = 'Percent'
    $webTopTlp.ColumnStyles[0].Width = 100
    $webTop.Controls.Add($webTopTlp)

    $script:webuiPanel = New-Object System.Windows.Forms.Panel
    $script:webuiPanel.Dock = 'Fill'
    $script:webuiPanel.BackColor = [System.Drawing.Color]::White

    $webTlp.Controls.Add($webTop, 0, 0)
    $webTlp.Controls.Add($script:webuiPanel, 0, 1)
    $tabWeb.Controls.Add($webTlp)

    $tabs.TabPages.Add($tabSettings)
    $tabs.TabPages.Add($tabLogsPage)
    $tabs.TabPages.Add($tabWeb)

    # 底部按钮栏
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 52
    $bottom.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)

    $script:btnStart = New-Object System.Windows.Forms.Button
    $script:btnStart.Text = '🚀 启动服务'
    $script:btnStart.Width = 110
    $script:btnStart.Height = 34
    $script:btnStart.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $script:btnStart.BackColor = [System.Drawing.Color]::FromArgb(47, 129, 247)
    $script:btnStart.ForeColor = [System.Drawing.Color]::White
    $script:btnStart.FlatStyle = 'Flat'
    $script:btnStart.Location = New-Object System.Drawing.Point(10, 8)

    $script:btnStop = New-Object System.Windows.Forms.Button
    $script:btnStop.Text = '■ 停止服务'
    $script:btnStop.Width = 100
    $script:btnStop.Height = 34
    $script:btnStop.Enabled = $false
    $script:btnStop.Location = New-Object System.Drawing.Point(130, 8)

    $btnHelp = New-Object System.Windows.Forms.Button
    $btnHelp.Text = '使用说明'
    $btnHelp.Width = 84
    $btnHelp.Height = 34
    $btnHelp.Location = New-Object System.Drawing.Point(240, 8)

    $script:lblStatus = New-Object System.Windows.Forms.Label
    $script:lblStatus.AutoSize = $true
    $script:lblStatus.Text = '状态: 未启动'
    $script:lblStatus.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $script:lblStatus.ForeColor = [System.Drawing.Color]::Gray
    $script:lblStatus.Location = New-Object System.Drawing.Point(350, 17)

    $bottom.Controls.Add($script:btnStart)
    $bottom.Controls.Add($script:btnStop)
    $bottom.Controls.Add($btnHelp)
    $bottom.Controls.Add($script:lblStatus)

    $form.Controls.Add($tabs)
    $form.Controls.Add($bottom)

    # ---------------- 逻辑函数（GUI 版） ----------------
    function Update-LlamaStatus {
        $exe = Find-LlamaServerExe $script:txtLlamaDir.Text.Trim()
        if ($exe) {
            $script:lblExeStatus.Text = "✓ 已找到 $([System.IO.Path]::GetFileName($exe))"
            $script:lblExeStatus.ForeColor = [System.Drawing.Color]::ForestGreen
        } elseif ($script:txtLlamaDir.Text.Trim()) {
            $script:lblExeStatus.Text = '✗ 未找到 llama-server.exe'
            $script:lblExeStatus.ForeColor = [System.Drawing.Color]::IndianRed
        } else {
            $script:lblExeStatus.Text = ''
        }
        Update-Preview
    }

    function Build-ArgItems {
        $s = @{
            llamaDir  = $script:txtLlamaDir.Text.Trim()
            model     = Resolve-SelectedFile $script:txtModelFile.Text.Trim()
            mmproj    = Resolve-SelectedFile $script:txtMmprojFile.Text.Trim()
            host      = $script:txtHost.Text.Trim()
            port      = $script:txtPort.Text.Trim()
            ctx       = $script:txtCtx.Text.Trim()
            threads   = $script:txtThreads.Text.Trim()
            gpu       = $script:txtGpu.Text.Trim()
            temp      = $script:txtTemp.Text.Trim()
            mlock     = [bool]$script:chkMlock.Checked
            noMmap    = [bool]$script:chkNoMmap.Checked
            extra     = $script:txtExtra.Text
        }
        if (-not $s.model) {
            $script:argError = '请先选择有效的模型文件（.gguf）'
            return $null
        }
        if ($script:txtMmprojFile.Text.Trim() -and -not $s.mmproj) {
            $script:argError = 'mmproj 文件无效，请重新选择'
            return $null
        }
        return Get-ArgsFromSettings $s
    }

    function Update-Preview {
        $items = Build-ArgItems
        $exe = Find-LlamaServerExe $script:txtLlamaDir.Text.Trim()
        if ($items -and $exe) {
            $cmd = "`"$exe`" $(ConvertTo-CommandLine $items)"
            $script:lastCommand = $cmd
            $script:txtPreview.Text = $cmd
            $script:txtPreview.ForeColor = [System.Drawing.Color]::Black
            $script:lblCmdInfo.Text = 'WebUI: 使用 llama-server 内置 WebUI（http://host:port/）'
        } else {
            $script:txtPreview.Text = '（设置完成后此处自动生成启动命令）'
            $script:txtPreview.ForeColor = [System.Drawing.Color]::DimGray
            $script:lblCmdInfo.Text = ''
        }
    }

    function Append-Log {
        param([string]$Text)
        if (-not $script:txtLog -or -not $Text) { return }
        $script:txtLog.AppendText(($Text -replace "`n", "`r`n"))
        if (-not $Text.EndsWith("`n")) { $script:txtLog.AppendText("`r`n") }
        if ($script:txtLog.TextLength -gt 500000) {
            $script:txtLog.Text = $script:txtLog.Text.Substring($script:txtLog.TextLength - 300000)
            Write-ClientLog '日志显示过长已自动截断（可导出完整日志）'
        }
        $script:txtLog.SelectionStart = $script:txtLog.TextLength
        $script:txtLog.ScrollToCaret()
    }

    function Read-FileTail {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return '' }
        try {
            $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
            try {
                $fs.Seek($script:logOffsets[$Path], 'Begin') | Out-Null
                $remaining = $fs.Length - $fs.Position
                if ($remaining -le 0) { return '' }
                $buf = New-Object byte[] $remaining
                $n = $fs.Read($buf, 0, $buf.Length)
                $script:logOffsets[$Path] = $fs.Position
                if ($n -le 0) { return '' }
                $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
                return ($text -replace "`r", "`n")
            } finally { $fs.Dispose() }
        } catch { return '' }
    }

    function Update-Logs {
        $t1 = Read-FileTail $script:OutLogPath
        if ($t1) { Append-Log $t1 }
        $t2 = Read-FileTail $script:ErrLogPath
        if ($t2) { Append-Log $t2 }
        # 运行中进程意外退出
        if ($script:serverProc -and $script:serverProc.HasExited -and $script:state -eq 'ready') {
            Append-Log "llama-server 进程已退出 (exit=$($script:serverProc.ExitCode))"
            $script:healthTimer.Stop()
            $script:serverProc = $null
            Set-ServerState 'idle'
        }
    }

    function Set-ServerState {
        param([string]$NewState)
        $script:state = $NewState
        switch ($NewState) {
            'idle' {
                $script:btnStart.Enabled = $true
                $script:btnStop.Enabled = $false
                $script:lblStatus.Text = '状态: 未启动'
                $script:lblStatus.ForeColor = [System.Drawing.Color]::Gray
            }
            'starting' {
                $script:btnStart.Enabled = $false
                $script:btnStop.Enabled = $true
                $script:lblStatus.Text = '状态: 正在启动 / 加载模型…'
                $script:lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
            }
            'ready' {
                $script:btnStart.Enabled = $false
                $script:btnStop.Enabled = $true
                $script:lblStatus.Text = "状态: 已就绪 ✓  http://$($script:healthHost):$($script:portNow)/"
                $script:lblStatus.ForeColor = [System.Drawing.Color]::ForestGreen
            }
            'stopping' {
                $script:btnStart.Enabled = $false
                $script:btnStop.Enabled = $false
                $script:lblStatus.Text = '状态: 正在停止…'
                $script:lblStatus.ForeColor = [System.Drawing.Color]::DimGray
            }
        }
    }

    function Log-Both {
        param([string]$Text)
        Write-ClientLog $Text
        Append-Log $Text
    }

    function Resize-WebView2 {
        if (-not $script:wvController) { return }
        try {
            $w = $script:webuiPanel.ClientSize.Width
            $h = $script:webuiPanel.ClientSize.Height
            if ($w -gt 0 -and $h -gt 0) {
                $script:wvController.Bounds = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
                $script:wvController.IsVisible = $true
            }
        } catch { }
    }

    function Init-EmbeddedWebUi {
        # 在窗口内创建 WebView2 并导航到 WebUI；失败返回 $false（可用浏览器兜底）
        if ($script:wvController) {
            $script:lblWvStatus.Text = "已嵌入: http://$($script:healthHost):$($script:portNow)/"
            $script:lblWvStatus.ForeColor = [System.Drawing.Color]::ForestGreen
            Resize-WebView2
            return $true
        }
        if (-not $script:wvReady) {
            $script:lblWvStatus.Text = 'WebView2 不可用，请使用"在浏览器中打开"'
            $script:lblWvStatus.ForeColor = [System.Drawing.Color]::DarkOrange
            return $false
        }
        $url = "http://$($script:healthHost):$($script:portNow)/"
        $script:lblWvStatus.Text = '正在嵌入 WebView2…'
        try {
            [void]$script:webuiPanel.Handle
            $script:wvController = New-WebView2Controller -Hwnd $script:webuiPanel.Handle -UserDataDir $script:wvUserData
            $script:wvCore = $script:wvController.CoreWebView2
            try { $script:wvCore.Settings.IsStatusBarEnabled = $false } catch { }
            $script:wvCore.Add_NavigationCompleted({
                param($s2, $e2)
                if ($e2.IsSuccess) { Write-ClientLog ('WebUI 页面加载完成: ' + $s2.Source) }
            })
            # 主文档 HTTP 错误提示（如某些 llama-server 版本无内置 WebUI）
            try {
                $script:wvCore.Add_WebResourceResponseReceived({
                    param($s2, $e2)
                    try {
                        $req = $e2.Request; $resp = $e2.Response
                        if ($req -and $resp -and $req.Uri -eq ("http://$($script:healthHost):$($script:portNow)/") -and $resp.StatusCode -ge 400) {
                            Write-ClientLog ("WebUI 页面返回 HTTP " + $resp.StatusCode + "（该 llama-server 版本可能没有内置 WebUI）")
                            $script:lblWvStatus.Text = '页面返回错误（HTTP ' + $resp.StatusCode + '），请在 ② 附加参数中自行处理'
                            $script:lblWvStatus.ForeColor = [System.Drawing.Color]::IndianRed
                        }
                    } catch { }
                })
            } catch { }
            Resize-WebView2
            $script:wvCore.Navigate($url)
            $script:lblWvStatus.Text = "已嵌入（llama-server 内置 WebUI）: $url"
            $script:lblWvStatus.ForeColor = [System.Drawing.Color]::ForestGreen
            Log-Both "WebUI 已嵌入客户端窗口（llama-server 内置 WebUI）: $url"
            return $true
        } catch {
            $err = $_.Exception.Message
            Log-Both ("WebView2 嵌入失败: " + $err)
            $script:lblWvStatus.Text = '嵌入失败（可点"在浏览器中打开"）'
            $script:lblWvStatus.ForeColor = [System.Drawing.Color]::IndianRed
            Close-WebView2Controller
            return $false
        }
    }

    function Start-LlamaServer {
        if ($script:state -ne 'idle') { return }
        $items = Build-ArgItems
        if (-not $items) {
            [System.Windows.Forms.MessageBox]::Show($form, $script:argError, '无法启动', 'OK', 'Warning') | Out-Null
            return
        }
        $exe = Find-LlamaServerExe $script:txtLlamaDir.Text.Trim()
        if (-not $exe) {
            [System.Windows.Forms.MessageBox]::Show($form, '未找到 llama-server.exe，请检查 llama.cpp 目录。', '无法启动', 'OK', 'Warning') | Out-Null
            return
        }
        $portStr = $script:txtPort.Text.Trim()
        if ($portStr -and $portStr -notmatch '^\d+$') {
            [System.Windows.Forms.MessageBox]::Show($form, '端口必须是数字。', '无法启动', 'OK', 'Warning') | Out-Null
            return
        }

        $s = @{
            llamaDir  = $script:txtLlamaDir.Text.Trim()
            model     = Resolve-SelectedFile $script:txtModelFile.Text.Trim()
            mmproj    = Resolve-SelectedFile $script:txtMmprojFile.Text.Trim()
            host      = $script:txtHost.Text.Trim()
            port      = $portStr
            ctx       = $script:txtCtx.Text.Trim()
            threads   = $script:txtThreads.Text.Trim()
            gpu       = $script:txtGpu.Text.Trim()
            temp      = $script:txtTemp.Text.Trim()
            mlock     = [bool]$script:chkMlock.Checked
            noMmap    = [bool]$script:chkNoMmap.Checked
            extra     = $script:txtExtra.Text
        }
        if (-not $s.model) {
            [System.Windows.Forms.MessageBox]::Show($form, '请先选择有效的模型文件（.gguf）。', '无法启动', 'OK', 'Warning') | Out-Null
            return
        }
        if ($script:txtMmprojFile.Text.Trim() -and -not $s.mmproj) {
            [System.Windows.Forms.MessageBox]::Show($form, 'mmproj 文件无效，请重新选择。', '无法启动', 'OK', 'Warning') | Out-Null
            return
        }

        $script:logOffsets = @{ $script:OutLogPath = 0; $script:ErrLogPath = 0 }
        $procRef = $null
        try {
            $r = Start-LlamaServerProcess -s $s -OutFile $script:OutLogPath -ErrFile $script:ErrLogPath -ProcRef ([ref]$procRef)
        } catch {
            [System.Windows.Forms.MessageBox]::Show($form, ('启动失败：' + $_.Exception.Message), '错误', 'OK', 'Error') | Out-Null
            return
        }
        $script:serverProc = $r.Proc
        $script:lastCommand = $r.Command
        $script:portNow = if ($portStr) { [int]$portStr } else { 8080 }
        $hostTxt = $s.host
        $script:healthHost = if ($hostTxt -in @('0.0.0.0', '::')) { '127.0.0.1' } else { $hostTxt }
        $script:healthAttempts = 0
        $script:autoOpenedWebui = $false
        $script:startedAt = Get-Date

        Append-Log '══════════════════════════════════════════'
        Write-ClientLog ("启动命令: " + $r.Command)
        Append-Log ("启动命令: " + $r.Command)
        Append-Log 'WebUI: llama-server 内置 WebUI（http://host:port/）'
        Append-Log ("进程 PID: " + $script:serverProc.Id)

        Set-ServerState 'starting'
        $script:logTimer.Start()
        $script:healthTimer.Start()
    }

    function Stop-LlamaServer {
        if (-not $script:serverProc) { return }
        $pidToKill = $script:serverProc.Id
        Set-ServerState 'stopping'
        Log-Both "正在停止服务 (PID=$pidToKill) …"
        $script:healthTimer.Stop()
        $script:logTimer.Stop()
        Stop-LlamaServerProcess $script:serverProc
        try { $script:serverProc.Refresh() } catch { }
        if ($script:serverProc.HasExited) {
            Log-Both '服务已停止。'
        } else {
            Log-Both '警告: 无法结束进程，请手动检查任务管理器。'
        }
        $script:serverProc = $null
        Set-ServerState 'idle'
        # 停止后立即刷一次日志尾部
        Update-Logs
    }

    function Open-WebUi {
        # 浏览器备用打开（默认即为 llama-server 内置 WebUI 或用户指定的 --path 页面）
        $url = "http://$($script:healthHost):$($script:portNow)/"
        Start-Process $url
    }

    # ---------------- 事件绑定 ----------------
    $btnBrowseLlama.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = '选择 llama.cpp 目录（包含 llama-server.exe）'
        if ($d.ShowDialog($form) -eq 'OK') {
            $script:txtLlamaDir.Text = $d.SelectedPath
            Update-LlamaStatus
        }
    })

    $btnPickModel.Add_Click({
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Filter = 'GGUF 模型 (*.gguf)|*.gguf|所有文件 (*.*)|*.*'
        $d.Title = '选择模型文件'
        if ($d.ShowDialog($form) -eq 'OK') {
            $script:txtModelFile.Text = $d.FileName
            # 若尚未选择 mmproj，自动查找同目录下的 mmproj 文件
            if (-not $script:txtMmprojFile.Text.Trim()) {
                $dir = [System.IO.Path]::GetDirectoryName($d.FileName)
                $mm = @(Get-ChildItem -Path $dir -Filter '*.gguf' -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match 'mmproj' })
                if ($mm.Count) {
                    $script:txtMmprojFile.Text = $mm[0].FullName
                }
            }
            Update-Preview
        }
    })

    $btnPickMmproj.Add_Click({
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Filter = 'GGUF 文件 (*.gguf)|*.gguf|所有文件 (*.*)|*.*'
        $d.Title = '选择 mmproj 文件'
        if ($d.ShowDialog($form) -eq 'OK') {
            $script:txtMmprojFile.Text = $d.FileName
            Update-Preview
        }
    })

    $btnCopy.Add_Click({
        if ($script:lastCommand) {
            [System.Windows.Forms.Clipboard]::SetText($script:lastCommand)
            $btnCopy.Text = '已复制 ✓'
            $t = New-Object System.Windows.Forms.Timer
            $t.Interval = 1500
            $t.Add_Tick({ $btnCopy.Text = '复制命令'; $t.Stop(); $t.Dispose() })
            $t.Start()
        }
    })

    $btnClearLog.Add_Click({
        $script:txtLog.Clear()
        $script:logOffsets = @{ $script:OutLogPath = (Get-Item $script:OutLogPath -ErrorAction SilentlyContinue).Length; $script:ErrLogPath = (Get-Item $script:ErrLogPath -ErrorAction SilentlyContinue).Length }
    })

    $btnExportLog.Add_Click({
        $d = New-Object System.Windows.Forms.SaveFileDialog
        $d.Filter = '文本文件 (*.log)|*.log|所有文件 (*.*)|*.*'
        $d.FileName = 'llama-server-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log'
        if ($d.ShowDialog($form) -eq 'OK') {
            [System.IO.File]::WriteAllText($d.FileName, $script:txtLog.Text, [System.Text.Encoding]::UTF8)
        }
    })

    $script:btnStart.Add_Click({ Start-LlamaServer })
    $script:btnStop.Add_Click({ if ($script:state -ne 'idle') { Stop-LlamaServer } })
    $btnWvLoad.Add_Click({
        $script:tabs.SelectedIndex = 2
        if ($script:state -ne 'ready') {
            [System.Windows.Forms.MessageBox]::Show($form, '服务未就绪，请先启动服务。', '提示', 'OK', 'Information') | Out-Null
            return
        }
        Init-EmbeddedWebUi
    })
    $btnWvBrowser.Add_Click({ Open-WebUi })
    $btnHelp.Add_Click({ $readme = Join-Path $script:AppDir 'README.md'; if (Test-Path $readme) { Start-Process $readme } })

    # 参数变化 → 刷新命令预览
    $script:txtLlamaDir.Add_TextChanged({ Update-LlamaStatus })
    $script:txtModelFile.Add_TextChanged({ Update-Preview })
    $script:txtMmprojFile.Add_TextChanged({ Update-Preview })
    $script:txtHost.Add_TextChanged({ Update-Preview })
    $script:txtPort.Add_TextChanged({ Update-Preview })
    $script:txtCtx.Add_TextChanged({ Update-Preview })
    $script:txtThreads.Add_TextChanged({ Update-Preview })
    $script:txtGpu.Add_TextChanged({ Update-Preview })
    $script:txtTemp.Add_TextChanged({ Update-Preview })
    $script:txtExtra.Add_TextChanged({ Update-Preview })
    $script:chkAutoOpen.Add_CheckedChanged({ Update-Preview })
    $script:chkMlock.Add_CheckedChanged({ Update-Preview })
    $script:chkNoMmap.Add_CheckedChanged({ Update-Preview })

    # 定时器
    $script:logTimer = New-Object System.Windows.Forms.Timer
    $script:logTimer.Interval = 400
    $script:logTimer.Add_Tick({ Update-Logs })

    $script:healthTimer = New-Object System.Windows.Forms.Timer
    $script:healthTimer.Interval = 1200
    $script:healthTimer.Add_Tick({
        if ($script:state -ne 'starting') { return }
        $script:healthAttempts++
        $url = "http://$($script:healthHost):$($script:portNow)/health"
        try {
            $h = Invoke-RestMethod -Uri $url -TimeoutSec 2
            if ($h.status -eq 'ok') {
                $script:healthTimer.Stop()
                Append-Log "服务已就绪: $url"
                Write-ClientLog "服务已就绪: $url"
                Set-ServerState 'ready'
                if ($script:chkAutoOpen.Checked -and -not $script:autoOpenedWebui) {
                    $script:autoOpenedWebui = $true
                    $script:tabs.SelectedIndex = 2
                    if (-not $script:wvInitTimer) {
                        $script:wvInitTimer = New-Object System.Windows.Forms.Timer
                        $script:wvInitTimer.Interval = 400
                        $script:wvInitTimer.Add_Tick({
                            $script:wvInitTimer.Stop()
                            if ($script:state -eq 'ready') {
                                if (-not (Init-EmbeddedWebUi)) {
                                    Log-Both '嵌入失败，已切换到"在浏览器中打开"备用方案'
                                }
                            }
                        })
                    }
                    $script:wvInitTimer.Start()
                }
            }
        } catch {
            if ($script:serverProc -and $script:serverProc.HasExited) {
                $script:healthTimer.Stop()
                Append-Log ("llama-server 进程已退出 (exit=" + $script:serverProc.ExitCode + ")，请查看下方日志")
                $script:serverProc = $null
                Set-ServerState 'idle'
            } elseif ($script:healthAttempts -gt 240) {
                $script:healthTimer.Stop()
                Append-Log '等待服务就绪超时（约 5 分钟），请检查端口占用与下方日志'
                Set-ServerState 'idle'
            }
        }
    })

    # 关闭窗体
    $form.Add_FormClosing({
        param($s2, $e)
        Save-Config
        Close-WebView2Controller
        if ($script:state -ne 'idle' -and $script:state -ne 'stopping') {
            $r = [System.Windows.Forms.MessageBox]::Show($form, 'llama-server 正在运行，确定要停止并退出吗？', '退出确认', 'YesNo', 'Question')
            if ($r -eq 'Yes') {
                $script:closing = $true
                Stop-LlamaServer
            } else {
                $e.Cancel = $true
            }
        }
    })

    # ---------------- 加载配置并显示 ----------------
    $cfg = Load-Config
    $script:txtLlamaDir.Text    = [string]$cfg.llamaDir
    $script:txtModelFile.Text   = [string]$cfg.modelFile
    $script:txtMmprojFile.Text  = [string]$cfg.mmprojFile
    $script:txtHost.Text        = [string]$cfg.host
    $script:txtPort.Text        = [string]$cfg.port
    $script:txtCtx.Text         = [string]$cfg.ctx
    $script:txtThreads.Text     = [string]$cfg.threads
    $script:txtGpu.Text         = [string]$cfg.gpu
    $script:txtTemp.Text        = [string]$cfg.temp
    $script:txtExtra.Text       = [string]$cfg.extra
    $script:chkAutoOpen.Checked = [bool]$cfg.autoOpen
    $script:chkMlock.Checked    = [bool]$cfg.mlock
    $script:chkNoMmap.Checked   = [bool]$cfg.noMmap
    Update-LlamaStatus

    $form.Add_Shown({
        if ($AutoStart -and $script:state -eq 'idle') { Start-LlamaServer }
    })

    # 切换到 WebUI 标签时：仅刷新尺寸（自动嵌入由就绪后的一次性定时器负责，避免重复尝试）
    $tabs.Add_SelectedIndexChanged({
        if ($tabs.SelectedIndex -eq 2) {
            Resize-WebView2
        }
    })

    $script:webuiPanel.Add_Resize({ Resize-WebView2 })

    if ($script:wvReady) {
        $script:lblWvStatus.Text = 'WebUI 未加载（服务就绪后自动嵌入本窗口）'
    } else {
        $script:lblWvStatus.Text = 'WebView2 组件缺失：嵌入不可用，可使用"在浏览器中打开"'
        $script:lblWvStatus.ForeColor = [System.Drawing.Color]::DarkOrange
    }

    [void]$form.ShowDialog()
}

# ------------------------------------------------------------
# 入口
# ------------------------------------------------------------
if ($SelfTest) {
    Run-SelfTest
    exit 0
}
Show-MainWindow
