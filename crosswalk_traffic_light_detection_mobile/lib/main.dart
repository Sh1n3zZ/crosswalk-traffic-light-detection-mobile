import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:ui';
import 'dart:io';
import 'traffic_light_detector.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:convert';
import 'dart:async';
import 'image_processor.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '红绿灯识别助手',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2C3E50),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          elevation: 0,
          centerTitle: true,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  CameraController? _camera;
  late TrafficLightDetector _detector;
  String _status = '准备就绪';
  bool _isProcessing = false;
  bool _isLeftRotation = false;
  bool _isVideoStreamMode = true;
  WebSocketChannel? _channel;
  Timer? _frameCaptureTimer;
  FlutterTts? _flutterTts;

  // 添加动画控制器和颜色状态
  late AnimationController _glowController;
  Color _glowColor = Colors.transparent;
  Timer? _glowTimer;

  @override
  void initState() {
    super.initState();
    _initTts();
    _detector = TrafficLightDetector();
    _initCamera();
    _initGyroscope();

    // 初始化动画控制器
    _glowController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _glowController.repeat(reverse: true);

    // 尝试初始化WebSocket连接
    _initializeWebSocketMode();
  }

  Future<void> _initTts() async {
    try {
      _flutterTts = FlutterTts();

      // 检查TTS引擎是否可用
      final available =
          await _flutterTts?.isLanguageAvailable("zh-CN") ?? false;
      print('TTS引擎是否可用: $available');

      if (!available) {
        print('TTS引擎不支持中文');
        return;
      }

      // 获取可用的语音引擎
      final engines = await _flutterTts?.getEngines;
      print('可用的语音引擎: $engines');

      // 设置TTS参数
      await _flutterTts?.setLanguage('zh-CN');
      await _flutterTts?.setSpeechRate(0.8);
      await _flutterTts?.setVolume(1.0);
      await _flutterTts?.setPitch(1.0);
      await _flutterTts?.awaitSpeakCompletion(true);

      // 设置TTS状态回调
      _flutterTts?.setStartHandler(() {
        print("TTS开始播放");
      });

      _flutterTts?.setCompletionHandler(() {
        print("TTS播放完成");
      });

      _flutterTts?.setErrorHandler((msg) {
        print("TTS错误: $msg");
      });

      // 测试TTS是否正常工作
      print('开始测试TTS...');
      final result = await _flutterTts?.speak('语音系统已就绪');
      print('TTS测试结果: $result');
    } catch (e) {
      print('TTS 初始化错误: $e');
      _flutterTts = null;
    }
  }

  Future<void> _speakResult(String text) async {
    try {
      if (_flutterTts == null) {
        print('TTS未初始化，重新初始化中...');
        await _initTts();
      }

      if (_flutterTts != null) {
        print('正在播放语音: $text');
        // 先停止之前的语音
        await _flutterTts?.stop();

        // 播放新的语音
        final result = await _flutterTts?.speak(text);
        print('语音播放结果: $result');
      } else {
        print('TTS仍然未初始化');
      }
    } catch (e) {
      print('语音播报错误: $e');
    }
  }

  Future<void> _initializeWebSocketMode() async {
    await Future.delayed(Duration(seconds: 1));
    if (!mounted) return;

    try {
      await _initWebSocket();
      if (_isVideoStreamMode) {
        _startFrameCapture();
      }
    } catch (e) {
      print('初始化错误: $e');
      if (mounted) {
        setState(() {
          _isVideoStreamMode = false;
        });
        _showErrorSnackBar('连接服务器失败，已切换到单张识别模式');
      }
    }
  }

  Future<void> _initWebSocket() async {
    try {
      _channel = WebSocketChannel.connect(
          Uri.parse('ws://175.178.245.188:27015/ws/video-stream'));

      // 等待连接建立
      await _channel!.ready;

      _channel!.stream.listen(
        (message) {
          // 处理来自服务器的消息
          final Map<String, dynamic> jsonResponse = json.decode(message);
          if (mounted) {
            setState(() {
              switch (jsonResponse['data']['result']) {
                case '0':
                  _status = '检测到红灯';
                  _speakResult('红灯');
                  _showGlowEffect(Colors.red);
                  break;
                case '1':
                  _status = '检测到绿灯';
                  _speakResult('绿灯');
                  _showGlowEffect(Colors.green);
                  break;
                default:
                  _status = '未检测到信号灯';
                  _speakResult('未检测到信号灯');
                  _showGlowEffect(Colors.transparent);
                  break;
              }
            });
          }
        },
        onDone: () {
          // 连接关闭时尝试重连
          if (_isVideoStreamMode && mounted) {
            Future.delayed(Duration(seconds: 5), () {
              _initializeWebSocketMode();
            });
          }
        },
        onError: (error) {
          print('WebSocket 错误: $error');
          if (mounted) {
            setState(() {
              _isVideoStreamMode = false;
              _stopFrameCapture();
            });
            _showErrorSnackBar('连接服务器失败，已切换到单张识别模式');
          }
        },
      );
    } catch (e) {
      print('WebSocket 初始化错误: $e');
      if (mounted) {
        setState(() {
          _isVideoStreamMode = false;
          _stopFrameCapture();
        });
        _showErrorSnackBar('连接服务器失败，已切换到单张识别模式');
      }
      rethrow;
    }
  }

  void _initGyroscope() {
    gyroscopeEvents.listen((GyroscopeEvent event) {
      setState(() {
        _isLeftRotation = event.y < -0.5;
      });
    });
  }

  Future<void> _initCamera() async {
    // 请求相机权限
    final permission = await Permission.camera.request();
    if (!permission.isGranted) {
      setState(() => _status = '需要相机权限');
      return;
    }

    // 获取相机列表
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      setState(() => _status = '没有可用的相机');
      return;
    }

    // 初始化相机
    _camera = CameraController(cameras[0], ResolutionPreset.medium);
    try {
      await _camera!.initialize();
      setState(() {});
    } catch (e) {
      setState(() => _status = '相机初始化失败');
    }
  }

  Future<void> _detectTrafficLight() async {
    if (_isProcessing || _camera == null || !_camera!.value.isInitialized) {
      return;
    }

    setState(() {
      _isProcessing = true;
      _status = '正在识别...';
    });

    try {
      // 获取当前方向
      final isLandscape =
          MediaQuery.of(context).orientation == Orientation.landscape;
      // 更新检测器
      _detector = TrafficLightDetector(
          isLandscape: isLandscape, isLeftRotation: _isLeftRotation);

      // 拍照
      final image = await _camera!.takePicture();
      // 检测
      final result = await _detector.detectTrafficLight(File(image.path));

      if (!mounted) return;

      // 更新状态
      setState(() {
        _isProcessing = false;
        switch (result) {
          case TrafficLightStatus.red:
            _status = '检测到红灯';
            _speakResult('红灯');
            _showGlowEffect(Colors.red);
            break;
          case TrafficLightStatus.green:
            _status = '检测到绿灯';
            _speakResult('绿灯');
            _showGlowEffect(Colors.green);
            break;
          case TrafficLightStatus.none:
            _status = '未检测到信号灯';
            _speakResult('未检测到信号灯');
            _showGlowEffect(Colors.transparent);
            break;
        }
      });
    } catch (e) {
      print('识别错误: $e');
      if (!mounted) return;

      setState(() {
        _isProcessing = false;
        _status = '识别失败';
      });

      _showErrorSnackBar('识别失败，请重试');
    }
  }

  void _startFrameCapture() {
    _frameCaptureTimer =
        Timer.periodic(Duration(milliseconds: 100), (timer) async {
      if (_camera != null && _camera!.value.isInitialized && !_isProcessing) {
        setState(() {
          _isProcessing = true;
        });
        final image = await _camera!.takePicture();
        final bytes = await image.readAsBytes();
        final isLandscape =
            MediaQuery.of(context).orientation == Orientation.landscape;
        final processedBytes =
            await processImageOrientation(bytes, isLandscape, _isLeftRotation);
        final base64Image = base64Encode(processedBytes);
        if (_channel != null && _channel!.sink != null && _isVideoStreamMode) {
          _channel!.sink.add(json.encode({'image': base64Image}));
        }
        setState(() {
          _isProcessing = false;
        });
      }
    });
  }

  void _stopFrameCapture() {
    _frameCaptureTimer?.cancel();
  }

  Future<void> _toggleMode() async {
    if (!_isVideoStreamMode) {
      // 从单张拍摄切换到连续识别
      setState(() {
        _isVideoStreamMode = true;
      });

      try {
        await _initWebSocket();
        _startFrameCapture();
      } catch (e) {
        print('切换到连续识别模式失败: $e');
        setState(() {
          _isVideoStreamMode = false;
        });
        _showErrorSnackBar('连接服务器失败，已切换到单张识别模式');
      }
    } else {
      // 从连续识别切换到单张拍摄
      setState(() {
        _isVideoStreamMode = false;
      });
      _stopFrameCapture();
      _channel?.sink.close();
    }
  }

  void _showErrorSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  // 添加处理霓虹光效果的方法
  void _showGlowEffect(Color color) {
    setState(() {
      _glowColor = color;
    });

    // 取消之前的定时器（如果存在）
    _glowTimer?.cancel();

    // 设置新的定时器，3秒后恢复透明
    _glowTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _glowColor = Colors.transparent;
        });
      }
    });
  }

  @override
  void dispose() {
    _glowController.dispose();
    _glowTimer?.cancel();
    _stopFrameCapture();
    _camera?.dispose();
    _detector.dispose();
    _channel?.sink.close();
    _flutterTts?.stop();
    super.dispose();
  }

  Widget _buildCameraPreview() {
    if (_camera == null || !_camera!.value.isInitialized) {
      return Container(
        color: Colors.grey[900],
        child: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: CameraPreview(_camera!),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 0,
      ),
      body: SafeArea(
        child: Stack(
          children: [
            // 背景相机预览
            if (_camera?.value.isInitialized ?? false)
              Positioned.fill(
                child: CameraPreview(_camera!),
              ),
            // 霓虹光效果
            if (_glowColor != Colors.transparent)
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _glowController,
                  builder: (context, child) {
                    return Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: _glowColor.withOpacity(
                            0.3 + 0.7 * _glowController.value,
                          ),
                          width: 20,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: _glowColor.withOpacity(
                              0.2 + 0.3 * _glowController.value,
                            ),
                            blurRadius: 30,
                            spreadRadius: 10,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            // 主要内容
            isLandscape
                ? Row(
                    children: [
                      // 相机预览区域
                      Expanded(
                        flex: 2,
                        child: Stack(
                          children: [
                            // 虚化背景
                            if (_camera?.value.isInitialized ?? false)
                              Positioned.fill(
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(
                                    sigmaX: 10.0,
                                    sigmaY: 10.0,
                                  ),
                                  child: Container(
                                    color: Colors.transparent,
                                  ),
                                ),
                              ),
                            // 清晰的预览窗口
                            Container(
                              margin: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: _glowColor != Colors.transparent
                                      ? _glowColor.withOpacity(0.5)
                                      : Colors.white30,
                                  width: 2,
                                ),
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: _glowColor != Colors.transparent
                                    ? [
                                        BoxShadow(
                                          color: _glowColor.withOpacity(0.3),
                                          blurRadius: 20,
                                          spreadRadius: 5,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: _buildCameraPreview(),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 状态和控制区域
                      Container(
                        width: MediaQuery.of(context).size.width * 0.35,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.horizontal(
                            left: Radius.circular(32),
                          ),
                        ),
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 16,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.grey[100],
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: _isProcessing
                                          ? Colors.orange
                                          : _glowColor != Colors.transparent
                                              ? _glowColor
                                              : Colors.green,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      _status,
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: ElevatedButton(
                                onPressed: _toggleMode,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF2C3E50),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  elevation: 0,
                                ),
                                child: Text(
                                  _isVideoStreamMode ? '切换到单张拍摄' : '切换到连续识别',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),
                            if (!_isVideoStreamMode)
                              SizedBox(
                                width: double.infinity,
                                height: 56,
                                child: ElevatedButton(
                                  onPressed: _isProcessing
                                      ? null
                                      : _detectTrafficLight,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF2C3E50),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    elevation: 0,
                                  ),
                                  child: Text(
                                    _isProcessing ? '识别中...' : '开始识别',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            if (!_isVideoStreamMode) const SizedBox(height: 16),
                            Text(
                              _isVideoStreamMode
                                  ? '正在连续识别中...'
                                  : '将手机对准红绿灯，点击按钮开始识别',
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 14,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      // 竖屏布局保持不变
                      Expanded(
                        flex: 3,
                        child: Stack(
                          children: [
                            if (_camera?.value.isInitialized ?? false)
                              Positioned.fill(
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(
                                    sigmaX: 10.0,
                                    sigmaY: 10.0,
                                  ),
                                  child: Container(
                                    color: Colors.transparent,
                                  ),
                                ),
                              ),
                            Container(
                              margin: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: _glowColor != Colors.transparent
                                      ? _glowColor.withOpacity(0.5)
                                      : Colors.white30,
                                  width: 2,
                                ),
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: _glowColor != Colors.transparent
                                    ? [
                                        BoxShadow(
                                          color: _glowColor.withOpacity(0.3),
                                          blurRadius: 20,
                                          spreadRadius: 5,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: _buildCameraPreview(),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(32),
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 16,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.grey[100],
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: _isProcessing
                                          ? Colors.orange
                                          : _glowColor != Colors.transparent
                                              ? _glowColor
                                              : Colors.green,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      _status,
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: ElevatedButton(
                                onPressed: _toggleMode,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF2C3E50),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  elevation: 0,
                                ),
                                child: Text(
                                  _isVideoStreamMode ? '切换到单张拍摄' : '切换到连续识别',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),
                            if (!_isVideoStreamMode)
                              SizedBox(
                                width: double.infinity,
                                height: 56,
                                child: ElevatedButton(
                                  onPressed: _isProcessing
                                      ? null
                                      : _detectTrafficLight,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF2C3E50),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    elevation: 0,
                                  ),
                                  child: Text(
                                    _isProcessing ? '识别中...' : '开始识别',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            if (!_isVideoStreamMode) const SizedBox(height: 16),
                            Text(
                              _isVideoStreamMode
                                  ? '正在连续识别中...'
                                  : '将手机对准红绿灯，点击按钮开始识别',
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 14,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ],
        ),
      ),
    );
  }
}
