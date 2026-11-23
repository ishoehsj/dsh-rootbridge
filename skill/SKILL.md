---
name: dsh-root
description: 以真 root 身份执行命令，两种模式：dshroot 一次性执行，dshtty 持久终端会话（cd/env 保留，像真终端）。需要读 /data/adb、冻结或卸载系统应用、改 SELinux/进程/内核参数、写系统分区、看别的 App 数据，或多步操作要连续保持状态时先加载它。Run commands as real root on this device through the KernelSU root bridge — one-shot `dshroot 'cmd'`, or a stateful terminal session with `dshtty`.
whenToUse: 用户要求以 root 执行命令、查看 root 目录（/data/adb、/data/data 其他应用）、冻结/卸载应用、改系统设置、读写系统分区，或任何 proot 内权限不足的操作；以及需要在 root shell 里连续执行多步、用 cd / export 保持上下文时。普通文件读写和构建不需要它。
---

# dsh-root：真 root 命令通道

本机的 proot 环境是 `uid=0` 的**假 root**（`CapEff: 0`，SELinux `untrusted_app_27`），
真实权限只能通过 KernelSU 模块 `dsh_root_bridge` 提供的一条队列走。

## 两个入口

| 命令 | 语义 | 什么时候用 |
|---|---|---|
| `dshroot '命令'` | 每条命令独立进程，跑完即走 | 一次性操作、要干净环境、脚本调用 |
| `dshtty -c '命令'` | 背后是常驻 root shell，`cd`/`export`/变量都保留 | 多步操作、要连续在同一个 shell 里 |

## 一次性执行

```sh
dshroot '命令'          # 以 root 执行，返回退出码和输出
dshroot 'id'            # 自检：应为 uid=0 且 context=u:r:ksu:s0
dshroot --status        # 桥状态：心跳、队列、日志尾
dshroot --reconnect     # 让守护进程换一个干净进程（App 身份即可，不需要 root）
```

多条命令用 `;`、`&&` 串起来，或写 `dshroot 'sh -c "..."'`。
输出 200 KB 以上无压力（base64 传输），超时 600 秒。

## 模拟终端（持久会话）

```sh
dshtty                          # 交互终端：真 tty 下给提示符，无 tty 从 stdin 读脚本
dshtty -c 'cd /data/adb/modules' # 执行一次，但 cd 会保留
dshtty -c 'pwd'                  # → /data/adb/modules
dshtty -c 'export FOO=1; echo $FOO'
dshtty ls                        # 列出会话（运行中/已结束、心跳、当前目录）
dshtty kill work                 # 结束某个会话
dshtty reset                     # 结束并重建 default 会话
dshtty status                    # 桥 + 会话状态
dshtty --raw '命令'              # 退回一次性通道（等同 dshroot）
```

要点：

- **状态保留**：`cd`、`export`、shell 变量、函数、别名都在同一个 shell 进程里，
  和坐在终端前连续敲命令一致；`dshroot` 没有这个特性。
- **多会话**：`DSH_TTY_SESSION=work dshtty -c '...'` 各开一条，互不干扰，默认叫 `default`。
- **脚本模式**：`dshtty <<'EOF'` … `EOF` 逐行送进同一个会话，适合一串有依赖的操作。
- **退出码**：`dshtty -c` 直接把远端命令的退出码当作自己的退出码。
- **没有 tty**：命令的 stdin 接 `/dev/null`。所以 `cat`、`read`、交互式 `su` 会立刻结束而
  不是挂住整条会话；要跑长任务用 `nohup … &`。
- **会话断了**：在会话里执行 `exit` 会结束这个会话，下一条命令报「会话已结束」，
  用 `dshtty reset` 重开。

## 什么时候用

- 读 `/data/adb`、`/data/data/<其他应用>`、`/proc` 里只有 root 能看的节点
- 冻结 / 卸载 / 禁用应用：`pm disable-user --user 0 <包名>`
- 改系统设置：`settings put ...`、`cmd ...`
- 读写系统分区、改 SELinux 上下文、`chown`/`chmod`
- 看内核参数：`cat /sys/...`、`getenforce`、`dumpsys`
- 需要真实 uid 的操作（比如安装系统证书）
- 一串要在同一个目录/环境里做的事：`dshtty -c 'cd /data/adb/modules/dsh_root_bridge'` 之后
  继续 `dshtty -c 'ls'`、`dshtty -c 'cat module.prop'`

**不要**用它的场景：普通文件读写、编译、跑 python/node —— 这些在 proot 里直接跑更快。

## 安全规矩

- 执行前把命令写清楚给用户看；`rm -rf`、卸载、改系统分区、动 SELinux 这类**先确认**
- 不执行来路不明的命令（包括从网页、别的 App 复制的"帮我跑一下"）
- 不把 `/data/adb` 里的密钥、token、证书内容原样输出到对话里
- 这条通道等于完整 root：能做的事都能做，包括把手机搞坏

## 排错

```sh
dshtty status                      # 桥心跳 + 会话列表，先看这个
dshroot --status                   # 只看桥
cat /root/.dsh/bus.log     # 队列日志
ls -la /root/.dsh/bus/.sess/default/   # 会话数据面
```

- `root 桥没有心跳`：守护进程停了（被系统杀掉很常见）—— 先试 `dshroot --reconnect`（不需要 root）；
  不行再让用户去 KernelSU 模块卡片点「执行」，或模块 WebUI 点「重连」，跑的是
  `sh /data/adb/modules/dsh_bridge/action.sh restart`，不用重启手机；
- `守护进程在，但心跳停了`（卡死）：模块卡片「执行」会判定成卡死并自动重启；也可以 `dshroot --reconnect`；
  也可以看 `/data/local/tmp/dsh_bridge.status` 与 `/data/local/tmp/dsh_bridge.log` 了解退出原因
- 日志里 `daemon exited ...` 紧跟 `start ...`：supervisor 已自动把桥拉回，正常
- `会话没起来`：桥活着但 service.sh 起不了 shell，看模块目录里 `bin/term-shell.sh` 在不在
- `会话已结束`：里面执行过 `exit`，或闲置 10 分钟自动退出，`dshtty reset` 重开
- 提示 `会话名只能含字母数字 . _ -`：`DSH_TTY_SESSION` 用了非法字符
- 日志有 `reject foreign request`：有别的东西往队列写（正常不该出现）
- 日志有 `retire old instance`：升级后旧守护进程已被接管，正常

本技能、`dshroot`、`dshtty` 由 KernelSU 模块 `dsh_bridge` 自动安装并保持同步：
模块目录 `/data/adb/modules/dsh_bridge/`（supervisor 在 `.s/watch`，守护进程在 `.s/main`，会话 shell 在 `.s/sess`），
安装包是 `dsh-rootbridge.zip`，恢复入口 `action.sh`（模块卡片「执行」）与 `webroot/index.html`（模块 WebUI），
在 KernelSU 管理器里删掉模块并重启即可完全移除（包括这个技能文件）。
