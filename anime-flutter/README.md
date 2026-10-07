# Anime Ringan (Flutter) — Metode Ringan API Scraper

Aplikasi HP streaming anime tanpa server video sendiri.
Alur: **Tenrai/Jikan** (metadata `mal_id`) → **Torrentio** (`kitsu:{mal_id}:{episode}`) → play.

## Syarat

- Flutter SDK ≥ 3.0 (`flutter --version`)
- HP Android / emulator tersambung (`flutter devices`)

## Jalankan

```bash
cd anime-flutter
flutter pub get
flutter run
```

## Cara pakai (3 langkah di layar)

1. Ketik judul anime → **Cari** (atau ketuk **⚡ Demo instan: One Piece EP1**).
2. Isi nomor episode → **Ambil Stream**.
3. Ketuk salah satu stream:
   - Ada URL HTTP → langsung play di pemutar bawaan.
   - Hanya magnet/infoHash → pilih **Salin** (buka di Flud/BiglyBT) atau **Buka Torrent**.

## Anime tak muncul? Lakukan ini berurutan

1. Ketuk **🛠 Tes koneksi API** di aplikasi. Harusnya muncul 3 baris `✅ HTTP 200`.
   - Ada `❌`? Foto/salin barisnya — itulah akar masalah (biasanya internet
     HP/emulator atau operator memblokir).
2. Pastikan `android/app/src/main/AndroidManifest.xml` memuat:
   `<uses-permission android:name="android.permission.INTERNET"/>`
   (template `flutter create` sudah menyertakannya).
3. Emulator Android kadang DNS-nya macet → tutup + Cold Boot emulator,
   atau tes di HP fisik.
4. Operator Indonesia sering memblokir domain torrent → aktifkan VPN
   (1.1.1.1) lalu tes koneksi lagi.
5. Jika Tenrai ❌ tapi Jikan ✅ (atau sebaliknya), aplikasi otomatis
   memakai yang hidup — lanjutkan pakai demo One Piece.

## Play magnet via server sendiri (opsional, recommended)

Torrentio publik hanya memberi `infoHash`. Agar bisa play langsung di HP:

```bash
cd ../torrent-http-bridge
npm install
npm start   # http://localhost:8765 — butuh jaringan yang bisa torrent
```

Lalu di aplikasi isi **Server konverter** dengan alamatnya
(mis. `http://192.168.1.5:8765`), ketuk stream magnet → **Putar via Server**.

## Tes player (garansi play instan)

Tempel URL MP4 langsung di kolom **Tes player**, mis.:

```
https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4
```

## Catatan Indonesia

- Torrent global mayoritas Eng-Sub/Raw → tempel URL `.vtt` Indonesia di kolom subtitle.
- Torrentio publik hanya memberi `infoHash` (tanpa HTTP langsung) → butuh app torrent atau micro-service magnet→HTTP.
- Jika stream kosong/buffering di jaringan seluler: aktifkan VPN (1.1.1.1), torrent publik sering diblokir operator.
- Jikan publik tutup 1 Okt 2026 → aplikasi memakai **Tenrai primer + Jikan fallback**.
- Gunakan hanya untuk konten legal.
