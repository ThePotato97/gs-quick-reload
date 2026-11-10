#!/system/bin/sh
# gs-reload-modules.sh  v22 — 让 KernelSU 模块生效，但不执行 stop/start
# （随「一键重载模块 gs_quick_reload」一起分发，装在 /data/adb/modules/gs_quick_reload/）
#
# 背景：KernelSU 的「软重启」== ksud 的 soft_reboot()，实际序列是：
#           stop  ->  on_post_data_fs()  ->  start  ->  on_services()
#       `stop` 会把 SurfaceFlinger 一起停掉，显示栈重建。在 Z Fold7 / F966B
#       这类折叠屏上，重建后 HWC 不会重新枚举副屏（DSI-2 / port=148），
#       结果副屏整场会话都不亮。
#
# v4 做法：不再自己遍历模块目录跑脚本，而是**直接调用 ksud 自己的阶段命令**，
#       这正是 soft_reboot() 在 stop 与 start 之间做的那两件事，只是跳过 stop/start：
#
#           ksud post-fs-data   → 挂载模块（magic mount）、跑 post-fs-data.sh、
#                                 加载 system.prop、执行 metamodule mount
#           ksud services       → 跑 service 阶段脚本
#           setprop ctl.restart zygote
#
#       这样模块的挂载/属性/脚本全都真正生效，而且 SurfaceFlinger 全程存活。
#
# v4 相比 v3 的修正（两处，都会导致卡死或误判）：
#   1. 不再把 ksud 的输出用管道接给 sed。on_post_data_fs() 内部会 spawn
#      `timeout -s 9 30s logcat -b all` 和 `dmesg -w -r` 两个子进程，
#      它们的 stderr 继承自父进程；一旦父进程 stdout 接的是管道，
#      子进程不退出管道就不 EOF，sed 会白等 30 秒甚至更久。
#      改成「输出重定向到临时文件 → 再 cat」，并统一套 timeout。
#   2. find_ksud 增加 find 兜底。late-load 之后 /data/adb/ksu/bin/ 可能还没解出来，
#      单靠路径列举会误报「未找到」。
#
# v2/v1 的问题：只跑了模块的 .sh 脚本，**没有** 执行 ksud 的挂载与 system.prop
#       加载阶段，所以对需要 overlay 的模块无效；v1 还会卡死（原因同上第 1 条）。
#
# v5：整条阶段命令套 setsid。否则 zygote 重启时终端被关、内核向前台进程组发
#       SIGHUP，模块脚本里 `daemon &` 起的 lspd / zygiskd 会一起死，LSPosed
#       表现为「注入侧一直 Connection refused」。
#
# v6：重启前挂一个夜间模式守护（同样 setsid）。ui_night_mode 为自动/定时时，
#       框架重启会让 TwilightService 丢状态，One UI 回落到深色且不自纠。
#       守护在 system_server 起来 45 秒后对比昼夜判定，偏了就拨回来，
#       再还原用户原本的模式。日志：/data/local/tmp/gs-night.log
#
# v7：① 全过程落盘 /data/local/tmp/gs-reload.log（含每个阶段的起止时间与完整
#       输出）。此前日志只出现在 App 界面上，跑完就没了，出问题无法复盘。
#     ② services 之前清理残留 lspd。每 reload 一次都会新起一个 lspd，旧的
#       因为 setsid 脱离了终端组不会自己退，累积多个会抢同一个 socket，
#       表现为 LSPosed 能注入但管理器读到旧状态。
#     ③ 每个阶段打时间戳，方便看出卡在哪一步（实测 services → zygote 之间
#       曾有约 5 分钟延迟，需要数据确认到底是哪个模块脚本在占时间）。
#
# v8：v7 ② 的「services 之前杀掉所有 lspd」是错的 —— 实测 17:57 那次
#       cleanup 把 lspd 全杀后，service 阶段没能及时补上新的，结果是注入侧
#       一直敲旧 uuid（Connection refused 314 次），LSPosed 彻底不工作。
#       改成：先跑 services，**之后**再收尾 ——
#         · 一个都没有 → 用 setsid 补跑一次 LSPosed 的 service.sh 并等待
#         · 多于一个   → 只保留最新（starttime 最大）的那个，其余杀掉
#     另外日志 chmod 644，否则 600 root 的文件在 adb 侧读不了。
#
# v9：v8 的收尾逻辑有两个实测问题 ——
#     ① `ksud services` 里的 service 阶段是**不阻塞**的（run_stage(..., false)），
#        它一返回就去查 lspd，往往还差 1~3 秒才有进程，于是误报“lspd 未运行”，
#        接着白跑一次补启动。改成先轮询等待（默认 20 秒）再判定。
#     ② 补启动用 `[ -x ... ]` 判断脚本，但 KernelSU 是用 `sh service.sh` 跑的，
#        模块里的脚本普遍是 0644、没有执行位 → 永远判成“找不到”。
#        改成 `-f`，并且按 module.prop 里的 id 动态定位 LSPosed 目录，
#        不再硬编码 zygisk_lsposed。
#     ③ 新增 `mods` 子命令：导出模块清单（目录、id、版本、脚本权限、分区目录、
#        disable 标记）到 /data/local/tmp/gs-modules.txt，方便事后核查装了哪些模块。
#
# v10：模块清单实测 5 个，其中 /data/adb/modules/m_rcq（RCQ环境 2.1.0）的
#       service.sh 每次 reload 都新起一个 busybox 循环且不退出（PPID=1），
#       三轮下来积了 3 个；它自己的 I_am_taffy 标记文件缺失，每次都报错。
#      · 新增 `dump <id>`：把模块目录打包到 /data/local/tmp/gs-mod-<id>.tar，
#        便于离线读脚本（/data/adb 是 0700，adb 侧读不了）。
#      · 新增 `trim`：清理重复的 lspd 与 RCQ 监控循环，只留最新一个。
#        zn-daemon 不清理，它是 Zygisk Next 的注入链核心，多实例暂未观察到问题。
#
# v11：读完 m_rcq/service.sh（163 行）后定位到它挂死的真正原因 ——
#      它靠 `resetprop -w sys.boot_completed 0/1` 等「启动阶段切换」事件分段：
#        第 29 行等 0 → 做 prop 伪装（avb/vbmeta/warranty 一大串）
#        第 129 行等 1 → 才执行真正的隐藏（chmod 000 /proc/modules 等）
#      而 ksud 的 soft_reboot() 本来会先把 boot_completed 置 0 再走一遍阶段
#      （init_event.rs: reset_boot_completed / wait_for_boot_completed），
#      我们绕开 stop/start 时把这步漏了 → 模块永远等不到事件，卡在第 129 行，
#      三个实例就是这么来的，而且它的隐藏段一次都没执行过。
#      → run 模式在 post-fs-data 之前补一次 `resetprop sys.boot_completed 0`，
#        重启 zygote 后 system_server 会重新置 1，模块即可跑完全程。
#      check 里增加「常驻实例盘点」，并在 /proc/net/unix 不可读时给出解释
#      （RCQ 生效后会把该文件 chmod 440）。
#
# v12：加 boot_completed 看门狗。19:02 那轮置 0 后 system_server 在高负载下
#      （load 42）90 秒没置回 1，整机 cold reboot（bootreason 记为
#      rollback_staged_install）。看门狗脱离会话、zygote 重启后仍存活。
#
# v13：看门狗升级为「边沿发生器」。实测 `resetprop -w` 只在 0→1 变化时唤醒，
#      值已是 1 时等待会永久挂起；19:08 那轮 system_server 起太快，边沿被模块
#      错过，RCQ 隐藏段没执行。现改为：等系统启动完成且距重启 ≥25s 后，
#      主动制造一次 0→1 边沿；若 /proc/modules 仍非 000，最多再补 2 次。
#      日志 $LOGDIR/gs-boot-wd.log（默认 /sdcard/GS/logs）
#
# v15：按「本机实际装的 5 个模块」重构，去掉对 m_rcq 的硬编码。
#      现状：bszip（悲伤压缩包环境隐藏）、hma_oss_zygisk（HMA-OSS）、
#            zygisk_lsposed、zygisksu（Zygisk Next）、gs_quick_reload。
#            m_rcq 与 YH_YC（月虹）已被卸载 → 边沿发生器失去目标。
#      ① 新增 boot_waiters()：扫模块脚本里的 `resetprop -w ...boot_completed`，
#         有等待者才制造边沿；没有就只保留「卡 0 → 置 1」的安全网。
#      ② 边沿成功与否改用「还有没有 resetprop -w 卡着」判断，不再看
#         /proc/modules 权限（那个判据只有 RCQ 适用，且曾误报）。
#      ③ trim 改为保留**最早**实例（最早那个才持有 socket），并把 zn-daemon
#         纳入；zn-daemon 曾累积到 5 个（每 reload +1）。
#      ④ check 增加本机模块画像：Zygisk Next 守护数、HMA/bszip 是否在位。
#
# v16/v17：① `socket_owner()` 只认 `/proc/net/unix` 第 4 列 Flags=00010000 的
#      监听 socket；② **zn-daemon 默认完全不 trim**（它的监听 socket 在 fork 出的
#      zygiskd 里，从自身 fd 判不出来，误杀会导致所有新进程 111）；
#      要清必须显式 `trim --zn`；③ 反向自愈：tmp 副本被清时从 /data/adb/gs 回填。
#
# v4~v17 的几点实测结论，供同机型的人少踩坑：
#      · 软重启后副屏不亮 = `stop` 打断显示栈，HWC 不再重发 hotplug；冷启动可恢复。
#      · `setprop ctl.restart zygote` 只重启 zygote，SurfaceFlinger/composer 存活，
#        副屏不受影响 —— 这就是整个方案成立的原因。
#      · zygote 重启会带走终端会话，模块里裸 `daemon &` 起的进程会被 SIGHUP 杀掉，
#        所以阶段命令必须套 setsid。
#      · 日志别放 /data/local/tmp：某些「隐藏 Root / 清理环境」模块会 rm -rf 掉它。
#
# v18：看门狗兜底重构 —— 没有 resetprop -w 等待者时不启动 helper，只挂一条
#      `sleep 90 → 若 boot_completed 仍为 0 就置 1` 的内联安全网；helper 的
#      stderr 落 $LOGDIR/gs-boot-wd.err，不再出现「日志 0 字节、进程消失」。
#
# v19：① check 的 Zygisk 健康统计排除 adbd 行 —— adb shell 执行的命令行本身会被
#          adbd 记进 logcat，grep 会把自己的命令当命中（曾两次误报「1 条失败」）；
#      ② 日志新增「运行副本: $0」，用于确认按钮跑的是哪一份（模块目录 / gs / tmp）。
# v20：修「LSPosed 要点两次执行才生效」（11-01 09:56 实测事故）。
#      现象：日志一切正常（daemons: lspd=18815 sockets=1），zygote 重启后
#            2 秒起 lspbridge 全 111，lspd 一个不剩，所有模块失效。
#      根因：`daemon --force` 是「让旧的退 → 新的绑 socket 起来」。旧 daemon
#            退得慢时新进程绑不上就自尽，最后两代都没了；而 trim_lspd 只看
#            pidof 非空，正好撞上旧 daemon「正在退出」的那一秒，判了健康。
#            历史三次事故（23:27 / 23:43 / 09:56）的日志特征完全一致：
#            lspd 的 pid 与上一轮相同 —— 即 --force 没有真正换出新进程。
#      改法：① lspd 永不 dedupe（dedupe 的"留旧杀新"会和 --force 正面互撞）；
#            ② `ensure_lspd()` 三条硬指标：有 daemon + lspbridge 在监听 +
#               它是本次 services 之后新起的；settle 5s 后仍不达标，就自己
#               干净重启 daemon（全杀→等消失→起 service.sh→轮询验证）；
#            ③ 仍不达标则 exit 3、**不重启 zygote**，绝不让手机停在无注入状态。
#
# v21：夜间模式收尾（11-01 10:05 实测：模式卡在固定值、用户看不到「自动」）。
#      ① 实测结论：`cmd uimode night auto` 在 computed 卡错时**不会触发重算**，
#         单发 auto 值一动不动；必须先给固定值再回 auto。所以守护不能省掉「顶」。
#         但「顶」之后被打断就会留在固定值上 —— 这正是「夜间模式不再自动」的成因。
#      ② 守护加 `trap ... EXIT INT TERM HUP`：任何退出路径（含终端断开、被 kill）
#         都还原用户原本的模式，并回读 `settings get secure ui_night_mode` 校验。
#      ③ 纠正最多重试 3 轮，每轮都回读判定，不再「一次不成就强制固定」。
#      ④ 新增子命令 `night`：一条命令把夜间模式还原成「0=自动(日落到日出)」，
#         并按当时的钟点校验昼夜判定，不需要 root。
#
# 用法：
#   sh /data/adb/modules/gs_quick_reload/gs-reload-modules.sh   # 模块自带副本（推荐）
#   sh /data/adb/gs/gs-reload-modules.sh            # 备份副本，卸模块后仍可用
#   sh /data/local/tmp/gs-reload-modules.sh         # 手推版（会自动同步到 /data/adb/gs）
#   不带参数 = ksud 阶段全跑 + 重启 zygote
#   sh <脚本> -n         # 只跑到 services，不重启
#   sh <脚本> -f         # 强制走兜底（逐模块跑脚本）
#   sh <脚本> mods       # 导出模块清单
#   sh <脚本> dump <id>  # 打包某个模块供分析
#   sh <脚本> trim       # 只清 lspd 重复（zn 不动）
#   sh <脚本> trim --zn  # 连 zn-daemon 一起清（有风险）
#   sh <脚本> check      # 只体检，不需要 root
#
# 注意：zygote 重启会让所有应用（含 GhostSam）退出，终端会断，属正常。

