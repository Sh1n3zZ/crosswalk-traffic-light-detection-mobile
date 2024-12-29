import 'dart:typed_data';
import 'package:image/image.dart' as img;

Future<Uint8List> processImageOrientation(
    Uint8List imageBytes, bool isLandscape, bool isLeftRotation) async {
  final img.Image? originalImage = img.decodeImage(imageBytes);

  if (originalImage == null) {
    throw Exception('无法解码图像');
  }

  img.Image processedImage = originalImage;
  if (isLandscape) {
    if (isLeftRotation) {
      // 向左旋转
      processedImage = img.copyRotate(originalImage, angle: -90);
    } else {
      // 向右旋转
      processedImage = img.copyRotate(originalImage, angle: 90);
    }
  }

  return Uint8List.fromList(img.encodeJpg(processedImage, quality: 90));
}
