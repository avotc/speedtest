#!/bin/bash
# speedtest.sh —— 用 curl + pv 测下载速度，输出总体速度和逐秒波动
#
# 用法:
#   ./speedtest.sh [URL] [最长测试秒数]
#
# 示例:
#   ./speedtest.sh https://sgp.proof.ovh.net/files/10Gb.dat 30
#   （不传参数默认用下面 URL，默认最长测 30 秒就停，不用把 10GB 全下完）

set -euo pipefail

URL="${1:-https://sgp.proof.ovh.net/files/10Gb.dat}"
TIME_LIMIT="${2:-30}"   # 最长测速秒数，避免大文件一直下到底

if ! command -v pv >/dev/null 2>&1; then
    echo "缺少 pv 工具，请先安装：" >&2
    echo "  Debian/Ubuntu: sudo apt install -y pv" >&2
    echo "  CentOS/RHEL:   sudo yum install -y pv" >&2
    exit 1
fi

RAW_LOG=$(mktemp)
trap 'rm -f "$RAW_LOG"' EXIT

echo "======================================================"
echo "开始测速..."
echo "======================================================"
echo "目标: $URL"
echo "最长测速时长: ${TIME_LIMIT}s（到时间自动停止，不必等文件下完）"
echo

START=$(date +%s.%N)

# curl 把数据流交给 pv；pv 每秒把瞬时速率打印一次（用 \r 覆盖同一行），
# 重定向到 RAW_LOG 后按 \r 拆分即可拿到每一秒的采样。
# timeout 用来限制最长测试时间。
set +e
timeout "${TIME_LIMIT}s" curl -s "$URL" | pv -f -i 1 -r -b -t 2>"$RAW_LOG" >/dev/null
set -e

END=$(date +%s.%N)
ELAPSED=$(echo "$END - $START" | bc)

# ---- 解析 pv 的输出 ----
# 一行大概长这样: 123MiB 0:00:05 [24.6MiB/s]
# 把 \r 换成 \n 后逐行取最后一条记录的累计流量，以及每一条记录的瞬时速率
tr '\r' '\n' < "$RAW_LOG" | grep -E '\[.*B/s\]' > "${RAW_LOG}.lines" || true

TOTAL_BYTES_STR=$(tail -n1 "${RAW_LOG}.lines" | awk '{print $1}')
# pv -b 的累计流量单位可能是 B/KiB/MiB/GiB，这里统一转成 MB 展示
convert_to_mb() {
    local val="$1"
    python3 - "$val" <<'PYEOF' 2>/dev/null || echo "0"
import sys, re
s = sys.argv[1]
m = re.match(r'([\d.]+)\s*([A-Za-z]+)', s)
if not m:
    print("0"); sys.exit()
num, unit = float(m.group(1)), m.group(2)
mult = {"B":1/1024/1024, "KiB":1/1024, "MiB":1, "GiB":1024, "TiB":1024*1024}
print(round(num * mult.get(unit, 1), 2))
PYEOF
}

TOTAL_MB=$(convert_to_mb "$TOTAL_BYTES_STR")
AVG_MBPS=$(echo "scale=2; $TOTAL_MB * 8 / $ELAPSED" | bc)
AVG_MB_S=$(echo "scale=2; $TOTAL_MB / $ELAPSED" | bc)

# 每一秒的瞬时速率（[xx.x MiB/s] 里的数字），转换成 Mbps
SPEEDS_MBPS=()
while IFS= read -r line; do
    rate=$(echo "$line" | grep -oE '\[[0-9.]+[A-Za-z]+/s\]' | tail -1 | tr -d '[]')
    rate_num=$(echo "$rate" | grep -oE '^[0-9.]+')
    rate_unit=$(echo "$rate" | grep -oE '[A-Za-z]+/s$' | sed 's#/s##')
    mb=$(convert_to_mb "${rate_num}${rate_unit}")
    mbps=$(echo "scale=2; $mb * 8" | bc)
    SPEEDS_MBPS+=("$mbps")
done < "${RAW_LOG}.lines"
rm -f "${RAW_LOG}.lines"

MIN=$(printf '%s\n' "${SPEEDS_MBPS[@]}" | sort -n | head -1)
MAX=$(printf '%s\n' "${SPEEDS_MBPS[@]}" | sort -n | tail -1)

echo "======================================================"
printf "时间: %.2fs | 流量: %s MB | 速度: %s MB/s ( %s Mbps )\n" \
    "$ELAPSED" "$TOTAL_MB" "$AVG_MB_S" "$AVG_MBPS"

# 拼波动数组
FLUC=$(printf '%s Mbps, ' "${SPEEDS_MBPS[@]}")
FLUC="[${FLUC%, }]"
echo "波动: ${FLUC} (范围: ${MIN}-${MAX} Mbps)"
