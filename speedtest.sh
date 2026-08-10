#!/bin/bash
# speedtest.sh —— 用 curl + pv 测下载速度，输出总体速度和逐秒波动
# 依赖: curl, pv, awk（脚本会自动检测并尝试自动安装缺失的 pv）
#
# 用法:
#   ./speedtest.sh [URL] [最长测试秒数]
#
# 示例:
#   ./speedtest.sh https://sgp.proof.ovh.net/files/10Gb.dat 30
#   （不传参数默认用下面 URL，默认最长测 30 秒就停，不用把大文件全下完）

set -euo pipefail

URL="${1:-https://sgp.proof.ovh.net/files/10Gb.dat}"
TIME_LIMIT="${2:-30}"   # 最长测速秒数，避免大文件一直下到底；传 0 表示不限时，一直下到文件完整下载完

# ---------------------------------------------------------------------------
# 自动安装缺失依赖
# ---------------------------------------------------------------------------

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    fi
fi

install_pkg() {
    local pkg="$1"
    echo "正在尝试自动安装依赖: $pkg ..." >&2

    if command -v pkg >/dev/null 2>&1 && [ -d "${PREFIX:-/data/data/com.termux/files/usr}" ]; then
        # Termux（安卓），没有 sudo，直接用 pkg
        pkg install -y "$pkg"
    elif command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -qq && $SUDO apt-get install -y "$pkg"
    elif command -v apt >/dev/null 2>&1; then
        $SUDO apt update -qq && $SUDO apt install -y "$pkg"
    elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y "$pkg"
    elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y "$pkg"
    elif command -v pacman >/dev/null 2>&1; then
        $SUDO pacman -Sy --noconfirm "$pkg"
    elif command -v apk >/dev/null 2>&1; then
        $SUDO apk add --no-cache "$pkg"
    elif command -v zypper >/dev/null 2>&1; then
        $SUDO zypper install -y "$pkg"
    elif command -v brew >/dev/null 2>&1; then
        brew install "$pkg"
    else
        echo "找不到可用的包管理器，无法自动安装 $pkg，请手动安装后重试。" >&2
        return 1
    fi
}

ensure_cmd() {
    local cmd="$1"
    local pkg="${2:-$1}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        if ! install_pkg "$pkg"; then
            echo "自动安装 $pkg 失败，请手动安装：" >&2
            echo "  Termux:        pkg install $pkg" >&2
            echo "  Debian/Ubuntu: sudo apt install -y $pkg" >&2
            echo "  CentOS/RHEL:   sudo yum install -y $pkg" >&2
            echo "  macOS:         brew install $pkg" >&2
            exit 1
        fi
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "已尝试安装 $pkg，但仍未检测到 $cmd 命令，请手动检查安装情况。" >&2
            exit 1
        fi
    fi
}

ensure_cmd curl
ensure_cmd pv
ensure_cmd awk

# ---------------------------------------------------------------------------
# 测速主流程
# ---------------------------------------------------------------------------

RAW_LOG=$(mktemp)
trap 'rm -f "$RAW_LOG" "${RAW_LOG}.lines"' EXIT

echo "======================================================"
echo "开始测速..."
echo "======================================================"
echo "目标: $URL"
if [ "$TIME_LIMIT" = "0" ]; then
    echo "最长测速时长: 不限时（会一直下到文件完整下载完）"
else
    echo "最长测速时长: ${TIME_LIMIT}s（到时间自动停止，不必等文件下完）"
fi
echo

START=$(date +%s.%N)

# curl 把数据流交给 pv；pv 每秒把瞬时速率打印一次（用 \r 覆盖同一行），
# 重定向到 RAW_LOG 后按 \r 拆分即可拿到每一秒的采样。
# timeout 用来限制最长测试时间。加 -S 让 curl 即使在 -s 静默模式下也会把真正的错误信息打出来，
# 方便区分「正常测完」和「中途断线/被 reset」这两种情况。
set +e
if [ "$TIME_LIMIT" = "0" ]; then
    curl -sS "$URL" | pv -f -i 1 -r -b -t 2>"$RAW_LOG" >/dev/null
else
    timeout "${TIME_LIMIT}s" curl -sS "$URL" | pv -f -i 1 -r -b -t 2>"$RAW_LOG" >/dev/null
fi
CURL_EXIT=${PIPESTATUS[0]}
set -e

END=$(date +%s.%N)

if [ "$CURL_EXIT" -ne 0 ] && [ "$CURL_EXIT" -ne 124 ]; then
    # 124 是 timeout 命令主动掐断的退出码，属于正常的"到时间停止"，不算异常。
    # 其他非 0 退出码说明 curl 是被网络问题中断的（超时/连接被重置/DNS 失败等）。
    echo "⚠️  提示：本次下载没有正常完成，curl 退出码 $CURL_EXIT（很可能是连接中途被断开/重置，" >&2
    echo "    不是脚本的限时设置导致的）。下面的统计数据只反映断线之前的部分下载情况。" >&2
fi

# ---- 解析 pv 的输出 ----
# 一行大概长这样: 123MiB 0:00:05 [24.6MiB/s]
tr '\r' '\n' < "$RAW_LOG" | grep -E '\[.*B/s\]' > "${RAW_LOG}.lines" || true

if [ ! -s "${RAW_LOG}.lines" ]; then
    echo "没有采集到任何速度样本，可能是目标地址无法访问（比如刚才的 Connection reset）。" >&2
    exit 1
