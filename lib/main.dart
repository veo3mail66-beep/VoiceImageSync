import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

void main() => runApp(const MyApp());

enum EffectKind { none, zoomIn, zoomOut, pan, slide, mix }

enum AspectKind { wide, tall, square }

enum QualityKind { hd, fullHd }

enum _Fx { still, zoomIn, zoomOut, panRight, panLeft, slideRight, slideLeft }

const Map<EffectKind, String> _effectLabels = {
  EffectKind.none: 'None (static image)',
  EffectKind.zoomIn: 'Zoom in (Ken Burns)',
  EffectKind.zoomOut: 'Zoom out',
  EffectKind.pan: 'Pan left / right',
  EffectKind.slide: 'Slide in from side',
  EffectKind.mix: 'Mix (all effects, recommended)',
};

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice Image Sync',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF6750A4),
        useMaterial3: true,
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
  static const int _fps = 25;

  PlatformFile? _audio;
  PlatformFile? _script;
  PlatformFile? _music;
  List<PlatformFile> _images = [];

  EffectKind _effect = EffectKind.mix;
  AspectKind _aspect = AspectKind.wide;
  QualityKind _quality = QualityKind.hd;
  bool _fade = true;
  bool _fill = false;
  double _musicVol = 0.15;

  double _progress = 0; // 0..100
  String _status = 'Ready';
  String _log = '';
  bool _busy = false;
  bool _cancelled = false;

  // ---------- helpers ----------

  /// "image2" sorts before "image10".
  String _natKey(String name) {
    return name.toLowerCase().replaceAllMapped(
          RegExp(r'\d+'),
          (m) => m[0]!.padLeft(12, '0'),
        );
  }

  String _ext(String name) {
    final i = name.lastIndexOf('.');
    if (i < 0) return '.jpg';
    final e = name.substring(i).toLowerCase();
    const ok = ['.jpg', '.jpeg', '.png', '.webp', '.bmp'];
    return ok.contains(e) ? e : '.jpg';
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- pickers ----------

  Future<void> _pickAudio() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (r != null && r.files.isNotEmpty && r.files.first.path != null) {
      setState(() => _audio = r.files.first);
    }
  }

  Future<void> _pickMusic() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (r != null && r.files.isNotEmpty && r.files.first.path != null) {
      setState(() => _music = r.files.first);
    }
  }

  Future<void> _pickScript() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (r != null && r.files.isNotEmpty && r.files.first.path != null) {
      setState(() => _script = r.files.first);
    }
  }

  Future<void> _pickImages() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (r != null) {
      final list = r.files.where((f) => f.path != null).toList();
      list.sort((a, b) => _natKey(a.name).compareTo(_natKey(b.name)));
      setState(() => _images = list);
    }
  }

  // ---------- ffmpeg helpers ----------

  Future<double> _probeDuration(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = await session.getMediaInformation();
      final d = await info?.getDuration();
      if (d == null) return 0;
      return double.tryParse(d) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Which effect does image number [i] get?
  _Fx _fxFor(int i) {
    List<_Fx> cycle;
    switch (_effect) {
      case EffectKind.none:
        cycle = [_Fx.still];
        break;
      case EffectKind.zoomIn:
        cycle = [_Fx.zoomIn];
        break;
      case EffectKind.zoomOut:
        cycle = [_Fx.zoomOut];
        break;
      case EffectKind.pan:
        cycle = [_Fx.panRight, _Fx.panLeft];
        break;
      case EffectKind.slide:
        cycle = [_Fx.slideRight, _Fx.slideLeft];
        break;
      case EffectKind.mix:
        cycle = [
          _Fx.zoomIn,
          _Fx.slideRight,
          _Fx.panRight,
          _Fx.zoomOut,
          _Fx.slideLeft,
          _Fx.panLeft,
        ];
        break;
    }
    return cycle[i % cycle.length];
  }

  String _fit(int ww, int hh) {
    if (_fill) {
      return 'scale=$ww:$hh:force_original_aspect_ratio=increase,'
          'crop=$ww:$hh,setsar=1';
    }
    return 'scale=$ww:$hh:force_original_aspect_ratio=decrease,'
        'pad=$ww:$hh:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1';
  }

  /// Returns something like ",fade=t=in:...,fade=t=out:..." (leading comma) or ''.
  String _fadeStr(int frames, {required bool fadeIn}) {
    if (!_fade) return '';
    final dur = frames / _fps;
    final fd = math.min(0.4, dur / 3);
    if (fd <= 0.05) return '';
    final out = 'fade=t=out:st=${(dur - fd).toStringAsFixed(3)}:d=${fd.toStringAsFixed(3)}';
    if (fadeIn) {
      return ',fade=t=in:st=0:d=${fd.toStringAsFixed(3)},$out';
    }
    return ',$out';
  }

  List<String> _clipArgs({
    required String img,
    required String out,
    required _Fx fx,
    required int frames,
    required int w,
    required int h,
    required double mult,
  }) {
    final head = <String>['-y', '-hide_banner', '-loglevel', 'error'];
    final enc = <String>[
      '-frames:v', '$frames',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '24',
      '-pix_fmt', 'yuv420p', '-r', '$_fps', '-an',
      out,
    ];

    // --- static image ---
    if (fx == _Fx.still) {
      final vf = '${_fit(w, h)}${_fadeStr(frames, fadeIn: true)},format=yuv420p';
      return [...head, '-loop', '1', '-framerate', '$_fps', '-i', img, '-vf', vf, ...enc];
    }

    // --- slide in over black ---
    if (fx == _Fx.slideRight || fx == _Fx.slideLeft) {
      final sd = math.min(0.7, frames / _fps / 2).toStringAsFixed(2);
      final xy = fx == _Fx.slideRight
          ? "x='W*pow(max(0,1-t/$sd),2)':y=0"
          : "x='-W*pow(max(0,1-t/$sd),2)':y=0";
      final fc = 'color=c=black:s=${w}x$h:r=$_fps[bg];'
          '[0:v]${_fit(w, h)}[im];'
          '[bg][im]overlay=$xy,format=yuv420p${_fadeStr(frames, fadeIn: false)}[v]';
      return [
        ...head,
        '-loop', '1', '-framerate', '$_fps', '-i', img,
        '-filter_complex', fc,
        '-map', '[v]',
        ...enc,
      ];
    }

    // --- zoom / pan (zoompan filter on a bigger image for smoothness) ---
    final bw = (w * mult).round();
    final bh = (h * mult).round();
    String z, x, y;
    switch (fx) {
      case _Fx.zoomIn:
        z = '1+0.2*on/$frames';
        x = 'iw/2-(iw/zoom/2)';
        y = 'ih/2-(ih/zoom/2)';
        break;
      case _Fx.zoomOut:
        z = '1.2-0.2*on/$frames';
        x = 'iw/2-(iw/zoom/2)';
        y = 'ih/2-(ih/zoom/2)';
        break;
      case _Fx.panRight:
        z = '1.2';
        x = '(iw-iw/1.2)*on/$frames';
        y = '(ih-ih/1.2)/2';
        break;
      default: // panLeft
        z = '1.2';
        x = '(iw-iw/1.2)*(1-on/$frames)';
        y = '(ih-ih/1.2)/2';
        break;
    }
    final vf = '${_fit(bw, bh)},'
        'zoompan=z=$z:x=$x:y=$y:d=$frames:s=${w}x$h:fps=$_fps,'
        'format=yuv420p${_fadeStr(frames, fadeIn: true)}';
    return [...head, '-i', img, '-vf', vf, ...enc];
  }

  Future<void> _cancel() async {
    _cancelled = true;
    setState(() => _status = 'Cancelling...');
    await FFmpegKit.cancel();
  }

  // ---------- main work ----------

  Future<void> _start() async {
    if (_audio == null || _script == null || _images.isEmpty) {
      _toast('Audio, TXT aur images select karo.');
      return;
    }
    setState(() {
      _busy = true;
      _cancelled = false;
      _progress = 0;
      _status = 'Preparing...';
      _log = '';
    });

    Directory? work;
    try {
      final tmp = await getTemporaryDirectory();
      work = Directory('${tmp.path}/voice_sync');
      if (await work.exists()) await work.delete(recursive: true);
      await work.create(recursive: true);
      final imgDir = Directory('${work.path}/images');
      await imgDir.create(recursive: true);
      final clipDir = Directory('${work.path}/clips');
      await clipDir.create(recursive: true);

      // output size
      final base = _quality == QualityKind.hd ? 720 : 1080;
      final mult = _quality == QualityKind.hd ? 2.0 : 1.5;
      int w, h;
      switch (_aspect) {
        case AspectKind.wide:
          h = base;
          w = (base * 16 / 9).round();
          break;
        case AspectKind.tall:
          w = base;
          h = (base * 16 / 9).round();
          break;
        case AspectKind.square:
          w = base;
          h = base;
          break;
      }

      // copy images to safe, simple file names
      final localPaths = <String>[];
      for (var i = 0; i < _images.length; i++) {
        final name = 'image_${(i + 1).toString().padLeft(5, '0')}${_ext(_images[i].name)}';
        final dst = '${imgDir.path}/$name';
        await File(_images[i].path!).copy(dst);
        localPaths.add(dst);
      }

      final audioPath = _audio!.path!;
      final duration = await _probeDuration(audioPath);
      if (duration <= 0) throw Exception('Audio duration could not be detected.');

      // read script
      final bytes = await File(_script!.path!).readAsBytes();
      var text = utf8.decode(bytes, allowMalformed: true);
      if (text.startsWith('\uFEFF')) text = text.substring(1);

      final splitter = RegExp(
        r'(?<=[.!?\u0964\u06D4\u061F\uFF01\uFF1F])\s+|\n+',
      );
      final usable = text
          .replaceAll('\r', ' ')
          .split(splitter)
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      // each image gets a share of the audio, proportional to its words
      final n = localPaths.length;
      final weights = List<int>.filled(n, 0);
      for (var i = 0; i < usable.length; i++) {
        var idx = ((i / usable.length) * n).floor();
        if (idx > n - 1) idx = n - 1;
        final words = usable[i].split(RegExp(r'\s+')).length;
        weights[idx] += words < 1 ? 1 : words;
      }
      var total = 0;
      for (final wt in weights) {
        total += wt < 1 ? 1 : wt;
      }

      // exact frame counts per image (no drift, sums to the audio length)
      final frames = List<int>.filled(n, 1);
      var cum = 0.0;
      var prevTotal = 0;
      final totalFrames = (duration * _fps).round();
      for (var i = 0; i < n; i++) {
        final wt = weights[i] < 1 ? 1 : weights[i];
        cum += duration * wt / total;
        final target = (i == n - 1) ? totalFrames : (cum * _fps).round();
        var f = target - prevTotal;
        if (f < 1) f = 1;
        frames[i] = f;
        prevTotal += f;
      }

      setState(() {
        _log = 'Audio: ${(duration / 60).toStringAsFixed(2)} min\n'
            'TXT: ${text.length} chars\n'
            'Size: ${w}x$h';
      });

      // ---------- step 1: one clip per image ----------
      final clipPaths = <String>[];
      for (var i = 0; i < n; i++) {
        if (_cancelled) throw Exception('Cancelled');
        setState(() {
          _status = 'Image ${i + 1} / $n ...';
          _progress = 90.0 * i / n;
        });
        final clipPath = '${clipDir.path}/clip_${(i + 1).toString().padLeft(5, '0')}.mp4';
        final args = _clipArgs(
          img: localPaths[i],
          out: clipPath,
          fx: _fxFor(i),
          frames: frames[i],
          w: w,
          h: h,
          mult: mult,
        );
        final session = await FFmpegKit.executeWithArguments(args);
        final rc = await session.getReturnCode();
        if (_cancelled) throw Exception('Cancelled');
        if (!ReturnCode.isSuccess(rc)) {
          final out = await session.getOutput();
          throw Exception('Image ${i + 1} failed:\n${out ?? ''}');
        }
        clipPaths.add(clipPath);
      }

      // ---------- step 2: join clips + audio (+ background music) ----------
      final concat = File('${work.path}/concat.txt');
      final sb = StringBuffer();
      for (final p in clipPaths) {
        sb.writeln("file '$p'");
      }
      await concat.writeAsString(sb.toString());

      final outFile = File('${work.path}/final_video.mp4');
      final args = <String>[
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'concat', '-safe', '0', '-i', concat.path,
        '-i', audioPath,
      ];
      if (_music != null) {
        args.addAll(['-stream_loop', '-1', '-i', _music!.path!]);
        final vol = _musicVol.toStringAsFixed(2);
        args.addAll([
          '-filter_complex',
          '[1:a]aresample=44100[v1];'
              '[2:a]aresample=44100,volume=$vol[m1];'
              '[v1][m1]amix=inputs=2:duration=first:dropout_transition=0,volume=2[a]',
          '-map', '0:v:0', '-map', '[a]',
        ]);
      } else {
        args.addAll(['-map', '0:v:0', '-map', '1:a:0']);
      }
      args.addAll([
        '-c:v', 'copy',
        '-c:a', 'aac', '-b:a', '192k',
        '-shortest', '-movflags', '+faststart',
        outFile.path,
      ]);

      setState(() {
        _status = 'Joining video + audio...';
        _progress = 90;
      });

      final totalMs = duration * 1000.0;
      final done = Completer<String?>(); // null = success, else error text

      await FFmpegKit.executeWithArgumentsAsync(
        args,
        (session) async {
          try {
            final rc = await session.getReturnCode();
            if (ReturnCode.isSuccess(rc)) {
              done.complete(null);
            } else {
              final trace = await session.getFailStackTrace();
              final output = await session.getOutput();
              done.complete(trace ??
                  ((output != null && output.isNotEmpty) ? output : 'FFmpeg failed'));
            }
          } catch (e) {
            if (!done.isCompleted) done.complete('FFmpeg error: $e');
          }
        },
        null,
        (stats) {
          final t = stats.getTime().toDouble();
          var p = (t / totalMs) * 100.0;
          if (p > 100) p = 100;
          if (p < 0) p = 0;
          if (mounted) setState(() => _progress = 90 + p * 0.1);
        },
      );

      final err = await done.future;
      if (_cancelled) throw Exception('Cancelled');
      if (err != null) {
        setState(() {
          _status = 'FFmpeg error';
          _log = err;
        });
        return;
      }

      // ---------- save to gallery ----------
      var where = outFile.path;
      var note = '';
      var saved = false;
      try {
        await Gal.putVideo(outFile.path, album: 'VoiceImageSync');
        where = 'Gallery > VoiceImageSync album';
        saved = true;
      } catch (e) {
        note = '\nGallery save failed: $e';
      }
      setState(() {
        _progress = 100;
        _status = 'DONE';
        _log += '\n\nVideo ready:\n$where$note';
      });
      if (saved) {
        try {
          await work.delete(recursive: true);
        } catch (_) {}
      }
      _toast('Video ready!');
    } catch (e, st) {
      setState(() {
        if (_cancelled) {
          _status = 'Cancelled';
          _log = 'Stopped by user.';
        } else {
          _status = 'Error';
          _log = '$e\n$st';
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- UI ----------

  Widget _section(String title, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Voice Image Sync',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('Audio + TXT + Images → MP4'),
            const SizedBox(height: 16),

            _section('Files', [
              FilledButton.tonal(
                onPressed: _busy ? null : _pickAudio,
                child: const Text('1. Select Audio (voice)'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(_audio?.name ?? 'No audio selected'),
              ),
              FilledButton.tonal(
                onPressed: _busy ? null : _pickScript,
                child: const Text('2. Select TXT Script'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(_script?.name ?? 'No script selected'),
              ),
              FilledButton.tonal(
                onPressed: _busy ? null : _pickImages,
                child: const Text('3. Select Images'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text('${_images.length} images selected (name order)'),
              ),
            ]),

            _section('Image effect', [
              DropdownButton<EffectKind>(
                isExpanded: true,
                value: _effect,
                items: EffectKind.values
                    .map((e) => DropdownMenuItem<EffectKind>(
                          value: e,
                          child: Text(_effectLabels[e]!),
                        ))
                    .toList(),
                onChanged: _busy
                    ? null
                    : (v) {
                        if (v != null) setState(() => _effect = v);
                      },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Fade in / out between images'),
                value: _fade,
                onChanged: _busy ? null : (v) => setState(() => _fade = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Fill screen (crop) instead of black bars'),
                value: _fill,
                onChanged: _busy ? null : (v) => setState(() => _fill = v),
              ),
            ]),

            _section('Video format', [
              const Text('Shape'),
              const SizedBox(height: 6),
              SegmentedButton<AspectKind>(
                segments: const <ButtonSegment<AspectKind>>[
                  ButtonSegment<AspectKind>(
                      value: AspectKind.wide, label: Text('16:9 YouTube')),
                  ButtonSegment<AspectKind>(
                      value: AspectKind.tall, label: Text('9:16 Shorts')),
                  ButtonSegment<AspectKind>(
                      value: AspectKind.square, label: Text('1:1')),
                ],
                selected: {_aspect},
                onSelectionChanged:
                    _busy ? null : (s) => setState(() => _aspect = s.first),
              ),
              const SizedBox(height: 12),
              const Text('Quality'),
              const SizedBox(height: 6),
              SegmentedButton<QualityKind>(
                segments: const <ButtonSegment<QualityKind>>[
                  ButtonSegment<QualityKind>(
                      value: QualityKind.hd, label: Text('720p (fast)')),
                  ButtonSegment<QualityKind>(
                      value: QualityKind.fullHd, label: Text('1080p (slower)')),
                ],
                selected: {_quality},
                onSelectionChanged:
                    _busy ? null : (s) => setState(() => _quality = s.first),
              ),
            ]),

            _section('Background music (optional)', [
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: _busy ? null : _pickMusic,
                      child: const Text('Select Music'),
                    ),
                  ),
                  if (_music != null) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _busy ? null : () => setState(() => _music = null),
                      icon: const Icon(Icons.close),
                      tooltip: 'Remove music',
                    ),
                  ],
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(_music?.name ?? 'No music selected'),
              ),
              if (_music != null) ...[
                Text('Music volume: ${(_musicVol * 100).round()}%'),
                Slider(
                  value: _musicVol,
                  min: 0.02,
                  max: 0.6,
                  onChanged: _busy ? null : (v) => setState(() => _musicVol = v),
                ),
              ],
            ]),

            FilledButton(
              onPressed: _busy ? null : _start,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: const Text('CREATE VIDEO', style: TextStyle(fontSize: 18)),
            ),
            if (_busy) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _cancel,
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                child: const Text('CANCEL'),
              ),
            ],
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress / 100),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_status),
            ),
            SelectableText(_log, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
