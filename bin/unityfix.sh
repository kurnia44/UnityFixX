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
CLFILE="$UF_DIR/clusters"

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

# ---------- auto-detect cluster (topologi CPU) ----------
# Sumber: cpufreq/cpuinfo_max_freq per core (fallback scaling_max_freq).
# Hasil disimpan di $CLFILE sebagai key=value, dipakai resolve_mask().
_corelist() {
    if [ -n "$UF_CORES_FILE" ] && [ -r "$UF_CORES_FILE" ]; then
        cat "$UF_CORES_FILE"
        return 0
    fi
    for _d in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$_d" ] || continue
        _id=${_d##*cpu}
        case "$_id" in ''|*[!0-9]*) continue ;; esac
        _f=$(cat "$_d/cpufreq/cpuinfo_max_freq" 2>/dev/null)
        [ -z "$_f" ] && _f=$(cat "$_d/cpufreq/scaling_max_freq" 2>/dev/null)
        case "$_f" in ''|*[!0-9]*) _f=0 ;; esac
        echo "$_id $_f"
    done | sort -n
}

# hitung grup cluster + semua varian mask, tulis ke $CLFILE, cetak key=value
detect_clusters() {
    _raw=$(_corelist)
    [ -z "$_raw" ] && return 1
    _out=$(printf '%s\n' "$_raw" | awk '
    {
        n++; core[n]=$1+0; fq[n]=$2+0
        if (!($2+0 in seenf)) { seenf[$2+0]=1; fl[++nf]=$2+0 }
    }
    END{
        if (n < 1) exit 1
        for (i=2;i<=nf;i++){ v=fl[i]; j=i-1; while (j>=1 && fl[j]>v){ fl[j+1]=fl[j]; j-- } fl[j+1]=v }
        all=0; for (i=1;i<=n;i++) all += 2^core[i]
        for (g=1; g<=nf; g++){
            _cs=""; _m=0; _c=0
            for (i=1;i<=n;i++) if (fq[i]==fl[g]) { _cs = _cs (_c?",":"") core[i]; _m += 2^core[i]; _c++ }
            gc[g]=_c; gm[g]=_m; gs[g]=_cs
        }
        for (g=1; g<=nf; g++)
            printf "cluster.%d.freq=%d\ncluster.%d.cores=%s\ncluster.%d.mask=%d\n", g-1, fl[g], g-1, gs[g], g-1, gm[g]
        _c2=0; t4=0; t2=0
        for (g=nf; g>=1; g--) for (i=n; i>=1; i--) if (fq[i]==fl[g]) {
            if (_c2 < 4) t4 += 2^core[i]
            if (_c2 < 2) t2 += 2^core[i]
            _c2++
        }
        big = (nf > 1) ? all - gm[1] : all
        prime = gm[nf]
        # auto: kalau ada cluster "kecil" yang jelas (<=65% freq max, >=2 core, total >=8 core)
        #        buang cluster kecil itu; selain itu pakai semua core.
        auto = all
        why = "all-cores (seimbang)"
        if (nf > 1 && (fl[1] * 100 <= fl[nf] * 65) && gc[1] >= 2 && n >= 8) {
            auto = big
            why = "tanpa-cluster-kecil"
        }
        printf "core.count=%d\ncluster.count=%d\nmask.all=%d\nmask.big=%d\nmask.prime=%d\nmask.top4=%d\nmask.top2=%d\nmask.auto=%d\nauto.reason=%s\n", n, nf, all, big, prime, t4, t2, auto, why
    }') || return 1
    [ -z "$_out" ] && return 1
    printf '%s\n' "$_out" > "$CLFILE" 2>/dev/null
    printf '%s\n' "$_out"
}

clusters_ensure() { [ -s "$CLFILE" ] || detect_clusters >/dev/null 2>&1; }

nf_cpu() {
    _n=$(nproc 2>/dev/null)
    case "$_n" in ''|*[!0-9]*) _n=8 ;; esac
    echo "$_n"
}

# terjemahkan symbol ("auto"/"big"/"prime"/"top4"/"all"/desimal) jadi desimal
resolve_mask() {
    _v=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' \t')
    case "$_v" in
        ''|auto|smart|balanced|detect) _k=mask.auto ;;
        all|max|full|unlock)           _k=mask.all ;;
        big|perf|performance)          _k=mask.big ;;
        prime|top|heavy)               _k=mask.prime ;;
        top4|big4)                     _k=mask.top4 ;;
        top2|big2)                     _k=mask.top2 ;;
        *[!0-9]*)                      _k=mask.auto ;;
        *)                             printf '%s\n' "$_v"; return 0 ;;
    esac
    clusters_ensure
    _r=$(awk -F= -v k="$_k" '$1==k{print $2;exit}' "$CLFILE" 2>/dev/null)
    [ -z "$_r" ] && _r=$(( (1 << $(nf_cpu)) - 1 ))
    printf '%s\n' "$_r"
}

# desimal -> "cpu4,5,6,7"
mask_cores_str() {
    _mm="$1"; _nn=$(nf_cpu); _oo=""; _ii=0
    while [ "$_ii" -lt "$_nn" ]; do
        [ $(( (_mm >> _ii) & 1 )) -eq 1 ] && _oo="$_oo,${_ii}"
        _ii=$((_ii+1))
    done
    printf 'cpu%s\n' "${_oo#,}"
}

