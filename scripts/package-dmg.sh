#!/bin/bash
# Dictately DMG 打包：build/Dictately.app → dist/Dictately-<版本>-<架构>.dmg
# 布局沿用 2026-10-06 首包：卷根 = Dictately.app + Applications 符号链接（拖拽安装）。
# 文件名带架构后缀（2026-10-07 用户裁决）：从二进制 lipo -archs 现取（单架构直用、
# 多架构 → universal），将来出 Intel/Universal 包时用户不会下错。
# 用法: ./scripts/package-dmg.sh        # 前置：./scripts/build.sh Release
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Dictately.app"
VOL="Dictately"
OUT_DIR="dist"

[ -d "$APP" ] || { echo "✗ 未找到 ${APP}——先运行 ./scripts/build.sh Release"; exit 1; }

# 版本取自 Info.plist（单一事实源；升级只改 plist 一处）
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist")"

# 架构取自二进制（与产物实际内容一致，非构建机假设）；多架构 = universal
ARCH="$(lipo -archs "$APP/Contents/MacOS/Dictately")"
[ "$(printf '%s' "$ARCH" | wc -w)" -gt 1 ] && ARCH="universal"

DMG="$OUT_DIR/Dictately-$VERSION-$ARCH.dmg"

echo "→ 组装暂存目录（App + Applications 快捷方式，卷名 ${VOL}）"
STAGING="$(mktemp -d /tmp/Dictately-dmg.XXXX)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "→ 生成 ${DMG}（UDZO 压缩）"
mkdir -p "$OUT_DIR"
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGING" -format UDZO -ov "$DMG"

SIZE="$(du -h "$DMG" | cut -f1)"
echo "✓ 打包完成：${DMG}（${SIZE}）"
echo "  安装：打开 DMG → 把 Dictately 拖入 Applications"
