#!/bin/bash
# Dictately 构建脚本（CLT-only：不需要 Xcode，只要 Swift 工具链 = Command Line Tools）
# 流程：swift build → 手工拼装 .app bundle → ad-hoc 签名
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

# 拷贝型资源（存在才拷，TASK-003 起补齐 AppIcon.icns / Localizable.strings）
for res in Dictately/Resources/*; do
  [ -e "${res}" ] && cp -R "${res}" "${APP}/Contents/Resources/"
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

# 签名：优先稳定身份（Dictately Dev 自签名证书——TCC 类授权跨编译有效；
# 但钥匙串弹窗按 cdhash 分区收紧、重建即复发，自签无解，见 AGENTS.md §30）。
# find-identity 对自签名证书的策略校验不可靠（显示 0 valid 但 codesign 可用），
# 故直接试签、失败回退。
if codesign --sign "Dictately Dev" --force --timestamp=none "${APP}" 2>/dev/null; then
  echo "→ codesign（Dictately Dev 稳定身份）"
else
  echo "→ codesign（ad-hoc 自签；提示：创建 Dictately Dev 证书可让 TCC 类授权跨编译有效）"
  codesign --sign - --force --timestamp=none "${APP}"
fi

echo "✓ 构建完成：${APP}"
echo "  运行：open ${APP}   （开发期裸跑：${BIN_DIR}/Dictately）"
