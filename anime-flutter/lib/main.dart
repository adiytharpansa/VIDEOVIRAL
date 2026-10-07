import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

const String jikanBase = 'https://api.jikan.moe/v4';
// Pengganti Jikan publik (tutup 1 Okt 2026): Tenrai v1, skema sama persis.
const String tenraiBase = 'https://api.tenrai.org/v1';
const String torrentioBase = 'https://torrentio.strem.fun';
const String torrentioProviders =
    'providers=nyaasi,horriblesubs,anidex|sort=seeders|qualityfilter=720p,1080p';

void main() => runApp(const AnimeRinganApp());

class AnimeRinganApp extends StatelessWidget {
  const AnimeRinganApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Anime Ringan',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F0F0F),
        colorScheme: const ColorScheme.dark(primary: Color(0xFFFF4E45)),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController queryC = TextEditingController();
  final TextEditingController episodeC = TextEditingController(text: '1');
  final TextEditingController subtitleC = TextEditingController();
  final TextEditingController directC = TextEditingController();
  final TextEditingController serverC = TextEditingController();

  bool loadingSearch = false;
  bool loadingStreams = false;
  Map<String, dynamic>? anime;
  List<dynamic> streams = [];
  String error = '';

  VideoPlayerController? player;
  String activeLabel = '';
  bool playerReady = false;
  bool testingConn = false;
  List<String> connResults = [];
  List<dynamic> topList = [];
  bool loadingTop = false;

  @override
  void initState() {
    super.initState();
    loadTopAiring(); // tampilkan anime otomatis saat aplikasi dibuka
  }

