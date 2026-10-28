#!/bin/bash
# Dictately 构建脚本（CLT-only：不需要 Xcode，只要 Swift 工具链 = Command Line Tools）
# 流程：swift build → 手工拼装 .app bundle（含 Sparkle framework 嵌入）→ 稳定身份签名
# 用法: ./scripts/build.sh [Debug|Release]
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="$(echo "${1:-Debug}" | tr '[:upper:]' '[:lower:]')"
APP="build/Dictately.app"

echo "→ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"
BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"

echo "→ 拼装 ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/Dictately" "${APP}/Contents/MacOS/Dictately"
cp Dictately/Info.plist "${APP}/Contents/Info.plist"

# 构建机路径脱敏（TASK-162）：Swift `#filePath` 字面量会把 $PWD 绝对路径（含用户名
# 与目录结构）编译进二进制——实测 GRDB 的运行时错误路径参数在 Release 主二进制留有
# 31 处（`-file-prefix-map` 只重映射 debug info、对此字面量无效，已实验排除）。codesign
# 前做**等长**字节替换（等长 = 不改任何 Mach-O 偏移，二进制安全；GRDB 仅将其用作错误
# 信息展示，功能零影响）。只处理自家构建产物主二进制；Sparkle/PBS 为官方预编译产物。
PWD_PAD="$(printf '/%*s' $((${#PWD}-1)) '' | tr ' ' '#')"
LC_ALL=C perl -pi -e "s|\Q${PWD}\E|${PWD_PAD}|g" "${APP}/Contents/MacOS/Dictately"

# 资源白名单散拷（TASK-161 双份收敛）：Resources/ 全量已经 SPM .process 进
# Dictately_Dictately.bundle（代码一律 AppResources.bundle 取——Phosphor 字体/
# Sounds/worker 脚本/MenuBarIcon/TestAudio 全部如此），Contents/Resources 根只散拷
# 必须在主 bundle 位置的两种：
# - AppIcon.icns：Info.plist CFBundleIconFile 引用，系统只查主 bundle Resources 根
# - Localizable.strings：macOS 标准本地化位置的兜底份（代码走 bundle，此份不供代码读）
# 其余资源不再向根目录散拷第二份（DMG 减重 ~1.4MB）。
for res in AppIcon.icns Localizable.strings; do
  [ -e "Dictately/Resources/${res}" ] && cp "Dictately/Resources/${res}" "${APP}/Contents/Resources/"
done

# SPM 资源 bundle（AppResources.bundle 运行时按此查找；Localizable.strings process 产物）。
# 只落位 Contents/Resources：.app 根目录放 bundle（目录或符号链接）都会被 codesign 以
# 「unsealed contents present in the bundle root」拒签（TASK-125 实测两态均 exit 1）；
# 异机可达性由代码侧定位器保证（Support/AppResources.swift 多候选查找，AGENTS §48）。
# bundle 缺失/落位失败一律硬报错，不走静默跳过（旧条件拷贝会静默产出异机必崩的包）。
SPM_BUNDLE="${BIN_DIR}/Dictately_Dictately.bundle"
[ -d "${SPM_BUNDLE}" ] || { echo "✗ swift build 产物缺 ${SPM_BUNDLE}（资源声明或构建异常）"; exit 1; }
cp -R "${SPM_BUNDLE}" "${APP}/Contents/Resources/"
[ -d "${APP}/Contents/Resources/Dictately_Dictately.bundle" ] || { echo "✗ Contents/Resources 落位失败：Dictately_Dictately.bundle"; exit 1; }

# Sparkle 自动更新 framework（TASK-148）：SPM 二进制产物（.build/artifacts 与构建
# 配置无关）嵌入 Contents/Frameworks。缺失一律硬报错（对齐 AppResources 纪律：
# 静默跳过 = 产出点了「检查更新」即崩的包）。
SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "${SPARKLE_FW}" ] || { echo "✗ SPM 产物缺 ${SPARKLE_FW}（swift package resolve 异常）"; exit 1; }
mkdir -p "${APP}/Contents/Frameworks"
cp -R "${SPARKLE_FW}" "${APP}/Contents/Frameworks/Sparkle.framework"
[ -d "${APP}/Contents/Frameworks/Sparkle.framework/Versions/B" ] || { echo "✗ Sparkle.framework 落位失败（Versions/B 缺失）"; exit 1; }

# rpath（§48 纪律）：swift build 链接 SPM 二进制目标只写 @loader_path 与 CLT 系统路径，
# 解析不到 ../Frameworks——分发形态必须显式补。改二进制作废签名，须在 codesign 之前。
# otool 输出先落变量再 grep（管道 grep -q 早退会 SIGPIPE × pipefail 误判）。
RPATH_LIST="$(otool -l "${APP}/Contents/MacOS/Dictately")"
if ! grep -q "path @loader_path/../Frameworks" <<<"${RPATH_LIST}"; then
  install_name_tool -add_rpath "@loader_path/../Frameworks" "${APP}/Contents/MacOS/Dictately"
fi

