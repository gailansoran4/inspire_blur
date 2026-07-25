import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Benchmarks the optimized blur shader against the pre-optimization
/// (legacy) version kept in `test/shaders/inspire_blur_child_legacy.frag`.
///
/// Both shaders are rasterized on the CPU by the test environment, executing
/// the exact same per-pixel program a GPU would run. The measured speedup is
/// therefore a good proxy for the relative GPU cost per blur pass.
///
/// Run with: flutter test test/blur_shader_benchmark_test.dart
void main() {
  const width = 390;
  const height = 600;
  const sigma = 25.0;

  const warmupIterations = 2;
  const measuredIterations = 8;

  Future<ui.Image> rasterize(ui.FragmentShader shader) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..shader = shader,
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();

    // Force rasterization to complete so the Stopwatch measures real work.
    final byteData = await image.toByteData();
    expect(byteData, isNotNull);

    return image;
  }

  Future<Duration> benchmark(ui.FragmentShader shader) async {
    for (var i = 0; i < warmupIterations; i++) {
      (await rasterize(shader)).dispose();
    }

    final stopwatch = Stopwatch()..start();
    for (var i = 0; i < measuredIterations; i++) {
      (await rasterize(shader)).dispose();
    }
    stopwatch.stop();

    return stopwatch.elapsed ~/ measuredIterations;
  }

  /// Draws a busy multi-color scene, so the blur has real content to sample.
  Future<ui.Image> createContentImage() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final random = math.Random(42);

    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF223344),
    );

    for (var i = 0; i < 200; i++) {
      canvas.drawCircle(
        ui.Offset(
          random.nextDouble() * width,
          random.nextDouble() * height,
        ),
        4.0 + random.nextDouble() * 40.0,
        ui.Paint()
          ..color = ui.Color.fromARGB(
            255,
            random.nextInt(256),
            random.nextInt(256),
            random.nextInt(256),
          ),
      );
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    return image;
  }

  /// Bottom-to-top gradient map: white (full blur) at the bottom,
  /// black (no blur) at the top — mirrors InspireBlurConfig.bottomToTop.
  Future<ui.Image> createGradientMap() async {
    const size = 256;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      ui.Paint()
        ..shader = ui.Gradient.linear(
          const ui.Offset(0, 0),
          ui.Offset(0, size.toDouble()),
          const [ui.Color(0xFF000000), ui.Color(0xFFFFFFFF)],
        ),
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(size, size);
    picture.dispose();
    return image;
  }

  /// Full-blur map (all white) — the worst case, every pixel at max sigma.
  Future<ui.Image> createUniformMap() async {
    const size = 8;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(size, size);
    picture.dispose();
    return image;
  }

  void configureShader(
    ui.FragmentShader shader, {
    required ui.Image content,
    required ui.Image gradientMap,
    required Axis direction,
  }) {
    shader
      ..setImageSampler(0, content)
      ..setImageSampler(1, gradientMap)
      ..setFloat(0, width.toDouble())
      ..setFloat(1, height.toDouble())
      ..setFloat(2, sigma)
      ..setFloat(3, direction == Axis.horizontal ? 1.0 : 0.0)
      ..setFloat(4, direction == Axis.vertical ? 1.0 : 0.0)
      // Screen position deltas — fully on-screen.
      ..setFloat(5, 0.0)
      ..setFloat(6, 0.0)
      ..setFloat(7, 0.0)
      ..setFloat(8, 0.0)
      // Identity transform.
      ..setFloat(9, 1.0)
      ..setFloat(10, 1.0)
      ..setFloat(11, 0.0)
      ..setFloat(12, 0.0)
      ..setFloat(13, 0.0)
      ..setFloat(14, 0.5)
      ..setFloat(15, 0.5)
      ..setFloat(16, 0.0)
      // Neutral color adjustment.
      ..setFloat(17, 0.0)
      ..setFloat(18, 1.0)
      ..setFloat(19, 0.0)
      ..setFloat(20, 1.0)
      ..setFloat(21, 0.0)
      ..setFloat(22, 0.0)
      ..setFloat(23, 0.0);
  }

  testWidgets('optimized blur shader is faster than the legacy one',
      (tester) async {
    await tester.runAsync(() async {
      final currentProgram = await ui.FragmentProgram.fromAsset(
        'shaders/inspire_blur_child.frag',
      );
      final legacyProgram = await ui.FragmentProgram.fromAsset(
        'test/shaders/inspire_blur_child_legacy.frag',
      );

      final content = await createContentImage();
      final gradientMap = await createGradientMap();
      final uniformMap = await createUniformMap();

      final scenarios = <String, ui.Image>{
        'bottomToTop gradient (sigma $sigma)': gradientMap,
        'uniform full blur (sigma $sigma)': uniformMap,
      };

      for (final MapEntry(key: name, value: map) in scenarios.entries) {
        var totalLegacyMicros = 0;
        var totalCurrentMicros = 0;

        // A blur render is two passes (horizontal + vertical), benchmark both.
        for (final direction in Axis.values) {
          final legacyShader = legacyProgram.fragmentShader();
          final currentShader = currentProgram.fragmentShader();

          configureShader(
            legacyShader,
            content: content,
            gradientMap: map,
            direction: direction,
          );
          configureShader(
            currentShader,
            content: content,
            gradientMap: map,
            direction: direction,
          );

          totalLegacyMicros += (await benchmark(legacyShader)).inMicroseconds;
          totalCurrentMicros +=
              (await benchmark(currentShader)).inMicroseconds;

          legacyShader.dispose();
          currentShader.dispose();
        }

        final speedup = totalLegacyMicros / totalCurrentMicros;

        debugPrint(
          '[$name] '
          'legacy: ${(totalLegacyMicros / 1000).toStringAsFixed(1)} ms/frame, '
          'optimized: '
          '${(totalCurrentMicros / 1000).toStringAsFixed(1)} ms/frame, '
          'speedup: ${speedup.toStringAsFixed(2)}x '
          '(${width}x$height, both blur passes)',
        );

        // The optimized shader must be meaningfully faster. The theoretical
        // reduction at sigma 25 is ~4x fewer texture reads; 1.5x is a
        // conservative floor that tolerates CI timing noise.
        expect(
          speedup,
          greaterThan(1.5),
          reason: 'Optimized shader should be significantly faster '
              'than the legacy one for "$name"',
        );
      }

      content.dispose();
      gradientMap.dispose();
      uniformMap.dispose();
    });
  });
}
