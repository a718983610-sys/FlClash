import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';
import 'package:zxing2/zxing2.dart';

/// mobile_scanner has no Windows implementation: the camera view and the
/// platform image analysis both throw there. On Windows the supported path
/// is picking an image file and decoding it in pure Dart (zxing2).
bool qfCameraScanSupported() => !Platform.isWindows;

/// Pure decode step over an ARGB pixel buffer (unit-testable without I/O).
String? qfDecodeQrPixels(int width, int height, Int32List argbPixels) {
  try {
    final source = RGBLuminanceSource(width, height, argbPixels);
    final bitmap = BinaryBitmap(HybridBinarizer(source));
    return QRCodeReader().decode(bitmap).text;
  } catch (_) {
    try {
      final source = RGBLuminanceSource(width, height, argbPixels);
      final bitmap = BinaryBitmap(HybridBinarizer(source));
      final hints = DecodeHints()..put(DecodeHintType.tryHarder);
      return QRCodeReader().decode(bitmap, hints: hints).text;
    } catch (_) {
      return null;
    }
  }
}

/// Decodes the first QR code found in an image file's bytes; returns null
/// when the image cannot be read or holds no QR code. Never throws.
String? qfDecodeQrImageBytes(Uint8List bytes) {
  try {
    var image = img.decodeImage(bytes);
    if (image == null) return null;
    const maxDimension = 1600;
    if (image.width > maxDimension || image.height > maxDimension) {
      image = image.width >= image.height
          ? img.copyResize(image, width: maxDimension)
          : img.copyResize(image, height: maxDimension);
    }
    final pixels = Int32List(image.width * image.height);
    var i = 0;
    for (final pixel in image) {
      pixels[i++] =
          (pixel.a.toInt() << 24) |
          (pixel.r.toInt() << 16) |
          (pixel.g.toInt() << 8) |
          pixel.b.toInt();
    }
    return qfDecodeQrPixels(image.width, image.height, pixels);
  } catch (_) {
    return null;
  }
}
