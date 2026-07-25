import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inspire_blur/src/distribution/blur_distribution.dart';
import 'package:inspire_blur/src/distribution/blur_distribution_map.dart';
import 'package:inspire_blur/src/distribution/maps/directional_distribution_map.dart';

void main() {
  const size = 256;

  DirectionalDistribution directional({
    required Alignment begin,
    required Alignment end,
  }) =>
      DirectionalDistribution(
        begin: begin,
        end: end,
        stops: [0.0, 0.5, 1.0],
        values: [0.0, 0.8, 1.0],
      );

  group('axis-aligned directional maps collapse the constant axis', () {
    test('vertical gradient uses a 1-texel-wide map', () {
      final map = directional(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
      ).toDistributionMap(size: size);

      expect(map.width, 1);
      expect(map.height, size);
    });

    test('horizontal gradient uses a 1-texel-tall map', () {
      final map = directional(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).toDistributionMap(size: size);

      expect(map.width, size);
      expect(map.height, 1);
    });

    test('diagonal gradient keeps the full-size map', () {
      final map = directional(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).toDistributionMap(size: size);

      expect(map.width, size);
      expect(map.height, size);
    });
  });

  group('collapsed maps produce identical intensities', () {
    test('vertical gradient matches full-size map along the y axis', () {
      final distribution = directional(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
      );

      final thin = distribution.toDistributionMap(size: size)
          as DirectionalDistributionMap;

      final full = DirectionalDistributionMap(
        width: size,
        height: size,
        begin: distribution.begin,
        end: distribution.end,
        values: distribution.values,
        stops: distribution.stops,
      );

      for (var y = 0; y < size; y++) {
        final v = y / (size - 1);

        // The thin map is sampled at u=0; the full map varies along u —
        // both must agree everywhere.
        for (final u in [0.0, 0.25, 0.5, 0.75, 1.0]) {
          expect(
            thin.intensityAt(0.0, v),
            moreOrLessEquals(full.intensityAt(u, v), epsilon: 1e-9),
            reason: 'Mismatch at u=$u, v=$v',
          );
        }
      }
    });

    test('horizontal gradient matches full-size map along the x axis', () {
      final distribution = directional(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      );

      final thin = distribution.toDistributionMap(size: size)
          as DirectionalDistributionMap;

      final full = DirectionalDistributionMap(
        width: size,
        height: size,
        begin: distribution.begin,
        end: distribution.end,
        values: distribution.values,
        stops: distribution.stops,
      );

      for (var x = 0; x < size; x++) {
        final u = x / (size - 1);

        for (final v in [0.0, 0.25, 0.5, 0.75, 1.0]) {
          expect(
            thin.intensityAt(u, 0.0),
            moreOrLessEquals(full.intensityAt(u, v), epsilon: 1e-9),
            reason: 'Mismatch at u=$u, v=$v',
          );
        }
      }
    });
  });

  test('collapsed map generates a valid image', () async {
    final map = directional(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
    ).toDistributionMap(size: size);

    final image = await map.getBlurDistributionImage();

    expect(image.image.width, 1);
    expect(image.image.height, size);

    image.dispose();
  });
}
