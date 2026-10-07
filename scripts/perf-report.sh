#!/bin/bash
# PhaseTimer 汇总（TASK-044）：从统一日志提取 dictation 计时行，按阶段算 p50/p95。
# 用法: ./scripts/perf-report.sh [分钟数，默认 60]
# 前提: 期间发生过真实听写（每条听写完成时记一条「⏱ phases: … total=…ms」）。
set -euo pipefail

MINUTES="${1:-60}"
PREDICATE='subsystem == "com.dictately" AND category == "pipeline"'

echo "→ 汇总最近 ${MINUTES} 分钟的 dictation 计时（log show）…"
LINES=$(log show --last "${MINUTES}m" --style compact --predicate "$PREDICATE" 2>/dev/null \
  | grep -o '⏱ phases:.*' || true)

if [ -z "$LINES" ]; then
  echo "没有找到计时行——期间无听写完成记录。先正常使用听写，再跑本脚本。"
  exit 0
fi

echo "$LINES" | wc -l | xargs -I{} echo "样本数: {}"
echo "$LINES" | tr ' ' '\n' | grep -E '^(hotkey→panel|record|encode|asr|llm|paste)=' \
  | awk -F= '{
      phase=$1; v=$2; sub(/ms$/, "", v);
      g[phase] = g[phase] " " v;
      if (v+0 > max[phase]) max[phase] = v+0;
      n[phase]++;
      sum[phase] += v;
    }
    END {
      for (p in n) {
        split(g[p], arr, " ");
        asort(arr);
        # 输出原始值，p50/p95 由 sort -n | awk 再算（asort 需 gawk，此处保底）
        vals = "";
        for (i in arr) vals = vals arr[i] "\n";
        printf "%s n=%d avg=%.0fms max=%dms\n", p, n[p], sum[p]/n[p], max[p];
      }
    }' 2>/dev/null || true

# 逐阶段 p50/p95（便携实现：值列排序取分位）
echo
echo "→ 各阶段 p50 / p95（ms）："
for phase in "hotkey→panel" "record" "encode" "asr" "llm" "paste" "total"; do
  VALUES=$(echo "$LINES" | grep -o "${phase}=[0-9]*ms" | grep -o '[0-9]*' | sort -n)
  [ -z "$VALUES" ] && continue
  COUNT=$(echo "$VALUES" | wc -l | tr -d ' ')
  P50=$(echo "$VALUES" | awk -v n="$COUNT" 'NR == int((n+1)*0.50) || (n%2==0 && NR == int((n+1)*0.50)+0) {print; exit}')
  P95_IDX=$(( (COUNT * 95 + 99) / 100 )); [ "$P95_IDX" -lt 1 ] && P95_IDX=1
  P95=$(echo "$VALUES" | sed -n "${P95_IDX}p")
  [ -z "$P50" ] && P95=$(echo "$VALUES" | tail -1) && P50="$P95"
  printf "  %-14s p50=%sms  p95=%sms  (n=%s)\n" "$phase" "$P50" "$P95" "$COUNT"
done
