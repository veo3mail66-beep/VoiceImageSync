import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

void main() => runApp(const MyApp());

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
  PlatformFile? _audio;
  PlatformFile? _script;
  List<PlatformFile> _images = [];
  double _progress = 0; // 0..100
  String _status = 'Ready';
  String _log = '';
  bool _busy = false;

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

  // ---------- main work ----------

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

  Future<void> _start() async {
    if (_audio == null || _script == null || _images.isEmpty) {
      _toast('Audio, TXT aur images select karo.');
      return;
    }
    setState(() {
      _busy = true;
      _progress = 0;
      _status = 'Preparing...';
      _log = '';
    });

    try {
      final tmp = await getTemporaryDirectory();
      final work = Directory('${tmp.path}/voice_sync');
      if (await work.exists()) await work.delete(recursive: true);
      await work.create(recursive: true);
      final imgDir = Directory('${work.path}/images');
      await imgDir.create(recursive: true);

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

      // split into sentences (. ! ? | Urdu/Hindi/CJK marks) and lines
      final splitter = RegExp(
        r'(?<=[.!?\u0964\u06D4\u061F\uFF01\uFF1F])\s+|\n+',
      );
      final usable = text
          .replaceAll('\r', ' ')
          .split(splitter)
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      // give every image a share of the audio, proportional to its words
      final n = localPaths.length;
      final weights = List<int>.filled(n, 0);
      for (var i = 0; i < usable.length; i++) {
        var idx = ((i / usable.length) * n).floor();
        if (idx > n - 1) idx = n - 1;
        final words = usable[i].split(RegExp(r'\s+')).length;
        weights[idx] += words < 1 ? 1 : words;
      }
      var total = 0;
      for (final w in weights) {
        total += w < 1 ? 1 : w;
      }
      final durations = List<double>.filled(n, 0);
      var used = 0.0;
      for (var i = 0; i < n; i++) {
        if (i == n - 1) {
          final rest = duration - used;
          durations[i] = rest < 0.08 ? 0.08 : rest;
        } else {
          final w = weights[i] < 1 ? 1 : weights[i];
          durations[i] = duration * w / total;
        }
        used += durations[i];
      }

      // ffmpeg concat list
      final concat = File('${work.path}/concat.txt');
      final sb = StringBuffer();
      for (var i = 0; i < n; i++) {
        sb.writeln("file '${localPaths[i]}'");
        sb.writeln('duration ${durations[i].toStringAsFixed(3)}');
      }
      // concat demuxer: last file must be repeated for its duration to count
      sb.writeln("file '${localPaths[n - 1]}'");
      await concat.writeAsString(sb.toString());

      final outFile = File('${work.path}/final_video.mp4');
      const vf = 'scale=1920:1080:force_original_aspect_ratio=decrease,'
          'pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,format=yuv420p';
      final args = <String>[
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'concat', '-safe', '0', '-i', concat.path,
        '-i', audioPath,
        '-map', '0:v:0', '-map', '1:a:0',
        '-vf', vf,
        '-r', '25',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'stillimage',
        '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-b:a', '192k',
        '-shortest', '-movflags', '+faststart',
        outFile.path,
      ];

      setState(() {
        _status = 'Rendering ${_images.length} images...';
        _log = 'Audio: ${(duration / 60).toStringAsFixed(2)} min\n'
            'TXT: ${text.length} chars';
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
          if (p > 99) p = 99;
          if (p < 0) p = 0;
          if (mounted) setState(() => _progress = p);
        },
      );

      final err = await done.future;
      if (err != null) {
        setState(() {
          _status = 'FFmpeg error';
          _log = err;
        });
        return;
      }

      // save to gallery (Movies/VoiceImageSync)
      var where = outFile.path;
      var note = '';
      try {
        await Gal.putVideo(outFile.path, album: 'VoiceImageSync');
        where = 'Gallery > VoiceImageSync album';
      } catch (e) {
        note = '\nGallery save failed: $e';
      }
      setState(() {
        _progress = 100;
        _status = 'DONE';
        _log += '\n\nVideo ready:\n$where$note';
      });
      _toast('Video ready!');
    } catch (e, st) {
      setState(() {
        _status = 'Error';
        _log = '$e\n$st';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const Text('Voice Image Sync',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('Audio + TXT + Images → MP4'),
            const SizedBox(height: 18),
            FilledButton.tonal(
              onPressed: _busy ? null : _pickAudio,
              child: const Text('1. Select Audio'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_audio?.name ?? 'No audio selected'),
            ),
            FilledButton.tonal(
              onPressed: _busy ? null : _pickScript,
              child: const Text('2. Select TXT Script'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_script?.name ?? 'No script selected'),
            ),
            FilledButton.tonal(
              onPressed: _busy ? null : _pickImages,
              child: const Text('3. Select Images'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('${_images.length} images selected (name order)'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy ? null : _start,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: const Text('CREATE VIDEO', style: TextStyle(fontSize: 18)),
            ),
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
