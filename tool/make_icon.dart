// Generates the FitSize launcher-icon source images with package:image.
//
// Run from the project root:
//   dart run tool/make_icon.dart
// then
//   dart run flutter_launcher_icons
//
// Outputs (all 1024x1024 PNG, written to assets/icon/):
//   icon.png             full-bleed teal square + white mark (iOS; the OS
//                        applies its own corner mask)
//   icon_android.png     same mark on a rounded teal square with transparent
//                        corners (legacy Android launcher icon)
//   icon_foreground.png  the white mark alone on a transparent canvas
//                        (Android adaptive-icon foreground + monochrome)
//
// The mark is an "F" whose top arm is a tape-measure strip: a white band
// with teal tick marks (every fifth tick taller), which is the app's
// measuring-tape motif. Everything is drawn at 2x and downsampled with cubic
// interpolation so edges come out anti-aliased.

import 'dart:io';

import 'package:image/image.dart' as img;

/// Final icon edge length in pixels.
const int outSize = 1024;

/// Supersampling factor; drawing happens on an [outSize] * [ss] canvas.
const int ss = 2;

// Brand palette (matches lib/theme/app_theme.dart).
final img.Color tealTop = img.ColorRgba8(0x18, 0x7F, 0x6C, 0xFF);
final img.Color tealBottom = img.ColorRgba8(0x07, 0x4A, 0x3E, 0xFF);
final img.Color tealTick = img.ColorRgba8(0x0E, 0x6B, 0x5B, 0xFF);
final img.Color white = img.ColorRgba8(0xFF, 0xFF, 0xFF, 0xFF);
final img.Color transparent = img.ColorRgba8(0, 0, 0, 0);

int s(num v) => (v * ss).round();

void main() {
  final outDir = Directory('assets/icon');
  outDir.createSync(recursive: true);

  final full = _canvas();
  _paintBackground(full, cornerRadius: 0);
  _paintMark(full);
  _save(full, 'assets/icon/icon.png');

  final rounded = _canvas();
  _paintBackground(rounded, cornerRadius: s(228));
  _paintMark(rounded);
  _save(rounded, 'assets/icon/icon_android.png');

  final foreground = _canvas();
  _paintMark(foreground);
  _save(foreground, 'assets/icon/icon_foreground.png');

  stdout.writeln('Wrote 3 icon images to ${outDir.path}/');
}

img.Image _canvas() {
  final c = img.Image(
    width: outSize * ss,
    height: outSize * ss,
    numChannels: 4,
  );
  img.fill(c, color: transparent);
  return c;
}

/// Teal square with a soft top-left to bottom-right gradient. A corner
/// radius of 0 gives a full-bleed square.
void _paintBackground(img.Image c, {required int cornerRadius}) {
  final w = c.width, h = c.height;
  final size = (w + h).toDouble();

  // Gradient first (whole canvas), then punch the corners out when rounded.
  for (final p in c) {
    final t = (p.x + p.y) / size; // 0 at top-left, 1 at bottom-right
    final r = tealTop.r + (tealBottom.r - tealTop.r) * t;
    final g = tealTop.g + (tealBottom.g - tealTop.g) * t;
    final b = tealTop.b + (tealBottom.b - tealTop.b) * t;
    p
      ..r = r.round()
      ..g = g.round()
      ..b = b.round()
      ..a = 255;
  }

  if (cornerRadius > 0) {
    // Build an alpha mask: opaque rounded rect on transparent.
    final mask = img.Image(width: w, height: h, numChannels: 4);
    img.fill(mask, color: transparent);
    img.fillRect(
      mask,
      x1: 0,
      y1: 0,
      x2: w - 1,
      y2: h - 1,
      color: white,
      radius: cornerRadius,
    );
    for (final p in c) {
      final m = mask.getPixel(p.x, p.y).a;
      if (m < 255) p.a = m;
    }
  }

  // A faint lighter disc behind the mark for depth.
  final glow = img.Image(width: w, height: h, numChannels: 4);
  img.fill(glow, color: transparent);
  img.fillCircle(
    glow,
    x: s(512),
    y: s(500),
    radius: s(360),
    color: img.ColorRgba8(0xFF, 0xFF, 0xFF, 0x16),
    antialias: true,
  );
  img.compositeImage(c, glow);
}

/// The white "F" whose top arm is a tape-measure strip.
void _paintMark(img.Image c) {
  // Geometry in 1024-space; s() scales to the supersampled canvas.
  const stemL = 286.0, stemR = 406.0; // vertical stem, 120 wide
  const stemT = 262.0, stemB = 790.0;
  const topT = 262.0, topB = 382.0, topR = 772.0; // tape strip, 120 tall
  const midT = 476.0, midB = 576.0, midR = 640.0; // middle arm, 100 tall
  const radius = 26.0;

  // Stem.
  img.fillRect(
    c,
    x1: s(stemL),
    y1: s(stemT),
    x2: s(stemR),
    y2: s(stemB),
    color: white,
    radius: s(radius),
  );
  // Middle arm.
  img.fillRect(
    c,
    x1: s(stemL),
    y1: s(midT),
    x2: s(midR),
    y2: s(midB),
    color: white,
    radius: s(radius),
  );
  // Top arm: the tape strip.
  img.fillRect(
    c,
    x1: s(stemL),
    y1: s(topT),
    x2: s(topR),
    y2: s(topB),
    color: white,
    radius: s(radius),
  );
  // Square off the inner joints so the three bars read as one letter.
  img.fillRect(
    c,
    x1: s(stemL),
    y1: s(topT + radius),
    x2: s(stemR),
    y2: s(stemB - radius),
    color: white,
  );
  img.fillRect(
    c,
    x1: s(stemL + radius),
    y1: s(topT),
    x2: s(stemR + radius),
    y2: s(topB),
    color: white,
  );
  img.fillRect(
    c,
    x1: s(stemL + radius),
    y1: s(midT),
    x2: s(stemR + radius),
    y2: s(midB),
    color: white,
  );

  // Tick marks along the tape strip, hanging from its top edge: every fifth
  // tick is tall, like the centimetre marks on a tailor's tape.
  const tickStart = stemR + 34.0;
  const tickStep = 32.0;
  const tickW = 9.0;
  var i = 0;
  for (var x = tickStart; x <= topR - 30; x += tickStep, i++) {
    final tall = i % 5 == 0;
    final len = tall ? 58.0 : (i % 5 == 2 ? 40.0 : 28.0);
    img.fillRect(
      c,
      x1: s(x - tickW / 2),
      y1: s(topT),
      x2: s(x + tickW / 2),
      y2: s(topT + len),
      color: tealTick,
      radius: s(3),
    );
  }
}

void _save(img.Image hi, String path) {
  final lo = img.copyResize(
    hi,
    width: outSize,
    height: outSize,
    interpolation: img.Interpolation.cubic,
  );
  File(path).writeAsBytesSync(img.encodePng(lo));
  stdout.writeln('  $path');
}
