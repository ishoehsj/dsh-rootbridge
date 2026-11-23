#!/system/bin/sh
# Module action button (KernelSU: 模块卡片 → 执行). Starts / restarts / inspects
# the bridge without a reboot — the only recovery path that does not need the
# bridge itself to be alive.
#
#   action.sh            → 自检：健康就只报状态；心跳死了就重启；没在跑就启动
#   action.sh start      → 启动（已健康则不动）
#   action.sh restart    → 硬重启：杀进程、清锁、拉起、等心跳，失败给原因
#   action.sh reconnect  → restart 的别名（给「重连」入口用）
#   action.sh stop       → 停掉 supervisor、守护进程和会话 shell
#   action.sh status     → 打印状态
#   action.sh doctor     → 排错信息（贴给别人看的那种）
#   action.sh log [行数]  → tail 诊断日志
#
# 设计要点（v1.9.0 修的就是这里）：
#   1. "运行中" 必须同时满足 pid 真、心跳新鲜；只有 pid 不算活 —— 否则模块卡片
#      的「执行」会在守护进程卡死时什么都不做，用户看到的就是"重启无效"。
#   2. 杀进程按 cmdline 匹配，覆盖 绝对路径 / 相对路径（./.s/watch）/
#      modules_update 里的安装期实例，杀不掉就升级到 KILL，并复核残留。
#   3. 启动后等真实心跳，不再用固定 sleep 假装成功；失败时打印原因线索。

# 允许被相对路径调用（本地调试）；真实场景管理器给的是绝对路径。
SELFDIR=${0%/*}
[ "$SELFDIR" = "$0" ] && SELFDIR=.
case "$SELFDIR" in
  .s)   MODDIR=. ;;
  */.s) MODDIR=${SELFDIR%/.s} ;;
  *)    MODDIR=$SELFDIR ;;
