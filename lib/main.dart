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

enum ModeKind { turbo, cinematic }

enum TimingKind { script, fixed }

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
  static const int _fps = 25; // Cinematic mode frame rate

  PlatformFile? _audio;
  PlatformFile? _script;
  PlatformFile? _music;
  List<PlatformFile> _images = [];
  double? _audioSec;

  ModeKind _mode = ModeKind.turbo;
  TimingKind _timing = TimingKind.fixed;
  double _secPerImage = 6.5;
  bool _shuffle = false;
  int _turboFps = 5;

  EffectKind _effect = EffectKind.mix;
  AspectKind _aspect = AspectKind.wide;
  QualityKind _quality = QualityKind.hd;
  bool _fade = true;
  bool _fill = false;
  bool _slideOn = true;
  double _musicVol = 0.15;

  double _progress = 0; // 0..100
  String _status = 'Ready';
  String _log = '';
  bool _busy = false;
  bool _cancelled = false;

  final Stopwatch _sw = Stopwatch();
  double _lastP = -1;
  String _lastLabel = '';

  // ---------- helpers ----------

  String _natKey(String name) {
    return name.toLowerCase().replaceAllMapped(
          RegExp(r'\d+'),
          (m) => m[0]!.padLeft(12, '0'),
        );
  }

  String _fmtDur(double s) {
    final t = s.round();
    final h = t ~/ 3600;
    final m = (t % 3600) ~/ 60;
    final sec = t % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${sec}s';
    return '${sec}s';
  }

  /// Escape for ffmpeg concat-demuxer single-quoted file names.
  String _cq(String s) => s.replaceAll("'", "'\\''");

  bool _canCopyAudio(String name) {
    final n = name.toLowerCase();
    return n.endsWith('.m4a') ||
        n.endsWith('.aac') ||
        n.endsWith('.mp3') ||
        n.endsWith('.mp4');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool> _confirm(String msg) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Slow mode'),
        content: Text(msg),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Continue anyway'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  void _setProgress(double p, String label) {
    if (!mounted) return;
    if ((p - _lastP).abs() < 0.2 && label == _lastLabel) return;
    _lastP = p;
    _lastLabel = label;
    var s = label;
    if (p >= 3 && p < 99.5) {
      final secs = _sw.elapsed.inSeconds * (100 - p) / p;
      s = '$label  (~${_fmtDur(secs)} left)';
    }
    setState(() {
      _progress = p;
      _status = s;
    });
  }

  // ---------- pickers ----------

  Future<void> _pickAudio() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (r == null || r.files.isEmpty || r.files.first.path == null) return;
    final f = r.files.first;
    setState(() {
      _audio = f;
      _audioSec = null;
    });
    final d = await _probeDuration(f.path!);
    if (!mounted) return;
    var switched = false;
    setState(() {
      _audioSec = d > 0 ? d : null;
      if (d > 900 && _mode == ModeKind.cinematic) {
        _mode = ModeKind.turbo;
        switched = true;
      }
    });
    if (switched) {
      _toast('Audio lambi hai, isliye Turbo mode select kar diya.');
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

  /// Runs ffmpeg and waits. Returns null on success, otherwise error text.
  Future<String?> _runFfmpeg(
    List<String> args,
    void Function(int frame, double timeMs) onStats,
  ) async {
    final done = Completer<String?>();
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
        onStats(stats.getVideoFrameNumber(), stats.getTime().toDouble());
      },
    );
    return done.future;
  }

  /// Frame counts per slot that always add up to the exact audio length.
  List<int> _framesFor(List<double> durs, int fps, double totalDur) {
    final n = durs.length;
    final res = List<int>.filled(n, 1);
    var cum = 0.0;
    var prev = 0;
    final totalFrames = (totalDur * fps).round();
    for (var i = 0; i < n; i++) {
      cum += durs[i];
      final target = (i == n - 1) ? totalFrames : (cum * fps).round();
      var f = target - prev;
      if (f < 1) f = 1;
      res[i] = f;
      prev += f;
    }
    return res;
  }

  /// Round slot boundaries to a [p]-second grid (used by Turbo slide effect,
  /// so the slide phase can be computed from the frame timestamp alone).
  List<double> _quantSlots(List<double> durs, double total, double p) {
    final res = <double>[];
    var prevB = 0.0;
    var cum = 0.0;
    for (var i = 0; i < durs.length; i++) {
      cum += durs[i];
      if (i == durs.length - 1) {
        var d = total - prevB;
        if (d < 0.1) d = 0.1;
        res.add(d);
      } else {
        final b = (cum / p).round() * p;
        var d = b - prevB;
        if (d < p) d = p;
        res.add(d);
        prevB += d;
      }
    }
    return res;
  }

  /// Image order for fixed-time mode (loops, optional shuffle).
  List<int> _sequence(int m, int k) {
    final res = <int>[];
    if (!_shuffle || k == 1) {
      for (var i = 0; i < m; i++) {
        res.add(i % k);
      }
      return res;
    }
    final rnd = math.Random();
    int? last;
    while (res.length < m) {
      final perm = List<int>.generate(k, (i) => i)..shuffle(rnd);
      if (last != null && perm.first == last) {
        final tmp = perm[0];
        perm[0] = perm[1];
        perm[1] = tmp;
      }
      for (final p in perm) {
        if (res.length >= m) break;
        res.add(p);
      }
      last = res.last;
    }
    return res;
  }

  _Fx _fxFor(int i) {
    if (_slideOn) return _Fx.slideRight;
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

  String _fadeStr(int frames, {required bool fadeIn}) {
    if (!_fade) return '';
    final dur = frames / _fps;
    final fd = math.min(0.4, dur / 3);
    if (fd <= 0.05) return '';
    final out =
        'fade=t=out:st=${(dur - fd).toStringAsFixed(3)}:d=${fd.toStringAsFixed(3)}';
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

    if (fx == _Fx.still) {
      final vf = '${_fit(w, h)}${_fadeStr(frames, fadeIn: true)},format=yuv420p';
      return [...head, '-loop', '1', '-framerate', '$_fps', '-i', img, '-vf', vf, ...enc];
    }

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
      default:
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

  /// Final step: concat list(s) + audio (+ music) -> mp4.
  /// If [prevConcatPath] is given, the video is built from two lists
  /// (previous image underneath, new image sliding over it) using [videoFc].
  List<String> _finalArgs({
    required String concatPath,
    String? prevConcatPath,
    required String audioPath,
    required String outPath,
    required bool turbo,
    required String vf,
    required int fps,
    bool vfr = false,
    String? videoFc,
  }) {
    final args = <String>['-y', '-hide_banner', '-loglevel', 'error'];
    var videoInputs = 1;
    if (prevConcatPath != null) {
      args.addAll(['-f', 'concat', '-safe', '0', '-i', prevConcatPath]);
      videoInputs = 2;
    }
    args.addAll(['-f', 'concat', '-safe', '0', '-i', concatPath]);
    args.addAll(['-i', audioPath]);
    final ai = videoInputs; // audio input index
    if (_music != null) {
      args.addAll(['-stream_loop', '-1', '-i', _music!.path!]);
    }

    final fcs = <String>[];
    if (videoFc != null) fcs.add(videoFc);
    if (_music != null) {
      final vol = _musicVol.toStringAsFixed(2);
      fcs.add('[$ai:a]aresample=44100[v1];'
          '[${ai + 1}:a]aresample=44100,volume=$vol[m1];'
          '[v1][m1]amix=inputs=2:duration=first:dropout_transition=0,volume=2[a]');
    }
    if (fcs.isNotEmpty) {
      args.addAll(['-filter_complex', fcs.join(';')]);
    }
    args.addAll([
      '-map', videoFc != null ? '[v]' : '0:v:0',
      '-map', _music != null ? '[a]' : '$ai:a:0',
    ]);

    if (turbo) {
      if (videoFc == null) args.addAll(['-vf', vf]);
      args.addAll([
        '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'stillimage',
        '-crf', '28', '-pix_fmt', 'yuv420p',
      ]);
      if (vfr) {
        args.addAll(['-fps_mode', 'vfr', '-g', '60']);
      } else {
        args.addAll(['-r', '$fps', '-g', '${fps * 10}']);
      }
    } else {
      args.addAll(['-c:v', 'copy']);
    }
    final canCopy = _music == null && _canCopyAudio(_audio!.name);
    args.addAll(canCopy ? ['-c:a', 'copy'] : ['-c:a', 'aac', '-b:a', '192k']);
    args.addAll(['-shortest', '-movflags', '+faststart', outPath]);
    return args;
  }

  Future<void> _cancel() async {
    _cancelled = true;
    setState(() => _status = 'Cancelling...');
    await FFmpegKit.cancel();
  }

  // ---------- main work ----------

  Future<void> _start() async {
    if (_audio == null || _images.isEmpty) {
      _toast('Audio aur images select karo.');
      return;
    }
    if (_timing == TimingKind.script && _script == null) {
      _toast('TXT script select karo (ya "Fixed seconds" timing chuno).');
      return;
    }
    if (_mode == ModeKind.cinematic && (_audioSec ?? 0) > 1800) {
      final ok = await _confirm(
        'Cinematic mode lambi audio (${_fmtDur(_audioSec!)}) par bahut zyada waqt le sakta hai. '
        'Turbo mode lambi videos ke liye tez hai. Phir bhi Cinematic chalana hai?',
      );
      if (!ok) return;
    }

    setState(() {
      _busy = true;
      _cancelled = false;
      _progress = 0;
      _status = 'Preparing...';
      _log = '';
      _lastP = -1;
      _lastLabel = '';
    });
    _sw
      ..reset()
      ..start();

    Directory? work;
    try {
      final turbo = _mode == ModeKind.turbo;
      final tmp = await getTemporaryDirectory();
      work = Directory('${tmp.path}/voice_sync');
      if (await work.exists()) await work.delete(recursive: true);
      await work.create(recursive: true);

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

      final audioPath = _audio!.path!;
      var duration = _audioSec ?? 0;
      if (duration <= 0) duration = await _probeDuration(audioPath);
      if (duration <= 0) throw Exception('Audio duration could not be detected.');

      final paths = _images.map((f) => f.path!).toList();
      final k = paths.length;

      // ---------- timing: which image, for how long ----------
      List<int> slotImg;
      List<double> slotDur;
      String info;
      if (_timing == TimingKind.script) {
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
        final weights = List<int>.filled(k, 0);
        for (var i = 0; i < usable.length; i++) {
          var idx = ((i / usable.length) * k).floor();
          if (idx > k - 1) idx = k - 1;
          final words = usable[i].split(RegExp(r'\s+')).length;
          weights[idx] += words < 1 ? 1 : words;
        }
        var total = 0;
        for (final wt in weights) {
          total += wt < 1 ? 1 : wt;
        }
        slotImg = List<int>.generate(k, (i) => i);
        slotDur = List<double>.generate(
          k,
          (i) => duration * (weights[i] < 1 ? 1 : weights[i]) / total,
        );
        info = 'TXT: ${text.length} chars';
      } else {
        final sec = _secPerImage;
        var m = (duration / sec).ceil();
        if (m < 1) m = 1;
        final durs = List<double>.filled(m, sec);
        final lastDur = duration - sec * (m - 1);
        durs[m - 1] = lastDur;
        if (m > 1 && lastDur < 1.0) {
          durs.removeLast();
          durs[durs.length - 1] += lastDur;
        }
        slotDur = durs;
        slotImg = _sequence(durs.length, k);
        info = '${slotDur.length} slots, ${sec.toStringAsFixed(1)}s each, '
            '$k images${k < slotDur.length ? ' (repeating)' : ''}';
      }
      final slots = slotImg.length;

      setState(() {
        _log = 'Audio: ${_fmtDur(duration)}\n$info\nSize: ${w}x$h\n'
            'Mode: ${turbo ? (_slideOn ? 'Turbo + slide' : 'Turbo (${_turboFps} fps)') : 'Cinematic'}';
      });

      final outFile = File('${work.path}/final_video.mp4');

      if (turbo) {
        // ===== TURBO: resize every image once, then ONE fast low-fps encode =====
        final fps = _turboFps;
        final frames = _framesFor(slotDur, fps, duration);

        // step 1: resize each unique image once (single ffmpeg run)
        final resizedDir = Directory('${work.path}/resized');
        await resizedDir.create(recursive: true);
        final prep = File('${work.path}/prep.txt');
        final psb = StringBuffer();
        for (final p in paths) {
          psb.writeln("file '${_cq(p)}'");
          psb.writeln('duration 0.04');
        }
        psb.writeln("file '${_cq(paths[k - 1])}'");
        await prep.writeAsString(psb.toString());

        _setProgress(0, 'Preparing $k images...');
        final prepErr = await _runFfmpeg(
          [
            '-y', '-hide_banner', '-loglevel', 'error',
            '-f', 'concat', '-safe', '0', '-i', prep.path,
            '-vf', _fit(w, h),
            '-fps_mode', 'passthrough',
            '-frames:v', '$k',
            '-q:v', '3', '-pix_fmt', 'yuvj420p',
            '${resizedDir.path}/r_%05d.jpg',
          ],
          (frame, ms) {
            _setProgress(60.0 * frame / k, 'Preparing images $frame / $k');
          },
        );
        if (_cancelled) throw Exception('Cancelled');

        var useResized = prepErr == null;
        final resizedPaths = <String>[];
        for (var i = 0; i < k; i++) {
          final rp = '${resizedDir.path}/r_${(i + 1).toString().padLeft(5, '0')}.jpg';
          resizedPaths.add(rp);
          if (useResized && !File(rp).existsSync()) useResized = false;
        }

        // step 2: concat list(s)
        final concat = File('${work.path}/concat.txt');
        String? prevPath;
        String? videoFc;
        final slide = _slideOn;

        if (!slide) {
          // plain static images on a low-fps grid
          final sb = StringBuffer();
          String lastPath = '';
          for (var s = 0; s < slots; s++) {
            final p = useResized ? resizedPaths[slotImg[s]] : paths[slotImg[s]];
            lastPath = p;
            sb.writeln("file '${_cq(p)}'");
            sb.writeln('duration ${(frames[s] / fps).toStringAsFixed(4)}');
          }
          sb.writeln("file '${_cq(lastPath)}'");
          await concat.writeAsString(sb.toString());
        } else {
          // slide: list A = new image, list B = previous image (underneath).
          // Each slot = 8 short entries (slide frames) + 1 long hold entry.
          final q = _quantSlots(slotDur, duration, 0.5);
          const int tn = 8;
          const double tdur = 0.05;
          final sbA = StringBuffer();
          final sbB = StringBuffer();
          String lastA = '';
          String lastB = '';
          for (var s = 0; s < slots; s++) {
            final cur = useResized ? resizedPaths[slotImg[s]] : paths[slotImg[s]];
            final pi = s > 0 ? slotImg[s - 1] : slotImg[0];
            final prv = useResized ? resizedPaths[pi] : paths[pi];
            final total = q[s];
            var td = tdur;
            double hold;
            if (total >= tn * tdur + 0.1) {
              hold = total - tn * tdur;
            } else {
              td = total / (tn + 1);
              hold = td;
            }
            for (var j = 0; j < tn; j++) {
              sbA.writeln("file '${_cq(cur)}'");
              sbA.writeln('duration ${td.toStringAsFixed(4)}');
              sbB.writeln("file '${_cq(prv)}'");
              sbB.writeln('duration ${td.toStringAsFixed(4)}');
            }
            sbA.writeln("file '${_cq(cur)}'");
            sbA.writeln('duration ${hold.toStringAsFixed(4)}');
            sbB.writeln("file '${_cq(prv)}'");
            sbB.writeln('duration ${hold.toStringAsFixed(4)}');
            lastA = cur;
            lastB = prv;
          }
          sbA.writeln("file '${_cq(lastA)}'");
          sbB.writeln("file '${_cq(lastB)}'");
          await concat.writeAsString(sbA.toString());
          final prevFile = File('${work.path}/concat_prev.txt');
          await prevFile.writeAsString(sbB.toString());
          prevPath = prevFile.path;

          const xExpr = "x='W*pow(max(0,1-mod(t+0.001,0.5)/0.4),2)':y=0";
          videoFc = useResized
              ? '[0:v][1:v]overlay=$xExpr,format=yuv420p[v]'
              : '[0:v]${_fit(w, h)}[bb];[1:v]${_fit(w, h)}[aa];'
                  '[bb][aa]overlay=$xExpr,format=yuv420p[v]';
        }

        // step 3: final encode (+ audio)
        _setProgress(60, 'Encoding video...');
        final totalMs = duration * 1000.0;
        final err = await _runFfmpeg(
          _finalArgs(
            concatPath: concat.path,
            prevConcatPath: prevPath,
            audioPath: audioPath,
            outPath: outFile.path,
            turbo: true,
            vf: useResized ? 'format=yuv420p' : '${_fit(w, h)},format=yuv420p',
            fps: fps,
            vfr: slide,
            videoFc: videoFc,
          ),
          (frame, ms) {
            var p = (ms / totalMs) * 100.0;
            if (p > 100) p = 100;
            if (p < 0) p = 0;
            _setProgress(60 + p * 0.4, 'Encoding video...');
          },
        );
        if (_cancelled) throw Exception('Cancelled');
        if (err != null) {
          setState(() {
            _status = 'FFmpeg error';
            _log = err;
          });
          return;
        }
      } else {
        // ===== CINEMATIC: one animated clip per slot, then join =====
        final clipDir = Directory('${work.path}/clips');
        await clipDir.create(recursive: true);
        final frames = _framesFor(slotDur, _fps, duration);
        final clipPaths = <String>[];
        for (var i = 0; i < slots; i++) {
          if (_cancelled) throw Exception('Cancelled');
          _setProgress(90.0 * i / slots, 'Image ${i + 1} / $slots ...');
          final clipPath =
              '${clipDir.path}/clip_${(i + 1).toString().padLeft(5, '0')}.mp4';
          final args = _clipArgs(
            img: paths[slotImg[i]],
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

        final concat = File('${work.path}/concat.txt');
        final sb = StringBuffer();
        for (final p in clipPaths) {
          sb.writeln("file '${_cq(p)}'");
        }
        await concat.writeAsString(sb.toString());

        _setProgress(90, 'Joining video + audio...');
        final totalMs = duration * 1000.0;
        final err = await _runFfmpeg(
          _finalArgs(
            concatPath: concat.path,
            audioPath: audioPath,
            outPath: outFile.path,
            turbo: false,
            vf: '',
            fps: _fps,
          ),
          (frame, ms) {
            var p = (ms / totalMs) * 100.0;
            if (p > 100) p = 100;
            if (p < 0) p = 0;
            _setProgress(90 + p * 0.1, 'Joining video + audio...');
          },
        );
        if (_cancelled) throw Exception('Cancelled');
        if (err != null) {
          setState(() {
            _status = 'FFmpeg error';
            _log = err;
          });
          return;
        }
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
        _status = 'DONE in ${_fmtDur(_sw.elapsed.inSeconds.toDouble())}';
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
      _sw.stop();
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

  String _infoText() {
    final d = _audioSec;
    if (d == null) return '';
    final k = _images.length;
    var s = 'Audio length: ${_fmtDur(d)}';
    if (_timing == TimingKind.fixed) {
      final need = (d / _secPerImage).ceil();
      s += '\nAt ${_secPerImage.toStringAsFixed(1)}s per image you need about $need images.';
      if (k > 0) {
        s += '\nYou selected $k';
        if (k < need) {
          s += ' → images will repeat about ${(need / k).ceil()} times.';
        } else {
          s += ' → enough, no repeat.';
        }
      }
    } else if (k > 0) {
      s += '\n$k images → about ${_fmtDur(d / k)} each (by TXT words).';
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final turbo = _mode == ModeKind.turbo;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Voice Image Sync',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('Audio + Images → MP4'),
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
                onPressed: _busy ? null : _pickImages,
                child: const Text('2. Select Images'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text('${_images.length} images selected (name order)'),
              ),
              FilledButton.tonal(
                onPressed: _busy ? null : _pickScript,
                child: Text(_timing == TimingKind.script
                    ? '3. Select TXT Script'
                    : '3. Select TXT Script (optional)'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(_script?.name ?? 'No script selected'),
              ),
            ]),

            _section('Speed mode', [
              SegmentedButton<ModeKind>(
                segments: const <ButtonSegment<ModeKind>>[
                  ButtonSegment<ModeKind>(
                      value: ModeKind.turbo, label: Text('Turbo (fast)')),
                  ButtonSegment<ModeKind>(
                      value: ModeKind.cinematic, label: Text('Cinematic')),
                ],
                selected: {_mode},
                onSelectionChanged:
                    _busy ? null : (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: 8),
              Text(
                turbo
                    ? 'Turbo: static images, low frame rate. Bohat lambi videos (ghanton) bhi jaldi banti hain. Sirf simple slide effect (neeche on/off).'
                    : 'Cinematic: zoom / pan / slide effects. Sirf chhoti videos ke liye (lambi video par bahut waqt lagta hai).',
                style: const TextStyle(fontSize: 12),
              ),
              if (turbo && _slideOn) ...[
                const SizedBox(height: 8),
                const Text('Slide ON: frame rate khud set hota hai.',
                    style: TextStyle(fontSize: 12)),
              ],
              if (turbo && !_slideOn) ...[
                const SizedBox(height: 12),
                const Text('Frame rate'),
                const SizedBox(height: 6),
                SegmentedButton<int>(
                  segments: const <ButtonSegment<int>>[
                    ButtonSegment<int>(value: 2, label: Text('2 fps (fastest)')),
                    ButtonSegment<int>(value: 5, label: Text('5 fps')),
                    ButtonSegment<int>(value: 10, label: Text('10 fps')),
                  ],
                  selected: {_turboFps},
                  onSelectionChanged:
                      _busy ? null : (s) => setState(() => _turboFps = s.first),
                ),
              ],
            ]),

            _section('Image timing', [
              SegmentedButton<TimingKind>(
                segments: const <ButtonSegment<TimingKind>>[
                  ButtonSegment<TimingKind>(
                      value: TimingKind.fixed, label: Text('Fixed seconds')),
                  ButtonSegment<TimingKind>(
                      value: TimingKind.script, label: Text('Follow TXT')),
                ],
                selected: {_timing},
                onSelectionChanged:
                    _busy ? null : (s) => setState(() => _timing = s.first),
              ),
              if (_timing == TimingKind.fixed) ...[
                const SizedBox(height: 10),
                Text('Change image every ${_secPerImage.toStringAsFixed(1)} seconds'),
                Slider(
                  value: _secPerImage,
                  min: 2,
                  max: 60,
                  divisions: 116,
                  onChanged: _busy ? null : (v) => setState(() => _secPerImage = v),
                ),
                TextButton(
                  onPressed: (_busy || _audioSec == null || _images.isEmpty)
                      ? null
                      : () {
                          final v = (_audioSec! / _images.length)
                              .clamp(2.0, 60.0)
                              .toDouble();
                          setState(() => _secPerImage = (v * 2).round() / 2);
                        },
                  child: const Text('Auto: spread my images over the whole audio'),
                ),
                const Text('When images run out'),
                const SizedBox(height: 6),
                SegmentedButton<bool>(
                  segments: const <ButtonSegment<bool>>[
                    ButtonSegment<bool>(value: false, label: Text('Repeat in order')),
                    ButtonSegment<bool>(value: true, label: Text('Shuffle')),
                  ],
                  selected: {_shuffle},
                  onSelectionChanged:
                      _busy ? null : (s) => setState(() => _shuffle = s.first),
                ),
              ],
              if (_infoText().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(_infoText(), style: const TextStyle(fontSize: 12)),
              ],
            ]),

            _section('Slide effect', [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Slide effect on every image'),
                subtitle: Text(turbo
                    ? 'Nayi image side se slide hoke purani image ke upar aati hai.'
                    : 'Har image side se slide hoke aati hai.'),
                value: _slideOn,
                onChanged: _busy ? null : (v) => setState(() => _slideOn = v),
              ),
              if (!turbo) ...[
                if (!_slideOn) ...[
                  const Text('Other effect (slide is off)'),
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
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Fade in / out between images'),
                  value: _fade,
                  onChanged: _busy ? null : (v) => setState(() => _fade = v),
                ),
              ],
            ]),

            _section('Video format', [
              const Text('Shape'),
              const SizedBox(height: 6),
              SegmentedButton<AspectKind>(
                segments: const <ButtonSegment<AspectKind>>[
                  ButtonSegment<AspectKind>(
                      value: AspectKind.wide, label: Text('16:9')),
                  ButtonSegment<AspectKind>(
                      value: AspectKind.tall, label: Text('9:16')),
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
                      value: QualityKind.fullHd, label: Text('1080p')),
                ],
                selected: {_quality},
                onSelectionChanged:
                    _busy ? null : (s) => setState(() => _quality = s.first),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Fill screen (crop) instead of black bars'),
                value: _fill,
                onChanged: _busy ? null : (v) => setState(() => _fill = v),
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
                const Text(
                  'Note: music add karne se audio dobara encode hota hai, '
                  'lambi video mein thora zyada waqt lagta hai.',
                  style: TextStyle(fontSize: 12),
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
