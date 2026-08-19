# llama.cpp 启动客户端（Windows 桌面版）

一个**零依赖**的 llama.cpp 桌面启动器：**双击 `llama-launcher.exe` 即可运行**（已打包为独立 exe，无需安装 Python / Node / .NET / PowerShell 组件以外的任何东西，Windows 10/11 自带 PowerShell）。WebUI **直接嵌入客户端窗口**（基于系统自带的 WebView2）。

## 快速开始

1. 把 **`llama-launcher.exe`** 复制到任意可写目录（与 `lib\` 放在一起）。
2. 双击 exe → ① 选 llama.cpp 目录；② 选模型文件（自动识别 mmproj）；③ 调参。
3. 点「🚀 启动服务」→ 就绪后自动切到「③ WebUI（嵌入窗口）」。

> 源码方式：也可双击 `启动客户端.bat`（直接运行 `llama-launcher.ps1`），两者功能一致。

## 功能对照

| 需求 | 实现 |
| --- | --- |
| ① 选取 llama.cpp 目录 | 设置区「llama.cpp 目录」+ 浏览按钮，自动检测 `llama-server.exe` 并给出 ✓/✗ 提示 |
| ② 选取模型文件与 mmproj 文件 | 「模型文件」「mmproj 文件」直接「选择文件…」即可（选择模型文件时若同目录有 `*mmproj*` 会**自动填入** mmproj） |
| ③ 选取 llama.cpp 启动参数 | 「启动参数」区提供常用参数（端口 / 监听地址 / 上下文长度 / 线程数 / GPU 层数 / 温度）+ 开关（`--mlock`、`--no-mmap`）+ 自由「附加参数」文本框 |
| ④ 生成最终启动命令并确认、自动启动、查看命令与日志 | 设置实时生成「最终启动命令」预览（可一键复制）；点「🚀 启动服务」确认后自动拉起 `llama-server.exe`；「② 运行日志」页实时滚动显示完整输出；「■ 停止服务」结束进程树；退出时确认停服 |
| ⑤ WebUI 嵌入窗口 | 服务就绪后自动切到「③ WebUI（嵌入窗口）」标签，用 **WebView2（Chromium 内核）** 在客户端窗口内渲染 `http://127.0.0.1:端口/`，显示 **llama-server 自带的内置 WebUI**，功能与浏览器打开完全一致 |

### 界面与行为（当前版本）

- **设置极简**：只需选择 ① llama.cpp 目录、② 模型文件、mmproj 文件（可选），再按需调参即可。
- **固定使用内置 WebUI**：启动命令**不包含 `--path`**，窗口始终访问 `http://127.0.0.1:端口/` 的 llama-server 内置 WebUI（新版 llama.cpp 自带 Svelte 前端，支持多模态图片等能力）。
- **WebUI 窗口**仅保留「加载到窗口」「在浏览器中打开」两个辅助按钮与状态提示。

## 使用方法

1. 双击 **`启动客户端.bat`**（如被 SmartScreen 拦截，点「更多信息 → 仍要运行」）。
2. 设置区：
   - ① 选择 llama.cpp 目录 → 确认显示「✓ 已找到 llama-server.exe」；
   - ② 点「选择文件…」选模型文件；再选 mmproj 文件（多模态模型才需要，可选）；
   - ③ 按需调整端口等参数。
3. ③ 处查看生成的最终启动命令（无 `--path`，使用内置 WebUI），确认无误。
4. 点 **「🚀 启动服务」** → 就绪后自动切到「③ WebUI（嵌入窗口）」。
5. 「② 运行日志」页可查看、清空、导出日志；客户端关键事件记录在 `logs\client.log`。

## 参数说明（常用）