set -u

MODDIR_BASE=/data/adb/modules
LOGF=/data/local/tmp/.gs-stage.log
# v14：日志改到 /sdcard，持久且 adb 侧免 root 可读。
# 20:28 那次 /data/local/tmp 被整个清空，脚本和全部日志一起没了，教训。
GS_DIR=/data/adb/gs
LOGDIR=/sdcard/GS/logs
PERSIST=$LOGDIR/gs-reload.log
NIGHT_HELPER=$GS_DIR/.gs-night-fix.sh
BOOT_WD=$GS_DIR/.gs-boot-wd.sh
SELF_BAK=$GS_DIR/gs-reload-modules.sh
MODE=run
DUMP_ID=""
DO_ZYGOTE=1
FORCE_FALLBACK=0

# 目录准备：/data/adb/gs 放 helper 与脚本自备份（重启/清 tmp 都不丢）；
# /sdcard/GS/logs 放日志（adb 侧免 root 可读）。/sdcard 不可用时回落到 tmp。
mkdir -p "$GS_DIR" 2>/dev/null
if mkdir -p "$LOGDIR" 2>/dev/null && : > "$LOGDIR/.wtest" 2>/dev/null; then
    rm -f "$LOGDIR/.wtest" 2>/dev/null
else
    LOGDIR=/data/local/tmp
    PERSIST=$LOGDIR/gs-reload.log
fi
if [ -f "$0" ] && [ "$0" != "$SELF_BAK" ]; then
    cp -f "$0" "$SELF_BAK" 2>/dev/null && chmod 755 "$SELF_BAK" 2>/dev/null
fi
# v16：反向自愈 —— 若从 /data/adb/gs 启动而 tmp 副本被清（「悲伤压缩包」的
#   隐藏 Root 功能会 chmod/rm -rf /data/local/tmp/*），把 tmp 副本补回来，
#   这样模块「执行」按钮（调 /data/local/tmp/gs-reload-modules.sh）不会失效。
if [ -f "$SELF_BAK" ] && [ ! -f /data/local/tmp/gs-reload-modules.sh ]; then
    cp -f "$SELF_BAK" /data/local/tmp/gs-reload-modules.sh 2>/dev/null \
        && chmod 755 /data/local/tmp/gs-reload-modules.sh 2>/dev/null
fi

# 落盘日志：追加一行带时间戳的记录（同时也打印到终端）
tlog() {
    _line="[$(date +%m-%d' '%H:%M:%S)] $*"
    echo "$_line" >> "$PERSIST" 2>/dev/null
    chmod 644 "$PERSIST" 2>/dev/null   # 否则 600 root，adb 侧读不到
    echo "$_line"
}

# 日志超过 256KB 就先截断，避免无限增长
rotate_log() {
    [ -f "$PERSIST" ] || return 0
    chmod 644 "$PERSIST" 2>/dev/null
    _sz=$(wc -c < "$PERSIST" 2>/dev/null | tr -d ' ')
    [ -n "$_sz" ] && [ "$_sz" -gt 262144 ] && mv -f "$PERSIST" "$PERSIST.old" 2>/dev/null
    return 0
}

usage() {
    cat <<'EOF'
用法: gs-reload-modules.sh [check] [-n] [-f] [mods] [dump <id>] [trim] [-h]

  check   只打印当前状态（显示设备、模块列表），不需要 root
  mods    导出模块清单到 /data/local/tmp/gs-modules.txt（需要 root）
  dump    把某个模块目录打包到 /data/local/tmp/gs-mod-<id>.tar（需要 root）
  trim    清理重复的常驻实例（lspd / zn-daemon / 卡住的等待循环），保留最早的
  night   把夜间模式还原成「自动（日落到日出）」并纠正昼夜判定，不需要 root
          ui_night_mode: 0=自动 1=始终浅色 2=始终深色 3=自定义时间表
  -n      只跑到 ksud services，不重启 zygote
  -f      强制走兜底模式（逐模块跑 post-fs-data.sh / service.sh，不做挂载）
  -h      显示本帮助

不要用 stop/start 或管理器里的「软重启」来应用模块，
那会在折叠屏上打掉副屏。用本脚本代替。
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        check|verify) MODE=check ;;
        mods|list) MODE=mods ;;
        dump|tar) MODE=dump; if [ $# -gt 1 ]; then shift; DUMP_ID="${1:-}"; fi ;;
        trim|clean) MODE=trim ;;
        night|dark) MODE=night ;;
        --zn) TRIM_ZN=1 ;;
        -n|--no-zygote) DO_ZYGOTE=0 ;;
        -f|--fallback) FORCE_FALLBACK=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1"; echo; usage; exit 2 ;;
    esac
    shift
