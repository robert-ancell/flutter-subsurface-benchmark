// Benchmark app for comparing Linux view renderers (GTK OpenGL vs Wayland
// subsurface).
//
// Runs a deterministic animation, records FrameTiming for a fixed number of
// frames after a warmup period, then prints a JSON summary and exits.
//
// Configuration (all environment variables, read at startup):
//   BENCH_SHAPES  - number of shapes drawn each frame (load knob), default 200
//   BENCH_WARMUP  - frames to discard before measuring, default 180
//   BENCH_FRAMES  - frames to measure, default 600
//   BENCH_LABEL   - free form label included in the output

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

int _envInt(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

final int kShapes = _envInt('BENCH_SHAPES', 200);
final int kWarmupFrames = _envInt('BENCH_WARMUP', 180);
final int kMeasuredFrames = _envInt('BENCH_FRAMES', 600);
final String kLabel = Platform.environment['BENCH_LABEL'] ?? 'unlabelled';
final String kRenderer =
    Platform.environment['FLUTTER_LINUX_VIEW_RENDERER'] ?? 'default';

String benchTitle(String phase) =>
    'Flutter bench - $kRenderer - $kLabel - $kShapes shapes - $phase';

final Stopwatch processClock = Stopwatch()..start();

void main() {
  // Touch the clock so it starts as early as possible, before any frames.
  processClock.elapsedMicroseconds;
  runApp(const BenchApp());
}

class BenchApp extends StatelessWidget {
  const BenchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(backgroundColor: Colors.black, body: BenchScene()),
    );
  }
}

class BenchScene extends StatefulWidget {
  const BenchScene({super.key});

  @override
  State<BenchScene> createState() => _BenchSceneState();
}

class _BenchSceneState extends State<BenchScene>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _time = ValueNotifier<double>(0);

  final List<FrameTiming> _timings = <FrameTiming>[];
  int _seenFrames = 0;
  double? _firstFrameMicros;
  bool _done = false;

  void _setTitle(String phase) {
    SystemChrome.setApplicationSwitcherDescription(
      ApplicationSwitcherDescription(label: benchTitle(phase)),
    );
  }

  @override
  void initState() {
    super.initState();
    _setTitle('warmup 0/$kWarmupFrames');
    // Drive the animation from a frame counter rather than wall time so both
    // runs draw exactly the same sequence of frames.
    _ticker = createTicker((Duration elapsed) {
      _time.value += 1 / 60;
    })..start();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    if (_done) {
      return;
    }
    if (_firstFrameMicros == null) {
      _firstFrameMicros = processClock.elapsedMicroseconds.toDouble();
      // Absolute time so the runner can measure latency from process launch,
      // which includes engine and window startup.
      stdout.writeln(
        'BENCH_FIRST_FRAME_EPOCH_US:${DateTime.now().microsecondsSinceEpoch}',
      );
    }
    for (final FrameTiming timing in timings) {
      _seenFrames++;
      if (_seenFrames <= kWarmupFrames) {
        if (_seenFrames % 30 == 0) {
          _setTitle('warmup $_seenFrames/$kWarmupFrames');
        }
        continue;
      }
      _timings.add(timing);
      if (_timings.length % 30 == 0) {
        _setTitle('measuring ${_timings.length}/$kMeasuredFrames');
      }
      if (_timings.length >= kMeasuredFrames) {
        _done = true;
        _setTitle('done');
        _report();
        return;
      }
    }
  }

  void _report() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _ticker.stop();

    double micros(Duration d) => d.inMicroseconds.toDouble();

    final List<double> build = <double>[];
    final List<double> raster = <double>[];
    final List<double> total = <double>[];
    final List<double> vsyncOverhead = <double>[];
    for (final FrameTiming t in _timings) {
      build.add(micros(t.buildDuration));
      raster.add(micros(t.rasterDuration));
      total.add(micros(t.totalSpan));
      vsyncOverhead.add(micros(t.vsyncOverhead));
    }

    // Wall clock span of the measured window, from the vsync of the first
    // measured frame to the raster finish of the last one.
    final int spanMicros =
        _timings.last.timestampInMicroseconds(ui.FramePhase.rasterFinish) -
            _timings.first.timestampInMicroseconds(ui.FramePhase.vsyncStart);
    final double fps =
        spanMicros > 0 ? (_timings.length - 1) * 1000000 / spanMicros : 0;

    final ui.FlutterView view = ui.PlatformDispatcher.instance.views.first;
    final Map<String, Object?> result = <String, Object?>{
      'label': kLabel,
      'shapes': kShapes,
      'warmup_frames': kWarmupFrames,
      'measured_frames': _timings.length,
      'first_frame_micros': _firstFrameMicros,
      'effective_fps': fps,
      'device_pixel_ratio': view.devicePixelRatio,
      'physical_size': <double>[
        view.physicalSize.width,
        view.physicalSize.height,
      ],
      'build': _summarise(build),
      'raster': _summarise(raster),
      'total_span': _summarise(total),
      'vsync_overhead': _summarise(vsyncOverhead),
      'raster_samples': raster,
      'total_span_samples': total,
    };

    stdout.writeln('BENCH_RESULT:${jsonEncode(result)}');
    stdout.flush().then((_) {
      exit(0);
    });
  }

  Map<String, double> _summarise(List<double> values) {
    final List<double> sorted = List<double>.of(values)..sort();
    double percentile(double p) {
      if (sorted.isEmpty) {
        return 0;
      }
      final int index =
          ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
      return sorted[index];
    }

    final double mean = sorted.isEmpty
        ? 0
        : sorted.reduce((double a, double b) => a + b) / sorted.length;
    double variance = 0;
    for (final double v in sorted) {
      variance += (v - mean) * (v - mean);
    }
    variance = sorted.isEmpty ? 0 : variance / sorted.length;

    return <String, double>{
      'mean': mean,
      'stddev': math.sqrt(variance),
      'p50': percentile(0.5),
      'p90': percentile(0.9),
      'p95': percentile(0.95),
      'p99': percentile(0.99),
      'min': sorted.isEmpty ? 0 : sorted.first,
      'max': sorted.isEmpty ? 0 : sorted.last,
    };
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _ShapesPainter(_time),
        size: Size.infinite,
      ),
    );
  }
}

