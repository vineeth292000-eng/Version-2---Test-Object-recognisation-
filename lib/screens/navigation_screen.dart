import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/arduino_service.dart';
import '../services/camera_service.dart';
import '../services/tts_service.dart';
import '../services/cascade_engine.dart';
import '../services/data_logger.dart';
import '../models/sensor_data.dart';
import '../models/detection_result.dart';
import '../config.dart';
import '../widgets/sensor_bar.dart';

class NavigationScreen extends StatefulWidget {
  const NavigationScreen({super.key});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  late ArduinoService  _arduino;
  late CameraService   _camera;
  late TtsService      _tts;
  late CascadeEngine   _cascade;
  late DataLogger      _logger;

  SensorData _sensors = SensorData.empty();
  NavCue?    _lastCue;
  bool       _isRunning        = false;
  bool       _arduinoConnected = false;
  Timer?     _pipelineTimer;

  // Camera diagnostics
  int       _frameCount      = 0;
  int       _nullFrameCount  = 0;
  int       _lastFrameBytes  = 0;
  DateTime? _lastFrameTime;
  bool      _cameraWorking   = false;

  // API health
  bool _apiWarning = false;

  @override
  void initState() {
    super.initState();
    _arduino  = ArduinoService();
    _camera   = CameraService();
    _tts      = TtsService();
    _cascade  = CascadeEngine(tts: _tts);
    _logger   = DataLogger();
    _initialize();
  }

  Future<void> _initialize() async {
    await _tts.init();

    final camOk = await _camera.init();
    if (!camOk) {
      await _tts.speak(
        'Camera failed to initialise. Navigation will use sensors only.',
        priority: TtsPriority.high,
        cueKey:   'cam_init_fail',
      );
    }

    _arduinoConnected = await _arduino.connect();
    if (!_arduinoConnected) {
      await _tts.speak(
        'Sensor belt not connected. Tap connect in settings.',
        priority: TtsPriority.high,
        cueKey:   'arduino_fail',
      );
    }

    _arduino.sensorStream.listen((reading) {
      if (mounted) setState(() => _sensors = reading);
    });

    await _logger.init();

    // Give camera 2 seconds to warm up before starting pipeline
    await Future.delayed(const Duration(seconds: 2));

    if (mounted) setState(() => _isRunning = true);

    _pipelineTimer = Timer.periodic(
      Duration(milliseconds: AppConfig.frameIntervalMs),
      _runCycle,
    );

    await WakelockPlus.enable();
    await _tts.speak(
      'Navigation assistant ready.',
      priority: TtsPriority.medium,
      cueKey:   'startup_ready',
    );
  }

  Future<void> _runCycle(Timer t) async {
    if (!_isRunning) return;

    final bytes = await _camera.captureFrame();
    _frameCount++;

    if (bytes == null) {
      _nullFrameCount++;
    } else {
      _lastFrameBytes = bytes.length;
      _lastFrameTime  = DateTime.now();
      _cameraWorking  = true;
    }

    // Warn if camera producing no frames after 5 cycles
    if (_frameCount >= 5 && _nullFrameCount == _frameCount) {
      if (mounted) setState(() => _cameraWorking = false);
      if (_frameCount == 5) {
        await _tts.speak(
          'Warning: camera not producing images. '
          'AI detection is disabled.',
          priority: TtsPriority.high,
          cueKey:   'cam_no_frames',
        );
      }
    }

    print('[camera] frame #$_frameCount '
        '${bytes == null ? "NULL" : "${bytes.length}B"} '
        'nulls=$_nullFrameCount '
        'camErr=${_camera.errorCount} '
        'overlap=${_camera.skippedOverlapCount}');

    final cue = await _cascade.process(_sensors, bytes);

    // Warn if Gemini keeps failing
    final apiWarn = _cascade.gemini.hasConsecutiveFailures;
    if (apiWarn != _apiWarning && mounted) {
      setState(() => _apiWarning = apiWarn);
      if (apiWarn) {
        await _tts.speak(
          'Gemini API errors detected. Check API key and internet.',
          priority: TtsPriority.high,
          cueKey:   'api_fail_warn',
        );
      }
    }

    _logger.log(
      sensors:        _sensors,
      safetyOverride: _sensors.isCritical,
      gateCalled:     _cascade.lastGate != null,
      gate:           _cascade.lastGate,
      classifyCalled: _cascade.lastDetection != null,
      detection:      _cascade.lastDetection,
      cue:            cue,
    );

    if (mounted) setState(() => _lastCue = cue);
  }

