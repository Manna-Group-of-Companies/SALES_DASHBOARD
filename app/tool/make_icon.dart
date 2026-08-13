// Builds the square source images the launcher icon is generated from.
//
// The Manna lockup is roughly twice as wide as it is tall. An app icon is
// square, and every icon generator resizes its source to a square — which
// would squash the wordmark. So the logo is composited onto a square canvas
// here, at its true aspect ratio, and the generator is handed something that
// is already the right shape.
//
// Two outputs, because Android wants two things:
//
//   app_icon.png            full-bleed, white behind the logo. Used for the
//                           legacy icon and for iOS, which has no transparency.
//   app_icon_foreground.png transparent, logo smaller. Android 8+ adaptive
//                           icons crop the foreground to a circle, squircle or
//                           whatever the launcher fancies, and only the middle
//                           ~66% is guaranteed to survive. Anything drawn
//                           outside that safe zone can be cut off.
//
// Run with: dart run tool/make_icon.dart

import 'dart:io';

import 'package:image/image.dart';

/// How much of the canvas width the logo takes up.
///
/// The full-bleed icon can go close to the edge; the adaptive foreground has
/// to stay inside the safe zone or a round launcher will shave the ends off
/// the wordmark.
const double _fullBleedWidthFraction = 0.88;
const double _adaptiveWidthFraction = 0.60;

const int _canvas = 1024;

void main() {
  final src = decodePng(File('assets/manna_logo.png').readAsBytesSync());
  if (src == null) {
    stderr.writeln('Could not read assets/manna_logo.png');
    exit(1);
  }
  stdout.writeln('source: ${src.width}x${src.height}');

  // The supplied file carries a wide white margin, and the artwork is not
  // centred inside it. Scaling that as-is gives a small logo sitting low and
  // to the right of the icon. Trimming to the ink first means the padding
  // below is the padding we actually chose.
  final art = _trimWhitespace(src);
  stdout.writeln('trimmed: ${art.width}x${art.height}');

  _write('assets/icon/app_icon.png', art, _fullBleedWidthFraction,
      background: ColorRgba8(255, 255, 255, 255));
  _write('assets/icon/app_icon_foreground.png', art, _adaptiveWidthFraction,
      background: ColorRgba8(0, 0, 0, 0));
}

/// Crops away the near-white (or fully transparent) border around the artwork.
Image _trimWhitespace(Image src) {
  var top = src.height, left = src.width, right = -1, bottom = -1;
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      final p = src.getPixel(x, y);
      // Anti-aliased edges sit just off pure white, so the threshold is a
      // little below it; a hard == 255 test would leave a grey halo.
      final isInk = p.a > 16 && !(p.r > 245 && p.g > 245 && p.b > 245);
      if (!isInk) continue;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }
  }
  if (right < left || bottom < top) return src; // nothing found; leave it be
  return copyCrop(src,
      x: left, y: top, width: right - left + 1, height: bottom - top + 1);
}

void _write(String path, Image src, double widthFraction,
    {required Color background}) {
  final target = (_canvas * widthFraction).round();
  // Scaled by width and left to find its own height, so the logo keeps its
  // proportions rather than being stretched into the square.
  final scaled = copyResize(src,
      width: target, interpolation: Interpolation.cubic);

  final canvas = Image(width: _canvas, height: _canvas, numChannels: 4)
    ..clear(background);
  compositeImage(canvas, scaled,
      dstX: (_canvas - scaled.width) ~/ 2,
      dstY: (_canvas - scaled.height) ~/ 2);

  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(encodePng(canvas));
  stdout.writeln('wrote $path  (${scaled.width}x${scaled.height} on $_canvas)');
}
