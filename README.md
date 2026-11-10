# UnityFix X — v10-multi

Fork of **UnityFix** by [@LeanHijosdesusMadres](https://t.me/modulostk), rebuilt by **eLSanz (@Reichtw)**.

Fungsi dasar tetap sama: paksa kernel melaporkan frekuensi CPU maksimum ke task yang memakai
library game engine — Unity (`libunity.so`), Unreal, Cocos, Godot, Flutter — supaya affinity yang
salah (engine naruh thread di core kecil) tidak bikin frame drop.

Yang baru di fork ini:

- **Multi-app.** Tidak cuma CoD/Genshin. Daftar app target bebas diisi dari WebUI.
- **WebUI penuh** (KernelSU / APatch / MMRL): toggle on-off, mode, daftar library, pilihan core,
  override per-app, log, apply langsung.
- **Mode Auto / Always.**
  - `auto` — setting hanya aktif saat salah satu app target jalan, app lain tidak tersentuh.
  - `always` — setting berlaku global ke semua proses yang memakai library terdaftar.
- **Override per-app** — app A pakai 4 core, app B pakai 2 core, app C pakai semua core.
- **Pin affinity (taskset)** — untuk kernel yang tidak punya patch `sched_lib_mask_force`,
  modul tetap bisa memaksa pinning core ke proses app target.
- **Config persisten** di `/data/adb/unityfix/config.conf` (tidak hilang saat update modul).

## Instal

1. Flash zip di Magisk / KernelSU / APatch.
2. Reboot.
3. Buka **WebUI modul** dari manager (KernelSU → Modules → UnityFix X → buka / ikon web).

Kalau manager tidak punya WebUI (Magisk biasa), tombol **Action** di kartu modul membuka menu
terminal cepat (Vol+ semua core, Vol- 4 core besar, layar 2 core besar).

## Mask core

Nilai desimal, `bit0 = cpu0`.

| Mask | Core | Keterangan |
|------|------|------------|
| 255 | 0-7 | semua core |
| 240 | 4-7 | 4 core besar (default) |
| 192 | 6-7 | 2 core besar |
| 15  | 0-3 | 4 core kecil |
| 128 | 7 | 1 core terbesar |

WebUI menghitung sendiri dari topologi HP kamu (`cpuinfo_max_freq`), jadi preset "Big N"
selalu sesuai jumlah core perangkat.

## Struktur

```
module.prop          metadata
customize.sh         installer
service.sh           start daemon saat boot
action.sh            menu tombol Action (Magisk)
uninstall.sh         bersihkan sysfs + config
defaults.conf        config awal
bin/unityfix.sh      CLI + daemon (dump/apply/setk/cores/installed/log)
webroot/index.html   WebUI
/data/adb/unityfix/  config.conf, state, unityfix.log
```

## Catatan kernel

Efek penuh butuh kernel dengan patch `sched_lib_name` / `sched_lib_mask_force`
(`/proc/sys/kernel/` atau `/proc/sys/walt/`). Tanpa patch itu, pakai **Pin affinity** di WebUI —
hasilnya mirip untuk kasus "game cuma boleh pakai 4 core", tapi tidak mengubah laporan frekuensi.

## Kredit

- Original module & riset sched_lib: **@LeanHijosdesusMadres** (t.me/modulostk)
- Jimmy Shiu, NotZeetaa, Zackptg5 (MMT-Ex), topjohnwu (Magisk)
- Fork + WebUI: **eLSanz (@Reichtw)**
## Checker — tau app-nya beneran ikut setting atau nggak

Modul gak cuma nulis setting lalu diem. Ada verifikasi 4 lapis:

1. **Sysfs vs config** — nilai `sched_lib_mask_force` / `sched_lib_name` di kernel dibanding nilai
   yang kamu simpan. Kalau kernel nolak tulis (read-only / gak didukung), ketahuan di sini.
2. **Lib benar-benar ke-load** — tiap library yang kamu daftar dicek ke `/proc/<pid>/maps` app target.
   Kalau game belum load `libunity.so`, statusnya "belum load", bukan pura-pura sukses.
3. **Affinity thread** — `Cpus_allowed_list` semua thread app dibanding mask kamu. Ini wajib
   hijau kalau **Pin affinity** dinyalakan; kalau pin mati cuma ditandai sebagai info, karena
   patch kernel bekerja per-library, bukan per-proses.
4. **Frekuensi realtime** — `scaling_cur_freq` per core yang kamu izinkan, dibanding
   `cpuinfo_max_freq`.

Hasilnya satu verdict: `OK` (semua cocok), `WARN` (jalan tapi ada yang belum sesuai),
`FAIL` (gak mungkin sesuai — app mati + sysfs beda, atau kernel tanpa patch dan pin mati).

Dari WebUI: kartu **Checker** → pilih app (atau "auto" = app target yang sedang jalan) → **Cek sekarang**.
Dari terminal:

```
sh /data/adb/unityfix/bin/unityfix.sh check                 # app target yang jalan
sh /data/adb/unityfix/bin/unityfix.sh check com.mobile.legends
```
