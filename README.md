# 一键重载模块（gs_quick_reload）· 三星 Galaxy Z Fold7 专用

> **一个按钮，让 KernelSU 模块生效——而不用拿折叠屏的副屏去换。**
>
> 专为 **三星 Galaxy Z Fold7（SM-F966B，One UI 9 / Android 17）** 调制。
> 点击模块页的「执行」，脚本会按 KernelSU 自己的流程执行 `post-fs-data` / `services`
> 两个阶段，然后只重启 zygote，**跳过 `stop` / `start`**。SurfaceFlinger 全程存活，
> 折叠屏的副屏（`port=148`）不会消失。

## Vector / NeoZygisk support in this fork

This fork adds separate handling for enabled `zygisk_vector` (Vector) and
`zygisk_lsposed` (LSPosed) modules, including renamed module directories.
Disabled or removal-pending modules are ignored. Enabling both frameworks
aborts before any boot-state change or module stage.

For Vector, the reload requires exactly one `vectord` process and a successful
response from its CLI API. It launches `org.matrix.vector.daemon.Cli status`
through `app_process` with the detected module's `daemon.apk` as its explicit
classpath. It does not use the upstream `cli` wrapper, which hardcodes the
module directory and may select a separate debug APK. Missing APK/runtime tools
abort before module stages; an absent CLI API or unresponsive daemon fails the
readiness gate and restores any boot flag changed by this run.
Each probe gets up to 10 seconds, within a 30-second polling deadline with
progress output. Process existence alone is not treated as a readiness check.
The check proves daemon IPC is responding, **not** that
every app will be injected after Zygote restarts. It does not kill Vector daemons
or blindly rerun Vector's `service.sh` to recover a failure.

NeoZygisk is identified from module metadata rather than assuming that every
`zygisksu` installation is Zygisk Next. Zygisk Next's `zn-daemon` deduplication
is only applied to that implementation.
Unidentified implementations are reported as `unknown` and are not subjected
to process-killing deduplication. Zygisk Next retains its daemon-count display.

LSPosed recovery remains on the `ksud` path (including `-n`, as upstream did),
and is skipped in script-only fallback mode. Only the exact supported identities
`zygisk_vector` and `zygisk_lsposed` select framework recovery; other fork IDs
are not guessed from generic `daemon` text in a script. Surrounding whitespace
in module metadata is trimmed.

When this script changes `sys.boot_completed`, exits or catchable signals before
the Zygote restart request restore the previous value. Stage-command failures
also abort the restart. After an accepted restart request, the existing detached
watchdog handles boot-state recovery. Restoring the property does not undo
module scripts or mounts already applied; SIGKILL cannot run shell cleanup.
Reloads and `trim` take the same per-kernel-boot directory lock, retained until
the main script and both detached helpers finish. A second run aborts without
replaying stages or trimming daemons.
An interrupted run that cannot clean up keeps its lock for that boot; a full
reboot uses a fresh boot-ID namespace. After acquisition, old-boot lock
directories are removed only if their UUID names and boot-ID metadata agree;
symlinks and directories without matching ownership metadata are left alone.

Night/boot helper wrappers detach before the restart request but wait for its
acceptance before executing. Immediately after a successful request, the main
script writes acceptance and removes its parent marker explicitly; the normal
handoff does not rely on the EXIT trap. A rejected request cancels both wrappers, restores
the changed boot flag, and releases the lock when they exit. All watchdog paths,
including inline fallbacks, receive the same resolved `resetprop` executable.
Failure to prepare the optional night helper is logged as a warning and does
not block the restart. The script does not recover a missing display by
restarting SurfaceFlinger.

