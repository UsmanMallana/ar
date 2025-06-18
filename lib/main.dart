import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:sensors_plus/sensors_plus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    final cameras = await availableCameras();
    final firstCamera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
    );
    runApp(MyApp(camera: firstCamera));
  } catch (e) {
    runApp(const PermissionErrorApp());
  }
}

class PermissionErrorApp extends StatelessWidget {
  const PermissionErrorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Text(
              'Camera permission required. Please enable in Settings',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18),
            ),
          ),
        ),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  final CameraDescription camera;
  const MyApp({super.key, required this.camera});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AR Data Streamer',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: StreamingScreen(camera: camera),
    );
  }
}

class StreamingScreen extends StatefulWidget {
  final CameraDescription camera;
  const StreamingScreen({super.key, required this.camera});

  @override
  State<StreamingScreen> createState() => _StreamingScreenState();
}

class _StreamingScreenState extends State<StreamingScreen> {
  CameraController? _controller;
  Future<void>? _initializeControllerFuture;
  WebSocketChannel? _channel;
  StreamSubscription<GyroscopeEvent>? _gyroscopeSubscription;
  Timer? _frameTimer;
  final TextEditingController _ipController = TextEditingController();
  bool _isStreaming = false;
  String _statusText = 'Disconnected';
  GyroscopeEvent _gyroscopeEvent = GyroscopeEvent(0, 0, 0, DateTime.now());
  bool _cameraError = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _gyroscopeSubscription = gyroscopeEvents.listen((event) {
      if (mounted) setState(() => _gyroscopeEvent = event);
    });
  }

  void _initializeCamera() {
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.medium,
      enableAudio: true,
    );

    _initializeControllerFuture = _controller!.initialize().catchError((e) {
      if (e is CameraException) {
        setState(() => _cameraError = true);
      }
      return Future.value();
    });

    setState(() {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    _gyroscopeSubscription?.cancel();
    _frameTimer?.cancel();
    _channel?.sink.close();
    _ipController.dispose();
    super.dispose();
  }

  void _toggleStreaming() {
    if (_controller == null || _cameraError) return;

    if (_isStreaming) {
      _frameTimer?.cancel();
      _channel?.sink.close();
      setState(() {
        _isStreaming = false;
        _statusText = 'Disconnected';
      });
    } else {
      final ip = _ipController.text;
      if (ip.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter the server IP address')),
        );
        return;
      }
      final wsUrl = 'ws://$ip:8765';
      setState(() => _statusText = 'Connecting to $wsUrl...');
      try {
        _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
        setState(() {
          _isStreaming = true;
          _statusText = 'Connected and streaming';
        });
        _startFrameTimer();
      } catch (e) {
        setState(() => _statusText = 'Connection Failed: $e');
      }
    }
  }

  void _startFrameTimer() {
    _frameTimer = Timer.periodic(const Duration(milliseconds: 66), (_) {
      if (!_isStreaming) return;
      _sendData();
    });
  }

  Future<void> _sendData() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        !_isStreaming)
      return;
    try {
      final image = await _controller!.takePicture();
      final bytes = await image.readAsBytes();
      final base64Image = base64Encode(bytes);
      final data = {
        'frame': base64Image,
        'gyro': {
          'x': _gyroscopeEvent.x,
          'y': _gyroscopeEvent.y,
          'z': _gyroscopeEvent.z,
        },
      };
      _channel?.sink.add(jsonEncode(data));
    } catch (e) {
      debugPrint('Error sending data: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AR Data Streamer')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Expanded(child: _buildCameraPreview()),
            const SizedBox(height: 16),
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(
                labelText: 'Laptop IP Address',
                border: OutlineInputBorder(),
                hintText: 'e.g., 192.168.1.100',
              ),
              keyboardType: TextInputType.phone,
              enabled: !_isStreaming,
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  children: [
                    Text(
                      _statusText,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Gyro X: ${_gyroscopeEvent.x.toStringAsFixed(2)}, ' +
                          'Y: ${_gyroscopeEvent.y.toStringAsFixed(2)}, ' +
                          'Z: ${_gyroscopeEvent.z.toStringAsFixed(2)}',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _cameraError ? null : _toggleStreaming,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isStreaming ? Colors.redAccent : Colors.green,
                padding: const EdgeInsets.symmetric(
                  horizontal: 50,
                  vertical: 20,
                ),
                textStyle: const TextStyle(fontSize: 18),
              ),
              child: Text(_isStreaming ? 'Stop Streaming' : 'Start Streaming'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    if (_cameraError) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.videocam_off, size: 64, color: Colors.red),
            SizedBox(height: 16),
            Text(
              'Camera access denied\nPlease enable in Settings',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18),
            ),
          ],
        ),
      );
    }

    return FutureBuilder<void>(
      future: _initializeControllerFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          return Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: _isStreaming ? Colors.green : Colors.red,
                width: 3,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: CameraPreview(_controller!),
            ),
          );
        } else {
          return const Center(child: CircularProgressIndicator());
        }
      },
    );
  }
}
