import React, { useState } from 'react';
import {
  SafeAreaView,
  View,
  Text,
  TextInput,
  TouchableOpacity,
  Image,
  ScrollView,
  ActivityIndicator,
  Alert,
  Linking,
  StyleSheet,
  StatusBar,
} from 'react-native';
import { Video, ResizeMode } from 'expo-av';
import * as Clipboard from 'expo-clipboard';

// ── Konfigurasi API ──────────────────────────────────────────────
// Tenrai v1 (primer, pengganti Jikan publik yg tutup 1 Okt 2026): https://api.tenrai.org/v1
// Jikan v4 (fallback): https://api.jikan.moe/v4
// Torrentio (host real): https://torrentio.strem.fun
const TENRAI_BASE = 'https://api.tenrai.org/v1';
const JIKAN_BASE = 'https://api.jikan.moe/v4';
const TORRENTIO_BASE = 'https://torrentio.strem.fun';
const TORRENTIO_PROVIDERS =
  'providers=nyaasi,horriblesubs,anidex|sort=seeders|qualityfilter=720p,1080p';

export default function App() {
  const [query, setQuery] = useState('');
  const [loadingSearch, setLoadingSearch] = useState(false);
  const [anime, setAnime] = useState(null);
  const [episode, setEpisode] = useState('1');
  const [loadingStreams, setLoadingStreams] = useState(false);
  const [streams, setStreams] = useState([]);
  const [activeUrl, setActiveUrl] = useState(null);
  const [activeLabel, setActiveLabel] = useState('');
  const [subtitleUrl, setSubtitleUrl] = useState('');
  const [error, setError] = useState('');

  // 1) Tenrai (primer) → fallback Jikan: cari metadata anime → mal_id
  async function searchAnime() {
    const q = query.trim();
    if (!q) {
      Alert.alert('Judul kosong', 'Ketik judul anime dulu, mis. "Naruto".');
      return;
    }
    try {
      setError('');
      setLoadingSearch(true);
      setAnime(null);
      setStreams([]);
      setActiveUrl(null);
      let hit = null;
      let lastErr = '';
      for (const base of [TENRAI_BASE, JIKAN_BASE]) {
        try {
          const url = `${base}/anime?q=${encodeURIComponent(q)}&limit=1`;
          const res = await fetch(url);
          if (!res.ok) throw new Error(`HTTP ${res.status}`);
          const json = await res.json();
          if (!json?.data?.[0]) throw new Error('Anime tidak ditemukan.');
          hit = json.data[0];
          break;
        } catch (e) {
          lastErr = e.message || 'API error';
        }
      }
      if (!hit) throw new Error(lastErr || 'Anime tidak ditemukan di MyAnimeList.');
      setAnime({
        malId: hit.mal_id,
        title: hit.title_english || hit.title || '-',
        image: hit.images?.jpg?.image_url || null,
        synopsis: hit.synopsis || 'Sinopsis tidak tersedia.',
        episodes: hit.episodes || null,
      });
      setEpisode('1');
    } catch (e) {
      setError(e.message || 'Gagal menghubungi Jikan API.');
    } finally {
      setLoadingSearch(false);
    }
  }

  // 2) Torrentio: kitsu:{mal_id}:{episode} → daftar streams
  async function fetchStreams() {
    if (!anime?.malId) {
      Alert.alert('Belum ada anime', 'Cari anime dulu lewat Jikan.');
      return;
    }
    const ep = parseInt(episode, 10);
    if (!ep || ep < 1) {
      Alert.alert('Episode invalid', 'Nomor episode minimal 1.');
      return;
    }
    if (anime.episodes && ep > anime.episodes) {
      Alert.alert(
        'Melebihi total',
        `Anime ini hanya ${anime.episodes} episode.`
      );
      return;
    }
    try {
      setError('');
      setLoadingStreams(true);
      setStreams([]);
      setActiveUrl(null);
      const url =
        `${TORRENTIO_BASE}/${TORRENTIO_PROVIDERS}` +
        `/stream/anime/kitsu:${anime.malId}:${ep}.json`;
      const res = await fetch(url);
      if (!res.ok) throw new Error(`Torrentio HTTP ${res.status}`);
      const json = await res.json();
      const list = Array.isArray(json?.streams) ? json.streams : [];
      if (!list.length)
        throw new Error(
          'Stream tidak ditemukan. Coba episode lain / kualitas lain.'
        );
      setStreams(list);
    } catch (e) {
      setError(e.message || 'Gagal menghubungi Torrentio API.');
    } finally {
      setLoadingStreams(false);
    }
  }

  function seedersOf(title = '') {
    const m = String(title).match(/👤\s*(\d+)/) || String(title).match(/seeders?:?\s*(\d+)/i);
    return m ? m[1] : '-';
  }

  function magnetOf(s) {
    if (s?.infoHash) return `magnet:?xt=urn:btih:${s.infoHash}`;
    if (s?.url && String(s.url).startsWith('magnet:')) return s.url;
    return null;
  }

  async function playStream(s) {
    try {
      const httpUrl = s?.url && s.url.startsWith('http') ? s.url : null;
      if (httpUrl) {
        setActiveUrl(httpUrl);
        setActiveLabel(s.name || 'Stream');
        return;
      }
      const magnet = magnetOf(s);
      if (magnet) {
        Alert.alert(
          'InfoHash / Magnet saja',
          'Pemutar bawaan HP tidak bisa memutar magnet langsung.\n\nPilih:\n1. Salin magnet & buka di aplikasi torrent (Flud / BiglyBT),\n2. atau konversi via micro-service serverless ke HTTP lalu putar di sini.',
          [
            {
              text: 'Salin Magnet',
              onPress: async () => {
                try {
                  await Clipboard.setStringAsync(magnet);
                  Alert.alert('Disalin', 'Magnet disalin ke clipboard.');
                } catch (err) {
                  Alert.alert('Gagal', 'Clipboard tidak tersedia.');
                }
              },
            },
            {
              text: 'Buka di App Torrent',
              onPress: async () => {
                try {
                  const ok = await Linking.canOpenURL(magnet);
                  if (ok) await Linking.openURL(magnet);
                  else Alert.alert('Tidak ada app torrent', 'Install Flud / uTorrent dulu.');
                } catch (err) {
                  Alert.alert('Gagal', 'Tidak bisa membuka URI magnet.');
                }
              },
            },
            { text: 'Tutup', style: 'cancel' },
          ]
        );
        return;
      }
      Alert.alert('Tidak ada sumber', 'Stream ini tanpa url & infoHash.');
    } catch (e) {
      Alert.alert('Error', e.message || 'Gagal memutar stream.');
    }
  }

  return (
    <SafeAreaView style={styles.safe}>
      <StatusBar barStyle="light-content" />
      <ScrollView contentContainerStyle={styles.container} keyboardShouldPersistTaps="handled">
        <Text style={styles.brand}>
          ANIME<Text style={styles.brandAccent}>RINGAN</Text>
        </Text>
        <Text style={styles.hint}>
          Jikan (metadata) → Torrentio (torrent global) • Dark mode • HP
        </Text>

        {/* Pencarian anime */}
        <Text style={styles.label}>1 • Cari anime (Jikan)</Text>
        <View style={styles.row}>
          <TextInput
            style={styles.input}
            placeholder="cth. One Piece"
            placeholderTextColor="#777"
            value={query}
            onChangeText={setQuery}
            onSubmitEditing={searchAnime}
            returnKeyType="search"
          />
          <TouchableOpacity style={styles.btn} onPress={searchAnime}>
            <Text style={styles.btnText}>Cari</Text>
          </TouchableOpacity>
        </View>
        {loadingSearch && <ActivityIndicator color="#ff4e45" style={{ marginTop: 12 }} />}

        {anime && (
          <View style={styles.card}>
            <View style={{ flexDirection: 'row', gap: 12 }}>
              {anime.image && (
                <Image source={{ uri: anime.image }} style={styles.poster} />
              )}
              <View style={{ flex: 1 }}>
                <Text style={styles.animeTitle}>{anime.title}</Text>
                <Text style={styles.meta}>
                  MAL ID: {anime.malId}
                  {anime.episodes ? ` • ${anime.episodes} eps` : ''}
                </Text>
                <Text style={styles.syn} numberOfLines={5}>
                  {anime.synopsis}
                </Text>
              </View>
            </View>

            {/* Episode + ambil streams */}
            <Text style={[styles.label, { marginTop: 14 }]}>
              2 • Episode + ambil stream (Torrentio)
            </Text>
            <View style={styles.row}>
              <TextInput
                style={[styles.input, { maxWidth: 90, textAlign: 'center' }]}
                value={episode}
                onChangeText={setEpisode}
                keyboardType="number-pad"
                placeholder="1"
                placeholderTextColor="#777"
              />
              <TouchableOpacity style={styles.btn} onPress={fetchStreams}>
                <Text style={styles.btnText}>Ambil Stream</Text>
              </TouchableOpacity>
            </View>
            {loadingStreams && (
              <ActivityIndicator color="#ff4e45" style={{ marginTop: 12 }} />
            )}
          </View>
        )}

        {error ? <Text style={styles.error}>⚠ {error}</Text> : null}

        {/* Daftar streams */}
        {streams.length > 0 && (
          <View style={{ marginTop: 14 }}>
            <Text style={styles.label}>
              3 • Pilih stream ({streams.length} hasil, sort seeders)
            </Text>
            {streams.map((s, i) => (
              <TouchableOpacity
                key={i}
                style={styles.streamItem}
                onPress={() => playStream(s)}
              >
                <View style={styles.streamTop}>
                  <Text style={styles.badge}>{s.name || 'STREAM'}</Text>
                  <Text style={styles.seed}>👤 {seedersOf(s.title)}</Text>
                </View>
                <Text style={styles.streamTitle} numberOfLines={2}>
                  {s.title || s.url || s.infoHash || '-'}
                </Text>
                <Text style={styles.playHint}>
                  {s.url && s.url.startsWith('http')
                    ? '▶ Ketuk untuk putar langsung (HTTP)'
                    : '🧲 Ketuk untuk opsi magnet / torrent eksternal'}
                </Text>
              </TouchableOpacity>
            ))}

            {/* Subtitle Indonesia eksternal */}
            <Text style={[styles.label, { marginTop: 14 }]}>
              Subtitle Indonesia (opsional .vtt)
            </Text>
            <TextInput
              style={styles.input}
              placeholder="https://…/episode1-id.vtt"
              placeholderTextColor="#777"
              value={subtitleUrl}
              onChangeText={setSubtitleUrl}
              autoCapitalize="none"
            />
            <Text style={styles.note}>
              Torrent global mayoritas Eng-Sub / Raw. Jika pemutar mendukung,
              muat file .vtt Bahasa Indonesia dari URL di atas (atau gabungkan
              via micro-service remux).
            </Text>
          </View>
        )}

        {/* Player */}
        {activeUrl && (
          <View style={{ marginTop: 16 }}>
            <Text style={styles.label}>▶ {activeLabel}</Text>
            <Video
              source={{ uri: activeUrl }}
              style={styles.video}
              useNativeControls
              resizeMode={ResizeMode.CONTAIN}
              shouldPlay
            />
            <Text style={styles.note}>
              Jika buffering / error di jaringan Indonesia, aktifkan VPN
              (mis. 1.1.1.1) karena torrent publik sering diblokir operator.
            </Text>
          </View>
        )}

        <Text style={styles.footer}>
          Metode Ringan: tanpa server video sendiri • Jikan v4 + Torrentio •
          Hormati hak cipta, gunakan hanya untuk konten legal.
        </Text>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: { flex: 1, backgroundColor: '#0f0f0f' },
  container: { padding: 16, paddingBottom: 40 },
  brand: { color: '#fff', fontSize: 22, fontWeight: '800', letterSpacing: 1 },
  brandAccent: { color: '#ff4e45' },
  hint: { color: '#aaa', fontSize: 12, marginTop: 4, marginBottom: 14 },
  label: { color: '#fff', fontWeight: '700', fontSize: 14, marginBottom: 8 },
  row: { flexDirection: 'row', gap: 10 },
  input: {
    flex: 1,
    backgroundColor: '#1a1a1a',
    borderColor: '#333',
    borderWidth: 1,
    borderRadius: 12,
    color: '#fff',
    paddingHorizontal: 14,
    paddingVertical: 12,
    fontSize: 15,
  },
  btn: {
    backgroundColor: '#ff4e45',
    borderRadius: 12,
    paddingHorizontal: 18,
    justifyContent: 'center',
  },
  btnText: { color: '#fff', fontWeight: '800', fontSize: 15 },
  card: {
    backgroundColor: '#161616',
    borderColor: '#2a2a2a',
    borderWidth: 1,
    borderRadius: 14,
    padding: 14,
    marginTop: 14,
  },
  poster: { width: 90, height: 130, borderRadius: 10, backgroundColor: '#222' },
  animeTitle: { color: '#fff', fontWeight: '800', fontSize: 16 },
  meta: { color: '#3ea6ff', fontSize: 12, marginTop: 4 },
  syn: { color: '#ccc', fontSize: 12.5, marginTop: 8, lineHeight: 18 },
  error: {
    color: '#ffb4b4',
    backgroundColor: '#2a1215',
    borderColor: '#5c1d22',
    borderWidth: 1,
    borderRadius: 10,
    padding: 10,
    marginTop: 12,
    fontSize: 13,
  },
  streamItem: {
    backgroundColor: '#161616',
    borderColor: '#2a2a2a',
    borderWidth: 1,
    borderRadius: 12,
    padding: 12,
    marginTop: 8,
  },
  streamTop: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  badge: {
    color: '#0f0f0f',
    backgroundColor: '#fff',
    fontWeight: '800',
    fontSize: 12,
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 8,
    overflow: 'hidden',
  },
  seed: { color: '#8f8', fontSize: 12, fontWeight: '700' },
  streamTitle: { color: '#ddd', fontSize: 12, marginTop: 8 },
  playHint: { color: '#3ea6ff', fontSize: 12, marginTop: 6, fontWeight: '600' },
  video: { width: '100%', aspectRatio: 16 / 9, backgroundColor: '#000', borderRadius: 12 },
  note: { color: '#999', fontSize: 12, marginTop: 8, lineHeight: 17 },
  footer: { color: '#666', fontSize: 11, marginTop: 22, textAlign: 'center' },
});
