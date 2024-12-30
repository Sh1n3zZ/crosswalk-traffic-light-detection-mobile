import 'dart:typed_data';
import 'package:image/image.dart' as img;

Future<Uint8List> processImage(Uint8List imageBytes) async {
  try {
    final img.Image? originalImage = img.decodeImage(imageBytes);
    if (originalImage == null) {
      throw Exception('无法解码图像');
    }

    // 更激进的降低分辨率
    final resizedImage = img.copyResize(
      originalImage,
      width: 240, // 进一步降低分辨率
      height: (240 * originalImage.height / originalImage.width).round(),
      interpolation: img.Interpolation.nearest, // 使用最快的插值方法
    );

    return Uint8List.fromList(img.encodeJpg(
      resizedImage,
      quality: 50, // 进一步降低质量
    ));
  } catch (e) {
    print('图像处理错误: $e');
    rethrow;
  }
}
