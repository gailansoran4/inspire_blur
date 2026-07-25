import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_shaders/flutter_shaders.dart';
import 'package:inspire_blur/src/color_adjustment/blur_color_adjustment.dart';
import 'package:inspire_blur/src/inspire_shaders.dart';
import 'package:inspire_blur/src/transform/blur_transform.dart';
import 'package:inspire_blur/src/utils/extensions/inspire_geometry_extensions.dart';

class InspireChildBlurAnimatedSamplerPass extends StatefulWidget {
  final ui.Image gradientMap;
  final BlurTransform transform;
  final BlurColorAdjustment colorAdjustment;
  final Axis direction;
  final double sigma;
  final Widget child;

  const InspireChildBlurAnimatedSamplerPass({
    super.key,
    required this.gradientMap,
    required this.transform,
    required this.colorAdjustment,
    required this.direction,
    required this.sigma,
    required this.child,
  });

  @override
  State<InspireChildBlurAnimatedSamplerPass> createState() =>
      _InspireChildBlurAnimatedSamplerPassState();
}

class _InspireChildBlurAnimatedSamplerPassState
    extends State<InspireChildBlurAnimatedSamplerPass> {
  ui.FragmentShader? _shader;
  final ui.Paint _paint = ui.Paint();

  double _dpr = 1.0;

  // AnimatedSampler re-captures the child into a texture whenever its
  // builder callback identity changes. Keeping a stable closure — replaced
  // only when the effect parameters actually change — prevents expensive
  // re-renders caused by unrelated ancestor rebuilds.
  AnimatedSamplerBuilder? _draw;

  @override
  void initState() {
    super.initState();
    _loadShader();
  }

  void _loadShader() {
    InspireShaders.childBlur.then((program) {
      final shader = program?.fragmentShader();
      if (mounted) {
        setState(() {
          _shader = shader;
          _invalidateDraw();
        });
      } else {
        _shader = shader;
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final newDpr = MediaQuery.devicePixelRatioOf(context);
    if (newDpr != _dpr) {
      _dpr = newDpr;
      _invalidateDraw();
    }
  }

  @override
  void didUpdateWidget(covariant InspireChildBlurAnimatedSamplerPass old) {
    super.didUpdateWidget(old);

    if (old.gradientMap != widget.gradientMap ||
        old.transform != widget.transform ||
        old.colorAdjustment != widget.colorAdjustment ||
        old.direction != widget.direction ||
        old.sigma != widget.sigma) {
      _invalidateDraw();
    }
  }

  void _invalidateDraw() {
    _draw = (image, size, canvas) => _onDraw(image, size, canvas);
  }

  void _onDraw(ui.Image image, Size size, ui.Canvas canvas) {
    final shader = _shader!;

    final normalizedOrigin = widget.transform.origin.toNormalizedOffset();

    shader
      ..setImageSampler(0, image)
      ..setImageSampler(1, widget.gradientMap)
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      // To ensure 1:1 effective blur strength with ImageFilter.shader
      // when using same sigma values — divide sigma by dpr.
      ..setFloat(2, widget.sigma / _dpr)
      ..setFloat(3, widget.direction == Axis.horizontal ? 1.0 : 0.0)
      ..setFloat(4, widget.direction == Axis.vertical ? 1.0 : 0.0)
      ..setFloat(5, 0.0)
      ..setFloat(6, 0.0)
      ..setFloat(7, 0.0)
      ..setFloat(8, 0.0)
      ..setFloat(9, widget.transform.scale.scaleX)
      ..setFloat(10, widget.transform.scale.scaleY)
      ..setFloat(11, widget.transform.offset.dx)
      ..setFloat(12, widget.transform.offset.dy)
      ..setFloat(13, widget.transform.rotation)
      ..setFloat(14, normalizedOrigin.dx)
      ..setFloat(15, normalizedOrigin.dy)
      ..setFloat(16, widget.transform.inversionFactor)
      ..setFloat(17, widget.colorAdjustment.shaderBrightness)
      ..setFloat(18, widget.colorAdjustment.shaderContrast)
      ..setFloat(19, widget.colorAdjustment.shaderExposure)
      ..setFloat(20, widget.colorAdjustment.shaderSaturation)
      ..setFloat(21, widget.colorAdjustment.shaderVibrance)
      ..setFloat(22, widget.colorAdjustment.blurAdjustmentStrength)
      ..setFloat(23, widget.colorAdjustment.nonBlurAdjustmentStrength);

    _paint.shader = shader;
    canvas.drawRect(Offset.zero & size, _paint);
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final draw = _draw;
    if (_shader == null || draw == null) return widget.child;

    return AnimatedSampler(
      draw,
      child: widget.child,
    );
  }
}
