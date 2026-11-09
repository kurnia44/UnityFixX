#!/system/bin/sh
# UnityFix X — action button (Magisk terminal), WebUI = cara utama
UF=/data/adb/unityfix
UFS=/data/adb/modules/unityfix/bin/unityfix.sh
[ -x "$UFS" ] || UFS="$UF/bin/unityfix.sh"
NCPU=$(nproc 2>/dev/null); [ -z "$NCPU" ] && NCPU=8

mask_range() { # $1 first core $2 count
    awk -v s="$1" -v c="$2" 'BEGIN{m=0; for(i=s;i<s+c;i++) m+=2^i; printf "%d", m}'
}
ALL=$(mask_range 0 "$NCPU")
BIG4=$(mask_range $(( NCPU > 4 ? NCPU-4 : 0 )) $(( NCPU > 4 ? 4 : NCPU )))
BIG2=$(mask_range $(( NCPU-2 )) 2)

echo "============================="
echo "▒█░▒█ █▀▀▄ ░▀░ ▀▀█▀▀ █░░█ ▒█▀▀▀ ░▀░ █░█ "
echo "▒█░▒█ █░░█ ▀█▀ ░░█░░ █▄▄█ ▒█▀▀▀ ▀█▀ ▄▀▄ "
echo "░▀▄▄▀ ▀░░▀ ▀▀▀ ░░▀░░ ▄▄▄█ ▒█░░░ ▀▀▀ ▀░▀  X"
echo "============================="
echo ""
sh "$UFS" status 2>/dev/null
echo ""
if [ -e /proc/sys/kernel/sched_lib_mask_force ] || [ -e /proc/sys/walt/sched_lib_mask_force ]; then
    echo "[✓] kernel sched_lib: SUPPORTED"
else
    echo "[!] kernel sched_lib: TIDAK ADA — pakai opsi pin affinity di WebUI"
fi
echo ""
echo "Cara lengkap: buka WebUI modul di KernelSU / APatch / MMRL."
echo ""
echo "[?] Aksi cepat (10 detik):"
echo " • Vol+  = semua core  [$ALL]"
echo " • Vol-  = 4 core besar [$BIG4]"
echo " • Layar = 2 core besar [$BIG2]"
echo " • Diam  = apply setting tersimpan"
echo ""

ACT=""
TMP=/data/local/tmp/uf_ev.$$
getevent -ql > "$TMP" 2>/dev/null &
EVPID=$!
i=0
while [ "$i" -lt 50 ]; do
    [ -s "$TMP" ] && break
    sleep 0.2
    i=$((i+1))
done
kill "$EVPID" 2>/dev/null
LINE=$(cat "$TMP" 2>/dev/null)
rm -f "$TMP" 2>/dev/null

case "$LINE" in
    *KEY_VOLUMEUP*DOWN*)   ACT="volup" ;;
    *KEY_VOLUMEDOWN*DOWN*) ACT="voldown" ;;
    "")                    ACT="" ;;
    *)                     ACT="touch" ;;
esac

case "$ACT" in
    volup)   sh "$UFS" setk mask "$ALL";   echo "[>] mask diset ke $ALL (semua core)" ;;
    voldown) sh "$UFS" setk mask "$BIG4";  echo "[>] mask diset ke $BIG4 (4 core besar)" ;;
    touch)   sh "$UFS" setk mask "$BIG2";  echo "[>] mask diset ke $BIG2 (2 core besar)" ;;
    *)       echo "[>] tidak ada input, pakai setting tersimpan" ;;
esac

[ -n "$ACT" ] && sh "$UFS" setk mode always 2>/dev/null
echo ""
sh "$UFS" apply 2>/dev/null
echo ""
echo "+ fork by eLSanz · original @LeanHijosdesusMadres"
echo "============================="