// main.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:camera/camera.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:sensors_plus/sensors_plus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1️⃣ Request runtime permissions
  final camStatus = await Permission.camera.request();
  final micStatus = await Permission.microphone.request();

  // 2️⃣ Check both granted
  if (camStatus.isGranted && micStatus.isGranted) {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      runApp(MyApp(camera: back));
    } catch (e) {
      runApp(const PermissionErrorApp());
    }
  } else {
    runApp(const PermissionErrorApp());
  }
}

class PermissionErrorApp extends StatelessWidget {
  const PermissionErrorApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'Camera & microphone permissions are required.\n'
            'Please enable them in Settings.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18),
          ),
        ),
      ),
    ),
  );
}

class MyApp extends StatelessWidget {
  final CameraDescription camera;
  const MyApp({super.key, required this.camera});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'AR Data Streamer',
    theme: ThemeData(primarySwatch: Colors.blue),
    home: StreamingScreen(camera: camera),
  );
}

class StreamingScreen extends StatefulWidget {
  final CameraDescription camera;
  const StreamingScreen({super.key, required this.camera});
  @override
  State<StreamingScreen> createState() => _StreamingScreenState();
}

class _StreamingScreenState extends State<StreamingScreen> {
  CameraController? _controller;
  Future<void>? _initFuture;
  WebSocketChannel? _channel;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  Timer? _frameTimer;
  final _ipCtrl = TextEditingController();
  bool _streaming = false, _camError = false;
  String _status = 'Disconnected';
  GyroscopeEvent _gyro = GyroscopeEvent(0, 0, 0, DateTime.now());

  @override
  void initState() {
    super.initState();
    _initCamera();
    _gyroSub = gyroscopeEvents.listen((e) {
      if (mounted) setState(() => _gyro = e);
    });
  }

  void _initCamera() {
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.medium,
      enableAudio: true,
    );
    _initFuture = _controller!.initialize().catchError((e) {
      if (e is CameraException) setState(() => _camError = true);
    });
    setState(() {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    _gyroSub?.cancel();
    _frameTimer?.cancel();
    _channel?.sink.close();
    _ipCtrl.dispose();
    super.dispose();
  }

  void _toggleStream() {
    if (_controller == null || _camError) return;
    if (_streaming) {
      _frameTimer?.cancel();
      _channel?.sink.close();
      setState(() {
        _streaming = false;
        _status = 'Disconnected';
      });
    } else {
      final ip = _ipCtrl.text.trim();
      if (ip.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Enter server IP')));
        return;
      }
      final url = 'ws://$ip:8765';
      setState(() => _status = 'Connecting to $url …');
      try {
        _channel = WebSocketChannel.connect(Uri.parse(url));
        setState(() {
          _streaming = true;
          _status = 'Connected & streaming';
        });
        _frameTimer = Timer.periodic(
          const Duration(milliseconds: 66),
          (_) => _send(),
        );
      } catch (e) {
        setState(() => _status = 'Connection failed: $e');
      }
    }
  }

  Future<void> _send() async {
    if (!_streaming || _controller == null || !_controller!.value.isInitialized)
      return;
    try {
      final pic = await _controller!.takePicture();
      final bytes = await pic.readAsBytes();
      final img64 = base64Encode(bytes);
      final data = {
        'frame': img64,
        'gyro': {'x': _gyro.x, 'y': _gyro.y, 'z': _gyro.z},
      };
      _channel?.sink.add(jsonEncode(data));
    } catch (e) {
      debugPrint('Send error: $e');
    }
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('AR Data Streamer')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Expanded(child: _buildPreview()),
          const SizedBox(height: 16),
          TextField(
            controller: _ipCtrl,
            decoration: const InputDecoration(
              labelText: 'Server IP (e.g. 192.168.1.100)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            enabled: !_streaming,
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  Text(
                    _status,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Gyro → X:${_gyro.x.toStringAsFixed(2)}, '
                    'Y:${_gyro.y.toStringAsFixed(2)}, '
                    'Z:${_gyro.z.toStringAsFixed(2)}',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _camError ? null : _toggleStream,
            style: ElevatedButton.styleFrom(
              backgroundColor: _streaming ? Colors.redAccent : Colors.green,
              padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 20),
              textStyle: const TextStyle(fontSize: 18),
            ),
            child: Text(_streaming ? 'Stop Streaming' : 'Start Streaming'),
          ),
        ],
      ),
    ),
  );

  Widget _buildPreview() {
    if (_camError) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.videocam_off, size: 64, color: Colors.red),
            SizedBox(height: 16),
            Text(
              'Camera access denied.\nEnable in Settings.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18),
            ),
          ],
        ),
      );
    }
    return FutureBuilder<void>(
      future: _initFuture,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.done) {
          return Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: _streaming ? Colors.green : Colors.red,
                width: 3,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: CameraPreview(_controller!),
            ),
          );
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }
}