done

# 找 ksud：KernelSU 会把二进制解到 /data/adb/ksu/bin/ 下，late-load 后可能没有
find_ksud() {
    for p in /data/adb/ksu/bin/ksud /data/adb/ksud /data/local/tmp/ksud \
             /system/bin/ksud /system/xbin/ksud /debug_ramdisk/ksud; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    p=$(command -v ksud 2>/dev/null) && [ -n "$p" ] && { echo "$p"; return 0; }
    p=$(find /data/adb /data/local/tmp /system /debug_ramdisk \
            -maxdepth 4 -name ksud -type f 2>/dev/null | head -1)
    [ -n "$p" ] && { echo "$p"; return 0; }
    return 1
}

# 稳定执行一条命令：输出落文件再 cat，彻底避开管道被后台子进程占住的问题。
# v5：整条命令套 setsid，脱离终端的会话/进程组。否则 zygote 重启时终端被关，
#     内核会给前台进程组发 SIGHUP，模块脚本里 `daemon &` 起的那批守护进程
#     （lspd / zygiskd / yhyc）会一起被带走 —— LSPosed 就是死在这一步：
#     注入侧读到了 lspd 的 uuid，但 lspd 已经没了，只能一直 Connection refused。
# v7：输出同时追加到 $PERSIST，跑完还能复盘；并加 600 秒硬超时兜底。
run_quiet() {
    _t0=$(date +%s)
    if command -v timeout >/dev/null 2>&1; then
        _TO="timeout 600"
    elif [ -x /system/bin/timeout ]; then
        _TO="/system/bin/timeout 600"
    else
        _TO=""
    fi
    if command -v setsid >/dev/null 2>&1; then
        $_TO setsid -w sh -c "$1" </dev/null >"$LOGF" 2>&1
    else
        $_TO sh -c "$1" </dev/null >"$LOGF" 2>&1
    fi
    _rc=$?
    _t1=$(date +%s)
    [ -s "$LOGF" ] && sed 's/^/    /' "$LOGF"
    {
        echo "---- $(date +%m-%d' '%H:%M:%S) cmd=$1 exit=$_rc elapsed=$((_t1-_t0))s"
        [ -s "$LOGF" ] && cat "$LOGF"
    } >> "$PERSIST" 2>/dev/null
    [ "$_rc" = "124" ] && echo "    [!] 超时 600 秒被中断，上面最后一步可能没做完"
    rm -f "$LOGF" 2>/dev/null
    return $_rc
}

# BEGIN framework helpers
# Detect enabled modules by identity, not a generic "daemon" string in service.sh.
# Vector supports Xposed APIs but does not expose LSPosed's lspd/lspbridge lifecycle.
find_enabled_module() {
    for module_dir in "$MODDIR_BASE"/*; do
        [ -d "$module_dir" ] || continue
        [ -f "$module_dir/disable" ] && continue
        [ -f "$module_dir/remove" ] && continue
        if sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$module_dir/module.prop" 2>/dev/null | grep -qx "id=$1"; then
            echo "$module_dir"
            return 0
        fi
    done
    return 1
}

detect_framework() {
    VECTOR_DIR=$(find_enabled_module zygisk_vector) || VECTOR_DIR=""
    LSPOSED_DIR=$(find_enabled_module zygisk_lsposed) || LSPOSED_DIR=""
    FRAMEWORK_KIND=none
    if [ -n "$VECTOR_DIR" ] && [ -n "$LSPOSED_DIR" ]; then
        echo "[X] Both Vector and LSPosed are enabled; reload aborted."
        return 1
    fi
    [ -n "$LSPOSED_DIR" ] && FRAMEWORK_KIND=lsposed
    if [ -n "$VECTOR_DIR" ]; then
        FRAMEWORK_KIND=vector
        if [ ! -r "$VECTOR_DIR/daemon.apk" ] || [ ! -x /system/bin/app_process ] || ! command -v timeout >/dev/null 2>&1; then
            echo "[X] Vector reload needs daemon.apk, app_process and timeout for a bounded readiness check."
            echo "    No boot property or module stage has been changed."
            return 1
        fi
    fi
    return 0
}

zygisk_kind() {
    zygisk_dir=$(find_enabled_module zygisksu) || { echo none; return; }
    zygisk_name=$(sed -n 's/^name=//p' "$zygisk_dir/module.prop" | head -1)
    case "$zygisk_name" in
        *NeoZygisk*) echo neozygisk ;;
        *"Zygisk Next"*) echo zygisk-next ;;
        *) echo unknown ;;
    esac
}

vector_ready() {
    vector_pids=$(pidof vectord 2>/dev/null)
    set -- $vector_pids
    [ "$#" -eq 1 ] || return 1
    # This probes the daemon's IPC, not just a PID or an unrelated unix socket.
    # It does not prove injection into every app after the upcoming zygote restart.
    # Do not call the cli wrapper: it hardcodes zygisk_vector and may select an
    # unrelated /data/local/tmp/daemon.apk. Use this detected installation only.
    timeout "${1:-10}" /system/bin/app_process \
        "-Djava.class.path=$VECTOR_DIR/daemon.apk" /system/bin \
        --nice-name=VectorCli org.matrix.vector.daemon.Cli status >/dev/null 2>&1
}

ensure_vector() {
    vector_deadline=$(( $(date +%s) + 30 ))
    while :; do
        vector_remaining=$(( vector_deadline - $(date +%s) ))
        [ "$vector_remaining" -gt 0 ] || break
        vector_limit=10
        [ "$vector_remaining" -lt "$vector_limit" ] && vector_limit=$vector_remaining
        tlog "Waiting for Vector daemon IPC (${vector_remaining}s remaining)"
        if vector_ready "$vector_limit"; then
            tlog "Vector daemon IPC ready: vectord=$(pidof vectord 2>/dev/null)"
            return 0
        fi
        sleep 1
    done
    echo "[X] Vector daemon IPC is not ready or multiple vectord processes exist."
    echo "    Zygote will not restart. No extra Vector service.sh or daemon kill was attempted."
    tlog "Vector readiness failed; vectord=$(pidof vectord 2>/dev/null)"
    return 1
}

ensure_framework() {
    case "$FRAMEWORK_KIND" in
        vector) ensure_vector ;;
        lsposed)
            # Upstream does not recover lspd in script-only fallback mode.
            if [ -n "${KSUD:-}" ]; then
                ensure_lspd "${1:-}"
            else
                tlog "LSPosed fallback: skipping daemon recovery (upstream behaviour)"
            fi
            ;;
        none) tlog "No enabled Vector/LSPosed module; skipping Xposed daemon gate" ;;
    esac
}

# Restore only the property this run changed, and only before restart handoff.
# Module stages cannot be rolled back by restoring this flag.
restore_boot_state() {
    if [ "${BOOT_CHANGED:-0}" = "1" ] && [ "${BOOT_HANDOFF:-0}" = "0" ]; then
        if "$BOOT_RESETPROP" sys.boot_completed "$BOOT_ORIGINAL"; then
            BOOT_CHANGED=0
            tlog "Abort cleanup: restored sys.boot_completed=$BOOT_ORIGINAL; module stages may have run"
        else
            echo "[X] Failed to restore sys.boot_completed=$BOOT_ORIGINAL" >&2
        fi
    fi
    return 0
}
# END framework helpers

# v9：按 module.prop 的 id 找 LSPosed 模块目录，不再硬编码目录名。
#   KernelSU 允许模块目录名与 id 不同（实测本机出现了 /data/adb/modules/m_rcq
#   这类与 id 不一致的目录），硬编码 zygisk_lsposed 会找不到。
find_lsposed_dir() {
    find_enabled_module zygisk_lsposed
}

# v15：找出「依赖 sys.boot_completed 0→1 边沿」的模块。
#   这类模块的 service.sh 里会有 `resetprop -w sys.boot_completed 1` 之类的等待，
#   而 resetprop -w 只在值**变化**时唤醒 —— 等待开始时值已经是 1 就永久挂起。
#   只有存在这类模块时，看门狗才需要主动制造边沿；否则纯属无谓地改系统属性。
boot_waiters() {
    for d in "$MODDIR_BASE"/*; do
        [ -d "$d" ] || continue
        for f in "$d/post-fs-data.sh" "$d/service.sh" "$d/boot-completed.sh" "$d/late-start.sh"; do
            [ -f "$f" ] || continue
            if grep -qs 'resetprop[[:space:]]*-w\|getprop[[:space:]]*-w' "$f"; then
                echo "${d##*/}"
                break
            fi
        done
    done
}

# v15：还卡在等待 boot_completed 的进程数（resetprop -w 阻塞中）。
#   这是「边沿有没有喂到」的唯一准确判据：喂到了，等待者会自己退出。
blocked_waiters() {
    ps -A -o ARGS 2>/dev/null | grep -a 'resetprop' | grep -a '\-w' | grep -a 'boot_completed' \
        | grep -av grep | wc -l | tr -d ' '
}