| 界面项 | 对应参数 | 说明 |
| --- | --- | --- |
| 端口 | `--port` | 服务监听端口，默认 8080 |
| 监听地址 | `--host` | 默认 127.0.0.1（仅本机）；填 0.0.0.0 可局域网访问 |
| 上下文长度 | `-c` | 默认 8192，越大越占显存/内存 |
| 线程数 | `-t` | 留空用默认 |
| GPU 层数 | `-ngl` | 如 99 = 全部层放 GPU（需 GPU 版 llama.cpp，如 vulkan/cuda 版） |
| 温度 | `--temp` | 采样温度 0~2 |
| `--mlock` | | 锁定内存避免交换 |
| `--no-mmap` | | 禁用内存映射 |
| 附加参数 | 任意 | 例如 `--no-warmup --cache-prompt --n-predict 2048` |

## 项目结构

```
llama.cpp\
├── llama-launcher.exe  # 打包版可执行文件（双击运行，脚本已内嵌）
├── 启动客户端.bat      # 源码方式入口（运行 llama-launcher.ps1）
├── llama-launcher.ps1  # 主程序源码（WinForms 桌面客户端 + WebView2 内嵌）
├── lib\                # WebView2 组件（Core.dll + WebView2Loader.dll）
├── build\              # exe 打包源码（launcher.cs、icon.ico），可重新编译
├── config.json         # 运行后自动生成：记住你的设置
├── logs\               # 运行后自动生成：server-out/err.log、client.log
└── README.md
```

## 打包与重新编译 exe

exe 是 C# 启动器（`build\launcher.cs`），把 `llama-launcher.ps1` 作为嵌入资源，运行时解出并调用 PowerShell 执行（-STA），`-AppDir` 指向 exe 所在目录，因此 `config.json` / `logs\` / `lib\` 都在 exe 旁边。重新编译：

```powershell
& 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe' /nologo /target:winexe `
  /out:llama-launcher.exe /win32icon:build\icon.ico `
  /resource:llama-launcher.ps1,LauncherScript `
  /r:System.Windows.Forms.dll /r:System.Drawing.dll build\launcher.cs
```

exe 支持透传命令行参数，例如：`llama-launcher.exe -SelfTest -LlamaDir ... -Model ... -Port 18100`。

## 命令行 / 自检

```powershell
# 无界面自检：验证 llama-server 启动、健康检查、内置 WebUI、对话接口、WebView2 运行时
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\llama-launcher.ps1 -SelfTest `
  -LlamaDir "F:\AI\llama-b10472-bin-win-vulkan-x64" `
  -Model "F:\AI\models\xxx\model-Q4_K_M.gguf" `
  -Mmproj "F:\AI\models\xxx\mmproj.gguf" -Port 18100
```

## 常见问题

- **提示未找到 llama-server.exe**：llama.cpp 目录里需要有 `llama-server.exe`（在根目录或 `bin\` 子目录）。
- **启动后一直「加载模型…」**：首次加载大模型需要时间；若超时请查看「② 运行日志」是否有端口占用或显存不足提示。
- **WebUI 页显示 HTTP 错误（如 415/404）**：该 llama-server 版本可能没有内置 WebUI，可在「附加参数」里手动加 `--path <webui目录>` 自行处理。
- **WebUI 标签提示"WebView2 组件缺失"**：`lib\` 目录被删或损坏；恢复后重启客户端。嵌入失败时可用「在浏览器中打开」按钮，功能一致。
- **Qwen-VL 类多模态模型图片理解不准**：可在「附加参数」里加 `--image-min-tokens 1024`。
- **想打包成独立 exe**：可自行安装 `ps2exe` 模块后执行：
  `ps2exe .\llama-launcher.ps1 llama-launcher.exe -noConsole`（需联网安装模块）。

## 备注

- 客户端本身**不下载任何东西**：只负责配置参数、拉起 llama-server、嵌入 WebUI。
- 嵌入内核是系统 WebView2（Chromium），内置 WebUI 的全部功能与浏览器打开完全一致。
- 注意：llama-server 内置 WebUI 要求客户端支持 **gzip**（浏览器/WebView2 默认支持；命令行 curl 需加 `--compressed`）。
