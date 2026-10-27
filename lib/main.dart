import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Renkler (beyaz zemin + açık pastel tonlar)
// ---------------------------------------------------------------------------
class AppColors {
  static const background = Colors.white;
  static const primary = Color(0xFF8E9BFF); // pastel mor-mavi
  static const primaryDark = Color(0xFF5C6BC0);
  static const text = Color(0xFF3E4462);
  static const subtext = Color(0xFF8A90A8);

  // Kartlar için dönüşümlü pastel renkler
  static const cardColors = <Color>[
    Color(0xFFEDEFFF), // lavanta
    Color(0xFFFFEBF1), // pembe
    Color(0xFFE3F8EF), // nane
    Color(0xFFFFF1E0), // şeftali
    Color(0xFFE2F4FF), // gök mavisi
  ];
  static const accentColors = <Color>[
    Color(0xFF8E9BFF),
    Color(0xFFFF9EBB),
    Color(0xFF6FCFA6),
    Color(0xFFFFB567),
    Color(0xFF6BBBF5),
  ];
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------
class Track {
  final String id;
  final String name; // ekranda görünen ad
  final String fileName; // uygulama klasöründeki dosya adı
  final String path; // tam yol (çalışma anında hesaplanır)

  Track({
    required this.id,
    required this.name,
    required this.fileName,
    required this.path,
  });

  String get extension => p.extension(fileName).replaceFirst('.', '').toUpperCase();
}

// ---------------------------------------------------------------------------
// Arşiv servisi: dosyaları uygulama klasörüne kopyalar ve listeyi saklar
// ---------------------------------------------------------------------------
class LibraryService {
  static const _prefsKey = 'library_v1';
  static const allowedExtensions = ['mp3', 'mp2', 'ogg', 'wav'];

  static Future<Directory> _musicDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'music'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<List<Track>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? [];
    final dir = await _musicDir();
    final tracks = <Track>[];
    for (final item in raw) {
      try {
        final map = jsonDecode(item) as Map<String, dynamic>;
        final fullPath = p.join(dir.path, map['fileName'] as String);
        if (await File(fullPath).exists()) {
          tracks.add(Track(
            id: map['id'] as String,
            name: map['name'] as String,
            fileName: map['fileName'] as String,
            path: fullPath,
          ));
        }
      } catch (_) {}
    }
    return tracks;
  }

  static Future<void> _save(List<Track> tracks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _prefsKey,
      tracks
          .map((t) => jsonEncode({
                'id': t.id,
                'name': t.name,
                'fileName': t.fileName,
              }))
          .toList(),
    );
  }

  /// Dosya seçtirir, kopyalar, listeye ekler. Eklenen yeni parçaları döndürür.
  static Future<List<Track>> pickAndAdd(List<Track> current) async {
    // file_picker v12+ : sonuç doğrudan PlatformFile listesi, iptalde boş liste
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
    );
    if (files.isEmpty) return [];

    final dir = await _musicDir();
    final added = <Track>[];

    for (final f in files) {
      final ext = p.extension(f.name).replaceFirst('.', '').toLowerCase();
      if (!allowedExtensions.contains(ext)) continue;

      final id = '${DateTime.now().microsecondsSinceEpoch}_${added.length}';
      final fileName = '$id.$ext';
      final destPath = p.join(dir.path, fileName);

      // Dosyayı uygulama klasörüne kopyala
      final sink = File(destPath).openWrite();
      await sink.addStream(f.readAsByteStream());
      await sink.close();

      added.add(Track(
        id: id,
        name: p.basenameWithoutExtension(f.name),
        fileName: fileName,
        path: destPath,
      ));
    }

    if (added.isNotEmpty) await _save([...current, ...added]);
    return added;
  }
}

// ---------------------------------------------------------------------------
// Uygulama
// ---------------------------------------------------------------------------
final AudioPlayer player = AudioPlayer();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Uygulama arka plandayken / kapatılınca da çalmaya devam etmesi için
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.example.music_player.channel.audio',
    androidNotificationChannelName: 'Müzik oynatma',
    androidNotificationOngoing: true,
  );
  final tracks = await LibraryService.load();
  runApp(MusicPlayerApp(initialTracks: tracks));
}

class MusicPlayerApp extends StatelessWidget {
  final List<Track> initialTracks;
  const MusicPlayerApp({super.key, required this.initialTracks});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Music Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          brightness: Brightness.light,
          surface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
      ),
      // Daha önce dosya eklenmişse doğrudan ana menü, yoksa başlangıç ekranı
      home: initialTracks.isEmpty
          ? const WelcomeScreen()
          : HomeScreen(initialTracks: initialTracks),
    );
  }
}

