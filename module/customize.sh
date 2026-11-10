#!/system/bin/sh
# KernelSU 安装脚本：只做权限设置与初始部署，不挂载任何文件

ui_print "- 一键重载模块 v2.3-vector（自带 gs-reload-modules.sh）"
ui_print "- 适用：三星 Galaxy Z Fold7（SM-F966B / One UI 9 / Android 17）"
ui_print "- 特点：只重启 zygote，不执行 stop/start，折叠屏副屏不会掉"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/gs-reload-modules.sh" 0 0 0755

# 备份一份到 /data/adb/gs，卸载模块后脚本仍然可用
mkdir -p /data/adb/gs 2>/dev/null
if cp -f "$MODPATH/gs-reload-modules.sh" /data/adb/gs/gs-reload-modules.sh 2>/dev/null; then
    chmod 755 /data/adb/gs/gs-reload-modules.sh 2>/dev/null
    ui_print "- 已备份到 /data/adb/gs/gs-reload-modules.sh"
else
    ui_print "- [!] 备份到 /data/adb/gs 失败（不影响使用）"
fi

# Refresh the legacy terminal path on every installation/update as well. Runtime
# copies never promote themselves over this package or the durable backup.
mkdir -p /data/local/tmp 2>/dev/null
if cp -f "$MODPATH/gs-reload-modules.sh" /data/local/tmp/gs-reload-modules.sh 2>/dev/null; then
    chmod 755 /data/local/tmp/gs-reload-modules.sh 2>/dev/null
else
    ui_print "- [!] 旧终端路径更新失败；请使用模块目录里的脚本"
fi

mkdir -p /sdcard/GS/logs 2>/dev/null
ui_print "- 日志目录：/sdcard/GS/logs"

ui_print ""
ui_print "- 用法：模块页点「执行」即可"
ui_print "- 终端等价命令："
ui_print "    sh /data/adb/modules/gs_quick_reload/gs-reload-modules.sh"
ui_print "- 只体检不重启：同上命令后加 check"
ui_print "- 重启 zygote 会让所有应用退出（含 root 终端），20 秒左右回锁屏"
