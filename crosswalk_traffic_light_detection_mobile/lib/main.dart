import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:ui';
import 'dart:io';
import 'traffic_light_detector.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:convert';
import 'dart:async';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  CameraController? _camera;
  late TrafficLightDetector _detector;
  String _status = '准备就绪';
  bool _isProcessing = false;
  bool _isVideoStreamMode = false;
  WebSocketChannel? _channel;

  // 音频播放器
  final AudioPlayer _redLightPlayer = AudioPlayer();
  final AudioPlayer _greenLightPlayer = AudioPlayer();
  final AudioPlayer _noLightPlayer = AudioPlayer();
  bool _isAudioReady = false;

  // 添加动画控制器和颜色状态
  late AnimationController _glowController;
  Color _glowColor = Colors.transparent;
  Timer? _glowTimer;
  Timer? _vibrationTimer;

  // 添加语音播报控制变量
  DateTime? _lastSpeakTime;
  static const Duration _minSpeakInterval =
      Duration(seconds: 30); // 设置最小播报间隔为30秒

  @override
  void initState() {
    super.initState();
    ambiguate(WidgetsBinding.instance)!.addObserver(this);
    _glowController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _detector = TrafficLightDetector();

    // 使用异步初始化
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      await _checkPermissions();
      await _initAudioPlayers();
      await _initCamera();
      if (mounted) {
        await _initializeWebSocketMode();
      }
    } catch (e) {
      print('初始化错误: $e');
      if (mounted) {
        _showErrorSnackBar('应用初始化失败，请重启应用');
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // 当应用进入后台时释放音频资源
      _redLightPlayer.stop();
      _greenLightPlayer.stop();
      _noLightPlayer.stop();
    }
  }

  Future<void> _checkPermissions() async {
    // 检查所有需要的权限状态
    final cameraStatus = await Permission.camera.status;
    final microphoneStatus = await Permission.microphone.status;
    final storageStatus = await Permission.storage.status;

    print('权限状态检查:');
    print('相机权限: ${cameraStatus.toString()}');
    print('麦克风权限: ${microphoneStatus.toString()}');
    print('存储权限: ${storageStatus.toString()}');

    // 如果权限未授予，请求权限
    if (!cameraStatus.isGranted) {
      final cameraResult = await Permission.camera.request();
      print('相机权限请求结果: ${cameraResult.toString()}');
    }
    if (!microphoneStatus.isGranted) {
      final microphoneResult = await Permission.microphone.request();
      print('麦克风权限请求结果: ${microphoneResult.toString()}');
    }
    if (!storageStatus.isGranted) {
      final storageResult = await Permission.storage.request();
      print('存储权限请求结果: ${storageResult.toString()}');
    }
  }

  Future<void> _initAudioPlayers() async {
    int retryCount = 0;
    const maxRetries = 3;

    Future<void> initAudio() async {
      try {
        // 确保已获取音频权限
        final permission = await Permission.microphone.request();
        if (!permission.isGranted) {
          print('未获得音频权限，尝试重新请求');
          throw Exception('音频权限未授予');
        }

        // 配置音频会话
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            usage: AndroidAudioUsage.assistanceAccessibility,
          ),
        ));

        // 设置错误监听
        void handleError(String player, Object e, StackTrace? stackTrace) {
          print('$player 播放错误: $e');
        }

        _redLightPlayer.playbackEventStream.listen(
          (event) {},
          onError: (Object e, StackTrace stackTrace) =>
              handleError('红灯语音', e, stackTrace),
        );

        _greenLightPlayer.playbackEventStream.listen(
          (event) {},
          onError: (Object e, StackTrace stackTrace) =>
              handleError('绿灯语音', e, stackTrace),
        );

        _noLightPlayer.playbackEventStream.listen(
          (event) {},
          onError: (Object e, StackTrace stackTrace) =>
              handleError('无信号灯语音', e, stackTrace),
        );

        // 使用 wav 格式的音频文件
        await Future.wait([
          _redLightPlayer.setAsset(
              'assets/audio/_tmp_gradio_572c5ad306024f103a35cfad0d01a1184f754836_audio.wav'),
          _greenLightPlayer.setAsset(
              'assets/audio/_tmp_gradio_3456314a2eb57f79a178bec1cadfcb5bd36662f1_audio.wav'),
          _noLightPlayer.setAsset(
              'assets/audio/_tmp_gradio_bc1ffe32d82d3dee94c1043942b8adf60af00b4e_audio.wav'),
        ]);

        // 设置音量
        await Future.wait([
          _redLightPlayer.setVolume(1.0),
          _greenLightPlayer.setVolume(1.0),
          _noLightPlayer.setVolume(1.0),
        ]);

        _isAudioReady = true;
        print('音频初始化成功');
      } catch (e) {
        print('音频初始化失败: $e');
        _isAudioReady = false;

        if (retryCount < maxRetries) {
          retryCount++;
          print('尝试重新初始化音频系统 (第 $retryCount 次)');
          await Future.delayed(Duration(seconds: 2));
          await initAudio();
        } else {
          print('音频初始化失败次数过多，请检查设备权限和音频设置');
          if (mounted) {
            _showErrorSnackBar('音频系统初始化失败，部分功能可能无法使用');
          }
        }
      }
    }

    await initAudio();
  }

  Future<void> _speakResult(String text) async {
    if (!_isAudioReady) {
      print('音频系统未就绪，尝试重新初始化');
      await _initAudioPlayers();
      if (!_isAudioReady) {
        print('重新初始化失败，无法播放音频');
        return;
      }
    }

    try {
      // 停止所有正在播放的音频
      await Future.wait([
        _redLightPlayer.stop(),
        _greenLightPlayer.stop(),
        _noLightPlayer.stop(),
      ]);

      // 播放对应的音频
      switch (text) {
        case '红灯':
          await _redLightPlayer.seek(Duration.zero);
          await _redLightPlayer.play();
          break;
        case '绿灯':
          await _greenLightPlayer.seek(Duration.zero);
          await _greenLightPlayer.play();
          break;
        case '未检测到信号灯':
          await _noLightPlayer.seek(Duration.zero);
          await _noLightPlayer.play();
          break;
      }
    } catch (e) {
      print('音频播放错误: $e');
      // 如果播放出错，标记音频系统为未就绪，下次将重新初始化
      _isAudioReady = false;
    }
  }

  Future<void> _initializeWebSocketMode() async {
    await Future.delayed(Duration(seconds: 1));
    if (!mounted) return;

    try {
      await _initWebSocket();
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

      await _channel!.ready.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException('WebSocket连接超时');
        },
      );

      // 启动定时发送图像的定时器
      Timer.periodic(const Duration(milliseconds: 500), (timer) async {
        if (!_isVideoStreamMode) {
          timer.cancel();
          return;
        }

        if (_camera != null && _camera!.value.isInitialized) {
          try {
            final XFile image = await _camera!.takePicture();
            final bytes = await image.readAsBytes();

            // 压缩图片
            final img = await decodeImageFromList(bytes);
            final resizedImg = await FlutterImageCompress.compressWithList(
              bytes,
              minHeight: 480, // 设置最小高度
              minWidth: 640, // 设置最小宽度
              quality: 80, // 设置压缩质量
              rotate: 0, // 不旋转
            );

            _channel!.sink.add(resizedImg);
          } catch (e) {
            print('拍照或发送失败: $e');
          }
        }
      });

      _channel!.stream.listen(
        (message) {
          if (message is String) {
            final Map<String, dynamic> jsonResponse = json.decode(message);
            if (mounted && jsonResponse['code'] == 200) {
              final data = jsonResponse['data'];
              setState(() {
                final now = DateTime.now();
                final shouldSpeak = _lastSpeakTime == null ||
                    now.difference(_lastSpeakTime!) >= _minSpeakInterval;

                switch (data['result']) {
                  case '0':
                    _status = '检测到${data['status']}';
                    if (shouldSpeak) {
                      _speakResult('红灯');
                      _lastSpeakTime = now;
                    }
                    _showGlowEffect(Colors.red);
                    break;
                  case '1':
                    _status = '检测到${data['status']}';
                    if (shouldSpeak) {
                      _speakResult('绿灯');
                      _lastSpeakTime = now;
                    }
                    _showGlowEffect(Colors.green);
                    break;
                  case '2':
                    _status = data['status'];
                    if (shouldSpeak) {
                      _speakResult('未检测到信号灯');
                      _lastSpeakTime = now;
                    }
                    _showGlowEffect(Colors.transparent);
                    break;
                }
              });
            } else {
              print('服务器响应错误: ${jsonResponse['message']}');
            }
          }
        },
        onDone: () {
          print('WebSocket连接已关闭');
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
        });
        _showErrorSnackBar('连接服务器失败，已切换到单张识别模式');
      }
      rethrow;
    }
  }

  Future<void> _initCamera() async {
    final permission = await Permission.camera.request();
    if (!permission.isGranted) {
      setState(() => _status = '需要相机权限');
      return;
    }

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      setState(() => _status = '没有可用的相机');
      return;
    }

    // 使用较低的分辨率和更高效的图像格式
    _camera = CameraController(
      cameras[0],
      ResolutionPreset.medium, // 降低分辨率，从 veryHigh 改为 medium
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.jpeg
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _camera!.initialize();
      if (mounted) {
        setState(() {});
      }
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
      _detector = TrafficLightDetector();

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

  Future<void> _toggleMode() async {
    if (!_isVideoStreamMode) {
      setState(() {
        _isVideoStreamMode = true;
      });

      try {
        await _initWebSocket();
      } catch (e) {
        print('切换到连续识别模式失败: $e');
        setState(() {
          _isVideoStreamMode = false;
        });
        _showErrorSnackBar('连接服务器失败，已切换到单张识别模式');
      }
    } else {
      setState(() {
        _isVideoStreamMode = false;
      });
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

  // 添加震动控制方法
  Future<void> _startVibration(bool isGreen) async {
    // 停止之前的震动
    _stopVibration();

    try {
      // 检查设备是否支持震动
      final hasVibrator = await Vibration.hasVibrator() ?? false;
      print('设备是否支持震动: $hasVibrator');
      if (!hasVibrator) {
        print('设备不支持震动，无法使用震动功能');
        return;
      }

      // 检查设备是否支持自定义震动强度
      final hasAmplitudeControl =
          await Vibration.hasCustomVibrationsSupport() ?? false;
      print('设备是否支持自定义震动强度: $hasAmplitudeControl');

      // 检查设备是否支持自定义震动频率
      final hasPattern = await Vibration.hasVibrator() ?? false;
      print('设备是否支持自定义震动模式: $hasPattern');

      // 尝试一个简单的震动测试
      print('执行震动测试...');
      await Vibration.vibrate(duration: 200);
      print('震动测试完成');

      if (isGreen) {
        print('开始绿灯快速震动模式');
        // 绿灯：快速震动（200ms间隔）
        _vibrationTimer =
            Timer.periodic(const Duration(milliseconds: 200), (timer) async {
          try {
            await Vibration.vibrate(
              duration: 100,
              amplitude: hasAmplitudeControl ? 128 : -1,
            );
            print('绿灯震动执行完成');
          } catch (e) {
            print('绿灯震动执行错误: $e');
          }
        });
      } else {
        print('开始红灯慢速震动模式');
        // 红灯：慢速震动（1000ms间隔）
        _vibrationTimer =
            Timer.periodic(const Duration(milliseconds: 1000), (timer) async {
          try {
            await Vibration.vibrate(
              duration: 500,
              amplitude: hasAmplitudeControl ? 255 : -1,
            );
            print('红灯震动执行完成');
          } catch (e) {
            print('红灯震动执行错误: $e');
          }
        });
      }
    } catch (e) {
      print('震动控制错误: $e');
    }
  }

  void _stopVibration() {
    print('停止震动');
    _vibrationTimer?.cancel();
    Vibration.cancel();
  }

  // 修改显示效果的方法
  void _showGlowEffect(Color color) {
    setState(() {
      _glowColor = color;
    });

    // 取消之前的定时器（如果存在）
    _glowTimer?.cancel();

    // 根据颜色开始相应的震动
    if (color == Colors.red) {
      print('检测到红灯，开始红灯震动模式');
      _startVibration(false);
    } else if (color == Colors.green) {
      print('检测到绿灯，开始绿灯震动模式');
      _startVibration(true);
    } else {
      print('未检测到信号灯，停止震动');
      _stopVibration();
    }

    // 设置新的定时器，3秒后恢复透明
    _glowTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _glowColor = Colors.transparent;
        });
        _stopVibration();
      }
    });
  }

  @override
  void dispose() {
    ambiguate(WidgetsBinding.instance)!.removeObserver(this);
    _redLightPlayer.dispose();
    _greenLightPlayer.dispose();
    _noLightPlayer.dispose();
    _glowController.dispose();
    _glowTimer?.cancel();
    _stopVibration();
    _vibrationTimer?.cancel();
    _camera?.dispose();
    _detector.dispose();
    _channel?.sink.close();
    _lastSpeakTime = null;
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
    // 获取屏幕方向
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
      // 使用 OrientationBuilder 来处理屏幕旋转
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
            // 主要内容布局
            isLandscape ? _buildLandscapeLayout() : _buildPortraitLayout(),
          ],
        ),
      ),
    );
  }

  // 将横屏布局抽取为单独的方法
  Widget _buildLandscapeLayout() {
    return Row(
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
                    onPressed: _isProcessing ? null : _detectTrafficLight,
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
                _isVideoStreamMode ? '正在连续识别中...' : '将手机对准红绿灯，点击按钮开始识别',
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
    );
  }

  // 将竖屏布局抽取为单独的方法
  Widget _buildPortraitLayout() {
    return Column(
      children: [
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
                    onPressed: _isProcessing ? null : _detectTrafficLight,
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
                _isVideoStreamMode ? '正在连续识别中...' : '将手机对准红绿灯，点击按钮开始识别',
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
    );
  }
}

// 添加ambiguate函数
T? ambiguate<T>(T? value) => value;
