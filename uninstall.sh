#!/system/bin/sh
# Remove everything this module installed into the app's own storage.
APP=io.github.ccch1mneyyy.dsh_app
ROOTFS=/data/data/$APP/files/runtime/rootfs

# Stop the daemon and any terminal session shell first, otherwise they keep
# writing into a tree we are about to delete.
for d in /proc/[0-9]*; do
  pid=${d#/proc/}
  cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
  case "$cmd" in
    *dsh_root_bridge/service.sh*|*dsh_root_bridge*/bin/term-shell.sh*|\
    *dsh_root_bridge/.s/watch*|*dsh_root_bridge/.s/main*|\
    *dsh_bridge/service.sh*|*dsh_bridge/.s/watch*|*dsh_bridge/.s/main*|*dsh_bridge/.s/sess*)
      kill -TERM "$pid" 2>/dev/null
      ;;
  esac
done
sleep 1

rm -rf "$ROOTFS/root/.dsh/skills/dsh-root" 2>/dev/null
rm -f "$ROOTFS/usr/local/bin/dshroot" "$ROOTFS/usr/local/bin/.dshroot.version" 2>/dev/null
rm -f "$ROOTFS/usr/local/bin/dshtty" "$ROOTFS/usr/local/bin/.dshtty.version" 2>/dev/null
rm -rf "$ROOTFS/root/.dsh/bus" "$ROOTFS/root/.dsh/root-bridge" 2>/dev/null
rm -f "$ROOTFS/root/.dsh/bus.log" "$ROOTFS/root/.dsh/root-bridge.log" 2>/dev/null
rm -f /data/adb/dsh-rootbridge.log 2>/dev/null
rm -f /data/local/tmp/dsh_bridge.log /data/local/tmp/dsh_bridge.status \
      /data/local/tmp/dsh_bridge.watch.pid 2>/dev/null