fi

TOTAL_BYTES_STR=$(tail -n1 "${RAW_LOG}.lines" | awk '{print $1}')

# 用 awk 统一做单位换算和所有数值计算，避免依赖 bc / python3
RESULT=$(awk -v total="$TOTAL_BYTES_STR" -v start="$START" -v end="$END" '
    function to_mb(s,   num, unit, mult) {
        gsub(/[ \t]/, "", s)   # pv 输出里数字和单位之间偶尔会带空格（比如 " 212 B/s"），先去掉再解析
        num = s + 0
        unit = s
        gsub(/^[0-9.]+/, "", unit)
        if (unit == "B")   mult = 1/1024/1024
        else if (unit == "KiB") mult = 1/1024
        else if (unit == "MiB") mult = 1
        else if (unit == "GiB") mult = 1024
        else if (unit == "TiB") mult = 1024*1024
        else mult = 1
        return num * mult
    }
    BEGIN {
        elapsed = end - start
        total_mb = to_mb(total)
        avg_mb_s = total_mb / elapsed
        avg_mbps = avg_mb_s * 8
        printf "%.2f|%.2f|%.2f|%.2f\n", elapsed, total_mb, avg_mb_s, avg_mbps
    }
')
IFS='|' read -r ELAPSED TOTAL_MB AVG_MB_S AVG_MBPS <<< "$RESULT"

# 每一秒的瞬时速率（[xx.x MiB/s] 里的数字），转换成 Mbps，同时算出 min/max 和拼接波动数组
FLUC_RESULT=$(awk '
    function to_mb(s,   num, unit, mult) {
        gsub(/[ \t]/, "", s)   # pv 输出里数字和单位之间偶尔会带空格（比如 " 212 B/s"），先去掉再解析
        num = s + 0
        unit = s
        gsub(/^[0-9.]+/, "", unit)
        if (unit == "B")   mult = 1/1024/1024
        else if (unit == "KiB") mult = 1/1024
        else if (unit == "MiB") mult = 1
        else if (unit == "GiB") mult = 1024
        else if (unit == "TiB") mult = 1024*1024
        else mult = 1
        return num * mult
    }
    {
        line = $0
        n = split(line, parts, "[][]")
        rate = parts[2]        # 例如 24.6MiB/s
        gsub(/\/s$/, "", rate)
        mbps = to_mb(rate) * 8
        mbps_fmt = sprintf("%.2f", mbps)
        printf "%s\n", mbps_fmt
        if (min == "" || mbps < min) min = mbps
        if (max == "" || mbps > max) max = mbps
        list = (list == "" ? mbps_fmt" Mbps" : list ", " mbps_fmt" Mbps")
    }
    END {
        print "MIN=" sprintf("%.2f", min) > "/dev/stderr"
        print "MAX=" sprintf("%.2f", max) > "/dev/stderr"
        print "LIST=[" list "]" > "/dev/stderr"
    }
' "${RAW_LOG}.lines" 2>&1 >/dev/null)

MIN=$(echo "$FLUC_RESULT" | grep '^MIN=' | cut -d= -f2)
MAX=$(echo "$FLUC_RESULT" | grep '^MAX=' | cut -d= -f2)
LIST=$(echo "$FLUC_RESULT" | grep '^LIST=' | cut -d= -f2-)

# 用 unicode 方块字符（▁▂▃▄▅▆▇█）把每一秒的速度样本画成一条 sparkline 曲线，
# 按 min~max 区间把每个样本映射到 8 个高度档位。
# awk 在非 UTF-8 locale 下按字节而不是按字符处理多字节 unicode 字符串会出问题，
# 所以这里让 awk 只算出 1~8 的档位数字，实际取字符交给 bash 数组来做，规避 locale 问题。
BAR_INDEXES=$(awk -v min="$MIN" -v max="$MAX" '
    function to_mb(s,   num, unit, mult) {
        gsub(/[ \t]/, "", s)   # pv 输出里数字和单位之间偶尔会带空格（比如 " 212 B/s"），先去掉再解析
        num = s + 0
        unit = s
        gsub(/^[0-9.]+/, "", unit)
        if (unit == "B")   mult = 1/1024/1024
        else if (unit == "KiB") mult = 1/1024
        else if (unit == "MiB") mult = 1
        else if (unit == "GiB") mult = 1024
        else if (unit == "TiB") mult = 1024*1024
        else mult = 1
        return num * mult
    }
    {
        n = split($0, parts, "[][]")
        rate = parts[2]
        gsub(/\/s$/, "", rate)
        mbps = to_mb(rate) * 8
        range = max - min
        if (range <= 0) { idx = 8 }
        else {
            idx = int((mbps - min) / range * 7 + 0.5) + 1
            if (idx < 1) idx = 1
            if (idx > 8) idx = 8
        }
        printf "%d ", idx
    }
' "${RAW_LOG}.lines")

BARS=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
SPARKLINE=""
for idx in $BAR_INDEXES; do
    SPARKLINE="${SPARKLINE}${BARS[$((idx - 1))]}"
done

echo "======================================================"
printf "时间: %ss | 流量: %s MB | 速度: %s MB/s ( %s Mbps )\n" \
    "$ELAPSED" "$TOTAL_MB" "$AVG_MB_S" "$AVG_MBPS"
echo "波动: ${LIST} (范围: ${MIN}-${MAX} Mbps)"
echo "      ${SPARKLINE}"