Known side effect: resetting `sys.boot_completed` and manufacturing a 0→1 edge
can re-run matching Android init property actions; it is not scoped to waiting
module scripts. See [Android init property triggers](https://android.googlesource.com/platform/system/core/+/main/init/README.md#trigger).
This stop applies to a failed `ksud` command or timeout. Current
[KernelSU-Next stage handling](https://github.com/KernelSU-Next/KernelSU-Next/blob/dev/userspace/ksud/src/init_event.rs)
logs individual module-script errors internally; those are not automatically
equivalent to a non-zero stage-command exit.

Installation refreshes both `/data/adb/gs/gs-reload-modules.sh` and the legacy
`/data/local/tmp/gs-reload-modules.sh` copy. Running a script never copies `$0`
over another copy. Use the installed module's Action button or its script path
for the current version. The installer reports a failed backup/copy operation.

Validation: `sh -n module/gs-reload-modules.sh` and
`python3 -m unittest discover -s tests -v` (host mocks, no Android operations).
**These fork changes have not been validated on a phone, including CZJ1.**
The device-test claims in the original documentation below belong to upstream.

Implementation references:
- [Vector service startup](https://github.com/JingMatrix/Vector/blob/master/zygisk/module/service.sh)
- [Vector daemon launcher](https://github.com/JingMatrix/Vector/blob/master/zygisk/module/daemon)
- [Vector CLI and exit status](https://github.com/JingMatrix/Vector/blob/master/daemon/src/main/kotlin/org/matrix/vector/daemon/Cli.kt)
- [NeoZygisk service stage](https://github.com/JingMatrix/NeoZygisk/blob/master/module/src/service.sh)

---

## 适用机型：三星 Galaxy Z Fold7（专用）

> **本模块专为 Z Fold7 调制。** 三星 Galaxy Z Fold7（SM-F966B），
> 系统 **One UI 9 / Android 17**，内核 6.6.127（KMI `android15-6.6`，
> 这里的 `android15` 是内核分支命名，与系统版本号无关），
> root 环境为 [GhostSam](https://github.com/snothin/GhostSam) 晚加载临时 root。

整套流程、看门狗时序、夜间模式纠正逻辑、lspd 健康判据，都是在这一台机器上反复实测调出来的
（包括「副屏 `port=148` 整场不掉」这个核心收益）。所以默认按 **Fold7 + Android 17** 交付，
`compatibility.androidMinApi` 也钉在 37（Android 17）。

其他三星折叠屏（Fold6 / Flip 系列）或别的 Android 版本，原理相通但**没有实测**；
要用的话请先跑一次 `check` 体检，出问题请提 issue 并附机型与系统版本。

- 作者：CodeFishK · https://github.com/CodeFishK
- 适用 root 环境：[GhostSam](https://github.com/snothin/GhostSam)（三星临时 root，冷启动后需重新获取）
  或任意 KernelSU / 兼容分支

---

## 一、它解决什么问题

KernelSU 自带的「软重启」实际是 `ksud` 的 `soft_reboot()`：

```
stop → post-fs-data → start → services → 等 boot_completed
```

`stop` 会把 SurfaceFlinger 一起停掉，整个显示栈重建。在折叠屏上，重建后 composer HAL
不再重发 hotplug，HWC 里就只剩内屏，副屏整场会话都不亮，只能冷启动恢复。

本模块只做中间那两步，跳过 `stop`/`start`：

```
ksud post-fs-data              # 挂载模块、跑 post-fs-data.sh、加载 system.prop
ksud services                  # 跑 service 阶段脚本
setprop ctl.restart zygote     # 只重启 zygote，SurfaceFlinger 活着
```

代价：所有应用退出一次（zygote 重启），约 20 秒回到锁屏。
收益：副屏不受影响。实测 SurfaceFlinger 可连续存活一整天，`port=147` / `port=148` 都在线。

---

## 二、安装

1. 在 KernelSU 管理器中安装本模块的 ZIP
2. 装完提示「重启生效」时**可以忽略**——本模块不挂载任何文件，装完即可点「执行」

前提：设备已有 root（KernelSU 或兼容分支）。本模块**不提供 root**，也不修改系统分区。

---

## 三、使用

装好后进入模块页，点「执行」。终端等价命令：

```sh
sh /data/adb/modules/gs_quick_reload/gs-reload-modules.sh
```

只体检、不重启（建议先跑这个看现状）：

```sh
sh /data/adb/modules/gs_quick_reload/gs-reload-modules.sh check
```

### 子命令

| 命令 | 作用 |
|---|---|
| 无参数 | 完整流程：ksud 两阶段 + 重启 zygote |
| `-n` | 只跑到 services，不重启（调试用） |
| `-f` | 兜底模式：逐个模块目录跑脚本，不走 ksud |
| `check` | 只体检：显示设备、模块画像、守护实例、注入健康、夜间模式 |
| `mods` | 导出模块清单到 `/data/local/tmp/gs-modules.txt` |
| `dump <模块id>` | 把某个模块目录打包成 tar，便于离线分析 |
| `trim` | 清理重复的 `lspd`（保留持有监听 socket 的那个） |
| `trim --zn` | 连 `zn-daemon` 一起清（**有风险**，见第五节） |
| `night` | 把夜间模式还原成「自动（日落到日出）」并纠正昼夜判定，不需要 root |

### 夜间模式自愈

`ui_night_mode` 取值：**0 = 自动（日落到日出）**、1 = 始终浅色、2 = 始终深色、
3 = 自定义时间表。注意 0 不是「始终浅色」，很容易搞反。

重启 zygote 会让 `TwilightService` 丢状态，One UI 常在工作日间回落到深色且不自纠。
所以脚本在重启前先记下当时的昼夜判定，45 秒后对比，偏了就拨回来，再还原用户原本的模式。

两个实测结论：

1. **`cmd uimode night auto` 在判定卡错时不会触发重算** —— 单发 auto 数值不动，
   必须先给一个明确的固定值（`night no` / `night yes`）顶过去，再回 auto 才有效。
2. 「顶」那一步若被打断（终端断开、进程被 kill），模式会停在固定值上，
   表现就是「夜间模式不再自动」。因此守护带 `trap`：任何退出路径都还原原模式，
   并回读 `settings get secure ui_night_mode` 校验。

真遇到了，用 `night` 子命令收尾：

```sh
sh /data/adb/modules/gs_quick_reload/gs-reload-modules.sh night
```

---

## 四、日志

都在 `/sdcard/GS/logs/`，不需要 root 就能读，方便直接贴出来求助：

| 文件 | 内容 |
|---|---|
| `gs-reload.log` | 主日志：每轮开始时间、各阶段 exit code、守护进程数、实际运行的脚本副本 |
| `gs-boot-wd.log` | `sys.boot_completed` 看门狗（仅当有模块等待该属性时才启动） |
| `gs-night.log` | 夜间模式守护：重启前后的昼夜判定对比 |
| `gs-boot-wd.err` | 看门狗 helper 的 stderr（正常为空） |

脚本自身另备份在 `/data/adb/gs/gs-reload-modules.sh`，即使 `/data/local/tmp`
被别的模块清空也仍可用。

---

## 五、几个已经踩过的坑

1. **`zn-daemon` 会一次比一次多**
   Zygisk Next 的 `service.sh` 每执行一次就多一个守护进程，都是 sleeping，不影响功能，
   但会线性增长。**不要随手 `trim` 它**：监听 socket 在 fork 出来的 `zygiskd` 里，
   从自身 fd 判不出持有者，误杀会让所有新启动的应用报
   `zn-zygisk-loader64: connect daemon failed with 111`（丢注入，已运行的应用不受影响）。
   嫌多就冷启动一次。

2. **`resetprop -w sys.boot_completed 1` 会永久挂起**
   该等待只在属性**发生 0→1 变化**时唤醒；若等待开始时值已是 1，就再也醒不过来。
   某些模块（如 RCQ 环境）依赖它分段执行，于是「启动太快」时后续片段永不执行。
   脚本会先扫描模块脚本里有没有这类等待者，有才在重启后主动制造一次 0→1 边沿
   （距重启 ≥25 秒，确保等待已开始）；没有就只保留「卡 0 太久 → 置 1」的安全网。

3. **不要把日志放在 `/data/local/tmp`**
   某些「隐藏 root / 清理环境」模块会 `rm -rf /data/local/tmp/*`，脚本和日志一起消失。

4. **临时 root（如 [GhostSam](https://github.com/snothin/GhostSam)）冷启动后全部丢失**
   root、模块挂载、脚本进程都会没有，需要重新获取 root 再点一次「执行」。
   这是临时 root 的固有行为，不是模块的问题。

---

## 六、排错顺序

1. `sh <脚本> check` —— 副屏端口（`port=147`/`port=148`）、`lspd` 实例数、
   `zn-daemon` 数量、注入失败数、夜间模式
2. `/sdcard/GS/logs/gs-reload.log` —— 哪一步 exit 非 0、卡在哪个阶段
3. `pidof lspd` —— LSPosed 是否在跑（只看这个；`/proc/net/unix` 被改成 440 时
   非 root 读不到是正常的）
4. `logcat | grep LSPosedFramework` —— 真正的注入证据，形如
   `(com.tencent.mobileqq:MSF)[...] installed 1 QQ hooks`
5. 副屏不亮且 `port=148` 缺失 —— 说明显示栈被 `stop` 重建过，
   检查是不是用了管理器自带的「软重启」而不是本模块

---

## 七、卸载

KernelSU → 模块 → 移除本模块即可，不会留下挂载。
`/data/adb/gs/` 与 `/sdcard/GS/logs/` 是纯脚本与文本，可一并手动删除。

## 免责

脚本会重启 zygote 并调用 `ksud` 的阶段命令，属于对系统运行状态有实际影响的操作，
请自行判断风险。本模块不修改系统分区，也不触碰 `/data/property` 等危险路径，
但**任何 root 操作都不能保证在所有 ROM 版本上零风险**。

## 相关项目与致谢

- **[GhostSam](https://github.com/snothin/GhostSam)** —— 三星机型的临时 root 方案，
  本模块的所有实测都在它提供的晚加载 root 环境下完成。没有它，Z Fold7 上连调试的
  入口都没有。
- **KernelSU / KernelSU Next** —— 模块框架与 `ksud` 的阶段命令。
- 本模块作者：**CodeFishK**（https://github.com/CodeFishK）。

## 许可证

MIT。见 [LICENSE](LICENSE)。
