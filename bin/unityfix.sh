#!/system/bin/sh
#################################################
# UnityFix X — config + daemon + helper CLI
# /data/adb/unityfix/bin/unityfix.sh <command>
#################################################

UF_DIR="${UF_DIR:-/data/adb/unityfix}"
CONF="$UF_DIR/config.conf"
STATE="$UF_DIR/state"
LOG="$UF_DIR/unityfix.log"
PIDF="$UF_DIR/daemon.pid"
SYSFS="${UF_SYSFS:-/proc/sys}"

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

ensure() {
    [ -d "$UF_DIR" ] || mkdir -p "$UF_DIR" 2>/dev/null
    [ -f "$CONF" ] || : > "$CONF"
    if [ -f "$LOG" ]; then
        n=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
        if [ -n "$n" ] && [ "$n" -gt 500 ]; then
            tail -n 250 "$LOG" > "$LOG.t" 2>/dev/null && mv "$LOG.t" "$LOG"
        fi
    fi
}

getv() { awk -v k="$1" 'index($0,k"=")==1{sub(/^[^=]*=/,"");print;exit}' "$CONF" 2>/dev/null; }

setv() {
    K="$1" V="$2" awk '
        BEGIN{k=ENVIRON["K"];v=ENVIRON["V"];done=0}
        index($0,k"=")==1{ if(!done){ print k"="v; done=1 }; next }
        { print }
        END{ if(!done) print k"="v }' "$CONF" > "$CONF.new" 2>/dev/null \
        && mv "$CONF.new" "$CONF"
}

delv() {
    K="$1" awk 'BEGIN{k=ENVIRON["K"]} index($0,k"=")!=1{ print }' "$CONF" > "$CONF.new" 2>/dev/null \
        && mv "$CONF.new" "$CONF"
}

# ---------- kernel knobs (sched_lib_name / sched_lib_mask_force) ----------
knobs() {
    for f in "$SYSFS"/kernel/sched_lib_mask_force \
             "$SYSFS"/walt/sched_lib_mask_force \
             "$SYSFS"/*/sched_lib_mask_force; do
        [ -e "$f" ] && echo "$f"
    done | sort -u
}

have_knob() { [ -n "$(knobs)" ] && echo 1 || echo 0; }

apply_kernel() { # $1 mask(decimal) $2 libs csv
    _am="$1"; _al="$2"; _ok=0
    for _f in $(knobs); do
        printf '%s' "$_am" 2>/dev/null > "$_f"
        _back=$(cat "$_f" 2>/dev/null | tr -d ' \n')
        [ "$_back" = "$_am" ] && _ok=1
        _n="${_f%mask_force}name"
        [ -e "$_n" ] && printf '%s' "$_al" 2>/dev/null > "$_n"
    done
    [ "$_ok" = 1 ]
}

clear_kernel() {
    for _f in $(knobs); do
        _n="${_f%mask_force}name"
        [ -e "$_n" ] && printf '' 2>/dev/null > "$_n"
    done
}

cur_mask() { cat "$SYSFS"/kernel/sched_lib_mask_force 2>/dev/null || cat "$SYSFS"/walt/sched_lib_mask_force 2>/dev/null; }
cur_libs() { cat "$SYSFS"/kernel/sched_lib_name 2>/dev/null || cat "$SYSFS"/walt/sched_lib_name 2>/dev/null; }

note() {
    echo "$1" > "$UF_DIR/last" 2>/dev/null
    echo "$1"
}

write_state() { # $1 app $2 mask $3 libs
    { echo "app=$1"; echo "mask=$2"; echo "libs=$3"; echo "ts=$(date +%s)"; } > "$STATE" 2>/dev/null
}

running_list() {
    for d in /proc/[0-9]*; do
        [ -r "$d/cmdline" ] || continue
        tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -n1
    done | sed '/^$/d' | sort -u
}

pin_app() { # $1 pkg $2 mask decimal
    command -v taskset >/dev/null 2>&1 || return 0
    hex=$(printf '%x' "$2" 2>/dev/null) || return 0
    for p in $(pidof "$1" 2>/dev/null); do
        for t in /proc/$p/task/*; do
            taskset -p "0x$hex" "${t##*/}" >/dev/null 2>&1
        done
    done
}

