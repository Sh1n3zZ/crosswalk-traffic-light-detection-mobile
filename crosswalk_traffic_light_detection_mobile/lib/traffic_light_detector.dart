import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:flutter/services.dart';
import 'image_processor.dart';

enum TrafficLightStatus {
  red,
  green,
  none,
}

class TrafficLightDetector {
  static const String serverUrl = 'http://175.178.245.188:27015/detect';

  TrafficLightDetector();

  Future<TrafficLightStatus> detectTrafficLight(File imageFile) async {
    File? processedFile;
    try {
      // 读取图像文件
      final Uint8List imageBytes = await imageFile.readAsBytes();

      // 使用简化的图像处理
      final Uint8List processedBytes = await processImage(imageBytes);

      // 使用原始图片所在的目录
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final File processedFile =
          File('${imageFile.parent.path}/processed_$timestamp.jpg');

      // 保存处理后的图片
      await processedFile.writeAsBytes(processedBytes);

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
        final Map<String, dynamic> jsonResponse = json.decode(result);

        if (jsonResponse['code'] == 200 && jsonResponse['data'] != null) {
          final String result = jsonResponse['data']['result'] ?? '2';

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