# v20：lspd 的判据 —— 「有一个 daemon 在跑」+「lspbridge 正在监听」+「它是本次
#   services 之后新起的」。三条缺一不可。
#   第三次条为什么必要（三次事故，同一个特征）：
#     · 23:27 / 23:43 / 11-01 09:56 —— 日志里 lspd 的 pid 与上一轮完全相同，
#       即 `daemon --force` 没有真正换出新进程；这三次的下场都是随后 111 刷屏。
#       --force 的语义是「让旧的退 → 新的绑 socket 起来」。旧 daemon 退得慢时，
#       新进程绑不上就自己退了，最后什么都不剩（09:56:57 还在报 sockets=1，
#       两秒后 111 刷屏，就是这个过程）。
#     · 只看 pidof 非空（v18 做法）会撞上「旧 daemon 正在退出」的瞬间，误判健康。
#   所以：settle 5s → 三条齐了才放行；否则**自己干净重启一遍 daemon**
#   （全杀 → 等它彻底消失 → 直接起 service.sh → 轮询验证），绕开 --force 的竞态。
lspbridge_count() { grep -c 'lspbridge' /proc/net/unix 2>/dev/null | tr -d ' '; }

lspd_newest() {
    _best=""; _bt=-1
    for _p in $1; do
        _st=$(awk '{print $22}' "/proc/$_p/stat" 2>/dev/null)
        [ -z "$_st" ] && continue
        if [ "$_st" -gt "$_bt" ]; then _bt=$_st; _best=$_p; fi
    done
    echo "$_best"
}

lspd_kill_all() {
    _pl=$(pidof lspd 2>/dev/null)
    [ -z "$_pl" ] && return 0
    kill $_pl 2>/dev/null
    _i=0
    while [ "$_i" -lt 10 ]; do
        sleep 1; _i=$((_i+1))
        [ -z "$(pidof lspd 2>/dev/null)" ] && return 0
    done
    _pl=$(pidof lspd 2>/dev/null)
    [ -n "$_pl" ] && kill -9 $_pl 2>/dev/null
    sleep 2
    return 0
}

lspd_start_fresh() {
    _ldir=$(find_lsposed_dir)
    if [ -z "$_ldir" ] || [ ! -f "$_ldir/service.sh" ]; then
        tlog "rescue 失败：找不到 zygisk_lsposed 的 service.sh（目录：${_ldir:-无}）"
        return 1
    fi
    tlog "rescue: 干净启动 $_ldir/service.sh"
    setsid sh "$_ldir/service.sh" </dev/null >/dev/null 2>&1 &
    _i=0
    while [ "$_i" -lt 60 ]; do
        sleep 1; _i=$((_i+1))
        [ -n "$(pidof lspd 2>/dev/null)" ] && [ "$(lspbridge_count)" -ge 1 ] && return 0
    done
    return 1
}

ensure_lspd() {
    _snap="$1"
    sleep 5
    _pids=$(pidof lspd 2>/dev/null)
    _n=$(echo $_pids | wc -w | tr -d ' ')
    _sock=$(lspbridge_count)
    _same=0
    for _p in $_pids; do case " $_snap " in *" $_p "*) _same=1 ;; esac; done
    echo "    --- 5s 后：lspd=[$_pids] 实例=$_n 监听=$_sock 旧实例=$_same"
    tlog "lspd 检查(5s): pids=[$_pids] 实例=$_n 监听=$_sock 快照=[$_snap] 旧实例=$_same"

    if [ "$_n" -ge 1 ] && [ "$_sock" -ge 1 ] && [ "$_same" = "0" ]; then
        echo "    [OK] services 已换出新 daemon：$_pids（监听 $_sock 个 socket）"
        tlog "lspd 健康（新实例）: $_pids 监听=$_sock"
        return 0
    fi

    if [ "$_n" -ge 1 ] && [ "$_same" = "1" ]; then
        echo "    [!] lspd 仍是旧实例 [$_pids]（--force 没换出来），主动干净重启 daemon"
        tlog "lspd: 仍是旧实例 [$_pids]，执行干净重启"
    else
        echo "    [!] lspd 缺失或不监听（实例=$_n 监听=$_sock），主动干净重启 daemon"
        tlog "lspd: 缺失或不监听（实例=$_n 监听=$_sock），执行干净重启"
    fi

    lspd_kill_all
    if lspd_start_fresh; then
        _pids=$(pidof lspd 2>/dev/null)
        _n=$(echo $_pids | wc -w | tr -d ' ')
        if [ "$_n" -gt 1 ]; then
            _keep=$(lspd_newest "$_pids")
            for _p in $_pids; do
                [ "$_p" = "$_keep" ] && continue
                kill "$_p" 2>/dev/null
            done
            sleep 1
            _pids=$(pidof lspd 2>/dev/null); _n=$(echo $_pids | wc -w | tr -d ' ')
        fi
        _sock=$(lspbridge_count)
        echo "    [OK] 干净重启成功：lspd=$_pids 实例=$_n 监听=$_sock"
        tlog "lspd 干净重启成功: pids=[$_pids] 实例=$_n 监听=$_sock"
        return 0
    fi

    _pids=$(pidof lspd 2>/dev/null)
    _n=$(echo $_pids | wc -w | tr -d ' ')
    _sock=$(lspbridge_count)
    echo "    [X] 干净重启失败：lspd=[$_pids] 实例=$_n 监听=$_sock"
    tlog "!! lspd 干净重启失败: pids=[$_pids] 实例=$_n 监听=$_sock，将放弃重启 zygote"
    return 1
}

# ---------------------------------------------------------------- night 模式（v21）
# 独立的夜间模式纠正/还原入口，不需要 root，一条命令就能把「自动」拨回来：
#     sh gs-reload-modules.sh night
# 背景：`ui_night_mode` 的取值是 0=自动(日落到日出) 1=始终浅色 2=始终深色 3=自定义时间表。
#   守护进程一旦在「强制固定 → 还原」之间被打断（终端断开、进程被 kill），
#   模式就会停在 1/2 上，表现就是「夜间模式不再自动」。这条命令专门收这个尾。
night_now() {
    _stored=$(settings get secure ui_night_mode 2>/dev/null)
    case "$_stored" in ""|null) _stored=0 ;; esac
    _cur=$(dumpsys uimode 2>/dev/null | grep -o 'mComputedNightMode=[a-z]*' | head -1 | cut -d= -f2)
    [ -z "$_cur" ] && _cur=false
    _tw=$(dumpsys uimode 2>/dev/null | grep -o 'getLastTwilightState()=[a-z]*' | head -1 | cut -d= -f2)

    # 目标是「自动」：本来就是自定义时间表(3)的保留 3，其余一律回到 0(日落到日出)。
    # 注意不要把 1/2 当成目标 —— 那样等于把「始终浅色/深色」又写了一遍。
    case "$_stored" in
        3) _target=3 ;;
        *) _target=0 ;;
    esac

    echo "== 夜间模式 =="
    echo "  存储值     : $_stored   (0=自动/日落到日出  1=始终浅色  2=始终深色  3=自定义时间表)"
    echo "  目标模式   : $_target"
    echo "  当前判定   : $_cur  (true=深色)"
    echo "  钟点       : $(date +%H:%M)   Twilight=$_tw"
    if [ "$_tw" = "null" ]; then
        echo "  提示：Twilight 为 null（拿不到日出日落），系统按 19:00-07:00 回落"
        _h=$(date +%H | sed 's/^0//')
        if [ -n "$_h" ] && { [ "$_h" -ge 19 ] || [ "$_h" -lt 7 ]; }; then _desired=true; else _desired=false; fi
    else
        # 有 Twilight 时算不出日落时刻，就沿用系统自己的判定
        _desired=$_cur
    fi
    echo "  应为判定   : $_desired"

    if [ "$_cur" = "$_desired" ] && [ "$_stored" = "$_target" ]; then
        [ "$_target" = "0" ] && cmd uimode night auto >/dev/null 2>&1
        [ "$_target" = "3" ] && cmd uimode night custom_schedule >/dev/null 2>&1
        echo "  [OK] 已是自动，判定也正确，无需改动"
        return 0
    fi

    # 实测：auto 下 computed 卡错时单发 auto 不会重算，必须先给固定值再回 auto。
    if [ "$_cur" != "$_desired" ]; then
        echo "  -> 纠正判定：先置 $_desired，再回到模式 $_target"
        if [ "$_desired" = "true" ]; then cmd uimode night yes; else cmd uimode night no; fi
        sleep 3
    else
        echo "  -> 判定正确，只改模式：$_stored -> $_target"
    fi
    case "$_target" in
        3) cmd uimode night custom_schedule ;;
        *) cmd uimode night auto ;;
    esac
    sleep 4

    _c2=$(dumpsys uimode 2>/dev/null | grep -o 'mComputedNightMode=[a-z]*' | head -1 | cut -d= -f2)
    _m2=$(settings get secure ui_night_mode 2>/dev/null)
    echo "  结果       : 判定=$_c2  模式=$_m2"
    if [ "$_c2" = "$_desired" ] && [ "$_m2" = "$_target" ]; then
        echo "  [OK] 已恢复自动（$_target），判定正确"
        return 0
    fi
    echo "  [!] 仍是 判定=$_c2 模式=$_m2（期望 判定=$_desired 模式=$_target）"
    echo "      请到 设置-显示-深色模式 手动点一次「日落到日出」"
    return 1
}

