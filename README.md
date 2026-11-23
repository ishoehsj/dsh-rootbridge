# DSH Root Bridge

让 dsh-go 里的助手以**真 root** 执行命令，**只对 dsh-go 生效**，不重编译 APK。

## 原理

dsh-go 的引擎跑在 proot 里（`uid=0` 是假的、无 capabilities），出不去。
模块的 `service.sh` 由 KernelSU 以真 root 在开机时启动，盯住一个目录：

```
数据面   /data/data/io.github.ccch1mneyyy.dsh_app/files/runtime/rootfs/root/.dsh/bus/
              ← 引擎写 req.<id>（base64 命令）
              → 模块以 root 执行，写 out.<id>（首行退出码 + base64 输出）
```

这个目录同时是 App 私有空间和 proot 内的 `/root/.dsh/bus/`，
所以两边都看得见，而别人都看不见。

守护进程外面还有一层 supervisor（`.s/watch`）：

```
service.sh → .s/watch（常驻，掉了就重启 .s/main）
                 └── .s/main（真正干活的守护进程）
```

`.s/main` 被系统杀掉（LMK、管理器清理、升级竞态）时，supervisor 3 秒内把它拉回来，
不会出现"root 用着用着就没了"；supervisor 自己也被杀的话，用下面任一入口一键重启：

| 入口 | 位置 |
|---|---|
| 模块动作按钮 | KernelSU → 模块卡片 → **执行**（跑 `action.sh`） |
| 模块 WebUI | 模块卡片 → **打开**（`webroot/index.html`，带状态和启停按钮） |
| 命令行 | `sh /data/adb/modules/dsh_bridge/action.sh status\|start\|restart\|reconnect\|stop\|doctor` |

App 重置运行时（升级、清数据）会连 `dshroot` 和技能一起清掉，守护进程每 30 秒
核对一次资产，自动补回，不需要重装模块。

## 两种用法

| 命令 | 语义 |
|---|---|
| `dshroot 'cmd'` | 一次性：每条命令独立进程，跑完即走 |
| `dshtty -c 'cmd'` | 会话式：背后是常驻 root shell，`cd`/`export`/变量都保留 |
| `dshtty` | 交互终端（有 tty 给提示符，无 tty 从 stdin 读脚本） |

```sh
dshroot 'id'                       # uid=0, context=u:r:ksu:s0
dshtty -c 'cd /data/adb/modules'   # 进目录
dshtty -c 'pwd'                    # → /data/adb/modules（状态保留）
dshtty -c 'ls -d */'               # 接着在这个目录里看
dshtty ls                          # 会话列表：状态、心跳、当前目录
dshtty kill work                   # 结束 DSH_TTY_SESSION=work 那个会话
dshtty status                      # 桥 + 会话状态，排错先看它
```

会话数据面（每个会话一个常驻 `term-shell.sh`，都以 root 跑）：

```
.sess/<名字>/
  in.<id>   客户端投递的命令（原子 mv）
  out.<id>  输出（stdout+stderr）
  rc.<id>   退出码；出现即表示执行完毕
  .pwd      当前目录，给客户端画提示符
  .beat     心跳 1 秒 1 次，客户端据此判断会话是否活着
  .quit     = 请求结束；  .dead = shell 已退出
  .pid    会话属主；有它且心跳新鲜才算活着，老实例晚退场不会误伤新会话
```

约定：命令的 stdin 接 `/dev/null`（会话没有 tty，`cat`/`read` 不会挂死整条会话），
长任务用 `nohup … &`；在会话里 `exit` 会结束它，用 `dshtty reset` 重开。

## 痕迹

模块本身刻意做"轻"：

| 项 | 状态 |
|---|---|
| system 分区挂载 | **不挂载**（`skip_mount`），`/proc/self/mounts` 里没有本模块的条目 |
| 模块目录 / 进程名 | `dsh_bridge` + `.s/main`，不含 `root` 关键词 |
| 常驻进程 | 1 个 supervisor + 1 个守护进程（空闲 2s 轮询）+ 按需的会话 shell（闲置 10 分钟自退） |
| 队列 / 会话文件 | 在 App 私有目录，0700，属主是 App uid |
| 普通 App 可见性 | `/data/adb` 是 `700 root`，`/proc` 是 `hidepid=invisible`，看不到目录也看不到进程 |

