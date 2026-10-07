<div align="center">

<img src="Assets/icon.png" width="140" alt="Dictately" />

# Dictately

**说完，字就在。**

[English](README.en.md) · 简体中文

![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=macos&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-SPM-F05138?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)

macOS 原生语音听写工具：在任意 App 里按下快捷键说话，云端转写、可选 AI 润色，文字 1–3 秒内自动粘贴到光标处。

</div>

---

## 核心特性

**听写**

- 默认**双击右 ⌘** 即录，不抢占当前 App 焦点；触发模式可换（双击 / 按住 / 切换），触发键与全部快捷键均可录制自定义
- 录音 HUD 悬浮于**光标所在屏幕**底部居中，实时计时；`Esc` 随时取消
- 误触守卫：短于 300ms 的录音按取消静默收口，不会送出空请求
- 录音上限 90–300 秒可调（默认 240），到点自动收尾

**AI 风格**

- 三种内置风格，一键把「转写」变「成品」：
  - `⌘1` **意图识别** —— 口语转写重构为规范、凝练的书面文本
  - `⌘2` **口语润色** —— 保留自然口语风格，只去语气词与杂音
  - `⌘3` **中英互译** —— 理顺后在中英文之间互译，保留原意
- 可自建风格：自定义 Prompt 模板（`{text}` 占位符）、描述、启用开关、专属快捷键

**历史与可靠性**

- 转写 / 润色结果与音频全部入库（本地 SQLite），支持筛选、搜索、多选批量删除
- 失败可救：网络错误自动重试一次；听写条目可「重新转写」，风格条目可「重新生成」（对原文重跑润色）
- 异常退出后的未收尾录音，下次启动提供**孤儿恢复**入口

**多供应商 BYOK（自带 Key）**

- 听写引擎 5 家、AI 服务 7 家（见下文），Key 按供应商分账户存入 **macOS Keychain**
- 推理思考默认**关闭且真正生效**（按各家 API 显式下发关闭参数，而非省略了事）
- 温度等参数默认不携带脏值，留空即用默认

**细节**

- 浅色 / 深色 / 跟随系统三态外观
- 可选：开录 / 停录效果音、录音时系统静音、自动复制剪贴板、状态栏常驻图标、隐藏 Dock 图标、登录启动
- 无账号、无埋点、无遥测

## 界面预览

| 听写模型（浅色） | AI 服务（深色） |
| :---: | :---: |
| ![听写模型设置页](Assets/ui-models-light.png) | ![AI 服务设置页](Assets/ui-ai-dark.png) |

## 下载安装

从 [Releases](../../releases) 下载最新 DMG，双击挂载后将 Dictately 拖入「应用程序」。

**首次打开（重要）**：Dictately 采用 ad-hoc 签名（无开发者证书）、未经 Apple 公证，首次打开会被 Gatekeeper 拦截，任选其一放行：

- 在「应用程序」中**右键 Dictately → 打开 → 再次点「打开」**；
- 或 系统设置 → 隐私与安全性 → 拉到底点「仍要打开」；
- 或在终端执行：

  ```bash
  xattr -d com.apple.quarantine /Applications/Dictately.app
  ```

首次启动有两步引导：授权麦克风 → 授权辅助功能。转写服务的 API Key 随后在「听写模型」设置页配置（未配置时页面有橙 chip 与横幅提示）。

### 系统要求

- macOS 14（Sonoma）及以上
- Apple Silicon Mac（M1 及之后；当前发布包为 arm64 架构）
- 至少一家听写供应商的 API Key（部分供应商提供免费额度）

### 系统权限

| 权限 | 用途 |
| --- | --- |
| 麦克风 | 录制语音；音频仅发送给你配置的转写服务 |
| 辅助功能 | 全局快捷键监听；把文字粘贴进当前 App（模拟 ⌘V） |

## 听写供应商（ASR）

| 供应商 | 默认模型 | 说明 |
| --- | --- | --- |
| QwenAI API | `qwen-audio-3.1-asr-flash` | 支持即时热词（≤50 条）、语言提示、方言保留 |
| OpenAI | `gpt-4o-transcribe` | OpenAI 兼容端点 |
| Groq | `whisper-large-v3-turbo` | OpenAI 兼容端点 |
| Mistral | `voxtral-mini-latest` | OpenAI 兼容端点 |
| 自定义端点 | — | 任意 OpenAI 兼容 `/audio/transcriptions`（放行 http，便于本地服务） |

## AI 服务供应商（LLM）

**DeepSeek**（默认）· **阿里云百炼** · **智谱 GLM** · **OpenCode** · **OpenRouter** · **OpenAI** · **自定义端点**

每家独立保存 Base URL / 模型 / API Key；模型可从预设下拉选择，也可填自定义模型 ID。

## 隐私与数据

- **API Key 仅存于 macOS Keychain**，按供应商分账户，不上传任何服务器
- 历史与音频全部本地：`~/Library/Application Support/Dictately/`（常规设置 → 数据文件夹 可一键打开）
- 音频保留期可选 30 天（默认）/ 90 天 / 永久
- 除你配置的 ASR / LLM 端点外，应用不产生任何外发流量

## 从源码构建

依赖：macOS 14+ 与 Xcode Command Line Tools（`xcode-select --install`）。**不需要完整 Xcode**——SwiftPM 直构，唯一第三方依赖 [GRDB.swift](https://github.com/groue/GRDB.swift)。

```bash
git clone https://github.com/Aprilpl/Dictately.git
cd Dictately
./scripts/build.sh          # swift build → 拼装 build/Dictately.app → 签名
open build/Dictately.app    # 运行
```

> 注：出于维护策略，公开仓库不包含单元测试目录，`swift build` 与 `./scripts/build.sh` 不受影响。

## 已知边界

- 本地离线转写模型尚未提供（设置页对应分段仅含说明卡，无假开关）。
- Intel Mac 未在支持与测试范围内（当前发布包仅 arm64 / Apple Silicon）。
- 应用未做 Apple 公证，版本更新后首次打开需重复一次 Gatekeeper 放行。

## 许可证

[MIT](LICENSE) © 2026 Aprilpl
