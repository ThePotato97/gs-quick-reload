#!/system/bin/sh
# KernelSU 模块页「执行」按钮入口（v2.0，脚本随模块一起分发）
# 查找顺序：模块目录 → /data/adb/gs → /data/local/tmp
D=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
S="$D/gs-reload-modules.sh"
[ -s "$S" ] || S=/data/adb/gs/gs-reload-modules.sh
[ -s "$S" ] || S=/data/local/tmp/gs-reload-modules.sh
if [ ! -s "$S" ]; then
    echo "[!] 找不到 gs-reload-modules.sh"
    echo "    检查模块是否完整安装：ls -l /data/adb/modules/gs_quick_reload/"
    sleep 5
    exit 1
fi
echo "[*] 开始执行 $S"
sh "$S"
