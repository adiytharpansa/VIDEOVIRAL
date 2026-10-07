import express from 'express';
import cors from 'cors';
import WebTorrent from 'webtorrent';

const PORT = parseInt(process.env.PORT || '8765', 10);
const META_TIMEOUT_MS = parseInt(process.env.META_TIMEOUT_MS || '90000', 10);
const IDLE_DESTROY_MS = parseInt(process.env.IDLE_DESTROY_MS || '1800000', 10); // 30 mnt

const app = express();
app.use(cors());
app.use(express.json());

const client = new WebTorrent();
// magnet -> { torrent, file, lastUsed, timer }
const cache = new Map();

const VIDEO_EXT = ['.mp4', '.m4v', '.webm', '.mkv', '.avi', '.mov'];
const isVideo = (name = '') =>
  VIDEO_EXT.some((e) => name.toLowerCase().endsWith(e));
const preferScore = (name = '') => {
  const n = name.toLowerCase();
  if (n.endsWith('.mp4') || n.endsWith('.m4v')) return 0; // paling kompatibel
  if (n.endsWith('.webm')) return 1;
  return 2;
};

function normMagnet(input) {
  const s = String(input || '').trim();
  if (!s) return null;
  if (s.startsWith('magnet:')) return s;
  if (/^[a-fA-F0-9]{40}$/.test(s)) return `magnet:?xt=urn:btih:${s.toLowerCase()}`;
  if (/^[a-zA-Z2-7]{32}$/.test(s)) return `magnet:?xt=urn:btih:${s}`; // base32 v1 (kasus langka)
  return null;
}

function touch(key) {
  const e = cache.get(key);
  if (!e) return;
  e.lastUsed = Date.now();
  clearTimeout(e.timer);
  e.timer = setTimeout(() => {
    try {
      client.remove(e.torrent.infoHash);
    } catch (_) {}
    cache.delete(key);
    console.log(`[idle] torrent dibuang: ${key.slice(0, 20)}…`);
  }, IDLE_DESTROY_MS);
  // refresh agar tidak kedaluwarsa saat dipakai
  e.timer.refresh?.();
}

async function getVideoFile(magnet) {
  if (cache.has(magnet)) {
    touch(magnet);
    return cache.get(magnet);
  }
  const torrent = await new Promise((resolve, reject) => {
    let t;
    try {
      t = client.add(magnet, { destroyStoreOnDestroy: false });
    } catch (e) {
      reject(e);
      return;
    }
    const to = setTimeout(() => {
      try {
        client.remove(t.infoHash);
      } catch (_) {}
      reject(new Error('Timeout menunggu metadata torrent (swarm sepi / tracker diblokir).'));
    }, META_TIMEOUT_MS);
    t.once('ready', () => {
      clearTimeout(to);
      resolve(t);
    });
    t.once('error', (e) => {
      clearTimeout(to);
      reject(e);
    });
  });

  const videos = (torrent.files || []).filter((f) => isVideo(f.name));
  if (!videos.length) {
    try {
      client.remove(torrent.infoHash);
    } catch (_) {}
    throw new Error('Torrent tidak berisi berkas video.');
  }
  videos.sort(
    (a, b) => preferScore(a.name) - preferScore(b.name) || b.length - a.length
  );
  const file = videos[0];
  const entry = { torrent, file, lastUsed: Date.now(), timer: null };
  cache.set(magnet, entry);
  touch(magnet);
  return entry;
}

function contentType(name = '') {
  const n = name.toLowerCase();
  if (n.endsWith('.webm')) return 'video/webm';
  if (n.endsWith('.mkv')) return 'video/x-matroska';
  if (n.endsWith('.avi')) return 'video/x-msvideo';
  if (n.endsWith('.mov')) return 'video/quicktime';
  return 'video/mp4';
}

app.get('/health', (req, res) => {
  res.json({ ok: true, torrents: cache.size, uptime: process.uptime() });
});

// Info file tanpa memutar: ?magnet=
app.get('/resolve', async (req, res) => {
  try {
    const magnet = normMagnet(req.query.magnet);
    if (!magnet) return res.status(400).json({ ok: false, error: 'Parameter ?magnet= tidak valid.' });
    const { file, torrent } = await getVideoFile(magnet);
    res.json({
      ok: true,
      infoHash: torrent.infoHash,
      name: file.name,
      size: file.length,
      contentType: contentType(file.name),
    });
  } catch (e) {
    res.status(502).json({ ok: false, error: String(e.message || e) });
  }
});

// Stream video dengan Range: ?magnet=
app.get('/stream', async (req, res) => {
  try {
    const magnet = normMagnet(req.query.magnet);
    if (!magnet) return res.status(400).json({ ok: false, error: 'Parameter ?magnet= tidak valid.' });
    const { file } = await getVideoFile(magnet);
    const total = file.length;
    const type = contentType(file.name);
    const range = req.headers.range;

    res.setHeader('Accept-Ranges', 'bytes');
    res.setHeader('Access-Control-Allow-Origin', '*');

    if (!range) {
      res.writeHead(200, {
        'Content-Length': total,
        'Content-Type': type,
      });
      file.createReadStream().pipe(res);
      return;
    }
    const m = range.match(/bytes=(\d*)-(\d*)/);
    const start = m && m[1] ? parseInt(m[1], 10) : 0;
    let end = m && m[2] ? parseInt(m[2], 10) : total - 1;
    if (isNaN(start) || isNaN(end) || start >= total) {
      res.writeHead(416, { 'Content-Range': `bytes */${total}` });
      return res.end();
    }
    end = Math.min(end, total - 1);
    res.writeHead(206, {
      'Content-Range': `bytes ${start}-${end}/${total}`,
      'Content-Length': end - start + 1,
      'Content-Type': type,
    });
    file.createReadStream({ start, end }).pipe(res);
  } catch (e) {
    if (!res.headersSent) {
      res.status(502).json({ ok: false, error: String(e.message || e) });
    } else {
      res.end();
    }
  }
});

// Proxy subtitle Indonesia (atasi CORS): ?url=https://…/x.vtt
app.get('/subs', async (req, res) => {
  try {
    const u = String(req.query.url || '').trim();
    if (!/^https?:\/\//.test(u)) {
      return res.status(400).json({ ok: false, error: 'Parameter ?url= harus http(s).' });
    }
    const r = await fetch(u, { redirect: 'follow' });
    if (!r.ok) throw new Error(`Subtitle HTTP ${r.status}`);
    const body = await r.text();
    const isVtt = /\.vtt(\?|$)/i.test(u) || /^WEBVTT/m.test(body);
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Content-Type', isVtt ? 'text/vtt; charset=utf-8' : 'text/plain; charset=utf-8');
    res.send(body);
  } catch (e) {
    res.status(502).json({ ok: false, error: String(e.message || e) });
  }
});

app.listen(PORT, () => {
  console.log(`[bridge] jalan di http://localhost:${PORT}`);
  console.log(`[bridge] GET /health | /resolve?magnet= | /stream?magnet= | /subs?url=`);
});