# ---------- core engine ----------
apply_once() {
    ensure
    en=$(getv enabled); [ -z "$en" ] && en=1
    mode=$(getv mode); [ -z "$mode" ] && mode=always
    gmask=$(getv mask); [ -z "$gmask" ] && gmask=240
    glibs=$(getv libs)

    if [ "$en" != "1" ]; then
        clear_kernel
        write_state none - -
        note "idle (module disabled)"
        return 0
    fi

    if [ "$mode" = "always" ]; then
        if apply_kernel "$gmask" "$glibs"; then
            note "applied: always mask=$gmask libs=$glibs"
        else
            note "gagal tulis sysfs (read-only?) mask=$gmask"
        fi
        write_state always "$gmask" "$glibs"
        return 0
    fi

    apps=$(getv apps | tr ',' ' ')
    running=$(running_list)
    tgt=""
    for _p in $apps; do
        [ -z "$_p" ] && continue
        echo "$running" | grep -qx "$_p" && { tgt="$_p"; break; }
    done

    if [ -z "$tgt" ]; then
        clear_kernel
        write_state none - -
        note "idle (no target app running)"
        return 0
    fi

    am=$(getv "app.$tgt.mask"); [ -z "$am" ] && am="$gmask"
    al=$(getv "app.$tgt.libs");  [ -z "$al" ] && al="$glibs"
    if apply_kernel "$am" "$al"; then
        note "applied: $tgt mask=$am"
    else
        note "gagal tulis sysfs (read-only?) $tgt mask=$am"
    fi
    if [ "$(getv pin)" = "1" ]; then pin_app "$tgt" "$am"; fi
    write_state "$tgt" "$am" "$al"
}

daemon() {
    ensure
    echo $$ > "$PIDF"
    log "daemon start (pid $$)"
    while :; do
        apply_once >/dev/null 2>&1
        cur=$(awk -F= '/^app=/{print $2}' "$STATE" 2>/dev/null)
        prev=$(cat "$UF_DIR/daemon.prev" 2>/dev/null)
        if [ "$cur" != "$prev" ]; then
            echo "$cur" > "$UF_DIR/daemon.prev"
            log "state -> ${cur:-unknown} ($(cat "$UF_DIR/last" 2>/dev/null))"
        fi
        i=$(getv interval)
        case "$i" in ''|*[!0-9]*) i=8 ;; esac
        [ "$i" -lt 3 ] && i=3
        sleep "$i"
    done
}


# ---------- checker: apakah app benar-benar sesuai setting ----------
expand_cores() { # "0-7" -> "0 1 2 3 4 5 6 7"
    echo "$1" | tr ',' '\n' | while IFS=- read -r _a _b; do
        if [ -z "$_b" ]; then
            echo "$_a"
        else
            _i=$_a
            while [ "$_i" -le "$_b" ]; do echo "$_i"; _i=$((_i+1)); done
        fi
    done | sort -n | tr '\n' ' '
}

mask_cores() { # desimal -> "4 5 6 7"
    _mm="$1"; _nn=$(nproc 2>/dev/null || echo 8); _oo=""; _ii=0
    while [ "$_ii" -lt "$_nn" ]; do
        [ $(( (_mm >> _ii) & 1 )) -eq 1 ] && _oo="$_oo $_ii"
        _ii=$((_ii+1))
    done
    echo "$_oo"
}

pids_of() {
    _pp=$(pidof "$1" 2>/dev/null)
    if [ -z "$_pp" ]; then
        for _dd in /proc/[0-9]*; do
            [ -r "$_dd/cmdline" ] || continue
            [ "$(tr '\0' '\n' < "$_dd/cmdline" 2>/dev/null | head -n1)" = "$1" ] && _pp="$_pp ${_dd##*/}"
        done
    fi
    echo "$_pp"
}

thread_count() { ls /proc/$1/task 2>/dev/null | wc -l | tr -d ' '; }

thread_affinity() { # pid -> union core (spasi)
    for _t in /proc/$1/task/*; do
        [ -r "$_t/status" ] || continue
        _l=$(awk '/^Cpus_allowed_list:/{print $2}' "$_t/status" 2>/dev/null)
        [ -n "$_l" ] && expand_cores "$_l"
    done | tr ' ' '\n' | sed '/^$/d' | sort -nu | tr '\n' ' ' | sed 's/ *$//'
}

thread_cores() { # core yang benar-benar dipakai thread
    for _t in /proc/$1/task/*/stat; do
        [ -r "$_t" ] || continue
        sed 's/^[0-9]* (.*) //' "$_t" 2>/dev/null | awk '{print $37}'
    done | sed '/^$/d' | sort -n | uniq | tr '\n' ' ' | sed 's/ *$//'
}

