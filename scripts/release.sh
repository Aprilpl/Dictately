#!/bin/bash
# Dictately 发布管线（TASK-148，Sparkle 自动更新）：
#   build.sh Release → package-dmg.sh → 更新包 zip → generate_appcast → gh release
# 产物：dist/Dictately-<版本>-<架构>.dmg（人工安装）+ dist/sparkle/…zip（Sparkle 更新包，
# EdDSA 签名进 appcast）+ 仓库根 appcast.xml（提交入库，经公开快照发布到
# raw.githubusercontent.com——SUFeedURL 指向处）。
# 前置：Info.plist 版本已手写更新（单一事实源）+ 已提交并打 tag v<版本>。
# 用法: ./scripts/release.sh
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Dictately.app"
REPO="Aprilpl/Dictately"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

# ── 版本与 tag 校验（tag 是刻意的发布动作，脚本不代打）──────────────────────
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Dictately/Info.plist)"
TAG="v${VERSION}"
if ! git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "✗ 缺 git tag ${TAG}——先提交版本变更并打 tag：git tag ${TAG}"
  exit 1
fi
echo "→ 发布 ${TAG}（Info.plist 版本 ${VERSION}）"

# ── 构建（§42：发布构建 = Release，收尾刷回 Debug）────────────────────────
./scripts/build.sh Release

# DMG（人工安装通道，命名/布局见 package-dmg.sh）
./scripts/package-dmg.sh

ARCH="$(lipo -archs "$APP/Contents/MacOS/Dictately")"
[ "$(printf '%s' "$ARCH" | wc -w)" -gt 1 ] && ARCH="universal"
ZIP_BASE="Dictately-${VERSION}-${ARCH}"
ZIP="dist/sparkle/${ZIP_BASE}.zip"

# ── Sparkle 更新包 zip（ditto 保符号链接与 bundle 结构，普通 zip 会打平）────
mkdir -p dist/sparkle
echo "→ 生成更新包 ${ZIP}"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# 发布说明（可选）：dist/release-notes-v<版本>.md → 与 zip 同名 .md 才会被
# generate_appcast 关联为该项的内置发布说明
if [ -f "dist/release-notes-v${VERSION}.md" ]; then
  cp "dist/release-notes-v${VERSION}.md" "dist/sparkle/${ZIP_BASE}.md"
fi

# appcast 历史回种：dist/ 是 gitignore 中间产物，被清空后用仓库根 appcast.xml
# 恢复旧条目（签名随条目保留），本次新版本在其上追加
if [ -f appcast.xml ] && [ ! -f dist/sparkle/appcast.xml ]; then
  cp appcast.xml dist/sparkle/appcast.xml
fi

# ── appcast 生成（EdDSA 私钥在登录钥匙串，首次可能弹钥匙串授权框→始终允许）──
echo "→ generate_appcast（私钥读登录钥匙串）"
"${SPARKLE_BIN}/generate_appcast" \
  --download-url-prefix "https://github.com/${REPO}/releases/download/${TAG}/" \
  --full-release-notes-url "https://github.com/${REPO}/releases/tag/${TAG}" \
  --link "https://github.com/${REPO}/releases" \
  dist/sparkle/

# appcast 落仓库根（提交入库 → §46 公开快照携带 → raw.githubusercontent 生效）
cp dist/sparkle/appcast.xml appcast.xml
echo "✓ appcast.xml 已更新（仓库根，待提交）"

# ── GitHub Release（资产名 = 文件名，与 appcast 下载 URL 一致）─────────────
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  NOTES_ARGS=(--generate-notes)
  [ -f "dist/release-notes-v${VERSION}.md" ] && NOTES_ARGS=(--notes-file "dist/release-notes-v${VERSION}.md")
  echo "→ gh release create ${TAG}"
  gh release create "${TAG}" \
    "dist/Dictately-${VERSION}-${ARCH}.dmg" "${ZIP}" \
    --title "Dictately ${VERSION}" "${NOTES_ARGS[@]}"
else
  echo "⚠ gh 未安装或未登录——手动发布："
  echo "  gh release create ${TAG} dist/Dictately-${VERSION}-${ARCH}.dmg ${ZIP} --title 'Dictately ${VERSION}'"
fi

# ── 刷回 Debug（§42：发布构建后本地交付物恢复 Debug 形态）──────────────────
./scripts/build.sh Debug >/dev/null

echo "✓ 发布产物就绪：${TAG}"
echo "  · dist/Dictately-${VERSION}-${ARCH}.dmg / ${ZIP}"
echo "  · appcast.xml（仓库根）——记得提交并走 §46 公开快照三步"
echo "  · EdDSA 私钥在登录钥匙串（勿删勿丢；备份/恢复/丢失应对见 docs/release.md）"