if [ "$MODE" = "night" ]; then
    night_now
    exit $?
fi

# ---------------------------------------------------------------- check 模式
if [ "$MODE" = "check" ]; then
    echo "== 设备 =="
    echo "型号      : $(getprop ro.product.model)"
    echo "构建      : $(getprop ro.build.display.id)"
    echo "内核      : $(uname -r)"
    echo "折叠屏预期: $(getprop ro.config.fold_disp)  (内屏 1968x2184, 副屏 1080x2520)"
    echo "boot_done : $(getprop sys.boot_completed)"
    echo
    echo "== 显示设备（应有两块：内屏 + 副屏）=="
    dumpsys SurfaceFlinger --display-id 2>/dev/null | sed 's/^/  /'
    n=$(dumpsys SurfaceFlinger --display-id 2>/dev/null | grep -c '^Display ')
    echo "  ---> HWC display 数量: $n"
    if [ "$n" -lt 2 ]; then
        echo "  [!] 少于 2 块，副屏当前未被枚举（需要冷启动恢复）"
    else
        echo "  [+] 两块都在，副屏枚举正常"
    fi
    echo
    echo "== 模块 =="
    if [ -r "$MODDIR_BASE" ]; then
        for d in "$MODDIR_BASE"/*; do
            [ -d "$d" ] || continue
            id=${d##*/}
            state=enabled
            [ -f "$d/disable" ] && state=DISABLED
            [ -f "$d/remove" ] && state=REMOVE
            desc=$(sed -n 's/^description=//p' "$d/module.prop" 2>/dev/null | head -1)
            echo "  [$state] $id  ${desc}"
        done
    else
        echo "  (读不到 $MODDIR_BASE：check 模式没 root，属正常)"
    fi
    echo
    echo "== 挂载 =="
    echo "  overlay 行数: $(grep -c overlay /proc/mounts 2>/dev/null)"
    if [ "$(id -u)" = "0" ]; then
        echo "  ksud: $(find_ksud 2>/dev/null || echo '未找到')"
    else
        echo "  ksud: (check 模式无 root，/data/adb 不可读，请在 GhostSam 终端里看)"
    fi
    echo
    echo "== 夜间模式 =="
    echo "  ui_night_mode: $(settings get secure ui_night_mode 2>/dev/null)  (0=自动 1=浅色 2=深色 3=定时)"
    echo "  解析结果    : $(dumpsys uimode 2>/dev/null | grep -o 'mComputedNightMode=[a-z]*' | head -1 | cut -d= -f2)"
    if [ -f /data/local/tmp/gs-night.log ]; then
        echo "  守护日志最后 3 行:"
        tail -3 /data/local/tmp/gs-night.log | sed 's/^/    /'
    fi
    echo
    echo "== 最近一次 reload 日志（$PERSIST）=="
    if [ -r "$PERSIST" ]; then
        tail -12 "$PERSIST" | sed 's/^/  /'
    else
        echo "  (暂无；跑一次 reload 才会生成)"
    fi
    exit 0
fi

# ------------------------------------------------------------------ run 模式
if [ "$(id -u)" != "0" ]; then
    echo "[!] 需要 root。请在 GhostSam 内置终端里执行："
    echo "      sh /data/local/tmp/gs-reload-modules.sh"
    exit 1
fi

# ----------------------------------------------------------------- mods 模式
# 导出模块清单，便于事后核查「到底装了哪些模块、脚本权限是否正常」。
# 背景：实测出现过 /data/adb/modules/m_rcq 这种目录名与 id 不一致、且
#       service.sh 第 27 行引用了不存在的 I_am_taffy 的模块，需要能快速看清。
if [ "$MODE" = "mods" ]; then
    OUT=/data/local/tmp/gs-modules.txt
    {
        echo "== 模块清单 $(date '+%m-%d %H:%M:%S') =="
        echo "kernel: $(uname -r)"
        echo "ksud  : $(find_ksud 2>/dev/null || echo 未找到)"
        echo
        for d in "$MODDIR_BASE"/*; do
            [ -d "$d" ] || continue
            echo "---------------- ${d##*/}"
            if [ -f "$d/module.prop" ]; then
                grep -E '^(id|name|version|versionCode|author)=' "$d/module.prop" 2>/dev/null | sed 's/^/  /'
            else
                echo "  (无 module.prop)"
            fi
            _flags=""
            [ -f "$d/disable" ] && _flags="$_flags disable"
            [ -f "$d/remove" ]  && _flags="$_flags remove"
            [ -f "$d/update" ]  && _flags="$_flags update"
            echo "  flags:${_flags:- 无}"
            _parts=""
            for sub in system vendor product odm my_stock; do
                [ -d "$d/$sub" ] && _parts="$_parts $sub"
            done
            echo "  partition:${_parts:- 无（不产生 overlay）}"
            for sc in post-fs-data.sh service.sh action.sh customize.sh uninstall.sh; do
                [ -f "$d/$sc" ] && echo "  $sc: $(ls -l "$d/$sc" 2>/dev/null | awk '{print $1}') $(wc -c < "$d/$sc" 2>/dev/null | tr -d ' ')B"
            done
            echo "  files: $(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')"
        done
    } > "$OUT" 2>&1
    chmod 644 "$OUT" 2>/dev/null
    cat "$OUT"
    echo
    echo "[+] 已写入 $OUT（adb 可读）"
    exit 0
fi

# ----------------------------------------------------------------- dump 模式
# 把某个模块目录打包到 /data/local/tmp，供 adb 侧拉下来逐行看脚本。
if [ "$MODE" = "dump" ]; then
    if [ -z "${DUMP_ID:-}" ]; then
        echo "用法: sh $0 dump <模块id>"
        echo "现有模块: $(ls "$MODDIR_BASE" 2>/dev/null | tr '\n' ' ')"
        exit 2
    fi
    _src="$MODDIR_BASE/$DUMP_ID"
    if [ ! -d "$_src" ]; then
        echo "[!] 没有这个目录: $_src"
        echo "    现有模块: $(ls "$MODDIR_BASE" 2>/dev/null | tr '\n' ' ')"
        exit 1
    fi
    OUT="/data/local/tmp/gs-mod-$DUMP_ID.tar"
    tar -cf "$OUT" -C "$MODDIR_BASE" "$DUMP_ID" 2>/dev/null
    chmod 644 "$OUT" 2>/dev/null
    ls -l "$OUT"
    echo "[+] 已打包，电脑侧：adb pull $OUT"
    exit 0
fi

# v14：只清理「本次 services 阶段新起」的重复实例，原有进程一律不动。
# 依据：zygisk_lsposed/service.sh 固定是 `daemon --force &`，zygisksu 的
# service.sh 也会再拉一次 zygiskd；每 reload 就各 +1，zn-daemon 曾累积到 7 个。
# 原有实例是 socket / 注入链的持有者，所以「留旧杀新」。
dedupe_new() {
    _dn=$1
    _before=$2
    _now=$(pidof "$_dn" 2>/dev/null)
    [ -z "$_now" ] && return 0
    _new=""
    for p in $_now; do
        case " $_before " in
            *" $p "*) ;;
            *) _new="$_new $p" ;;
        esac
    done
    _new=$(echo $_new)
    [ -z "$_new" ] && return 0
    _old_alive=0
    for p in $_before; do [ -d "/proc/$p" ] && _old_alive=1; done
    if [ "$_old_alive" = "1" ]; then
        kill $_new 2>/dev/null
        sleep 1
        for p in $_new; do [ -d "/proc/$p" ] && kill -9 "$p" 2>/dev/null; done
        echo "    --- dedupe $_dn: 清理本次新增 [$_new]（原有实例仍在，保留）"
        tlog "dedupe: $_dn 新增 [$_new] 已清理"
    else
        _keep=$(echo $_new | awk '{print $NF}')
        for p in $_new; do
            [ "$p" = "$_keep" ] && continue
            kill "$p" 2>/dev/null
        done
        echo "    --- dedupe $_dn: 原有已退出，本批只留 $_keep"
        tlog "dedupe: $_dn 保留 $_keep（原有已退出）"
    fi
    return 0
}

