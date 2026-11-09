#!/system/bin/sh
# UnityFix X — cleanup saat uninstall
UF=/data/adb/unityfix
for f in /proc/sys/kernel/sched_lib_mask_force /proc/sys/walt/sched_lib_mask_force /proc/sys/*/sched_lib_mask_force; do
    [ -e "$f" ] || continue
    n="${f%mask_force}name"
    [ -e "$n" ] && printf '' > "$n" 2>/dev/null
    printf '0' > "$f" 2>/dev/null
done
[ -f "$UF/daemon.pid" ] && kill "$(cat "$UF/daemon.pid")" 2>/dev/null
rm -rf "$UF"
exit 0