  @override
  void dispose() {
    queryC.dispose();
    episodeC.dispose();
    subtitleC.dispose();
    directC.dispose();
    serverC.dispose();
    player?.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _msg(Object e, String fallback) {
    final s = e.toString().replaceFirst('Exception: ', '');
    return s.isEmpty ? fallback : s;
  }

  Future<void> _disposePlayer() async {
    try {
      await player?.dispose();
    } catch (_) {}
    player = null;
    playerReady = false;
    activeLabel = '';
  }

  Map<String, dynamic> animeFromHit(Map<String, dynamic> hit) {
    final images = hit['images'] as Map<String, dynamic>?;
    final jpg = images?['jpg'] as Map<String, dynamic>?;
    return {
      'malId': hit['mal_id'],
      'title': hit['title_english'] ?? hit['title'] ?? '-',
      'image': jpg?['image_url'],
      'synopsis': hit['synopsis'] ?? 'Sinopsis tidak tersedia.',
      'episodes': hit['episodes'],
    };
  }

  // Daftar "sedang tayang" agar frontend langsung berisi anime.
  Future<void> loadTopAiring() async {
    try {
      setState(() {
        loadingTop = true;
      });
      for (final base in [tenraiBase, jikanBase]) {
        try {
          final url =
              Uri.parse('$base/top/anime?filter=airing&limit=8');
          final res =
              await http.get(url).timeout(const Duration(seconds: 20));
          if (res.statusCode != 200) continue;
          final data =
              ((jsonDecode(res.body) as Map<String, dynamic>)['data']
                      as List?) ??
                  [];
          if (data.isEmpty) continue;
          if (mounted) setState(() => topList = data);
          return;
        } catch (_) {
          continue;
        }
      }
    } catch (_) {
      // diam: daftar top boleh kosong, pencarian manual tetap bisa
    } finally {
      if (mounted) setState(() => loadingTop = false);
    }
  }

  // Pilih anime dari daftar top → langsung ambil stream EP1.
  Future<void> pickFromTop(dynamic raw) async {
    try {
      final hit = Map<String, dynamic>.from(raw as Map);
      setState(() {
        anime = animeFromHit(hit);
        streams = [];
        error = '';
      });
      episodeC.text = '1';
      await _disposePlayer();
      if (mounted) {
        setState(() {});
        await fetchStreams();
      }
    } catch (e) {
      _snack(_msg(e, 'Gagal membuka anime.'));
    }
  }

  Future<void> searchAnime() async {
    final q = queryC.text.trim();
    if (q.isEmpty) {
      _snack('Ketik judul anime dulu, mis. "Naruto".');
      return;
    }
    try {
      setState(() {
        error = '';
        loadingSearch = true;
        anime = null;
        streams = [];
      });
      await _disposePlayer();
      // Primer: Tenrai (pengganti Jikan). Fallback: Jikan publik.
      Map<String, dynamic>? hit;
      String lastErr = '';
      for (final base in [tenraiBase, jikanBase]) {
        try {
          final url = Uri.parse(
              '$base/anime?q=${Uri.encodeComponent(q)}&limit=1');
          final res =
              await http.get(url).timeout(const Duration(seconds: 20));
          if (res.statusCode != 200) {
            throw Exception('HTTP ${res.statusCode}');
          }
          final data =
              ((jsonDecode(res.body) as Map<String, dynamic>)['data']
                      as List?) ??
                  [];
          if (data.isEmpty) throw Exception('Anime tidak ditemukan.');
          hit = data.first as Map<String, dynamic>;
          break;
        } catch (e) {
          lastErr = _msg(e, 'API error');
        }
      }
      if (hit == null) {
        throw Exception(lastErr.isEmpty
            ? 'Anime tidak ditemukan di MyAnimeList.'
            : lastErr);
      }
      setState(() {
        anime = animeFromHit(hit);
      });
      episodeC.text = '1';
    } catch (e) {
      setState(() => error = _msg(e, 'Gagal menghubungi Tenrai/Jikan API.'));
    } finally {
      if (mounted) setState(() => loadingSearch = false);
    }
  }

  Future<void> fetchStreams() async {
    final malId = anime?['malId'];
    if (malId == null) {
      _snack('Cari anime dulu (Tenrai/Jikan).');
      return;
    }
    final ep = int.tryParse(episodeC.text.trim()) ?? 0;
    if (ep < 1) {
      _snack('Nomor episode minimal 1.');
      return;
    }
    final total = anime?['episodes'] as int?;
    if (total != null && ep > total) {
      _snack('Anime ini hanya $total episode.');
      return;
    }
    try {
      setState(() {
        error = '';
        loadingStreams = true;
        streams = [];
      });
      await _disposePlayer();
      final url = Uri.parse(
          '$torrentioBase/$torrentioProviders/stream/anime/kitsu:$malId:$ep.json');
      final res = await http.get(url).timeout(const Duration(seconds: 25));
      if (res.statusCode != 200) {
        throw Exception('Torrentio HTTP ${res.statusCode}');
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (json['streams'] as List?) ?? [];
      if (list.isEmpty) {
        throw Exception('Stream tidak ditemukan. Coba episode / kualitas lain.');
      }
      setState(() => streams = list);
    } catch (e) {
      setState(() => error = _msg(e, 'Gagal menghubungi Torrentio API.'));
    } finally {
      if (mounted) setState(() => loadingStreams = false);
    }
  }

  String seedersOf(String title) {
    try {
      final m1 = RegExp(r'\d+').firstMatch(title.split('👤').last);
      if (title.contains('👤') && m1 != null) return m1.group(0)!;
      final m2 =
          RegExp(r'seeders?:?\s*(\d+)', caseSensitive: false).firstMatch(title);
      if (m2 != null) return m2.group(1)!;
    } catch (_) {}
    return '-';
  }

  String? magnetOf(Map<String, dynamic> s) {
    try {
      if (s['infoHash'] != null) return 'magnet:?xt=urn:btih:${s['infoHash']}';
      final u = s['url']?.toString() ?? '';
      if (u.startsWith('magnet:')) return u;
    } catch (_) {}
    return null;
  }

  Future<void> playStream(Map<String, dynamic> s) async {
    try {
      final u = (s['url'] ?? '').toString();
      if (u.startsWith('http')) {
        await _disposePlayer();
        final ctl = VideoPlayerController.networkUrl(Uri.parse(u));
        setState(() {
          player = ctl;
          playerReady = false;
          activeLabel = (s['name'] ?? 'Stream').toString();
        });
        await ctl.initialize();
        if (!mounted) return;
        setState(() => playerReady = true);
        await ctl.play();
        return;
      }
      final magnet = magnetOf(s);
      if (magnet == null) {
        _snack('Stream ini tanpa url & infoHash.');
        return;
      }
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: const Text('InfoHash / Magnet saja'),
          content: const Text(
            'Pemutar bawaan HP tidak bisa memutar magnet langsung.\n\n'
            '1. Salin magnet & buka di app torrent (Flud / BiglyBT),\n'
            '2. atau konversi via micro-service serverless ke HTTP.',
            style: TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => playViaServer(
                  magnet, (s['name'] ?? 'Via Server').toString()),
              child: const Text('Putar via Server'),
            ),
            TextButton(
              onPressed: () async {
                try {
                  await Clipboard.setData(ClipboardData(text: magnet));
                  if (context.mounted) Navigator.pop(context);
                  _snack('Magnet disalin ke clipboard.');
                } catch (_) {
                  _snack('Clipboard tidak tersedia.');
                }
              },
              child: const Text('Salin'),
            ),
            TextButton(
              onPressed: () async {
                try {
                  final uri = Uri.parse(magnet);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri,
                        mode: LaunchMode.externalApplication);
                  } else {
                    _snack('Install app torrent dulu (Flud / uTorrent).');
                  }
                } catch (_) {
                  _snack('Tidak bisa membuka URI magnet.');
                }
              },
              child: const Text('Buka Torrent'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Tutup'),
            ),
          ],
        ),
      );
    } catch (e) {
      _snack(_msg(e, 'Gagal memutar stream.'));
    }
  }

  // Diagnosa: tes ketiga API langsung dari HP, hasil tampil di layar.
  Future<void> testConnection() async {
    final checks = <String, String>{
      'Tenrai': '$tenraiBase/anime?q=Naruto&limit=1',
      'Jikan': '$jikanBase/anime?q=Naruto&limit=1',
      'Torrentio': '$torrentioBase/$torrentioProviders/stream/anime/kitsu:20:1.json',
    };
    setState(() {
      testingConn = true;
      connResults = [];
    });
    for (final e in checks.entries) {
      try {
        final res = await http
            .get(Uri.parse(e.value))
            .timeout(const Duration(seconds: 20));
        if (res.statusCode == 200) {
          int n = 0;
          try {
            final j = jsonDecode(res.body) as Map<String, dynamic>;
            final l = (j['data'] as List?) ?? (j['streams'] as List?) ?? [];
            n = l.length;
          } catch (_) {}
          setState(() => connResults.add('✅ ${e.key}: HTTP 200 ($n data)'));
        } else {
          setState(() =>
              connResults.add('❌ ${e.key}: HTTP ${res.statusCode}'));
        }
      } catch (err) {
        setState(() => connResults.add('❌ ${e.key}: ${_msg(err, 'gagal')}'));
      }
    }
    if (mounted) setState(() => testingConn = false);
  }

  // Demo terverifikasi: One Piece EP1 → 13 streams (13 Okt 2026).
  Future<void> loadDemo() async {
    try {
      queryC.text = 'One Piece';
      await searchAnime();
      if (anime != null && mounted) await fetchStreams();
    } catch (e) {
      _snack(_msg(e, 'Demo gagal dimuat.'));
    }
  }

  // Tes player dengan URL MP4 langsung (jaminan bisa play instan).
  Future<void> playDirect() async {
    final u = directC.text.trim();
    if (!u.startsWith('http')) {
      _snack('Tempel URL MP4 http(s) dulu.');
      return;
    }
    await playHttpUrl(u, 'URL langsung');
  }

  Future<void> playHttpUrl(String u, String label) async {
    try {
      setState(() => error = '');
      await _disposePlayer();
      final ctl = VideoPlayerController.networkUrl(Uri.parse(u));
      setState(() {
        player = ctl;
        playerReady = false;
        activeLabel = label;
      });
      await ctl.initialize();
      if (!mounted) return;
      setState(() => playerReady = true);
      await ctl.play();
    } catch (e) {
      setState(() => error = _msg(e, 'URL tidak bisa diputar.'));
    }
  }

  // Magnet → HTTP via micro-service torrent-http-bridge.
  Future<void> playViaServer(String magnet, String label) async {
    try {
      final base = serverC.text.trim().replaceAll(RegExp(r'/$'), '');
      if (base.isEmpty) {
        _snack('Isi alamat Server konverter dulu (lihat README).');
        return;
      }
      if (mounted) Navigator.pop(context); // tutup dialog magnet
      await playHttpUrl(
          '$base/stream?magnet=${Uri.encodeComponent(magnet)}', label);
      if (mounted && error.isNotEmpty) {
        _snack('Server gagal: periksa server + jaringan torrent-nya.');
      }
    } catch (e) {
      _snack(_msg(e, 'Gagal memutar via server.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F0F),
        title: const Text('ANIME',
            style:
                TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('1. Cari anime (Tenrai/Jikan)',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: queryC,
                    onSubmitted: (_) => searchAnime(),
                    decoration: const InputDecoration(
                      hintText: 'cth. One Piece',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: loadingSearch ? null : searchAnime,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF4E45)),
                  child: const Text('Cari'),
                ),
              ],
            ),
            if (loadingSearch)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Center(child: CircularProgressIndicator()),
              ),
            TextButton(
              onPressed: loadingSearch ? null : loadDemo,
              child: const Text(
                '⚡ Demo instan: One Piece EP1 (terverifikasi 13 streams)',
                style: TextStyle(color: Colors.lightBlue),
              ),
            ),
            TextButton(
              onPressed: testingConn ? null : testConnection,
              child: Text(
                testingConn
                    ? '⏳ Mengetes koneksi…'
                    : '🛠 Tes koneksi API (jika anime tak muncul)',
                style: const TextStyle(color: Colors.orange),
              ),
            ),
            if (connResults.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF141414),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF333333)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: connResults
                      .map((r) => Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 2),
                            child: Text(r,
                                style: const TextStyle(fontSize: 12.5)),
                          ))
                      .toList(),
                ),
              ),
            if (loadingTop)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!loadingTop && topList.isNotEmpty) ...[
              const SizedBox(height: 6),
              const Text('🔥 Sedang tayang — ketuk untuk buka',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SizedBox(
                height: 200,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: topList.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (_, i) {
                    final raw =
                        Map<String, dynamic>.from(topList[i] as Map);
                    final imgs =
                        raw['images'] as Map<String, dynamic>?;
                    final img =
                        (imgs?['jpg'] as Map<String, dynamic>?)?['image_url']
                            ?.toString();
                    final title = ((raw['title_english'] ?? raw['title'])
                            ?.toString() ??
                        '-');
                    return GestureDetector(
                      onTap: () => pickFromTop(raw),
                      child: SizedBox(
                        width: 110,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: img != null
                                  ? Image.network(
                                      img,
                                      width: 110,
                                      height: 150,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) =>
                                          Container(
                                        width: 110,
                                        height: 150,
                                        color: const Color(0xFF222222),
                                        child: const Icon(
                                            Icons.broken_image,
                                            color: Colors.grey),
                                      ),
                                    )
                                  : Container(
                                      width: 110,
                                      height: 150,
                                      color: const Color(0xFF222222),
                                      child: const Icon(Icons.movie,
                                          color: Colors.grey),
                                    ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11.5),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
            if (anime != null) ...[
              const SizedBox(height: 14),
              Card(
                color: const Color(0xFF161616),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (anime!['image'] != null)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.network(
                                anime!['image'].toString(),
                                width: 90,
                                height: 130,
                                fit: BoxFit.cover,
                              ),
                            ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                    (anime!['title'] ?? '-').toString(),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 16)),
                                Text(
                                  'MAL ID: ${anime!['malId']}'
                                  '${anime!['episodes'] != null ? ' • ${anime!['episodes']} eps' : ''}',
                                  style: const TextStyle(
                                      color: Colors.lightBlue, fontSize: 12),
                                ),
                                Text(
                                  (anime!['synopsis'] ?? '').toString(),
                                  maxLines: 5,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 12.5),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      const Text('2. Episode + ambil stream (Torrentio)',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          SizedBox(
                            width: 90,
                            child: TextField(
                              controller: episodeC,
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              decoration: const InputDecoration(
                                hintText: '1',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton(
                              onPressed:
                                  loadingStreams ? null : fetchStreams,
                              style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      const Color(0xFFFF4E45)),
                              child: const Text('Ambil Stream'),
                            ),
                          ),
                        ],
                      ),
                      if (loadingStreams)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Center(
                              child: CircularProgressIndicator()),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            if (error.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A1215),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: const Color(0xFF5C1D22)),
                ),
                child: Text('⚠ $error',
                    style: const TextStyle(color: Color(0xFFFFB4B4))),
              ),
            if (streams.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('3. Pilih stream (${streams.length} hasil)',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              ...streams.map((raw) {
                final s = Map<String, dynamic>.from(raw as Map);
                final title = (s['title'] ?? '').toString();
                final httpOk =
                    (s['url'] ?? '').toString().startsWith('http');
                return Card(
                  color: const Color(0xFF161616),
                  child: ListTile(
                    onTap: () => playStream(s),
                    title: Text(
                      (s['name'] ?? 'STREAM').toString(),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      '${title.isEmpty ? '-' : title}\n'
                      '${httpOk ? '▶ Ketuk untuk putar langsung' : '🧲 Ketuk untuk opsi magnet'}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                    trailing: Text('👤 ${seedersOf(title)}',
                        style: const TextStyle(
                            color: Colors.lightGreen, fontSize: 12)),
                  ),
                );
              }),
              const SizedBox(height: 8),
              const Text('Subtitle Indonesia (opsional .vtt)',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              TextField(
                controller: subtitleC,
                decoration: const InputDecoration(
                  hintText: 'https://…/episode1-id.vtt',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            if (player != null) ...[
              const SizedBox(height: 14),
              Text('▶ $activeLabel',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  color: Colors.black,
                  child: playerReady
                      ? VideoPlayer(player!)
                      : const Center(
                          child: CircularProgressIndicator()),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: Icon(player!.value.isPlaying
                        ? Icons.pause
                        : Icons.play_arrow),
                    onPressed: () async {
                      try {
                        if (player!.value.isPlaying) {
                          await player!.pause();
                        } else {
                          await player!.play();
                        }
                        setState(() {});
                      } catch (_) {}
                    },
                  ),
                ],
              ),
              const Text(
                'Jika buffering di jaringan Indonesia, aktifkan VPN (1.1.1.1) — torrent publik sering diblokir operator.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
            const SizedBox(height: 22),
            const Text('Server konverter magnet→HTTP',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: serverC,
              decoration: const InputDecoration(
                hintText: 'http://192.168.1.5:8765',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Jalankan torrent-http-bridge (README) di laptop/VPS satu jaringan, lalu pakai tombol “Putar via Server” di dialog magnet.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 22),
            const Text('Tes player (URL MP4 langsung)',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: directC,
                    decoration: const InputDecoration(
                      hintText: 'https://…/video.mp4',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: playDirect,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF22C55E)),
                  child: const Text('Putar'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Metode Ringan: tanpa server video • Tenrai/Jikan + Torrentio • Gunakan hanya konten legal.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
