#!/system/bin/sh
# UnityFix X — installer (Magisk / KernelSU / APatch, MMT-Ex template)
SKIPUNZIP=0
uptime=$(cut -d. -f1 /proc/uptime)
memory=$(cat /proc/meminfo | tr -s ' ')

echo ""
echo "▒█░▒█ █▀▀▄ ░▀░ ▀▀█▀▀ █░░█ ▒█▀▀▀ ░▀░ █░█ "
echo "▒█░▒█ █░░█ ▀█▀ ░░█░░ █▄▄█ ▒█▀▀▀ ▀█▀ ▄▀▄ "
echo "░▀▄▄▀ ▀░░▀ ▀▀▀ ░░▀░░ ▄▄▄█ ▒█░░░ ▀▀▀ ▀░▀  X"
echo ""

echo "· OS        : Android $(getprop ro.build.version.release)"
echo "· Model     : $(getprop ro.product.manufacturer) $(getprop ro.product.model)"
echo "· Kernel    : $(uname -r | cut -f1,2,3 -d-)"
echo "· CPU       : $(getprop ro.soc.manufacturer) $(getprop ro.soc.model) ($(grep -c ^processor /proc/cpuinfo) cores)"
echo "· Memory    : $(( ($(awk '/MemTotal/{print $2}' /proc/meminfo) - $(awk '/MemAvailable/{print $2}' /proc/meminfo)) / 1024 ))MiB / $(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))MiB"
echo ""

# ---------- copy payload ----------
mkdir -p "$MODPATH/bin" "$MODPATH/webroot" 2>/dev/null

chmod 755 "$MODPATH/bin/unityfix.sh" 2>/dev/null
chmod 755 "$MODPATH/service.sh" "$MODPATH/action.sh" "$MODPATH/uninstall.sh" 2>/dev/null
chmod 644 "$MODPATH/module.prop" "$MODPATH/defaults.conf" 2>/dev/null

# ---------- persistent config ----------
UF="${NVBASE:-/data/adb}/unityfix"
mkdir -p "$UF" 2>/dev/null
[ -s "$UF/config.conf" ] || cp -f "$MODPATH/defaults.conf" "$UF/config.conf" 2>/dev/null
chmod 644 "$UF/config.conf" 2>/dev/null

# ---------- kernel support check ----------
SUP="NO"
for f in /proc/sys/kernel/sched_lib_mask_force /proc/sys/walt/sched_lib_mask_force; do
    [ -e "$f" ] && SUP="YES ($f)"
done

echo ""
if [ "$SUP" = "NO" ]; then
    echo "· Kernel sched_lib : TIDAK ADA di kernel ini"
    echo "  → modul tetap bisa dipakai lewat mode 'pin affinity' (taskset) di WebUI."
    echo "  → untuk efek penuh, pakai kernel yang punya patch sched_lib_mask_force."
else
    echo "· Kernel sched_lib : $SUP"
fi
echo ""
echo "· Buka WebUI dari manager (KernelSU/APatch/MMRL) untuk atur app & core."
echo "+ fork by eLSanz · original @LeanHijosdesusMadres"
echo ""