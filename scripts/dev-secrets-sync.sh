#!/bin/bash
# 一次性迁移：Keychain（服务 Dictately）→ 开发旁路 secrets.json（TASK-131）。
#
# 用途：开发期只跑 build/Dictately.app（defaults 开关 devSecretsBypass 开启
# FileSecretStore 旁路）后，把既有 Keychain 里的 API Key 搬进 secrets.json，
# 避免在设置页逐家重录。幂等：可反复跑，已有账户覆盖、缺失跳过。
#
# 纪律（AGENTS.md 硬约束 #6）：Key 值绝不回显——只打印账户名与长度。
# 预期：逐条读取可能弹钥匙串授权框（输开机密码点「始终允许」），属一次性过渡。
set -euo pipefail

SERVICE="Dictately"
TARGET="$HOME/Library/Application Support/Dictately/secrets.json"
ACCOUNTS=(
  asr.apiKey asr.apiKey.openai asr.apiKey.groq asr.apiKey.mistral asr.apiKey.custom
  llm.apiKey llm.apiKey.openai llm.apiKey.zhipu llm.apiKey.bailian
  llm.apiKey.openrouter llm.apiKey.opencode llm.apiKey.custom
)

mkdir -p "$(dirname "$TARGET")"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

for acct in "${ACCOUNTS[@]}"; do
  val="$(security find-generic-password -s "$SERVICE" -a "$acct" -w 2>/dev/null)" || continue
  [ -n "$val" ] || continue
  printf '%s\t%s\n' "$acct" "$val" >>"$TMP"
  echo "  ✓ $acct (len=${#val})"
done

if [ ! -s "$TMP" ]; then
  echo "未读到任何钥匙串条目（可能均已迁移或未配置）——$TARGET 未改动。"
  exit 0
fi

python3 - "$TMP" "$TARGET" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
pairs = {}
for line in open(src):
    if "\t" in line:
        account, value = line.rstrip("\n").split("\t", 1)
        pairs[account] = value
merged = {}
if os.path.exists(dst):
    try:
        with open(dst) as f:
            merged = json.load(f)
    except Exception:
        merged = {}
merged.update(pairs)
with open(dst, "w") as f:
    json.dump(merged, f, ensure_ascii=False, indent=2, sort_keys=True)
os.chmod(dst, 0o600)
PY

echo "✓ 已写入 $TARGET（0600，$(wc -l <"$TMP" | tr -d ' ') 个账户）"
echo "  打包 App 旁路开关：defaults write com.dictately.Dictately devSecretsBypass -bool true"
echo "  关闭开发旁路（恢复 Keychain）：defaults delete com.dictately.Dictately devSecretsBypass"
