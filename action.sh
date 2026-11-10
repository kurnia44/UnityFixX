#!/system/bin/sh
# UnityFix X — action button (Magisk terminal), WebUI = cara utama
UF=/data/adb/unityfix
UFS=/data/adb/modules/unityfix/bin/unityfix.sh
[ -x "$UFS" ] || UFS="$UF/bin/unityfix.sh"
NCPU=$(nproc 2>/dev/null); [ -z "$NCPU" ] && NCPU=8

# semua mask diambil dari auto-detect topologi di bin/unityfix.sh
sh "$UFS" init >/dev/null 2>&1
AUTO=$(sh "$UFS" resolve auto 2>/dev/null)
ALL=$(sh "$UFS" resolve all 2>/dev/null)
BIG=$(sh "$UFS" resolve big 2>/dev/null)
PRIME=$(sh "$UFS" resolve prime 2>/dev/null)
[ -z "$ALL" ] && ALL=$(awk -v c="$NCPU" 'BEGIN{printf "%d", 2^c-1}')
[ -z "$BIG" ] && BIG="$ALL"
[ -z "$AUTO" ] && AUTO="$ALL"
[ -z "$PRIME" ] && PRIME="$AUTO"
now() { sh "$UFS" resolve "$1" 2>/dev/null; }

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
echo " • Vol+  = auto (deteksi topologi) [$AUTO]"
echo " • Vol-  = semua core              [$ALL]"
echo " • Layar = big cluster             [$BIG]"
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
    volup)   sh "$UFS" setk mask auto; echo "[>] mask diset ke auto ($AUTO = $(now auto))" ;;
    voldown) sh "$UFS" setk mask all;  echo "[>] mask diset ke semua core ($ALL)" ;;
    touch)   sh "$UFS" setk mask big;  echo "[>] mask diset ke big cluster ($BIG)" ;;
    *)       echo "[>] tidak ada input, pakai setting tersimpan" ;;
esac

[ -n "$ACT" ] && sh "$UFS" setk mode always 2>/dev/null
echo ""
sh "$UFS" apply 2>/dev/null
echo ""
echo "+ fork by eLSanz · original @LeanHijosdesusMadres"
echo "============================="