  @override
  void dispose() {
    _isRunning = false;
    _pipelineTimer?.cancel();
    WakelockPlus.disable();
    _camera.dispose();
    _arduino.disconnect();
    _logger.close();
    _tts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final confirmed = await _showExitDialog();
        if (confirmed && mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Navigating'),
          actions: [
            // Camera health indicator
            Tooltip(
              message: _cameraWorking
                  ? 'Camera active'
                  : 'Camera not producing frames',
              child: Icon(
                Icons.camera_alt,
                color: _cameraWorking ? Colors.green : Colors.red,
              ),
            ),
            const SizedBox(width: 8),
            // API health indicator
            if (_apiWarning)
              const Tooltip(
                message: 'Gemini API errors',
                child: Icon(Icons.cloud_off, color: Colors.orange),
              ),
            const SizedBox(width: 8),
            // Arduino indicator
            Tooltip(
              message: _arduinoConnected
                  ? 'Sensor belt connected'
                  : 'Sensor belt not connected',
              child: Icon(
                _arduinoConnected
                    ? Icons.bluetooth_connected
                    : Icons.bluetooth_disabled,
                color: _arduinoConnected ? Colors.green : Colors.red,
              ),
            ),
            const SizedBox(width: 16),
          ],
        ),
        body: Column(
          children: [

            // Camera preview
            Expanded(
              flex: 2,
              child: Stack(
                children: [
                  _camera.isReady
                      ? CameraPreview(_camera.controller!)
                      : Container(
                          color: Colors.grey.shade900,
                          child: const Center(
                            child: Text(
                              'Camera initialising...',
                              style: TextStyle(
                                  color: Colors.white, fontSize: 18),
                            ),
                          ),
                        ),
                  // Camera status overlay
                  if (!_cameraWorking && _frameCount >= 5)
                    Container(
                      color: Colors.red.withOpacity(0.7),
                      child: const Center(
                        child: Text(
                          'CAMERA NOT WORKING\nUsing sensors only',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Sensor bars
            Container(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  const Text('SENSORS',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      SensorBar(label: 'L', distance: _sensors.left),
                      SensorBar(label: 'C', distance: _sensors.center),
                      SensorBar(label: 'R', distance: _sensors.right),
                    ],
                  ),
                ],
              ),
            ),

            // Last cue card
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _lastCue == null
                      ? const Text('Waiting for first detection...',
                          style: TextStyle(fontSize: 16))
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _lastCue!.text,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                _sourceBadge(_lastCue!.source),
                                const SizedBox(width: 8),
                                Text('${_lastCue!.totalLatencyMs}ms',
                                    style:
                                        const TextStyle(fontSize: 13)),
                                const SizedBox(width: 8),
                                if (_lastCue!.urgency.isNotEmpty)
                                  _urgencyBadge(_lastCue!.urgency),
                              ],
                            ),
                          ],
                        ),
                ),
              ),
            ),

            // Scene description card
            if (_cascade.lastSceneDescription.isNotEmpty)
              Card(
                color: Colors.blueGrey[800],
                margin: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 4),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.visibility,
                              color: Colors.lightBlueAccent,
                              size: 14),
                          SizedBox(width: 4),
                          Text(
                            'SCENE',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.lightBlueAccent,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _cascade.lastSceneDescription,
                        style: const TextStyle(
                            fontSize: 14, height: 1.3),
                      ),
                    ],
                  ),
                ),
              ),

            // Stats and camera diagnostics
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 4),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Text('Frames: ${_cascade.totalFrames}',
                          style: const TextStyle(fontSize: 12)),
                      Text('API: ${_cascade.classifyCount}',
                          style: const TextStyle(fontSize: 12)),
                      Text(
                          'Saved: '
                          '${_cascade.apiSavingPercent.toStringAsFixed(0)}%',
                          style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Text(
                        'Cam: ${_lastFrameBytes > 0 ? "${(_lastFrameBytes / 1024).toStringAsFixed(0)}KB" : "no frames"}',
                        style: TextStyle(
                          fontSize: 11,
                          color: _lastFrameBytes > 0
                              ? Colors.green
                              : Colors.red,
                        ),
                      ),
                      Text(
                        'Nulls: $_nullFrameCount  '
                        'Err: ${_camera.errorCount}',
                        style: TextStyle(
                          fontSize: 11,
                          color: (_nullFrameCount + _camera.errorCount) > 0
                              ? Colors.orange
                              : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // STOP button
            Padding(
              padding: const EdgeInsets.all(12),
              child: ElevatedButton(
                onPressed: () async {
                  _isRunning = false;
                  _pipelineTimer?.cancel();
                  await _tts.speakUrgent(
                    'Navigation stopped.',
                    cueKey: 'navigation_stopped',
                  );
                  if (mounted) Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(65),
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: const Text(
                  'STOP NAVIGATION',
                  style: TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourceBadge(CueSource source) {
    final map = {
      CueSource.safety: (Colors.red,    'SAFETY'),
      CueSource.sensor: (Colors.grey,   'SENSOR'),
      CueSource.gate:   (Colors.blue,   'GATE'),
      CueSource.gemini: (Colors.green,  'GEMINI'),
    };
    final (color, label) = map[source] ?? (Colors.grey, '?');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          )),
    );
  }

  Widget _urgencyBadge(String urgency) {
    final map = {
      'critical': Colors.red,
      'high':     Colors.orange,
      'medium':   Colors.yellow.shade700,
      'low':      Colors.grey,
    };
    final color = map[urgency] ?? Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        urgency.toUpperCase(),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Future<bool> _showExitDialog() async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Stop navigation?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('No'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Yes'),
              ),
            ],
          ),
        ) ??
        false;
  }
}
