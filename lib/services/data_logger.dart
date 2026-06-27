import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/sensor_data.dart';
import '../models/detection_result.dart';

class DataLogger {
  IOSink? _sink;
  int     _rows     = 0;
  String  _filePath = '';

  static const List<String> _headers = [
    'timestamp', 'L_cm', 'C_cm', 'R_cm',
    'safety_override', 'gate_called', 'gate_detected', 'gate_confidence',
    'gate_latency_ms', 'classify_called', 'gemini_label', 'gemini_position',
    'gemini_confidence', 'gemini_latency_ms', 'cue_text', 'cue_source',
    'direction', 'total_latency_ms',
    'scene_desc_triggered', 'scene_desc_trigger_reason', 'scene_description',
  ];

  Future<void> init() async {
    try {
      final dir = await getExternalStorageDirectory()
                  ?? await getApplicationDocumentsDirectory();
      final ts  = DateTime.now()
          .toIso8601String().replaceAll(':', '-').substring(0, 19);
      final file = File('${dir.path}/nav_log_$ts.csv');
      _sink      = file.openWrite();
      _filePath  = file.path;
      _sink!.writeln(_headers.join(','));
      print('[logger] Logging to $_filePath');
    } catch (e) {
      print('[logger] init() error: $e');
    }
  }

  void log({
    required SensorData     sensors,
    required bool           safetyOverride,
    required bool           gateCalled,
    required GateResult?    gate,
    required bool           classifyCalled,
    required DetectionResult? detection,
    required NavCue         cue,
  }) {
    if (_sink == null) return;
    try {
      final row = [
        DateTime.now().toIso8601String(),
        sensors.left.toStringAsFixed(1),
        sensors.center.toStringAsFixed(1),
        sensors.right.toStringAsFixed(1),
        safetyOverride   ? '1' : '0',
        gateCalled       ? '1' : '0',
        gate?.obstacleDetected == true ? '1' : '0',
        gate?.confidence.toStringAsFixed(3) ?? '',
        gate?.latencyMs.toString() ?? '',
        classifyCalled ? '1' : '0',
        detection?.label.name ?? '',
        detection?.position.name ?? '',
        detection?.confidence.toStringAsFixed(3) ?? '',
        detection?.latencyMs.toString() ?? '',
        '"${cue.text.replaceAll('"', "'")}"',
        cue.source.name,
        cue.direction,
        cue.totalLatencyMs.toString(),
        cue.sceneDescTrigger != null ? '1' : '0',
        cue.sceneDescTrigger ?? '',
        '"${(cue.sceneDescription ?? '').replaceAll('"', "'")}"',
      ];
      _sink!.writeln(row.join(','));
      _rows++;
      if (_rows % 10 == 0) _sink!.flush();
    } catch (e) {
      print('[logger] log() error: $e');
    }
  }

  Future<void> close() async {
    await _sink?.flush();
    await _sink?.close();
    print('[logger] Saved $_rows rows → $_filePath');
  }

  String get filePath  => _filePath;
  int    get rowCount  => _rows;
}
