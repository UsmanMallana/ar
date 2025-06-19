// main.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:camera/camera.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:sensors_plus/sensors_plus.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'AR Data Streamer',
    theme: ThemeData(primarySwatch: Colors.blue),
    home: const StreamingScreen(),
  );
}

class StreamingScreen extends StatefulWidget {
  const StreamingScreen({super.key});
  @override
  State<StreamingScreen> createState() => _StreamingScreenState();
}

class _StreamingScreenState extends State<StreamingScreen> {
  List<CameraDescription>? _cameras;
  CameraController? _controller;
  Future<void>? _initFuture;

  WebSocketChannel? _channel;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  Timer? _frameTimer;

  final _ipCtrl = TextEditingController();
  bool _streaming = false, _camError = false, _hasCamPermission = false;
  String _status = 'Disconnected';
  GyroscopeEvent _gyro = GyroscopeEvent(0, 0, 0, DateTime.now());

  @override
  void initState() {
    super.initState();
    // load available cameras (no permission needed)
    availableCameras()
        .then((list) {
          setState(() => _cameras = list);
        })
        .catchError((_) {
          // if no camera found
          setState(() => _camError = true);
        });

    // listen gyro always
    _gyroSub = gyroscopeEvents.listen((e) {
      if (mounted) setState(() => _gyro = e);
    });
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

  Future<void> _onCameraButtonPressed() async {
    // ask only for camera
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Camera permission denied')));
      return;
    }

    if (_hasCamPermission) return;
    setState(() => _hasCamPermission = true);

    // initialize controller with back camera
    final back = _cameras?.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => _cameras!.first,
    );
    if (back == null) {
      setState(() => _camError = true);
      return;
    }

    _controller = CameraController(
      back,
      ResolutionPreset.medium,
      enableAudio: false, // no mic
    );
    _initFuture = _controller!.initialize().catchError((e) {
      setState(() => _camError = true);
    });

    setState(() {});
  }

  void _toggleStream() {
    if (!_hasCamPermission || _camError || _controller == null) return;

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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter the server IP')),
        );
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
          (_) => _sendFrame(),
        );
      } catch (e) {
        setState(() => _status = 'Connection failed: $e');
      }
    }
  }

  Future<void> _sendFrame() async {
    if (!_streaming || _controller == null || !_controller!.value.isInitialized)
      return;
    try {
      final pic = await _controller!.takePicture();
      final bytes = await pic.readAsBytes();
      final img64 = base64Encode(bytes);
      final payload = {
        'frame': img64,
        'gyro': {'x': _gyro.x, 'y': _gyro.y, 'z': _gyro.z},
      };
      _channel?.sink.add(jsonEncode(payload));
    } catch (e) {
      debugPrint('Send error: $e');
    }
  }

  Widget _buildPreview() {
    if (!_hasCamPermission) {
      return const Center(child: Text('Tap the camera icon to enable preview'));
    }
    if (_camError) {
      return const Center(child: Text('Unable to access camera'));
    }
    return FutureBuilder<void>(
      future: _initFuture,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.done) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CameraPreview(_controller!),
          );
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('AR Data Streamer')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // camera preview area
          Expanded(child: _buildPreview()),

          const SizedBox(height: 12),
          // camera-permission button
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              icon: const Icon(Icons.camera_alt, size: 32),
              onPressed: _hasCamPermission ? null : _onCameraButtonPressed,
              tooltip: 'Enable Camera',
            ),
          ),

          // IP address input
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
          // status & gyro
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
          // start/stop streaming
          ElevatedButton(
            onPressed: (_hasCamPermission && !_camError) ? _toggleStream : null,
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
}