affinity_ok() { # $1 mask $2 "0 1 2 3"
    for _c in $2; do
        [ $(( ($1 >> _c) & 1 )) -eq 1 ] || { echo 0; return; }
    done
    echo 1
}

do_check() {
    ensure
    _pkg="$1"
    _apps=$(getv apps | tr ',' ' ')

    if [ -z "$_pkg" ]; then
        for _a in $_apps; do
            [ -n "$(pids_of "$_a")" ] && { _pkg="$_a"; break; }
        done
        [ -z "$_pkg" ] && _pkg=$(echo $_apps | awk '{print $1}')
    fi

    _support=$(have_knob)
    _mode=$(getv mode); [ -z "$_mode" ] && _mode=always
    _pin=$(getv pin)
    _gmask=$(getv mask); [ -z "$_gmask" ] && _gmask=240
    _glibs=$(getv libs)
    _pmask=$(getv "app.$_pkg.mask"); [ -z "$_pmask" ] && _pmask="$_gmask"
    _plibs=$(getv "app.$_pkg.libs"); [ -z "$_plibs" ] && _plibs="$_glibs"

    echo "check.pkg=$_pkg"
    echo "check.support=$_support"
    echo "check.mode=$_mode"
    echo "check.pin=$_pin"
    echo "check.cfg_mask=$_pmask"
    echo "check.cfg_libs=$_plibs"
    echo "check.expected=$(mask_cores "$_pmask" | sed 's/^ //')"

    _sysmask=$(cur_mask | tr -d ' ')
    _syslibs=$(cur_libs | sed 's/,[[:space:]]*/,/g')
    echo "check.sysfs_mask=$_sysmask"
    echo "check.sysfs_libs=$_syslibs"

    _pids=$(pids_of "$_pkg")
    if [ -z "$_pids" ]; then
        echo "check.running=0"
        echo "check.pids="
        echo "check.threads=0"
        echo "check.affinity="
        echo "check.cores_used="
        echo "check.libs_loaded="
        echo "check.libs_missing=$(echo "$_plibs" | tr ',' ' ')"
        if [ "$_sysmask" != "$_pmask" ]; then
            echo "check.verdict=FAIL"
            echo "check.msg=Aplikasi tidak jalan dan sysfs mask ($_sysmask) != config ($_pmask). Jalankan app dulu lalu cek lagi."
        elif [ "$_syslibs" != "$_plibs" ]; then
            echo "check.verdict=WARN"
            echo "check.msg=Aplikasi tidak jalan. Sysfs libs beda dari config, dan mode auto baru apply saat app jalan."
        else
            echo "check.verdict=OK"
            echo "check.msg=Aplikasi tidak jalan, tapi sysfs sudah sesuai config. Cek ulang saat app berjalan untuk bukti affinity."
        fi
        return 0
    fi

    echo "check.running=1"
    echo "check.pids=$_pids"

    _first=$(echo "$_pids" | awk '{print $1}')
    echo "check.threads=$(thread_count "$_first")"
    _aff=$(thread_affinity "$_first")
    echo "check.affinity=$_aff"
    echo "check.affinity_ok=$(affinity_ok "$_pmask" "$_aff")"
    echo "check.cores_used=$(thread_cores "$_first" | sed 's/^ //')"

    _loaded=""; _missing=""
    for _l in $(echo "$_plibs" | tr ',' ' '); do
        if grep -qs -- "$_l" "/proc/$_first/maps"; then _loaded="$_loaded,$_l"; else _missing="$_missing,$_l"; fi
    done
    echo "check.libs_loaded=$(echo "$_loaded" | sed 's/^,//')"
    echo "check.libs_missing=$(echo "$_missing" | sed 's/^,//')"

    for _c in $(mask_cores "$_pmask"); do
        _cf=$(cat "/sys/devices/system/cpu/cpu$_c/cpufreq/scaling_cur_freq" 2>/dev/null)
        _cm=$(cat "/sys/devices/system/cpu/cpu$_c/cpufreq/cpuinfo_max_freq" 2>/dev/null)
        echo "check.freq.$_c=${_cf:-0}/${_cm:-0}"
    done

    # verdict
    _problems=""
    [ "$_support" = "0" ] && [ "$_pin" != "1" ] && _problems="$_problems kernel-tanpa-patch-sched_lib(pin off)"
    [ "$_sysmask" != "$_pmask" ] && _problems="$_problems sysfs-mask(${_sysmask:-kosong})-beda-dari-config($_pmask)"
    [ "$_syslibs" != "$_plibs" ] && _problems="$_problems sysfs-libs-beda-dari-config"
    [ -n "$_missing" ] && _problems="$_problems lib-belum-load:$(echo "$_missing" | sed 's/^,//')"
    if [ "$_pin" = "1" ] && [ "$(affinity_ok "$_pmask" "$_aff")" != "1" ]; then
        _problems="$_problems affinity-di-luar-mask($_aff)"
    fi

    if [ -z "$_problems" ]; then
        echo "check.verdict=OK"
        echo "check.msg=App jalan di core $(echo $(mask_cores "$_pmask")) dan sysfs sesuai config."
    else
        echo "check.verdict=WARN"
        echo "check.msg=$(echo "$_problems" | sed 's/^ //')"
    fi
}