# ----------------------------------------------------------------- trim 模式
# 清理「重复的常驻实例」：lspd（LSPosed）与 zn-daemon（Zygisk Next），
# 以及任何依赖 boot_completed 边沿、卡住的等待循环。
# v15：保留**最早**的那个 —— 最早实例才持有 lspbridge / zygiskd 的 socket，
#      杀它会让「新启动的应用」拿不到注入（已运行的应用不受影响）。
# v15：保留哪个不再靠猜 —— 先用 socket_owner() 找「真正持有 unix socket」的那个，
#      找不到才退回「最早实例」。
socket_owner() {
    _nm=$1
    for p in $(pidof "$_nm" 2>/dev/null); do
        for l in /proc/$p/fd/*; do
            t=$(readlink "$l" 2>/dev/null) || continue
            case "$t" in
                socket:\[*\])
                    ino=${t#socket:[}; ino=${ino%]}
                    # v17：只认**监听中**的 socket（/proc/net/unix 第 4 列 Flags=00010000）。
                    # v16 只比对 inode，结果把某个随便的 socket 当成了持有者，
                    # trim 掉真正的 zn-daemon 后 Zygisk 注入全部 111 拒绝。
                    if awk -v i="$ino" '{for(k=1;k<=NF;k++) if($k==i && $4=="00010000"){f=1}} END{exit !f}' /proc/net/unix 2>/dev/null; then
                        echo "$p"; return 0
                    fi
                    ;;
            esac
        done
    done
    return 1
}

trim_group() {
    _name=$1
    shift
    _pids="$*"
    _n=$(echo $_pids | wc -w | tr -d ' ')
    if [ "$_n" -le 1 ]; then
        echo "  $_name: $_n 个，无需处理"
        return 0
    fi
    _keep=""
    _best=999999999
    for p in $_pids; do
        st=$(awk '{print $22}' "/proc/$p/stat" 2>/dev/null)
        [ -z "$st" ] && continue
        if [ "$st" -lt "$_best" ]; then _best=$st; _keep=$p; fi
    done
    if [ -z "$_keep" ]; then
        echo "  $_name: 读不到 starttime，跳过"
        return 0
    fi
    # socket 持有者优先（它才是注入侧真正连着的那个）
    if [ -n "${KEEP_HINT:-}" ]; then
        case " $_pids " in
            *" $KEEP_HINT "*) _keep=$KEEP_HINT; echo "  $_name: socket 持有者 = $_keep（优先保留）" ;;
        esac
    fi
    echo "  $_name: $_pids → 保留 $_keep"
    for p in $_pids; do
        [ "$p" = "$_keep" ] && continue
        kill "$p" 2>/dev/null
    done
    sleep 2
    for p in $_pids; do
        [ "$p" = "$_keep" ] && continue
        [ -d "/proc/$p" ] && kill -9 "$p" 2>/dev/null
    done
    echo "    --- 处理后：$(echo $_pids | wc -w) → $(pidof $_name 2>/dev/null | wc -w | tr -d ' ') 个"
    return 0
}

if [ "$MODE" = "trim" ]; then
    echo "== 清理重复常驻实例 =="
    _pids=$(pidof lspd 2>/dev/null)
    if [ -n "$_pids" ] && [ "$(echo $_pids | wc -w)" -gt 1 ]; then
        KEEP_HINT=$(socket_owner lspd 2>/dev/null); export KEEP_HINT
        trim_group lspd $_pids
        unset KEEP_HINT
    else
        echo "  lspd: ${_pids:-未运行}，无需处理"
    fi

    # zn-daemon 默认不动 —— 它的 socket 由 fork 出的 zygiskd 持有，
    # 从 zn-daemon 的 fd 里查不到监听 socket，无法可靠判断该留哪个。
    # 实测 v16 误杀后所有新进程报 `zn-zygisk-loader: connect daemon failed 111`。
    if [ "${TRIM_ZN:-0}" = "1" ]; then
        _zp=$(pidof zn-daemon 2>/dev/null)
        trim_group zn-daemon $_zp
    else
        echo "  zn-daemon: $(pidof zn-daemon 2>/dev/null | wc -w | tr -d ' ') 个（默认不清理，加 --zn 才动）"
    fi

    for _w in $(boot_waiters); do
        _wp=$(ps -A -o PID,ARGS 2>/dev/null | grep -a "$_w/service.sh" | grep -av grep | awk '{print $1}' | tr '\n' ' ')
        trim_group "$_w 循环" $_wp
    done
    echo
    echo "== 现状 =="
    echo "  lspd         : $(pidof lspd 2>/dev/null || echo 无)"
    echo "  zn-daemon    : $(pidof zn-daemon 2>/dev/null | wc -w | tr -d ' ') 个"
    echo "  卡住的等待者 : $(blocked_waiters)"
    echo "  boot 等待模块: $(boot_waiters | tr '\n' ' ')"
    echo "  /proc/modules: $(ls -l /proc/modules 2>/dev/null | awk '{print $1}')"
    exit 0
fi

if [ "$(getprop sys.boot_completed)" != "1" ]; then
    echo "[!] 系统未完成启动，先别动"
    exit 1
fi

# Validate the installed framework before replaying stages or changing boot state.
detect_framework || exit 3
ZYGISK_KIND=$(zygisk_kind)
BOOT_ORIGINAL=$(getprop sys.boot_completed)
BOOT_CHANGED=0
BOOT_HANDOFF=0
BOOT_RESETPROP=""
trap 'restore_boot_state' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# 兜底：逐模块跑脚本（不做挂载）。输出同样走文件，避免后台 daemon 占住管道。
run_one() {
    _dir=$1
    _sc=$2
    run_quiet "cd '$_dir' && MODDIR='$_dir' KSU=1 sh '$_dir/$_sc'"
}

run_fallback() {
    echo "[!] 兜底模式：只跑脚本，不做模块挂载 / system.prop，部分模块不会生效"
    for stage in post-fs-data.sh service.sh; do
        echo
        echo "==== $stage ===="
        for d in "$MODDIR_BASE"/*; do
            [ -d "$d" ] || continue
            id=${d##*/}
            [ -f "$d/disable" ] && { echo "[-] $id : disabled"; continue; }
            [ -f "$d/remove" ] && { echo "[-] $id : remove"; continue; }
            [ -f "$d/$stage" ] || continue
            echo "[*] $id"
            run_one "$d" "$stage"
        done
    done
}

echo "[*] uid=0  kernel=$(uname -r)"

rotate_log
T0=$(date +%s)
tlog "==== reload 开始  kernel=$(uname -r)  mode=$MODE zygote=$DO_ZYGOTE ===="
tlog "运行副本: $0"

KSUD=""
[ "$FORCE_FALLBACK" = "0" ] && KSUD=$(find_ksud) || true

if [ -z "$KSUD" ]; then
    [ "$FORCE_FALLBACK" = "0" ] && echo "[!] 找不到 ksud，退回兜底模式"
    tlog "找不到 ksud，走兜底模式"
    run_fallback
else
    echo "[*] 使用 $KSUD（等同软重启去掉 stop/start）"
    echo

    # v11：把 sys.boot_completed 置回 0。这是 ksud 的 soft_reboot() 本来就会做的一步
    # （init_event.rs: reset_boot_completed → ... → wait_for_boot_completed →
    #  on_boot_completed），我们绕开 stop/start 时漏掉了它。
    # 依赖「启动阶段切换」的模块会因此卡死：例如 m_rcq（RCQ环境）的 service.sh
    # 第 29 行 `resetprop -w sys.boot_completed 0`、第 129 行 `... 1`，
    # 在 boot_completed 始终为 1 的情况下拿不到事件，于是永久挂起在 129 行，
    # 它后面那一整段隐藏逻辑（chmod 000 /proc/modules 等）从头到尾没执行过。
    # 置 0 之后：service.sh 正常往下跑，重启 zygote 后 system_server 会把
    # boot_completed 重新设回 1，模块收到事件继续跑完。
    if [ "$DO_ZYGOTE" = "1" ]; then
        _rp=$(command -v resetprop 2>/dev/null || echo /data/adb/ksu/bin/resetprop)
        if [ -x "$_rp" ]; then
            BOOT_RESETPROP=$_rp
            BOOT_CHANGED=1
            "$_rp" sys.boot_completed 0 2>/dev/null
            _boot_rc=$?
            if [ "$_boot_rc" -ne 0 ] || [ "$(getprop sys.boot_completed)" != "0" ]; then
                echo "[X] Could not reset boot state; aborting before module stages."
                exit 3
            fi
            echo "    --- 已置 sys.boot_completed=0（供依赖启动阶段的模块使用）"
            tlog "resetprop sys.boot_completed 0（模拟 ksud soft_reboot 的启动阶段切换）"
        else
            echo "    --- 未找到 resetprop，跳过 boot_completed 重置"
            tlog "未找到 resetprop，跳过 boot_completed 重置"
        fi
    fi

    echo
    echo "==== ksud post-fs-data  (挂载模块 + post-fs-data.sh + system.prop) ===="
    tlog "stage post-fs-data 开始"
    run_quiet "\"$KSUD\" post-fs-data"
    _rc=$?
    echo "    exit=$_rc"
    tlog "stage post-fs-data 结束 exit=$_rc 累计=$(( $(date +%s) - T0 ))s"
    if [ "$_rc" -ne 0 ]; then
        echo "[X] post-fs-data failed; zygote will not restart."
        exit "$_rc"
    fi
    tlog "modules: $(ls "$MODDIR_BASE" 2>/dev/null | tr '\n' ' ')"

    echo
    echo "    --- overlay 挂载数: $(grep -c overlay /proc/mounts 2>/dev/null)  (只有带 system/ vendor/ 目录的模块才会产生)"
    _ov=""
    for d in "$MODDIR_BASE"/*; do
        [ -d "$d" ] || continue
        for sub in system vendor product odm; do
            [ -d "$d/$sub" ] && _ov="$_ov ${d##*/}:$sub"
        done
    done
    if [ -n "$_ov" ]; then
        echo "    --- 声明了分区 overlay 的模块:$_ov"
    else
        echo "    --- 现有模块都没有分区目录，overlay=0 属正常，看下面的进程判断是否生效"
    fi

    echo
    echo "==== ksud services  (service 阶段脚本) ===="
    # v14：先记下当前已有实例，services 跑完只清理「新增」的那些
    _snap_lspd=$(pidof lspd 2>/dev/null)
    _snap_zn=$(pidof zn-daemon 2>/dev/null)
    tlog "stage services 开始"
    run_quiet "\"$KSUD\" services"
    _rc=$?
    echo "    exit=$_rc"
    tlog "stage services 结束 exit=$_rc 累计=$(( $(date +%s) - T0 ))s"
    if [ "$_rc" -ne 0 ]; then
        echo "[X] services failed; zygote will not restart."
        exit "$_rc"
    fi
    # v20：lspd 绝对不能走 dedupe（"留旧杀新"会和 `daemon --force` 互撞，
    # 结果是新旧全没）。zn-daemon 没有这个语义，照旧只清本次新增。
    [ "$ZYGISK_KIND" = "zygisk-next" ] && dedupe_new zn-daemon "$_snap_zn"

    echo
    echo "==== Xposed daemon readiness: $FRAMEWORK_KIND / $ZYGISK_KIND ===="