真正的指纹来自 KernelSU 自身（`/system/bin/su`、`/data/adb/ksu`），不是这个模块；
反 root 检测命中的是那一层。

## 为什么只对 dsh 生效

1. 目录在 `/data/data/<dsh 包名>/files/` 下 —— Android 每个应用独立 uid + `app_data_file`
   的 SELinux 域，**别的应用连父目录都进不去**，不是靠文件名保密。
2. 目录 0700、属主是 dsh 的 uid；写出的结果文件 0600。
3. 守护进程逐个校验 `req.*` 的属主，**不是 dsh 的 uid 就拒绝并删掉**，日志留一行 `reject foreign request`。
4. 没有 TCP、没有 unix socket、没有 world-readable 的临时文件（`umask 077`，临时文件在 0700 目录内）。
5. App 被卸载或数据被清，守护进程只空闲，**不会**自己去重建目录。
6. 日志写在 App 私有目录里（`root/.dsh/bus.log`），不落在 `/data/adb`。

## 适配的管理器

同一个 zip 通吃三种，不需要改任何东西：

| 管理器 | 依赖的机制 | 说明 |
|---|---|---|
| **Magisk** (v20.4+) | `module.prop` + `service.sh` + `customize.sh` | 自带 `META-INF/` 安装器，也支持 recovery 刷入；`skip_mount` 表示不挂载 system |
| **KernelSU** | 同 Magisk 模块格式 | 用自己的安装器，`META-INF/` 会被忽略 |
| **APatch** | 同 Magisk 模块格式 | 模块目录同样是 `/data/adb/modules`，`service.sh` 照常执行 |

差异都做了兜底：

- `ui_print` / `set_perm_recursive` 在三个安装器里都有；万一缺了，`customize.sh` 用等价命令补上
- `customize.sh` 里**不调用 `exit`**（Magisk 要求由安装器收尾）
- `service.sh` 只用 POSIX shell + busybox 常见命令（`base64`/`stat`/`timeout`/`find`），
  宿主的 root shell 由 `/system/bin/sh` 显式调用，不受 busybox 影响
- 启动日志会记 `manager=Magisk|KernelSU|APatch`，排错时先看这一行

## 安装

1. KernelSU 管理器 → 模块 → 从本地安装 → 选 `dsh-rootbridge.zip`
2. **重启手机**
3. 回到对话里让我自检（`dshroot id`）

装完立刻就能用；如果 `dshroot` 没反应，先去模块卡片点一次 **执行**（或 WebUI 里的「启动」），
不用重启。

安装时模块会顺手做两件事，重启后新开一个会话就能直接用：

- 把 `dsh-root` 技能写进 `~/.dsh/skills/dsh-root/`（每个新会话自动出现在技能列表里）
- 把 `dshroot` 命令写进 `/usr/local/bin/`（proot 里的调用入口）

App 重置运行时或升级后，模块每分钟检查一次，缺了自动补回。

## 验证

```sh
dshroot id           # 期望 uid=0(root)，且 context 不是 untrusted_app
dshroot getenforce
dshtty -c 'cd /data/adb && pwd && ls | head -3'
dshtty -c 'pwd'      # 期望仍是 /data/adb —— 证明会话状态真的保留了
dshtty status
sh /data/adb/modules/dsh_bridge/action.sh status   # 桥 + supervisor 状态
```

## 排错

先看状态（不需要 root 通道活着）：

```sh
sh /data/adb/modules/dsh_bridge/action.sh status
cat /data/local/tmp/dsh_bridge.status    # 守护进程快照：pid / appuid / loop / assets
cat /data/local/tmp/dsh_bridge.log       # 完整日志（含每次退出与重启原因）
```

容器里也可以直接看：

```sh
dshroot --status
cat ~/.dsh/bus.log
```

日志里常见行：