class _ShapesPainter extends CustomPainter {
  _ShapesPainter(this.time) : super(repaint: time);

  final ValueNotifier<double> time;

  @override
  void paint(Canvas canvas, Size size) {
    final double t = time.value;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF101018));

    for (int i = 0; i < kShapes; i++) {
      final double phase = i * 0.61803398875;
      final double angle = t * 0.7 + phase * math.pi * 2;
      final double radius = 40 + (i % 17) * 12.0;
      final Offset centre = Offset(
        size.width * (0.5 + 0.35 * math.cos(angle + i * 0.013)),
        size.height * (0.5 + 0.35 * math.sin(angle * 1.3 + i * 0.017)),
      );
      final Paint paint = Paint()
        ..color = HSVColor.fromAHSV(
          0.8,
          (phase * 360 + t * 30) % 360,
          0.75,
          0.95,
        ).toColor()
        ..style = i.isEven ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = 3;

      if (i % 3 == 0) {
        canvas.drawCircle(centre, radius * 0.4, paint);
      } else if (i % 3 == 1) {
        canvas.save();
        canvas.translate(centre.dx, centre.dy);
        canvas.rotate(angle);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset.zero,
              width: radius,
              height: radius * 0.6,
            ),
            const Radius.circular(8),
          ),
          paint,
        );
        canvas.restore();
      } else {
        final Path path = Path()
          ..moveTo(centre.dx, centre.dy - radius * 0.35)
          ..lineTo(centre.dx + radius * 0.35, centre.dy + radius * 0.3)
          ..lineTo(centre.dx - radius * 0.35, centre.dy + radius * 0.3)
          ..close();
        canvas.drawPath(path, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ShapesPainter oldDelegate) => true;
}
