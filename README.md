<div align="center">

<img src="Assets/icon.png" width="140" alt="Dictately" />

# Dictately

**说完，字就在。**

[English](README.en.md) · 简体中文

![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=macos&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-SPM-F05138?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)

macOS 原生语音听写工具：在任意 App 里按下快捷键说话，云端或本地离线转写、可选 AI 润色，文字 1–3 秒内自动粘贴到光标处。

</div>

---

## 核心特性

**听写**

- 默认**双击右 ⌘** 即录，不抢占当前 App 焦点；触发模式可换（双击 / 按住 / 切换），触发键与全部快捷键均可录制自定义
- 录音 HUD 悬浮于**光标所在屏幕**底部居中，实时计时；录音、转写与润色全程可 `Esc` 取消
- 文字送达方式可选：标准粘贴（`⌘V`，适配 QWERTY / Colemak / Dvorak / Optimot 键位布局）或「模拟按键」逐字输入——兼容不接受粘贴指令的输入框；文字始终同时复制到剪贴板
- 误触守卫：短于 300ms 的录音按取消静默收口，不会送出空请求
- 录音上限 90–300 秒可调（默认 240），到点自动收尾

**本地离线转写（可选）**

- 7 款开源模型 App 内直接下载（Qwen3-ASR / Whisper / BELLE Whisper 中文版三组），无需 API Key，**音频不出本机**
- ModelScope / HuggingFace 双下载渠道，断点续传，失败可换渠道重试；模型卡附实测质量 / 速度 / 内存数据，按需选择
- 常驻引擎即点即转，空闲 5 分钟自动卸载内存；状态条实时显示 CPU 与内存占用

**AI 风格**

- 三种内置风格，一键把「转写」变「成品」：
  - `⌘1` **意图识别** —— 口语转写重构为规范、凝练的书面文本
  - `⌘2` **口语润色** —— 保留自然口语风格，只去语气词与杂音
  - `⌘3` **中英互译** —— 理顺后在中英文之间互译，保留原意
- 可自建风格：自定义 Prompt 模板（`{text}` 占位符）、描述、启用开关、专属快捷键

**历史与可靠性**

- 转写 / 润色结果与音频全部入库（本地 SQLite），支持筛选、搜索、多选批量删除
- 失败可救：网络错误自动重试一次；听写条目可「重新转写」，风格条目可「重新生成」——转写已完成的仅重跑润色，未完成的自动从音频补全转写再润色
- **使用统计**：今天 / 近 7 天 / 近 30 天 / 全部四时段的条数、时长、字数、语速与日均，听写与 AI 风格的工作模式分布，并按可调的手打速度估算为你省下的时间

**云端供应商 BYOK（自带 Key）**

- 听写引擎 5 家、AI 服务 6 家（见下文），Key 按供应商分账户存入 **macOS Keychain**；使用本地离线引擎则完全无需 Key
- 推理思考默认**关闭且真正生效**（按各家 API 显式下发关闭参数，而非省略了事）
- 温度等参数默认不携带脏值，留空即用默认

**细节**

- 浅色 / 深色 / 跟随系统三态外观
- 可选：开录 / 停录效果音、录音时系统静音、API 请求日志、状态栏常驻图标、隐藏 Dock 图标、登录启动
- 无账号、无埋点、无遥测

## 界面预览

| 听写模型 · API（深色） | 听写模型 · 本地模型（浅色） | AI 服务（深色） |
| :---: | :---: | :---: |
| ![听写模型 API 页](Assets/ui-models-dark.png) | ![本地离线模型页](Assets/ui-local-models-light.png) | ![AI 服务设置页](Assets/ui-ai-dark.png) |
| **常规设置（浅色）** | **使用统计（深色）** | **快捷键（深色）** |
| ![常规设置页](Assets/ui-general-light.png) | ![使用统计页](Assets/ui-stats-dark.png) | ![快捷键页](Assets/ui-hotkeys-dark.png) |

## 下载安装

从 [Releases](../../releases) 下载最新 DMG，双击挂载后将 Dictately 拖入「应用程序」。

**首次打开（重要）**：Dictately 采用自签证书（非 Apple 认可的开发者证书）、未经 Apple 公证，首次打开会被 Gatekeeper 拦截，任选其一放行：

- 在「应用程序」中**右键 Dictately → 打开 → 再次点「打开」**；
- 或 系统设置 → 隐私与安全性 → 拉到底点「仍要打开」；
- 或在终端执行：

  ```bash
  xattr -d com.apple.quarantine /Applications/Dictately.app
  ```

