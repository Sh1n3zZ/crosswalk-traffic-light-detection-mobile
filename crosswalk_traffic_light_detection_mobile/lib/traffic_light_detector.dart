import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'dart:convert';
import 'dart:async';
import 'package:flutter/services.dart';

enum TrafficLightStatus {
  red,
  green,
  none,
}

class TrafficLightDetector {
  static const String serverUrl = 'https://cr.rakuyou.uk/detect';
  final bool isLandscape;
  final bool isLeftRotation;

  TrafficLightDetector({
    this.isLandscape = false,
    this.isLeftRotation = false,
  });

  Future<File> _processImage(File imageFile) async {
    try {
      // 读取图像文件
      final Uint8List imageBytes = await imageFile.readAsBytes();
      final img.Image? originalImage = img.decodeImage(imageBytes);

      if (originalImage == null) {
        throw Exception('无法解码图像');
      }

      // 根据设备方向处理图片
      img.Image processedImage = originalImage;
      if (isLandscape) {
        // 如果是横屏，根据旋转方向调整图片
        processedImage =
            img.copyRotate(originalImage, angle: isLeftRotation ? 90 : 270);
      }

      // 使用原始图片所在的目录
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final File processedFile =
          File('${imageFile.parent.path}/processed_$timestamp.jpg');

      // 保存图片，仅压缩质量
      await processedFile
          .writeAsBytes(img.encodeJpg(processedImage, quality: 90));

      return processedFile;
    } catch (e) {
      print('图像处理错误: $e');
      rethrow;
    }
  }

  Future<TrafficLightStatus> detectTrafficLight(File imageFile) async {
    File? processedFile;
    try {
      // 处理图像
      processedFile = await _processImage(imageFile);

      // 创建 multipart 请求
      final request = http.MultipartRequest('POST', Uri.parse(serverUrl));
      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          processedFile.path,
        ),
      );

      // 设置超时时间为10秒
      final response = await request.send().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('请求超时');
        },
      );

      final String result = await response.stream.bytesToString();
      print('服务器返回结果: $result');

      if (response.statusCode == 200) {
        // 解析 JSON 响应
        final Map<String, dynamic> jsonResponse = json.decode(result);

        if (jsonResponse['code'] == 200 && jsonResponse['data'] != null) {
          final String result = jsonResponse['data']['result'] ?? '2';

          // 解析响应
          switch (result) {
            case '1':
              return TrafficLightStatus.green;
            case '0':
              return TrafficLightStatus.red;
            default:
              return TrafficLightStatus.none;
          }
        } else {
          print('服务器响应格式错误: $jsonResponse');
          throw Exception('服务器响应格式错误');
        }
      } else {
        print('服务器响应错误状态码: ${response.statusCode}');
        throw Exception('服务器响应错误: ${response.statusCode}');
      }
    } catch (e) {
      print('检测过程出错: $e');
      rethrow;
    } finally {
      // 清理临时文件
      try {
        if (processedFile != null && await processedFile.exists()) {
          await processedFile.delete();
        }
      } catch (e) {
        print('清理临时文件错误: $e');
      }
    }
  }

  void dispose() {}
}
