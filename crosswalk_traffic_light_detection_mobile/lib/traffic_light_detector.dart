import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:flutter_tts/flutter_tts.dart';
import 'dart:convert';

enum TrafficLightStatus {
  red,
  green,
  none,
}

class TrafficLightDetector {
  static const String serverUrl = 'http://175.178.245.188:27015/detect';
  FlutterTts? _flutterTts;
  final bool useChinese;

  TrafficLightDetector({this.useChinese = true});

  Future<void> initTts() async {
    try {
      _flutterTts = FlutterTts();

      if (useChinese) {
        await _flutterTts?.setLanguage('zh-CN');
        await _flutterTts?.setSpeechRate(0.8);
      } else {
        await _flutterTts?.setLanguage('en-US');
        await _flutterTts?.setSpeechRate(0.5);
      }
      await _flutterTts?.setVolume(1.0);
      await _flutterTts?.setPitch(1.0);
    } catch (e) {
      print('TTS 初始化错误: $e');
      _flutterTts = null;
    }
  }

  Future<File> _resizeImage(File imageFile) async {
    try {
      // 读取图像文件
      final Uint8List imageBytes = await imageFile.readAsBytes();
      final img.Image? originalImage = img.decodeImage(imageBytes);

      if (originalImage == null) {
        throw Exception('无法解码图像');
      }

      // 使用原始图片所在的目录
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final File processedFile =
          File('${imageFile.parent.path}/processed_$timestamp.jpg');

      // 保存图片，仅压缩质量
      await processedFile
          .writeAsBytes(img.encodeJpg(originalImage, quality: 90));

      return processedFile;
    } catch (e) {
      print('图像处理错误: $e');
      rethrow;
    }
  }

  Future<TrafficLightStatus> detectTrafficLight(File imageFile) async {
    File? resizedFile;
    try {
      // 调整图像大小
      resizedFile = await _resizeImage(imageFile);

      // 创建 multipart 请求
      final request = http.MultipartRequest('POST', Uri.parse(serverUrl));
      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          resizedFile.path,
        ),
      );

      // 发送请求并等待响应
      final response = await request.send();
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
              await _speakResult(TrafficLightStatus.green);
              return TrafficLightStatus.green;
            case '0':
              await _speakResult(TrafficLightStatus.red);
              return TrafficLightStatus.red;
            default:
              await _speakResult(TrafficLightStatus.none);
              return TrafficLightStatus.none;
          }
        } else {
          throw Exception('服务器响应格式错误');
        }
      } else if (response.statusCode == 422) {
        throw Exception('请求参数错误');
      } else {
        throw Exception('服务器响应错误: ${response.statusCode}');
      }
    } catch (e) {
      print('检测过程出错: $e');
      rethrow;
    } finally {
      // 清理临时文件
      try {
        if (resizedFile != null && await resizedFile.exists()) {
          await resizedFile.delete();
        }
      } catch (e) {
        print('清理临时文件错误: $e');
      }
    }
  }

  Future<void> _speakResult(TrafficLightStatus status) async {
    if (_flutterTts == null) {
      print('TTS 未初始化');
      return;
    }

    try {
      String text;
      switch (status) {
        case TrafficLightStatus.red:
          text = useChinese ? '红灯' : 'Light is red';
          break;
        case TrafficLightStatus.green:
          text = useChinese ? '绿灯' : 'Light is green';
          break;
        case TrafficLightStatus.none:
          text = useChinese ? '没有检测到信号灯' : 'No light detected';
          break;
      }
      await _flutterTts?.speak(text);
    } catch (e) {
      print('语音播报错误: $e');
    }
  }

  void dispose() {
    try {
      _flutterTts?.stop();
      _flutterTts = null;
    } catch (e) {
      print('TTS 停止错误: $e');
    }
  }
}