fi

# Apply the same readiness gate to the fallback path. Vector is never passed to
# LSPosed's lspd recovery or duplicate-process cleanup.
ensure_framework "${_snap_lspd:-}" || exit 3

echo
echo "== 模块脚本是否跑起来（看进程）=="
_dup_lspd=$(pidof lspd 2>/dev/null | wc -w | tr -d ' ')
_dup_zn=$(pidof zn-daemon 2>/dev/null | wc -w | tr -d ' ')
ps -A -o NAME 2>/dev/null | grep -iE 'lspd|vectord|yhyc|zygiskd|zygisk-ptrace|sulogd|zn-daemon' | sort | uniq -c | sed 's/^/    /' || echo "    (无)"
[ "$_dup_lspd" -gt 1 ] 2>/dev/null && echo "    [!] lspd 有 $_dup_lspd 个实例，应为 1 个"

echo
echo "== 本机模块画像 =="
_any=0
for d in "$MODDIR_BASE"/*; do
    [ -d "$d" ] || continue
    _any=1
    _id=$(sed -n 's/^id=//p' "$d/module.prop" 2>/dev/null | head -1)
    _nm=$(sed -n 's/^name=//p' "$d/module.prop" 2>/dev/null | head -1)
    _st=""
    [ -f "$d/disable" ] && _st="${_st}已禁用"
    [ -f "$d/remove" ] && _st="${_st}待移除"
    case "$_id" in
        zygisksu)
            _st="${_st} implementation=$ZYGISK_KIND"
            [ "$ZYGISK_KIND" = "zygisk-next" ] && _st="${_st} zn-daemon=${_dup_zn}"
            ;;
        zygisk_vector) _st="${_st} Vector：vectord=$(pidof vectord 2>/dev/null)" ;;
        zygisk_lsposed) _st="${_st} LSPosed：lspd ${_dup_lspd} 个" ;;
        hma_oss_zygisk)
            _hj=""
            for _f in /data/misc/hide_my_applist_*/status.json; do
                [ -f "$_f" ] && _hj=$(grep -o '"workMode":[0-9]*' "$_f" 2>/dev/null | cut -d: -f2)
            done
            _st="${_st} HMA：控制端$(pm list packages 2>/dev/null | grep -q 'org.frknkrc44.hma_oss' && echo 已装 || echo 未装)，后台 workMode=${_hj:-未知}" ;;
        bszip)        _st="${_st} 仅 post-fs-data 阶段生效（隐藏逻辑在闭源 bin/main 里）" ;;
    esac
    echo "    ${_id:-?}（${_nm:-无 name}）${_st}"
done
[ "$_any" = "0" ] && echo "    (无 root，读不到 $MODDIR_BASE，跳过)"
if [ -d "$MODDIR_BASE/bszip" ]; then
    echo "    [!] bszip 的「隐藏 Root / 清理环境」会 rm -rf /data/local/tmp/*（连脚本和日志一起删）"
    echo "        以后请用这条固定路径：sh $SELF_BAK"
fi

echo
if [ "$FRAMEWORK_KIND" = "lsposed" ]; then
echo "== LSPosed 握手检查 =="
_pid=$(pidof lspd 2>/dev/null)
if [ -r /proc/net/unix ]; then
    _sock=$(grep -a lspbridge /proc/net/unix 2>/dev/null | sed 's/.*@//')
else
    _sock=""
    echo "    [!] /proc/net/unix 不可读（某个隐藏模块把它 chmod 成 440 了），本次无法查 socket"
fi
echo "    lspd pid : ${_pid:-无}"
echo "    socket   : ${_sock:-无}"
tlog "daemons: lspd=${_pid:-none} zn=$(pidof zn-daemon 2>/dev/null | wc -w | tr -d ' ') sockets=$(grep -ac lspbridge /proc/net/unix 2>/dev/null)"
if [ -z "$_pid" ]; then
    echo "    [!] lspd 没在跑，重启 zygote 后 LSPosed 会 Connection refused"
    echo "        改用：setsid sh /data/adb/modules/zygisk_lsposed/service.sh </dev/null >/dev/null 2>&1 &"
    tlog "警告: lspd 未运行"
fi
else
    echo "== Xposed daemon =="
    echo "    framework=$FRAMEWORK_KIND zygisk=$ZYGISK_KIND vectord=$(pidof vectord 2>/dev/null)"
    echo "    Vector is not tested using lspd/lspbridge or zn-daemon."
    _pid=""
fi

echo
echo "== 常驻实例盘点 =="
_wait_n=$(blocked_waiters)
_wait_mods=$(boot_waiters | tr '\n' ' ')
echo "    lspd: $([ -n "$_pid" ] && echo "$_pid" || echo 无)   zn-daemon: ${_dup_zn:-0}   卡住的边沿等待者: ${_wait_n:-0}"
[ -n "$_wait_mods" ] && echo "    依赖 boot_completed 边沿的模块: $_wait_mods"
[ "${_wait_n:-0}" -gt 0 ] && echo "    [!] 有 $_wait_n 个 resetprop -w 仍在阻塞，边沿没喂到（看门狗会补）"
[ "${_dup_zn:-0}" -gt 1 ] 2>/dev/null && echo "    [!] zn-daemon 有 ${_dup_zn} 个实例（每 reload +1），可跑：sh $0 trim"

echo
echo "== Zygisk 注入健康 =="
# 注意：adb shell 执行的命令行本身会被 adbd 记进 logcat，grep 时若不排除会把
# 自己的命令行当成命中（20:51/20:59 两次误报「1 条失败」都是这个原因）。
_zyf=$(logcat -d -t 500 2>/dev/null | grep 'zn-zygisk' | grep -v ' adbd ' | grep -c 'connect daemon failed')
_zyok=$(logcat -d -t 500 2>/dev/null | grep 'LSPosedFramework' | grep -vc ' adbd ')
echo "    近期 connect daemon failed: ${_zyf:-0}  LSPosedFramework 记录: ${_zyok:-0}"
if [ "${_zyf:-0}" -gt 0 ]; then
    echo "    [!] Zygisk 守护连不上（111）→ 新启动的应用拿不到注入，需跑一次 reload 重建"
    tlog "警告: zn-zygisk-loader connect daemon failed ${_zyf} 次"
fi

echo
if [ "$DO_ZYGOTE" = "0" ]; then
    echo "[+] 已跑到 services（-n）。要生效请手动：setprop ctl.restart zygote"
    exit 0
fi

# --------------------------------------------------- 夜间模式守护（v6）
# 现象：ui_night_mode 为「自动/定时」时，重启框架后 TwilightService 状态丢失，
#       One UI 会在拿到定位前回落成深色，且不会自己纠正。
# 做法：重启前把「用户模式 + 当时的昼夜判定」记下来，detach 一个守护进程，
#       等 system_server 起来后对比，发现偏了就拨回来，再还原用户原本的模式。
#       守护进程必须 setsid，否则 zygote 重启时被 SIGHUP 带走。
night_watch_start() {
    _pm=$(settings get secure ui_night_mode 2>/dev/null)
    case "$_pm" in
        0|3) ;;
        *) echo "    --- 夜间模式为固定值($_pm)，不需要守护"; return 0 ;;
    esac

    _pd=$(dumpsys uimode 2>/dev/null | grep -o 'mComputedNightMode=[a-z]*' | head -1 | cut -d= -f2)
    [ -z "$_pd" ] && _pd=false

    cat > "$NIGHT_HELPER" <<'EOS'
