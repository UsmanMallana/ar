import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:sensors_plus/sensors_plus.dart';

void main() async {
  // Ensure that plugin services are initialized so that `availableCameras()`
  // can be called before `runApp()`
  WidgetsFlutterBinding.ensureInitialized();

  // Obtain a list of the available cameras on the device.
  final cameras = await availableCameras();

  // Get a specific camera from the list of available cameras.
  final firstCamera = cameras.firstWhere(
    (camera) => camera.lensDirection == CameraLensDirection.back,
  );

  runApp(MyApp(camera: firstCamera));
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
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  WebSocketChannel? _channel;
  StreamSubscription<GyroscopeEvent>? _gyroscopeSubscription;

  final TextEditingController _ipController = TextEditingController();
  bool _isStreaming = false;
  String _statusText = 'Disconnected';
  // Corrected: Added DateTime.now() for the timestamp
  GyroscopeEvent _gyroscopeEvent = GyroscopeEvent(0, 0, 0, DateTime.now());

  // We will send frames at a controlled rate
  Timer? _frameTimer;

  @override
  void initState() {
    super.initState();
    _controller = CameraController(
      widget.camera,
      // Set a lower resolution to reduce latency.
      // The python server will resize it anyway.
      ResolutionPreset.medium,
      enableAudio: false,
    );

    _initializeControllerFuture = _controller.initialize();

    // Listen to gyroscope events
    _gyroscopeSubscription = gyroscopeEvents.listen((GyroscopeEvent event) {
      if (mounted) {
        setState(() {
          _gyroscopeEvent = event;
        });
      }
    });

    // For debugging, you can pre-fill an IP
    // _ipController.text = "192.168.1.10";
  }

  void _toggleStreaming() {
    if (_isStreaming) {
      // Stop streaming
      _frameTimer?.cancel();
      _channel?.sink.close();
      if (mounted) {
        setState(() {
          _isStreaming = false;
          _statusText = 'Disconnected';
        });
      }
    } else {
      // Start streaming
      final ip = _ipController.text;
      if (ip.isEmpty) {
        // Show an error or a snackbar
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter the server IP address')),
        );
        return;
      }

      final wsUrl = "ws://$ip:8765";
      if (mounted) {
        setState(() {
          _statusText = 'Connecting to $wsUrl...';
        });
      }

      try {
        _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
        _channel!.ready
            .then((_) {
              if (mounted) {
                setState(() {
                  _isStreaming = true;
                  _statusText = 'Connected and streaming';
                });
                // Start sending frames at a fixed interval (e.g., 15 FPS)
                _startFrameTimer();
              }
            })
            .catchError((error) {
              if (mounted) {
                setState(() {
                  _statusText = 'Connection Failed: $error';
                });
              }
            });
      } catch (e) {
        if (mounted) {
          setState(() {
            _statusText = 'Invalid WebSocket URL';
          });
        }
      }
    }
  }

  void _startFrameTimer() {
    // Send data every ~66ms, which is about 15 FPS
    _frameTimer = Timer.periodic(const Duration(milliseconds: 66), (timer) {
      if (!_isStreaming) {
        timer.cancel();
        return;
      }
      _sendData();
    });
  }

  Future<void> _sendData() async {
    if (!_controller.value.isInitialized || !_isStreaming || !mounted) {
      return;
    }

    try {
      final image = await _controller.takePicture();
      final bytes = await image.readAsBytes();

      // The image from `takePicture` is already JPEG encoded.
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
      print("Error sending data: $e");
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _gyroscopeSubscription?.cancel();
    _frameTimer?.cancel();
    _channel?.sink.close();
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AR Data Streamer')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: <Widget>[
            // Camera Preview
            Expanded(
              child: FutureBuilder<void>(
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
                        child: CameraPreview(_controller),
                      ),
                    );
                  } else {
                    return const Center(child: CircularProgressIndicator());
                  }
                },
              ),
            ),
            const SizedBox(height: 16),
            // IP Address Input
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
            // Status and Gyro Data
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
                      'Gyro X: ${_gyroscopeEvent.x.toStringAsFixed(2)}, Y: ${_gyroscopeEvent.y.toStringAsFixed(2)}, Z: ${_gyroscopeEvent.z.toStringAsFixed(2)}',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Start/Stop Button
            ElevatedButton(
              onPressed: _toggleStreaming,
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
}
