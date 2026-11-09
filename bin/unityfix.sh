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
    log)       tail -n 40 "$LOG" 2>/dev/null ;;
    *)         echo "usage: unityfix.sh {dump|status|apply|daemon|cores|installed|setk k v|unsetk k|log|init}" ;;
esac