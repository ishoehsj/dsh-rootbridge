SKIPUNZIP=0
ASSET_VERSION=$(cat "$MODPATH/asset_version" 2>/dev/null || echo 1)

# Magisk, KernelSU and APatch each provide these installer helpers. Anything
# missing gets an equivalent fallback so one zip fits all three.
if ! command -v ui_print >/dev/null 2>&1; then
  ui_print() { echo "$1"; }
fi

if ! command -v set_perm_recursive >/dev/null 2>&1; then
  set_perm_recursive() {
    chown -R "$2:$3" "$1" 2>/dev/null
    find "$1" -type d -exec chmod "$4" {} \; 2>/dev/null
    find "$1" -type f -exec chmod "$5" {} \; 2>/dev/null
  }
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
chmod 755 "$MODPATH/service.sh" "$MODPATH/action.sh" "$MODPATH/bin/dshroot" \
          "$MODPATH/bin/dshtty" "$MODPATH/.s/main" "$MODPATH/.s/watch" \
          "$MODPATH/.s/sess" 2>/dev/null

# Best effort at install time: if dsh-go already ran once, drop the skill and the
# helper right away so they are usable after the next engine start. service.sh
# repeats the same sync on every boot and restores them after a runtime reset.
APP=io.github.ccch1mneyyy.dsh_app
ROOTFS=/data/data/$APP/files/runtime/rootfs

if [ -d "$ROOTFS/root" ]; then
  APPUID=$(stat -c %u "/data/data/$APP" 2>/dev/null)
  [ -z "$APPUID" ] && APPUID=$(stat -c %u "$ROOTFS" 2>/dev/null)

  SKILLDST="$ROOTFS/root/.dsh/skills/dsh-root"
  if [ -f "$MODPATH/skill/SKILL.md" ]; then
    mkdir -p "$SKILLDST" 2>/dev/null
    cp -f "$MODPATH/skill/SKILL.md" "$SKILLDST/SKILL.md" 2>/dev/null
    echo "$ASSET_VERSION" > "$SKILLDST/.version" 2>/dev/null
    [ -n "$APPUID" ] && chown -R "$APPUID" "$SKILLDST" 2>/dev/null
    chmod 700 "$SKILLDST" 2>/dev/null
    chmod 600 "$SKILLDST/SKILL.md" "$SKILLDST/.version" 2>/dev/null
    ui_print "- dsh-root 技能已安装"
  fi

  if [ -f "$MODPATH/bin/dshroot" ]; then
    mkdir -p "$ROOTFS/usr/local/bin" 2>/dev/null
    cp -f "$MODPATH/bin/dshroot" "$ROOTFS/usr/local/bin/dshroot" 2>/dev/null
    echo "$ASSET_VERSION" > "$ROOTFS/usr/local/bin/.dshroot.version" 2>/dev/null
    [ -n "$APPUID" ] && chown "$APPUID" "$ROOTFS/usr/local/bin/dshroot" "$ROOTFS/usr/local/bin/.dshroot.version" 2>/dev/null
    chmod 755 "$ROOTFS/usr/local/bin/dshroot" 2>/dev/null
    chmod 600 "$ROOTFS/usr/local/bin/.dshroot.version" 2>/dev/null
    ui_print "- dshroot 命令已安装"
  fi

  if [ -f "$MODPATH/bin/dshtty" ]; then
    mkdir -p "$ROOTFS/usr/local/bin" 2>/dev/null
    cp -f "$MODPATH/bin/dshtty" "$ROOTFS/usr/local/bin/dshtty" 2>/dev/null
    echo "$ASSET_VERSION" > "$ROOTFS/usr/local/bin/.dshtty.version" 2>/dev/null
    [ -n "$APPUID" ] && chown "$APPUID" "$ROOTFS/usr/local/bin/dshtty" "$ROOTFS/usr/local/bin/.dshtty.version" 2>/dev/null
    chmod 755 "$ROOTFS/usr/local/bin/dshtty" 2>/dev/null
    chmod 600 "$ROOTFS/usr/local/bin/.dshtty.version" 2>/dev/null
    ui_print "- dshtty 终端会话命令已安装"
  fi
fi

# An upgrade must not leave the previous daemon (or its terminal shells) holding
# the queue: two daemons would execute one request twice.
# 上一版留下的锁跟着模块一起被复制会挡住新实例，装的时候就删掉
rm -rf "$MODPATH/.supervisor.lock" "$MODPATH/.daemon.lock" 2>/dev/null
rm -f  "$MODPATH/.daemon.pid" 2>/dev/null

stop_running() {
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    # 进程可能在扫描途中消失，cat 失败静默掉，别在安装日志里刷屏
    cmd=$(cat "$d/cmdline" 2>/dev/null | tr '\0' ' ')
    case "$cmd" in
      *dsh_root_bridge/service.sh*|*dsh_root_bridge*/bin/term-shell.sh*|\
      *dsh_root_bridge/.s/watch*|*dsh_root_bridge/.s/main*|\
      *dsh_bridge/service.sh*|*dsh_bridge/.s/watch*|*dsh_bridge/.s/main*|*dsh_bridge/.s/sess*)
        ui_print "- 停掉旧实例 pid=$pid"
        kill -TERM "$pid" 2>/dev/null
        ;;
    esac
  done
  sleep 1
  # 陈旧锁会让新实例判"已有实例"后直接退出，升级时一并清掉
  rm -rf "$ROOTFS/root/.dsh/bus/.daemon.lock" 2>/dev/null
  rm -f /data/adb/modules/dsh_root_bridge/.daemon.pid /data/adb/modules/dsh_bridge/.daemon.pid 2>/dev/null
  rm -rf /data/adb/modules/dsh_root_bridge/.supervisor.lock /data/adb/modules/dsh_bridge/.supervisor.lock 2>/dev/null
  rm -f /data/local/tmp/dsh_bridge.watch.pid 2>/dev/null
}

# 旧版本的队列目录带 "root" 字样，升级时一并清掉
LEGACY="$ROOTFS/root/.dsh/root-bridge"
[ -d "$LEGACY" ] && rm -rf "$LEGACY" 2>/dev/null
rm -f "$ROOTFS/root/.dsh/root-bridge.log" 2>/dev/null

stop_running

# Start the bridge right away so a fresh install works without a reboot; the
# boot-time service.sh launch takes over (single instance, same pid file).
# service.sh detaches with setsid itself, so a manager that reaps the installer's
# process group cannot take the bridge with it.
if [ -f "$MODPATH/service.sh" ]; then
  ( DSH_RB_FORCE=1 /system/bin/sh "$MODPATH/service.sh" >/dev/null 2>&1 & ) 2>/dev/null
  # 等真实心跳再宣布成功：装完立刻可用才有意义，起不来就老实说清楚。
  BUS=$ROOTFS/root/.dsh/bus
  i=0
  ok=0
  while [ $i -lt 24 ]; do
    b=$(cat "$BUS/.alive" 2>/dev/null)
    case "$b" in
      ''|*[!0-9]*) ;;
      *) [ $(( $(date +%s) - b )) -le 5 ] && { ok=1; break; } ;;
    esac
    sleep 0.5
    i=$((i + 1))
  done
  if [ "$ok" = "1" ]; then
    ui_print "- root 桥已启动：现在就能用，不用重启"
  else
    ui_print "- root 桥这次没起来：模块卡片 → 执行，或重启一次手机（诊断见 action.sh doctor）"
  fi
fi
