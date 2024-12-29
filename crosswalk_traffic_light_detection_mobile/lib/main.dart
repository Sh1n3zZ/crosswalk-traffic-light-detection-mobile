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

class _HomePageState extends State<HomePage> {
  CameraController? _camera;
  late TrafficLightDetector _detector;
  String _status = '准备就绪';
  bool _isProcessing = false;
  bool _isLeftRotation = false;
  bool _isVideoStreamMode = true;
  WebSocketChannel? _channel;
  Timer? _frameCaptureTimer;

  @override
  void initState() {
    super.initState();
    _detector = TrafficLightDetector();
    _initCamera();
    _initGyroscope();
    // 尝试初始化WebSocket连接
    _initializeWebSocketMode();
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
                  break;
                case '1':
                  _status = '检测到绿灯';
                  break;
                default:
                  _status = '未检测到信号灯';
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
      // 更新状态
      setState(() {
        _isProcessing = false;
        switch (result) {
          case TrafficLightStatus.red:
            _status = '检测到红灯';
            break;
          case TrafficLightStatus.green:
            _status = '检测到绿灯';
            break;
          case TrafficLightStatus.none:
            _status = '未检测到信号灯';
            break;
        }
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _status = '识别失败';
      });
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

  @override
  void dispose() {
    _stopFrameCapture();
    _camera?.dispose();
    _detector.dispose();
    _channel?.sink.close();
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
                                      sigmaX: 10.0, sigmaY: 10.0),
                                  child: Container(
                                    color: Colors.black.withOpacity(0.1),
                                  ),
                                ),
                              ),
                            // 清晰的预览窗口
                            Container(
                              margin: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                border:
                                    Border.all(color: Colors.white30, width: 2),
                                borderRadius: BorderRadius.circular(12),
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
                                      sigmaX: 10.0, sigmaY: 10.0),
                                  child: Container(
                                    color: Colors.black.withOpacity(0.1),
                                  ),
                                ),
                              ),
                            Container(
                              margin: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                border:
                                    Border.all(color: Colors.white30, width: 2),
                                borderRadius: BorderRadius.circular(12),
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