// ---------------------------------------------------------------------------
// Başlangıç ekranı
// ---------------------------------------------------------------------------
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  bool _busy = false;

  Future<void> _add() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final added = await LibraryService.pickAndAdd([]);
      if (added.isNotEmpty && mounted) {
        // pushReplacement: geri tuşuyla başlangıç ekranına dönülemez
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => HomeScreen(initialTracks: added),
          ),
        );
        return;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Dosya eklenemedi: $e')),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              const Spacer(flex: 2),
              Container(
                width: 160,
                height: 160,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [Color(0xFFE3E7FF), Color(0xFFFFE3EE)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const Icon(
                  Icons.music_note_rounded,
                  size: 84,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 36),
              const Text(
                'Başlamak için bir müzik\ndosyası ekleyin',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  height: 1.3,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'MP3, MP2, OGG ve WAV desteklenir',
                style: TextStyle(fontSize: 14, color: AppColors.subtext),
              ),
              const Spacer(flex: 3),
              SizedBox(
                width: 76,
                height: 76,
                child: FloatingActionButton(
                  heroTag: 'welcome_add',
                  onPressed: _busy ? null : _add,
                  elevation: 3,
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: const CircleBorder(),
                  child: _busy
                      ? const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.add_rounded, size: 44),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Ana menü
// ---------------------------------------------------------------------------
class HomeScreen extends StatefulWidget {
  final List<Track> initialTracks;
  const HomeScreen({super.key, required this.initialTracks});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late List<Track> _tracks;
  String? _currentId;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _tracks = List.of(widget.initialTracks);
    // Ses bitince tekrar tekrar çal
    player.setLoopMode(LoopMode.one);
  }

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Bu dosya oynatılamadı: $e')),
    );
  }

  Future<bool> _load(Track t) async {
    try {
      setState(() => _currentId = t.id);
      await player.setAudioSource(
        AudioSource.file(
          t.path,
          tag: MediaItem(id: t.id, title: t.name, album: 'Music Player'),
        ),
      );
      await player.setLoopMode(LoopMode.one);
      return true;
    } catch (e) {
      _showError(e);
      return false;
    }
  }

  Future<void> _togglePlay(Track t) async {
    if (_currentId == t.id) {
      if (player.playing) {
        await player.pause();
      } else {
        unawaited(player.play());
      }
      return;
    }
    if (await _load(t)) unawaited(player.play());
  }

  Future<void> _seekBy(Track t, int seconds) async {
    if (_currentId != t.id) {
      if (!await _load(t)) return;
    }
    final duration = player.duration ?? Duration.zero;
    var target = player.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    await player.seek(target);
  }

  Future<void> _addFiles() async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      final added = await LibraryService.pickAndAdd(_tracks);
      if (added.isNotEmpty && mounted) {
        setState(() => _tracks.addAll(added));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Dosya eklenemedi: $e')),
        );
      }
    }
    if (mounted) setState(() => _adding = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 20, 24, 0),
              child: Text(
                'Music Player',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: AppColors.text,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.library_music_rounded,
                      size: 20,
                      color: AppColors.primaryDark,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Ses Arşivi',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_tracks.length} parça',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.subtext,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 110),
                itemCount: _tracks.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, i) {
                  final t = _tracks[i];
                  return TrackCard(
                    track: t,
                    index: i,
                    isCurrent: _currentId == t.id,
                    onPlayPause: () => _togglePlay(t),
                    onBack: () => _seekBy(t, -5),
                    onForward: () => _seekBy(t, 5),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'home_add',
        onPressed: _adding ? null : _addFiles,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 3,
        shape: const CircleBorder(),
        child: _adding
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.add_rounded, size: 34),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Parça kartı
// ---------------------------------------------------------------------------
class TrackCard extends StatelessWidget {
  final Track track;
  final int index;
  final bool isCurrent;
  final VoidCallback onPlayPause;
  final VoidCallback onBack;
  final VoidCallback onForward;

  const TrackCard({
    super.key,
    required this.track,
    required this.index,
    required this.isCurrent,
    required this.onPlayPause,
    required this.onBack,
    required this.onForward,
  });

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final bg = AppColors.cardColors[index % AppColors.cardColors.length];
    final accent = AppColors.accentColors[index % AppColors.accentColors.length];

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isCurrent ? accent : Colors.transparent,
          width: 2,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(Icons.music_note_rounded, color: accent, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      track.extension,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.subtext,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              // Kontroller
              IconButton(
                onPressed: onBack,
                tooltip: '5 saniye geri',
                icon: const Icon(Icons.replay_5_rounded),
                iconSize: 30,
                color: AppColors.text,
              ),
              StreamBuilder<PlayerState>(
                stream: player.playerStateStream,
                builder: (context, snap) {
                  final playing = snap.data?.playing ?? false;
                  final showPause = isCurrent && playing;
                  return Material(
                    color: accent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onPlayPause,
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(
                          showPause
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                    ),
                  );
                },
              ),
              IconButton(
                onPressed: onForward,
                tooltip: '5 saniye ileri',
                icon: const Icon(Icons.forward_5_rounded),
                iconSize: 30,
                color: AppColors.text,
              ),
            ],
          ),
          // Sadece çalan/seçili parçada ilerleme çubuğu
          if (isCurrent)
            StreamBuilder<Duration?>(
              stream: player.durationStream,
              builder: (context, durSnap) {
                final total = durSnap.data ?? Duration.zero;
                return StreamBuilder<Duration>(
                  stream: player.positionStream,
                  builder: (context, posSnap) {
                    var pos = posSnap.data ?? Duration.zero;
                    if (pos > total) pos = total;
                    final maxMs = total.inMilliseconds.toDouble();
                    return Column(
                      children: [
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 4,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 7,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 14,
                            ),
                            activeTrackColor: accent,
                            inactiveTrackColor: Colors.white,
                            thumbColor: accent,
                          ),
                          child: Slider(
                            min: 0,
                            max: maxMs <= 0 ? 1 : maxMs,
                            value: maxMs <= 0
                                ? 0
                                : pos.inMilliseconds.toDouble().clamp(0, maxMs),
                            onChanged: maxMs <= 0
                                ? null
                                : (v) => player
                                    .seek(Duration(milliseconds: v.round())),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(_fmt(pos),
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.subtext)),
                              Text(_fmt(total),
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.subtext)),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
        ],
      ),
    );
  }
}