#!/bin/bash
# 构建机路径脱敏（TASK-162 抽出，TASK-192）：把二进制里的构建根路径做**等长**字节
# 替换（等长 = 不改 Mach-O 偏移；GRDB #filePath 仅用于错误信息展示，功能零影响）。
# 用法: redact-build-paths.sh <build-root> <binary> [--dry-run]
set -euo pipefail

ROOT="${1:?usage: redact-build-paths.sh <build-root> <binary> [--dry-run]}"
BIN="${2:?usage: redact-build-paths.sh <build-root> <binary> [--dry-run]}"
MODE="${3:-}"
[ -f "${BIN}" ] || { echo "✗ 脱敏目标不存在：${BIN}"; exit 1; }

COUNT="$( { LC_ALL=C grep -a -o -F "${ROOT}" "${BIN}" || true; } | wc -l | tr -d ' ')"
if [ "${MODE}" = "--dry-run" ]; then
  echo "dry-run：${BIN} 含构建根路径 ${COUNT} 处"
  exit 0
fi
if [ "${COUNT}" -eq 0 ]; then
  echo "→ 路径脱敏：0 处（无需替换）"
  exit 0
fi

BEFORE_SIZE="$(stat -f%z "${BIN}")"
BEFORE_MD5="$(md5 -q "${BIN}")"
PAD="$(printf '/%*s' $((${#ROOT}-1)) '' | tr ' ' '#')"
LC_ALL=C perl -pi -e "s|\Q${ROOT}\E|${PAD}|g" "${BIN}"
AFTER_SIZE="$(stat -f%z "${BIN}")"
AFTER_MD5="$(md5 -q "${BIN}")"

[ "${BEFORE_SIZE}" = "${AFTER_SIZE}" ] || {
  echo "✗ 脱敏后大小变化：${BEFORE_SIZE} → ${AFTER_SIZE}（等长约束被破坏）"; exit 1; }
REMAIN="$( { LC_ALL=C grep -a -o -F "${ROOT}" "${BIN}" || true; } | wc -l | tr -d ' ')"
[ "${REMAIN}" -eq 0 ] || { echo "✗ 脱敏后仍残留 ${REMAIN} 处构建根路径"; exit 1; }
echo "→ 路径脱敏：${COUNT} 处（${BEFORE_MD5} → ${AFTER_MD5}，大小 ${AFTER_SIZE} 不变）"