esac
[ -f "$MODDIR/.s/watch" ] || MODDIR=/data/adb/modules/dsh_bridge
# 相对路径在杀进程匹配里毫无用处，统一换算成绝对路径。
case "$MODDIR" in
  /*) ;;
  *)  MODDIR=$(cd "$MODDIR" 2>/dev/null && pwd) || MODDIR=. ;;
esac

APP=${DSH_RB_APP:-io.github.ccch1mneyyy.dsh_app}
ROOTFS=${DSH_RB_ROOTFS:-/data/data/$APP/files/runtime/rootfs}
DIR=${DSH_RB_DIR:-$ROOTFS/root/.dsh/bus}
STATUS=${DSH_RB_STATUS:-/data/local/tmp/dsh_bridge.status}
SYSLOG=${DSH_RB_SYSLOG:-/data/local/tmp/dsh_bridge.log}
WPIDF=/data/local/tmp/dsh_bridge.watch.pid

# 心跳超过这个秒数就算死：守护进程空闲时也 2 秒一跳，20 秒是很宽的余量。
BEAT_MAX=20

pid_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

cmd_of() { cat "/proc/$1/cmdline" 2>/dev/null | tr '\0' ' '; }

# kill -0 不够：重启后 pid 会被复用，必须确认那个 pid 真是守护进程。
is_daemon_pid() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "$(cmd_of "$1")" in *".s/main"*) return 0 ;; esac
  return 1
}

# 锁可能落在队列目录，也可能落在模块目录（守护进程比 App 运行时先起来的时候）。
# 两处都看，最后再扫一次 cmdline：锁文件丢了也不该把活着的桥说成"没运行"。
bridge_pid() {
  for f in "$DIR/.daemon.lock/pid" "$MODDIR/.daemon.lock/pid" \
           "$DIR/.daemon.pid" "$MODDIR/.daemon.pid"; do
    p=$(cat "$f" 2>/dev/null)
    case "$p" in ''|*[!0-9]*) continue ;; esac
    is_daemon_pid "$p" && { echo "$p"; return 0; }
  done
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    c=$(cmd_of "$pid")
    case "$c" in *".s/main"*) ;; *) continue ;; esac
    case "$c" in
      *dsh_bridge*|*dsh_root_bridge*|*"$MODDIR"*) echo "$pid"; return 0 ;;
    esac
  done
  echo ""
}

# 不要把"启动我们的人"（管理器、WebUI 的 su shell）当成桥的进程杀掉。
is_ancestor() {
  p=$$
  i=0
  while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] && [ $i -lt 32 ]; do
    [ "$p" = "$1" ] && return 0
    p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    i=$((i + 1))
  done
  return 1
}

# 模块自己的进程：绝对路径、相对路径（watch 用 ./ 拉起的）、以及安装期在
# modules_update 里跑的那一份，三种都要认。
matches_bridge() {
  case "$1" in
    *"$MODDIR/.s/main"*|*"$MODDIR/.s/watch"*|*"$MODDIR/.s/sess"*) return 0 ;;
    *"$MODDIR/service.sh"*|*"$MODDIR/bin/term-shell.sh"*) return 0 ;;
    *dsh_bridge/.s/main*|*dsh_bridge/.s/watch*|*dsh_bridge/.s/sess*) return 0 ;;
    *dsh_root_bridge/.s/main*|*dsh_root_bridge/.s/watch*|*dsh_root_bridge/.s/sess*) return 0 ;;
    *dsh_bridge/service.sh*|*dsh_root_bridge/service.sh*) return 0 ;;
    *dsh_bridge/bin/term-shell.sh*|*dsh_root_bridge/bin/term-shell.sh*) return 0 ;;
    *"./.s/main"*|*"./.s/watch"*|*"./.s/sess"*) return 0 ;;
    *"./service.sh"*) return 0 ;;
  esac
  return 1
}

beat_age() {
  b=$(cat "$DIR/.alive" 2>/dev/null)
  case "$b" in ''|*[!0-9]*) echo -1 ;; *) echo $(( $(date +%s) - b )) ;; esac
}

# 真活着 = pid 在 + cmdline 对 + 心跳新鲜。
healthy() {
  p=$(bridge_pid)
  pid_alive "$p" || return 1
  is_daemon_pid "$p" || return 1
  a=$(beat_age)
  [ "$a" -ge 0 ] && [ "$a" -le "$BEAT_MAX" ]
}

daemon_present() {
  p=$(bridge_pid)
  pid_alive "$p" || return 1
  is_daemon_pid "$p"
}

count_matches() {
  n=0
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    [ "$pid" = "$$" ] && continue
    c=$(cmd_of "$pid")
    [ -n "$c" ] || continue
    case "$c" in *" -c "*) continue ;; esac
    is_ancestor "$pid" && continue
    matches_bridge "$c" && n=$((n + 1))
  done
  echo "$n"
}

kill_matches() {
  sig=$1
  n=0
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    [ "$pid" = "$$" ] && continue
    c=$(cmd_of "$pid")
    [ -n "$c" ] || continue
    # `sh -c '...'` 形式的父进程（安装器、管理器）不是桥
    case "$c" in *" -c "*) continue ;; esac
    is_ancestor "$pid" && continue
    matches_bridge "$c" || continue
    if kill "-$sig" "$pid" 2>/dev/null; then
      n=$((n + 1))
    fi
  done
  echo "$n"
}

# supervisor 和守护进程一起收：分两轮只会让 supervisor 先把 daemon 拉回来。
# 收不掉就升级到 KILL，最后复核一遍残留（KILL 也可能因为状态特殊失败）。
stop_bridge() {
  killed=0
  i=0
  while [ $i -lt 4 ]; do
    n=$(kill_matches TERM)
    killed=$((killed + n))
    sleep 1
    [ "$(count_matches)" = "0" ] && break
    n=$(kill_matches KILL)
    killed=$((killed + n))
    sleep 1
    [ "$(count_matches)" = "0" ] && break
    i=$((i + 1))
  done

  left=$(count_matches)
  # 锁一定要清：pid 复用或半启动留下的锁会让新实例判"已有实例"后直接退出。
  rm -rf "$DIR/.daemon.lock" "$DIR/.daemon.pid" "$DIR/.reconnect" \
         "$MODDIR/.supervisor.lock" "$MODDIR/.daemon.pid" "$WPIDF" 2>/dev/null
  [ "$killed" -eq 0 ] && [ "$left" = "0" ] && echo "停止：没有在运行的桥进程"
  [ "$killed" -gt 0 ] && echo "停止：收了 $killed 个进程"
  [ "$left" != "0" ] && echo "停止：还有 $left 个进程没杀掉（权限/SELinux？看 action.sh doctor）"
  return 0
}

# 等真实心跳出现，而不是 sleep 3 后假装成功。
# $2 = 心跳时间戳下限：重启时必须看到比旧心跳更新的心跳，否则"刚被杀掉的
# 守护进程留下的 .alive"会让重启立刻返回成功，用户以为好了其实没起来。
wait_healthy() {
  want=${1:-20}
  min=${2:-0}
  case "$min" in ''|*[!0-9]*) min=0 ;; esac
  t=0
  while [ "$t" -lt $((want * 2)) ]; do
    b=$(cat "$DIR/.alive" 2>/dev/null)
    case "$b" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$b" -gt "$min" ]; then
          a=$(( $(date +%s) - b ))
          p=$(bridge_pid)
          if [ "$a" -ge 0 ] && [ "$a" -le 8 ] && pid_alive "$p" && is_daemon_pid "$p"; then
            return 0
          fi
        fi
        ;;
    esac
    sleep 0.5
    t=$((t + 1))
  done
  return 1
}

start_bridge() {
  [ -f "$MODDIR/service.sh" ] || { echo "启动：找不到 $MODDIR/service.sh，模块不完整，重装一次"; return 1; }
  # 旧心跳的时间戳：新实例必须写出更新的心跳才算成功
  floor=$(cat "$DIR/.alive" 2>/dev/null)
  case "$floor" in ''|*[!0-9]*) floor=0 ;; esac
  # DSH_RB_FORCE=1: 忽略陈旧 supervisor 锁。service.sh 自己 setsid 脱离，
  # 所以这里不需要再 detach。
  DSH_RB_FORCE=1 /system/bin/sh "$MODDIR/service.sh" >/dev/null 2>&1 &
  wait_healthy 20 "$floor" && { echo "启动：桥已就绪"; return 0; }

  # 第二次机会：把可能挡路的锁全清掉再来一遍。
  rm -rf "$DIR/.daemon.lock" "$DIR/.daemon.pid" "$MODDIR/.supervisor.lock" 2>/dev/null
  DSH_RB_FORCE=1 /system/bin/sh "$MODDIR/service.sh" >/dev/null 2>&1 &
  wait_healthy 20 "$floor" && { echo "启动：桥已就绪（第二次尝试）"; return 0; }

  return 1
}

# 起不来时给出方向，而不是只说"失败"。
start_failure_hint() {
  [ -d "/data/data/$APP" ] || echo "  → /data/data/$APP 不存在：App 没装或数据被清"
  [ -d "$ROOTFS/root" ] || echo "  → $ROOTFS/root 不存在：dsh-go 还没解包运行时，先打开一次 App"
  if [ -d "$DIR" ]; then
    echo "  → 队列目录：$DIR"
  else
    echo "  → 队列目录还没建：$DIR（App 起来后守护进程会自己建）"
  fi
  lockpid=$(cat "$DIR/.daemon.lock/pid" 2>/dev/null)
  [ -n "$lockpid" ] && echo "  → 锁里登记的 pid=$lockpid（cmdline: $(cmd_of "$lockpid")）"
  [ -f "$SYSLOG" ] && { echo "  → 日志尾："; tail -n 6 "$SYSLOG" | sed 's/^/    /'; }
  echo "  → 完整排错：sh $MODDIR/action.sh doctor"
}

show_status() {
  pid=$(bridge_pid)
  age=$(beat_age)
  echo "模块目录：$MODDIR"
  echo "队列目录：$DIR"
  if healthy; then
    echo "状态：运行中 · 守护进程 pid=$pid · 心跳 ${age}s 前"
  elif daemon_present; then
    echo "状态：守护进程 pid=$pid 在，但心跳异常（${age}s）—— 卡死状态，执行 restart 可恢复"
  else
    echo "状态：没有在运行（dsh-go 现在拿不到 root）"
    echo "处理：执行一次本按钮（action.sh start / restart），或重装模块后重启"
  fi

  if [ -f "$STATUS" ]; then
    echo "--- 守护进程快照 ---"
    sed -n '1,20p' "$STATUS"
  fi
  if [ -f "$SYSLOG" ]; then
    echo "--- 最近日志（$SYSLOG）---"
    tail -n 8 "$SYSLOG"
  else
    echo "（还没有日志：$SYSLOG）"
  fi
}

do_doctor() {
  echo "== 环境 =="
  echo "时间：$(date '+%F %T')"
  echo "身份：$(id 2>/dev/null | tr '\n' ' ')"
  echo "SELinux：$(getenforce 2>/dev/null)"
  echo "模块目录：$MODDIR"
  [ -d "$MODDIR" ] && echo "模块版本：$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)"
  echo "asset_version：$(cat "$MODDIR/asset_version" 2>/dev/null)"
  echo
  echo "== App 与队列 =="
  echo "App 目录：$([ -d "/data/data/$APP" ] && echo 存在 || echo 缺失)"
  echo "rootfs：$([ -d "$ROOTFS/root" ] && echo 存在 || echo 缺失)"
  echo "队列：$([ -d "$DIR" ] && echo 存在 || echo 缺失)  $DIR"
  echo "心跳：$(beat_age)s 前（文件：$([ -f "$DIR/.alive" ] && echo 有 || echo 无)）"
  echo "锁 pid：$(cat "$DIR/.daemon.lock/pid" 2>/dev/null)"
  echo "supervisor pid 文件：$(cat "$WPIDF" 2>/dev/null)"
  echo "资产：$(sed -n 's/^assets=//p' "$STATUS" 2>/dev/null)"
  echo "队列计数：执行中 $(ls -1 "$DIR"/.job.* 2>/dev/null | wc -l | tr -d ' ') · 排队 $(ls -1 "$DIR"/req.* 2>/dev/null | wc -l | tr -d ' ') · 未领取 $(ls -1 "$DIR"/out.* 2>/dev/null | wc -l | tr -d ' ')"
  echo
  echo "== 进程 =="
  found=0
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    [ "$pid" = "$$" ] && continue
    c=$(cmd_of "$pid")
    [ -n "$c" ] || continue
    matches_bridge "$c" || continue
    echo "  pid=$pid $c"
    found=1
  done
  [ "$found" = 0 ] && echo "  （没有桥的进程在跑）"
  echo
  echo "== 日志尾 15 行 =="
  if [ -f "$SYSLOG" ]; then tail -n 15 "$SYSLOG"; else echo "（无 $SYSLOG）"; fi
}

do_log() {
  lines=${1:-40}
  case "$lines" in ''|*[!0-9]*) lines=40 ;; esac
  [ -f "$SYSLOG" ] || { echo "没有日志：$SYSLOG"; return 0; }
  tail -n "$lines" "$SYSLOG"
}

case "${1:-auto}" in
  start)
    if healthy; then
      echo "启动：已经在运行，不动它"
    else
      daemon_present && { stop_bridge; }
      start_bridge || { echo "启动失败：等不到心跳"; start_failure_hint; show_status; exit 1; }
    fi
    show_status
    ;;
  stop)
    stop_bridge
    echo "已停止。dsh-go 现在拿不到 root，直到再次 start / restart / 重启。"
    ;;
  restart|reconnect)
    stop_bridge
    if start_bridge; then
      echo "重启完成：桥已恢复（心跳 $(beat_age)s 前）"
    else
      echo "重启失败：进程起来了但等不到心跳"
      start_failure_hint
      show_status
      exit 1
    fi
    show_status
    ;;
  status)
    show_status
    ;;
  doctor)
    do_doctor
    ;;
  log)
    do_log "${2:-40}"
    ;;
  auto|*)
    if healthy; then
      show_status
      exit 0
    fi
    # 关键分支：pid 在、心跳死 = 卡死。以前这里因为"alive"就跳过，等于没修。
    if daemon_present; then
      echo "自检：守护进程在但没有心跳（$(beat_age)s），按卡死处理 → 重启"
      stop_bridge
      start_bridge || { echo "重启失败：等不到心跳"; start_failure_hint; show_status; exit 1; }
      echo "自检：已重启"
    else
      echo "自检：桥没在运行 → 启动"
      start_bridge || { echo "启动失败：等不到心跳"; start_failure_hint; show_status; exit 1; }
    fi
    show_status
    ;;
esac