- `supervisor: up pid=...` — supervisor 起来了
- `daemon exited rc=... after ...s` — 守护进程退出过；紧跟的 `start ...` 是自动重启
- `start manager=KernelSU appuid=... dir=...` — 守护进程接手
- `skill synced` / `helper synced (...)` — App 重置运行时后资产被补回
- `already running pid=...` — 另一个实例在服务（正常，不会重复执行请求）
- `reject foreign request` — 有人冒充 App 写队列（会被删掉）
- 什么都没有：SELinux 可能不让 su 域写 App 私有目录，需要把队列换到 `/sdcard`

桥彻底停了（`action.sh status` 说"没有在运行"）：点模块卡片的 **执行** 或 WebUI 的「启动」；
再不行就重装模块并重启一次。守护进程还在但心跳停了（"卡死"）时，模块卡片的 **执行** 会自动
判定并重启它；App 里也可以先试 `dshroot --reconnect`（不需要 root）。

v1.9.0 起，`执行` / `重连` 都会核对**真实心跳**才报成功，失败会打印方向（App 目录、
rootfs、锁、日志尾），`action.sh doctor` 一次给全，贴出来就能定位。

## 安全边界

- 这是**完整 root 通道**，dsh-go 里能跑的东西就能拿到 root —— 包括被提示注入左右的会话。
- 不要把手机借给不信任的人，也不要在这个会话里粘贴来路不明的"帮我执行一下"。
- 删模块重启即可彻底关闭，不留后台进程。

## 发布与在线更新

管理器通过 `module.prop` 的 `updateJson` 拉一个 JSON 判断有没有新版本。仓库里已经接好了：

```json
{ "version": "v1.2.0", "versionCode": 3,
  "zipUrl": "https://github.com/<repo>/releases/download/v1.2.0/dsh-rootbridge-v1.2.0.zip",
  "changelog": "https://raw.githubusercontent.com/<repo>/main/CHANGELOG.md" }
```

发一版要做的四件事：

1. `build.sh` 会自动生成 `update.json` 和 `dsh-rootbridge-<版本>.zip`
2. 把 `update.json`、`CHANGELOG.md` 推到仓库 `main` 分支
3. 发 Release：**tag 必须等于 `version`**（如 `v1.2.0`），**附件名必须是 `dsh-rootbridge-v1.2.0.zip`**
4. 管理器里下拉刷新，模块卡片就会出现更新提示

仓库名不叫 `lxsfful/dsh-rootbridge` 的话，构建时传 `REPO=你的/仓库 ./build.sh`，
同时把 `module.prop` 里的 `updateJson` 一并改掉 —— 两处指向同一个仓库才有用。

## 迭代升级

改完代码，两条命令：

```sh
cd /root/workspace/dsh-rootbridge
./test-local.sh     # 本地模拟：资源同步、命令队列、越权拦截
./build.sh          # 打包到 /sdcard/Download/DSH-Go/dsh-rootbridge.zip
```

**两个版本号别忘**

| 改了什么 | 要动的版本 |
|---|---|
| `service.sh` / `customize.sh` 的逻辑 | `module.prop` 的 `version` + `versionCode` 各 +1 |
| `skill/SKILL.md`、`bin/dshroot`、`bin/dshtty` 的内容 | `asset_version` +1 |
| `.s/watch`、`action.sh`、`webroot/` | `version` + `versionCode` +1 |
| 队列协议（`req.*` / `out.*` 格式） | 两个都 +1 |

`asset_version` 是设备端覆盖的依据：技能和命令文件已存在时，只有版本变了才会重写；
不 +1 的话装上去设备里还是旧文件。协议变了不 +1，旧 helper 配新 daemon 会直接对不上。

**装包与回滚**

1. KernelSU → 模块 → 从本地安装 → 覆盖旧包
2. 重启（`service.sh` 改动必须重启才生效；`customize.sh` 安装时就跑过了）
3. 验证：`dshroot id` + `cat ~/.dsh/root-bridge.log` + 看 `~/.dsh/skills/dsh-root/.version`
4. 回滚：装回上一版 zip 再重启

## 卸载

KernelSU 管理器里删掉模块并重启。
