#!/system/bin/sh
MODDIR=${0%/*}
UF=/data/adb/unityfix

mkdir -p "$UF" 2>/dev/null
[ -s "$UF/config.conf" ] || cp -f "$MODDIR/defaults.conf" "$UF/config.conf" 2>/dev/null
chmod 755 "$MODDIR/bin/unityfix.sh" 2>/dev/null
chmod 644 "$UF/config.conf" 2>/dev/null

# migrasi config lama (mask=240 hardcoded -> auto) + deteksi cluster awal
/system/bin/sh "$MODDIR/bin/unityfix.sh" init 2>/dev/null

# tunggu boot selesai biar gak rebutan sama init
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ "$(getprop sys.boot_completed)" = "1" ] && break
    sleep 5
done
sleep 20

# sudah jalan? jangan dobel
if [ -f "$UF/daemon.pid" ] && kill -0 "$(cat "$UF/daemon.pid" 2>/dev/null)" 2>/dev/null; then
    exit 0
fi

exec /system/bin/sh "$MODDIR/bin/unityfix.sh" daemon