# 本地转写运行时（TASK-134）：python-build-standalone（PBS）打包进 .app——
# 用户裁决（2026-10-11）：中国用户全程不碰 GitHub，运行时随安装包分发；
# 用户机首次用本地模型只需 pip 装 mlx-audio（PyPI，失败自动切清华镜像）。
# 钉版本 + sha256；缓存 build/assets/（gitignore），已缓存即离线可构建。
PBS_TAG="20261009"
PBS_VER="3.13.16"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/cpython-${PBS_VER}%2B${PBS_TAG}-aarch64-apple-darwin-install_only.tar.gz"
PBS_SHA256="3338fcd572a670ec45ac9ef75480b95595ea9b6b5dd320952fcf5df185089941"
PBS_ARCHIVE="build/assets/pbs-cpython-${PBS_VER}.tar.gz"
mkdir -p build/assets
if [ ! -f "${PBS_ARCHIVE}" ] || [ "$(shasum -a 256 "${PBS_ARCHIVE}" | cut -d' ' -f1)" != "${PBS_SHA256}" ]; then
  echo "→ 下载 PBS Python ${PBS_VER}（${PBS_TAG}，约 25MB）"
  curl -fsSL -o "${PBS_ARCHIVE}" "${PBS_URL}"
  ACTUAL_SHA="$(shasum -a 256 "${PBS_ARCHIVE}" | cut -d' ' -f1)"
  [ "${ACTUAL_SHA}" = "${PBS_SHA256}" ] || { echo "✗ PBS 校验失败：${ACTUAL_SHA}"; exit 1; }
fi
# tar 内顶层为 python/ → 解到 Contents/Resources/Runtime/python（LocalRuntimeManager 定位处）
mkdir -p "${APP}/Contents/Resources/Runtime"
tar -xzf "${PBS_ARCHIVE}" -C "${APP}/Contents/Resources/Runtime"
[ -x "${APP}/Contents/Resources/Runtime/python/bin/python3" ] || { echo "✗ PBS 解压异常：Runtime/python/bin/python3 不存在"; exit 1; }
echo "→ PBS Python 已打入（Runtime/python，本地转写运行时）"

# 发布泄漏门禁（TASK-162，随路径脱敏配套）：全部文件落位后、签名前，对整个 .app
# 递归扫描构建机身份串（$PWD 含用户名与目录结构、$USER 兜底裸用户名）——任何文件
# 携带即硬失败。个人信息零外泄由结构保证，不靠人工记得。PBS Python 运行时自带
# CPython 开发者公开邮箱属官方产物内容，不在本门禁的 $PWD/$USER 特征面内。
if grep -raq -F "${PWD}" -- "${APP}"; then
  echo "✗ 泄漏门禁：${APP} 内仍有文件包含构建机路径 ${PWD}——检查资源/嵌套产物"; exit 1
fi
if [ -n "${USER:-}" ] && grep -raq -F "${USER}" -- "${APP}"; then
  echo "✗ 泄漏门禁：${APP} 内仍有文件包含构建机用户名 ${USER}"; exit 1
fi

# 签名：优先稳定身份（Dictately Dev 自签名证书——TCC 类授权跨编译有效；
# 但钥匙串弹窗按 cdhash 分区收紧、重建即复发，自签无解，见 AGENTS.md §30）。
# find-identity 对自签名证书的策略校验不可靠（显示 0 valid 但 codesign 可用），
# 故直接试签、失败回退。
# Sparkle（TASK-148）：嵌套代码自底向上逐个签名（XPC → Updater.app → framework → app）；
# SPM 分发的 framework 自带 adhoc 签名，--force 覆签为本地身份。
SPARKLE_XPC="${APP}/Contents/Frameworks/Sparkle.framework/XPCServices"
SIGN_IDENTITY="-"
if codesign --sign "Dictately Dev" --force --timestamp=none "${SPARKLE_XPC}/Installer.xpc" 2>/dev/null; then
  SIGN_IDENTITY="Dictately Dev"
  echo "→ codesign（Dictately Dev 稳定身份）"
else
  echo "⚠ codesign 回退 ad-hoc：钥匙串无「Dictately Dev」证书——TCC 授权（辅助功能/麦克风）将随每次重建失效、用户每次启动都要重新授权！重建证书配方见 AGENTS.md §30 追记（2026-10-10 实案：证书丢失后静默回退未被察觉，用户每次启动重新授权辅助功能）"
fi
SIGN_ARGS=(--sign "${SIGN_IDENTITY}" --force --timestamp=none)
codesign "${SIGN_ARGS[@]}" "${SPARKLE_XPC}/Installer.xpc"
codesign "${SIGN_ARGS[@]}" "${SPARKLE_XPC}/Downloader.xpc"
codesign "${SIGN_ARGS[@]}" "${APP}/Contents/Frameworks/Sparkle.framework/Updater.app"
codesign "${SIGN_ARGS[@]}" "${APP}/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" "${APP}"

echo "✓ 构建完成：${APP}"
echo "  运行：open ${APP}   （开发期裸跑：${BIN_DIR}/Dictately）"
