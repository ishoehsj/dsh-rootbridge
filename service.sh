#!/system/bin/sh
# Manager entry point. Magisk / KernelSU / APatch all require this exact file
# name, and a running process shows its script path as its cmdline — so this
# file does nothing but exec the supervisor in .s/watch, which in turn keeps the
# real daemon (.s/main) alive. Every process this module creates therefore
# carries a path with no "root" in it.
SELFDIR=${0%/*}
[ "$SELFDIR" = "$0" ] && SELFDIR=.
case "$SELFDIR" in
  .s)   MODDIR=. ;;
  */.s) MODDIR=${SELFDIR%/.s} ;;
  *)    MODDIR=$SELFDIR ;;
esac
[ -f "$MODDIR/.s/watch" ] || MODDIR=/data/adb/modules/dsh_bridge

# Detach into our own session so killing the manager's process group (or the
# app that launched the installer) cannot take the bridge with it.
if command -v setsid >/dev/null 2>&1; then
  exec setsid /system/bin/sh "$MODDIR/.s/watch"
fi
exec /system/bin/sh "$MODDIR/.s/watch"