首次启动有两步引导：授权麦克风 → 授权辅助功能。转写服务的 API Key 随后在「听写模型」设置页配置（未配置时页面有橙 chip 与横幅提示）。

### 应用内更新

「关于」页的**检查更新**会在 App 内完成整个升级：检查新版本 → 自动下载 → 安装并重启（更新包经 EdDSA 签名校验，由 [Sparkle](https://sparkle-project.org) 安装，**更新后的版本无需再次 Gatekeeper 放行**；手动下载 DMG 覆盖安装才需重复放行）。更新只手动触发，应用不会在后台自动检查。早期 0.1.x 版本不含更新器，需手动下载一次新版本 DMG。

### 系统要求

- macOS 14（Sonoma）及以上
- Apple Silicon Mac（M1 及之后；当前发布包为 arm64 架构，本地离线转写依赖 MLX 也仅支持 Apple Silicon）
- 云端转写需至少一家听写供应商的 API Key（部分供应商提供免费额度）；或使用本地离线转写，无需任何 Key（首次使用需联网安装约 500MB 推理依赖并下载所选模型）

### 系统权限

| 权限 | 用途 |
| --- | --- |
| 麦克风 | 录制语音；音频仅发送给你配置的转写服务 |
| 辅助功能 | 全局快捷键监听；把文字粘贴进当前 App（模拟 ⌘V） |

## 听写供应商（ASR）

云端听写 5 家 + 本地离线引擎（见上文本地离线转写）：

| 供应商 | 默认模型 | 说明 |
| :--- | :--- | :--- |
| QwenAI API | `qwen-audio-3.1-asr-flash` | 支持即时热词（≤50 条）、语言提示、方言保留 |
| OpenAI | `gpt-4o-transcribe` | OpenAI 兼容端点 |
| Groq | `whisper-large-v3-turbo` | OpenAI 兼容端点 |
| Mistral | `voxtral-mini-latest` | OpenAI 兼容端点 |
| 自定义端点 | — | 任意 OpenAI 兼容 `/audio/transcriptions`（放行 http，便于本地服务） |

## AI 服务供应商（LLM）

**DeepSeek**（默认）· **QwenAI** · **OpenCode** · **OpenRouter** · **OpenAI** · **自定义端点**

每家独立保存 Base URL / 模型 / API Key；模型可从预设下拉选择，也可填自定义模型 ID。

## 隐私与数据

- **API Key 仅存于 macOS Keychain**，按供应商分账户，不上传任何服务器
- **本地离线转写全程在本机完成**，音频与文字都不出本机
- 历史与音频全部本地：`~/Library/Application Support/Dictately/`（常规设置 → 数据文件夹 可一键打开）
- 音频保留期可选 30 天（默认）/ 90 天 / 永久
- 可选的 **API 请求日志**（默认开启，可在常规设置关闭）：一行一请求，仅记端点、耗时与结果等元数据，**API Key 恒脱敏**，5MB 自动轮转
- 除你配置的云端 ASR / LLM 端点、模型下载渠道（ModelScope / HuggingFace）与应用内更新检查（GitHub）外，应用不产生任何外发流量

## 从源码构建

依赖：macOS 14+ 与 Xcode Command Line Tools（`xcode-select --install`）。**不需要完整 Xcode**——SwiftPM 直构，第三方运行时依赖为 [GRDB.swift](https://github.com/groue/GRDB.swift)（SQLite 封装）与 [Sparkle 2](https://github.com/sparkle-project/Sparkle)（应用内更新）。

```bash
git clone https://github.com/Aprilpl/Dictately.git
cd Dictately
./scripts/build.sh          # swift build → 拼装 build/Dictately.app → 签名
open build/Dictately.app    # 运行
```

> 注：出于维护策略，公开仓库不包含单元测试目录，`swift build` 与 `./scripts/build.sh` 不受影响。

## 已知边界

- 本地离线转写首次使用需联网安装推理依赖（约 500MB）并下载所选模型（每款约 42MB–1GB）；各模型的能力差异（如 Whisper 系列无标点）在设置页模型卡有说明。
- Intel Mac 未在支持与测试范围内（当前发布包仅 arm64 / Apple Silicon）。
- 应用未做 Apple 公证：手动下载 DMG 安装/覆盖后首次打开需重复一次 Gatekeeper 放行（App 内自动更新不受影响，见「应用内更新」）。

## 许可证

[MIT](LICENSE) © 2026 Aprilpl
