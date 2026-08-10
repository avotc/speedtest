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
# timeout 用来限制最长测试时间。
set +e
if [ "$TIME_LIMIT" = "0" ]; then
    curl -s "$URL" | pv -f -i 1 -r -b -t 2>"$RAW_LOG" >/dev/null
else
    timeout "${TIME_LIMIT}s" curl -s "$URL" | pv -f -i 1 -r -b -t 2>"$RAW_LOG" >/dev/null
fi
set -e

END=$(date +%s.%N)

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
        printf "%.2f\n", mbps
        if (min == "" || mbps < min) min = mbps
        if (max == "" || mbps > max) max = mbps
        list = (list == "" ? mbps" Mbps" : list ", " mbps" Mbps")
    }
    END {
        print "MIN=" min > "/dev/stderr"
        print "MAX=" max > "/dev/stderr"
        print "LIST=[" list "]" > "/dev/stderr"
    }
' "${RAW_LOG}.lines" 2>&1 >/dev/null)

MIN=$(echo "$FLUC_RESULT" | grep '^MIN=' | cut -d= -f2)
MAX=$(echo "$FLUC_RESULT" | grep '^MAX=' | cut -d= -f2)
LIST=$(echo "$FLUC_RESULT" | grep '^LIST=' | cut -d= -f2-)

echo "======================================================"
printf "时间: %ss | 流量: %s MB | 速度: %s MB/s ( %s Mbps )\n" \
    "$ELAPSED" "$TOTAL_MB" "$AVG_MB_S" "$AVG_MBPS"
echo "波动: ${LIST} (范围: ${MIN}-${MAX} Mbps)"
