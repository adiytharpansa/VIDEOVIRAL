# Torrent HTTP Bridge — magnet/infoHash → HTTP

Micro-service Node.js untuk aplikasi **Anime Ringan (Flutter)**.
Mengubah torrent menjadi stream HTTP biasa (mendukung Range/`206`)
sehingga `video_player` di HP bisa memutarnya langsung.

## Jalankan

```bash
cd torrent-http-bridge
npm install
npm start
# → http://localhost:8765
```

Variabel env: `PORT` (default `8765`), `META_TIMEOUT_MS` (default `90000`),
`IDLE_DESTROY_MS` (default `1800000`, torrent dibuang setelah idle 30 mnt).

## Endpoint

| Method | Contoh | Fungsi |
|---|---|---|
| `GET /health` | `/health` | Cek hidup + jumlah torrent aktif |
| `GET /resolve?magnet=` | `/resolve?magnet=INFOHASH` | Info file video terbesar (nama, size) |
| `GET /stream?magnet=` | `/stream?magnet=MAGNET` | **Stream video (Range)** → pasang di video player |
| `GET /subs?url=` | `/subs?url=https://…/x.vtt` | Proxy subtitle (bebas CORS) |

`?magnet=` menerima magnet URI penuh **atau** infoHash hex 40 karakter.

## Pakai dari HP

1. Jalankan server ini di laptop/VPS yang jaringannya **bisa torrent**
   (UDP tracker/DHT tidak diblokir).
2. Di aplikasi Flutter, isi **Server konverter** dengan alamatnya,
   mis. `http://192.168.1.5:8765` (satu WiFi) atau `https://domain-kamu`.
3. Ketuk stream magnet → **Putar via Server**.

## Catatan jujur hasil tes (runner sandbox, 2026)

- `/health`, validasi error, `/subs` proxy: **lolos**.
- Fetch metadata torrent asli dari sandbox: **timeout** (UDP/tracker
  diblokir di jaringan sandbox) → server menjawab `502` JSON dengan
  pesan jelas dan **tetap hidup**. Di VPS/jaringan normal, metadata
  akan masuk dan `/stream` mengalir.
- Bug ditemukan & diperbaiki saat tes: `webtorrent@2.8.5` crash
  (`arr2hex` menerima string dari `parse-torrent@11`) → upgrade ke
  `webtorrent@^3.0.0`, crash hilang total.
- Pilih otomatis file video terbesar, prioritas `.mp4` (paling
  kompatibel dengan `video_player`; `.mkv` ikut ter-stream tapi
  belum tentu bisa diputar HP — konversi/remux server-side di luar
  cakupan file ini).