do_clusters() {
    ensure
    detect_clusters >/dev/null 2>&1
    clusters_ensure
    _ask=$(resolve_mask "${1:-auto}")
    echo "─────────────────────────────"
    echo " Topologi CPU"
    echo "─────────────────────────────"
    _nc=$(awk -F= '$1=="cluster.count"{print $2}' "$CLFILE" 2>/dev/null)
    _i=0
    while [ -n "$_nc" ] && [ "$_i" -lt "$_nc" ]; do
        _f=$(awk -F= -v k="cluster.$_i.freq" '$1==k{print $2}' "$CLFILE")
        _c=$(awk -F= -v k="cluster.$_i.cores" '$1==k{print $2}' "$CLFILE")
        _m=$(awk -F= -v k="cluster.$_i.mask" '$1==k{print $2}' "$CLFILE")
        _mhz=$(( ${_f:-0} / 1000 ))
        echo " cluster $_i : cpu$_c @ ${_mhz}MHz  mask=$_m"
        _i=$((_i+1))
    done
    echo "─────────────────────────────"
    for k in mask.auto mask.all mask.big mask.prime mask.top4 mask.top2; do
        v=$(awk -F= -v k="$k" '$1==k{print $2}' "$CLFILE" 2>/dev/null)
        [ -n "$v" ] && printf ' %-12s : %s (%s)\n' "${k#mask.}" "$v" "$(mask_cores_str "$v")"
    done
    echo "─────────────────────────────"
    echo " auto dipakai : $_ask ($(mask_cores_str "$_ask")) — $(awk -F= '$1=="auto.reason"{print $2}' "$CLFILE" 2>/dev/null)"
    echo "─────────────────────────────"
}

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
    gmask_raw=$(getv mask); [ -z "$gmask_raw" ] && gmask_raw=auto
    gmask=$(resolve_mask "$gmask_raw")
    glibs=$(getv libs)

    if [ "$en" != "1" ]; then
        clear_kernel
        write_state none - -
        note "idle (module disabled)"
        return 0
    fi

    if [ "$mode" = "always" ]; then
        if apply_kernel "$gmask" "$glibs"; then
            note "applied: always mask=$gmask (${gmask_raw}) libs=$glibs"
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

    am_raw=$(getv "app.$tgt.mask"); [ -z "$am_raw" ] && am_raw="$gmask_raw"
    am=$(resolve_mask "$am_raw")
    al=$(getv "app.$tgt.libs");  [ -z "$al" ] && al="$glibs"
    if apply_kernel "$am" "$al"; then
        note "applied: $tgt mask=$am ($am_raw)"
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
    _graw=$(getv mask); [ -z "$_graw" ] && _graw=auto
    _glibs=$(getv libs)
    _praw=$(getv "app.$_pkg.mask"); [ -z "$_praw" ] && _praw="$_graw"
    _pmask=$(resolve_mask "$_praw")
    _plibs=$(getv "app.$_pkg.libs"); [ -z "$_plibs" ] && _plibs="$_glibs"

    echo "check.pkg=$_pkg"
    echo "check.support=$_support"
    echo "check.mode=$_mode"
    echo "check.pin=$_pin"
    echo "check.cfg_mask=$_pmask"
    echo "check.cfg_mask_raw=$_praw"
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
    echo "rt.ncpu=$(nf_cpu)"
    detect_clusters >/dev/null 2>&1
    if [ -s "$CLFILE" ]; then
        echo "rt.auto_mask=$(awk -F= '$1=="mask.auto"{print $2}' "$CLFILE")"
        echo "rt.auto_reason=$(awk -F= '$1=="auto.reason"{print $2}' "$CLFILE")"
        echo "rt.mask_all=$(awk -F= '$1=="mask.all"{print $2}' "$CLFILE")"
        echo "rt.mask_big=$(awk -F= '$1=="mask.big"{print $2}' "$CLFILE")"
        echo "rt.mask_prime=$(awk -F= '$1=="mask.prime"{print $2}' "$CLFILE")"
        _ncl=$(awk -F= '$1=="cluster.count"{print $2}' "$CLFILE")
        echo "rt.cluster_count=$_ncl"
        _k=0
        while [ "$_k" -lt "${_ncl:-0}" ]; do
            _cf=$(awk -F= -v k="cluster.$_k.freq" '$1==k{print $2}' "$CLFILE")
            _cc=$(awk -F= -v k="cluster.$_k.cores" '$1==k{print $2}' "$CLFILE")
            echo "rt.cluster.$_k=cpu$_cc@$(( ${_cf:-0} / 1000 ))MHz"
            _k=$((_k+1))
        done
    fi
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
    echo " mask                 : $(getv mask) -> $(resolve_mask "$(getv mask)")"
    echo " libs                 : $(getv libs)"
    echo " apps                 : $(getv apps)"
    echo " pin (taskset)        : $(getv pin)"
    echo " last state           : $( [ -f "$STATE" ] && tr '\n' ' ' < "$STATE" )"
    echo "─────────────────────────────"
}

do_migrate() {
    ensure
    [ -s "$CONF" ] || cat "$UF_DIR/defaults.conf" > "$CONF" 2>/dev/null
    _sch=$(getv cfgschema)
    case "$_sch" in ''|*[!0-9]*) _sch=1 ;; esac
    if [ "$_sch" -lt 2 ]; then
        if [ "$(getv mask)" = "240" ]; then
            setv mask auto
            log "migrate: mask 240 (hardcoded lama) -> auto"
        fi
        setv cfgschema 2
        log "migrate: cfgschema=$_sch -> 2"
    fi
    detect_clusters >/dev/null 2>&1
    log "clusters: $(tr '\n' ' ' < "$CLFILE" 2>/dev/null)"
    exit 0
}

case "$1" in
    init)      do_migrate ;;
    clusters)  do_clusters "$2" ;;
    resolve)   clusters_ensure; resolve_mask "$2" ;;
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
    *)         echo "usage: unityfix.sh {dump|status|apply|check [pkg]|daemon|cores|clusters [auto|all|big|prime|top4|top2]|resolve <symbol>|installed|setk k v|unsetk k|log|init}" ;;
esac