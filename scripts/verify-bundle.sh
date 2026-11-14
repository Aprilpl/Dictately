#!/bin/bash
# 发布泄漏门禁（TASK-162 抽出，TASK-192）：整个 .app 递归扫描构建机身份串。
# 用法: verify-bundle.sh <app> <build-root>
set -euo pipefail

APP="${1:?usage: verify-bundle.sh <app> <build-root>}"
ROOT="${2:?usage: verify-bundle.sh <app> <build-root>}"
[ -d "${APP}" ] || { echo "✗ 门禁目标不存在：${APP}"; exit 1; }

if grep -raq -F "${ROOT}" -- "${APP}"; then
  echo "✗ 泄漏门禁：${APP} 内仍有文件包含构建机路径 ${ROOT}——检查资源/嵌套产物"; exit 1
fi
if [ -n "${USER:-}" ] && grep -raq -F "${USER}" -- "${APP}"; then
  echo "✗ 泄漏门禁：${APP} 内仍有文件包含构建机用户名 ${USER}"; exit 1
fi

# 真实邮箱身份门禁（TASK-196）：本机真实 Gmail 的 local part 在整包内零命中。
# 不能直接全包禁 "@gmail.com"——打包的 CPython Runtime 自带上游贡献者邮箱；
# 因此只允许第三方 Runtime 目录内出现 "@gmail.com"，其余位置零命中。
IDENTITY_LOCAL="imlpliang"
RUNTIME_DIR="${APP}/Contents/Resources/Runtime"

if grep -raq -F "${IDENTITY_LOCAL}" -- "${APP}"; then
  echo "✗ 泄漏门禁：${APP} 内仍有文件包含真实邮箱标识 ${IDENTITY_LOCAL}："
  grep -ral -F "${IDENTITY_LOCAL}" -- "${APP}" | sed 's|^|  |'
  exit 1
fi
GMAIL_OUTSIDE="$(grep -ral -F "@gmail.com" -- "${APP}" 2>/dev/null | grep -v -F "${RUNTIME_DIR}/" || true)"
if [ -n "${GMAIL_OUTSIDE}" ]; then
  echo "✗ 泄漏门禁：${APP} 内（第三方 Runtime 之外）出现 @gmail.com 地址："
  printf '%s\n' "${GMAIL_OUTSIDE}" | sed 's|^|  |'
  exit 1
fi

echo "→ 泄漏门禁通过（无构建机路径/用户名/真实邮箱身份）"