#!/system/bin/sh
# v21 夜间模式纠偏守护
#   MODE = 用户原本的模式（0 自动 / 3 定时 / 1 浅色 / 2 深色）
#   PRE  = 重启前那一刻的昼夜判定（true=深色）
# 实测（11-01 10:09）：auto 模式下 computed 卡在错误值时，单发 `cmd uimode night auto`
# 不会触发重算，值一动不动。必须先给一个明确的固定值把它顶过去，再回到 auto。
# 而「顶」的那一步一旦被打断（终端断开 / 进程被 kill），模式就留在固定值上，
# 表现出来就是「夜间模式不再自动」——所以这里加了 trap，任何路径都还原。
MODE=$1; PRE=$2
LOG=${3:-/data/local/tmp/gs-night.log}
log() { echo "[$(date +%m-%d' '%H:%M:%S)] $*" >> "$LOG"; chmod 644 "$LOG" 2>/dev/null; }
cur() { dumpsys uimode 2>/dev/null | grep -o 'mComputedNightMode=[a-z]*' | head -1 | cut -d= -f2; }
setmode() {
    case "$1" in
        0) cmd uimode night auto ;;
        3) cmd uimode night custom_schedule ;;
        1) cmd uimode night no ;;
        2) cmd uimode night yes ;;
    esac
}
restore() {
    trap - EXIT INT TERM HUP
    [ "${_RESTORED:-0}" = "1" ] && return 0
    _RESTORED=1
    setmode "$MODE" >/dev/null 2>&1
    _v=$(settings get secure ui_night_mode 2>/dev/null)
    if [ "$_v" != "$MODE" ]; then
        sleep 1
        setmode "$MODE" >/dev/null 2>&1
        _v=$(settings get secure ui_night_mode 2>/dev/null)
    fi
    log "restore mode=$_v"
}
trap 'restore; exit 0' EXIT INT TERM HUP

: > "$LOG"
log "start mode=$MODE pre_dark=$PRE"

i=0
while [ $i -lt 180 ]; do
    [ "$(getprop sys.boot_completed)" = "1" ] && pidof system_server >/dev/null 2>&1 && break
    sleep 2; i=$((i+1))
done
sleep 45

C=$(cur); [ -z "$C" ] && C=$PRE
log "post_dark=$C"

n=0
while [ "$C" != "$PRE" ] && [ $n -lt 3 ]; do
    n=$((n+1))
    if [ "$PRE" = "false" ]; then cmd uimode night no; else cmd uimode night yes; fi
    sleep 3
    setmode "$MODE" >/dev/null 2>&1
    sleep 4
    C=$(cur); [ -z "$C" ] && C=$PRE
    log "第 $n 轮纠正后 post_dark=$C"
done

if [ "$C" = "$PRE" ]; then
    log "判定正确，模式已还原 $MODE"
else
    log "仍偏（$C != $PRE），模式已还原 $MODE；如需手动确认：设置-显示-深色模式"
fi
EOS
    chmod 755 "$NIGHT_HELPER" 2>/dev/null
    setsid sh "$NIGHT_HELPER" "$_pm" "$_pd" "$LOGDIR/gs-night.log" </dev/null >/dev/null 2>&1 &
    echo "    --- 已挂夜间模式守护：模式=$_pm 当前昼夜=$_pd（日志 $LOGDIR/gs-night.log）"
}

night_watch_start

# v13：boot_completed 看门狗（兼「边沿发生器」）。
# 实测结论：`resetprop -w sys.boot_completed 1` 只在值发生 0→1 变化时被唤醒，
# 若等待开始时值已经是 1，它会永久挂起。
# v15：改成「按需」——先由主脚本扫出真正会等 boot_completed 的模块（boot_waiters），
#   有等待者才制造边沿；没有就只保留「卡 0 → 置 1」的安全网。
#   成功判据也从「/proc/modules 是否 000」（只有 RCQ 适用）改为
#   「还有没有 resetprop -w 卡着」—— 模块无关，喂到了等待者自己会退出。
# 看门狗用 setsid 脱离会话，zygote 重启后依然存活。
boot_watchdog_start() {
    cat > "$BOOT_WD" <<'EOS'
#!/system/bin/sh
LOG=${1:-/data/local/tmp/gs-boot-wd.log}
WAITERS=${2:-}
RP=$(command -v resetprop 2>/dev/null || echo /data/adb/ksu/bin/resetprop)
log() { echo "[$(date +%m-%d' '%H:%M:%S)] $*" >> "$LOG"; chmod 644 "$LOG" 2>/dev/null; }
perm() { p=$(stat -c %a "$1" 2>/dev/null); case "$p" in ''|*[!0-9]*) echo "$p" ;; *) printf "%03d" "$p" ;; esac; }
blocked() {
    ps -A -o ARGS 2>/dev/null | grep -a 'resetprop' | grep -a '\-w' | grep -a 'boot_completed' \
        | grep -av grep | wc -l | tr -d ' '
}
edge() {
    "$RP" sys.boot_completed 0 2>/dev/null
    sleep 2
    "$RP" sys.boot_completed 1 2>/dev/null
    log "已制造 0->1 边沿，boot_completed=$(getprop sys.boot_completed)"
}
: > "$LOG"
T0=$(date +%s)

# ---- 安全网：boot_completed 长时间停在 0 会把系统拖到冷重启（19:02 那次）
safety() {
    for w in 60 60; do
        sleep $w
        B=$(getprop sys.boot_completed)
        if [ "$B" = "0" ]; then
            "$RP" sys.boot_completed 1 2>/dev/null
            log "发现 boot_completed=0，已主动置 1"
        else
            return 0
        fi
    done
}

if [ -z "$WAITERS" ]; then
    log "start（本机无依赖 boot_completed 边沿的模块 → 只跑安全网）"
    safety
    log "结束，boot_completed=$(getprop sys.boot_completed)"
    exit 0
fi

log "start（等待模块：$WAITERS；等系统启动 + ≥25s 后制造边沿）"

i=0
while [ $i -lt 300 ]; do
    [ "$(getprop sys.boot_completed)" = "1" ] && break
    sleep 1; i=$((i+1))
done
log "系统启动完成，用时 ${i}s"

while [ $(( $(date +%s) - T0 )) -lt 25 ]; do sleep 1; done

edge

n=0
while [ $n -lt 2 ]; do
    sleep 8
    b=$(blocked)
    if [ "$b" = "0" ]; then
        log "边沿已喂到（无等待者残留），/proc/modules=$(perm /proc/modules)"
        break
    fi
    n=$((n+1))
    log "仍有 $b 个等待者阻塞，第 $n 次补边沿"
    edge
done
log "结束：等待者残留=$(blocked)，/proc/modules=$(perm /proc/modules)，/proc/cmdline=$(perm /proc/cmdline)"
EOS
    chmod 755 "$BOOT_WD" 2>/dev/null
    _ws=$(boot_waiters | tr '\n' ' ')
    # v18：先确认 helper 真的落盘了，否则启动只会静默失败（20:47 那次就丢了日志）
    if [ ! -s "$BOOT_WD" ]; then
        echo "    [!] 看门狗脚本没写成（$BOOT_WD 为空），改走内联安全网"
        tlog "警告: $BOOT_WD 写入失败，退回内联安全网"
        setsid sh -c 'sleep 90; [ "$(getprop sys.boot_completed)" = "0" ] && /data/adb/ksu/bin/resetprop sys.boot_completed 1' </dev/null >/dev/null 2>&1 &
        return 0
    fi
    if [ -z "$_ws" ]; then
        # 没有等待者时不需要边沿，只挂一条最小的安全网（卡 0 会拖到冷重启）
        setsid sh -c 'sleep 90; [ "$(getprop sys.boot_completed)" = "0" ] && /data/adb/ksu/bin/resetprop sys.boot_completed 1' </dev/null >/dev/null 2>&1 &
        echo "    --- 无依赖 boot_completed 的模块，只挂 90s 安全网"
        tlog "watchdog: 无等待者，跳过边沿制造（仅安全网）"
        return 0
    fi
    setsid sh "$BOOT_WD" "$LOGDIR/gs-boot-wd.log" "$_ws" </dev/null >>"$LOGDIR/gs-boot-wd.err" 2>&1 &
    echo "    --- 已挂 boot_completed 看门狗（等待模块：$_ws｜日志 $LOGDIR/gs-boot-wd.log）"
}

# Framework readiness was checked immediately after module stages, before any
# night-mode helper was launched. An abort there runs restore_boot_state.
[ "$DO_ZYGOTE" = "1" ] && boot_watchdog_start

echo "[*] 重启 zygote ..."
tlog "下发 setprop ctl.restart zygote（累计 $(( $(date +%s) - T0 ))s）"
# Transfer boot-state recovery to the detached watchdog before the terminal can
# receive HUP. If init rejects the request, the EXIT trap still restores it.
BOOT_HANDOFF=1
if ! setprop ctl.restart zygote; then
    BOOT_HANDOFF=0
    echo "[X] Zygote restart request failed."
    exit 3
fi
tlog "zygote 重启已下发，本次 reload 结束"
echo "[+] 已下发。终端会立即断开，约 10-20 秒回到锁屏。"
echo "    副屏不应受影响；若断开后副屏黑了，说明走的是 stop/start 那条路。"
echo "    日志：$PERSIST"