# ---------- output for WebUI ----------
do_dump() {
    ensure
    echo "rt.support=$(have_knob)"
    echo "rt.cur_mask=$(cur_mask)"
    echo "rt.cur_libs=$(cur_libs)"
    echo "rt.model=$(getprop ro.product.model 2>/dev/null)"
    dp=""
    [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null && dp=1
    echo "rt.daemon=${dp:-0}"
    if [ -f "$STATE" ]; then
        while IFS= read -r line; do
            case "$line" in
                app=*)  echo "rt.state_app=${line#app=}" ;;
                mask=*) echo "rt.state_mask=${line#mask=}" ;;
                libs=*) echo "rt.state_libs=${line#libs=}" ;;
                ts=*)   echo "rt.state_ts=${line#ts=}" ;;
            esac
        done < "$STATE"
    fi
    echo "rt.applied=$(cat "$UF_DIR/last" 2>/dev/null | head -n1)"
    cat "$CONF" 2>/dev/null | sed '/^[[:space:]]*$/d'
}

do_cores() {
    for d in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$d" ] || continue
        id="${d##*cpu}"
        f=$(cat "$d/cpufreq/cpuinfo_max_freq" 2>/dev/null)
        [ -z "$f" ] && f=$(cat "$d/cpufreq/scaling_max_freq" 2>/dev/null)
        echo "$id ${f:-0}"
    done
}

do_installed() {
    pm list packages -3 2>/dev/null | sed 's/^package://' | sort
    # fallback for ROMs without pm
    [ -z "$(pm list packages -3 2>/dev/null)" ] && cmd package list packages -3 2>/dev/null | sed 's/^package://' | sort
}

do_status() {
    ensure
    echo "─────────────────────────────"
    echo " UnityFix X — status"
    echo "─────────────────────────────"
    echo " kernel sched_lib     : $( [ "$(have_knob)" = 1 ] && echo SUPPORTED || echo 'NOT FOUND' )"
    [ "$(have_knob)" = 1 ] && echo " current mask / libs  : $(cur_mask) / $(cur_libs)"
    echo " enabled              : $(getv enabled)"
    echo " mode                 : $(getv mode)"
    echo " interval             : $(getv interval)s"
    echo " mask                 : $(getv mask)"
    echo " libs                 : $(getv libs)"
    echo " apps                 : $(getv apps)"
    echo " pin (taskset)        : $(getv pin)"
    echo " last state           : $( [ -f "$STATE" ] && tr '\n' ' ' < "$STATE" )"
    echo "─────────────────────────────"
}

case "$1" in
    init)      ensure; [ -s "$CONF" ] || cat "$UF_DIR/defaults.conf" > "$CONF" 2>/dev/null; exit 0 ;;
    dump)      do_dump ;;
    cores)     do_cores ;;
    installed) do_installed ;;
    status)    do_status ;;
    apply)     apply_once ;;
    daemon)    daemon ;;
    setk)      ensure; setv "$2" "$3"; exit 0 ;;
    unsetk)    ensure; delv "$2"; exit 0 ;;
    setall)    ensure; [ -n "$2" ] && setv "$2" "$3"; exit 0 ;;
    cleark)    clear_kernel; echo "cleared" ;;
    purgeov)   # remove all app.* overrides
               ensure
               grep -v '^app\.' "$CONF" > "$CONF.new" 2>/dev/null && mv "$CONF.new" "$CONF"
               echo "overrides purged" ;;
    check)     do_check "$2" ;;
    log)       tail -n 40 "$LOG" 2>/dev/null ;;
    *)         echo "usage: unityfix.sh {dump|status|apply|check [pkg]|daemon|cores|installed|setk k v|unsetk k|log|init}" ;;
esac