import 'dart:async';
import 'dart:typed_data';
import '../models/sensor_data.dart';
import '../models/detection_result.dart';
import '../config.dart';
import 'gemini_service.dart';
import 'tts_service.dart';
import 'scene_description_service.dart';

class CascadeEngine {
  final GeminiService _gemini = GeminiService();
  final TtsService    _tts;
  final SceneDescriptionService _sceneDesc = SceneDescriptionService();

  // ── Research counters (shown on Results screen) ───────────────────────
  int totalFrames     = 0;
  int gateCalledCount = 0;   // Stage 1 calls
  int gateYesCount    = 0;   // Stage 1 returned YES
  int classifyCount   = 0;   // Stage 2 calls (only when gate said YES)
  int safetyCount     = 0;   // Safety override fires
  int sensorOnlyCount = 0;   // Handled by sensors alone
  int apiErrorCount   = 0;

  // ── Latest state for UI ───────────────────────────────────────────────
  SensorData?      lastSensors;
  GateResult?      lastGate;
  DetectionResult? lastDetection;
  NavCue?          lastCue;

  CascadeEngine({required TtsService tts}) : _tts = tts;

  /// Main pipeline. Called every frameIntervalMs by NavigationScreen.
  /// Takes current sensor reading + camera frame bytes.
  /// Returns NavCue with what was spoken.
  Future<NavCue> process(SensorData sensors, Uint8List? frameBytes) async {
    final sw = Stopwatch()..start();
    lastSensors = sensors;
    totalFrames++;

    // ── SAFETY LAYER: always first, no AI, no delay ────────────────────
    if (sensors.isCritical) {
      safetyCount++;
      const text = 'Stop! Obstacle directly ahead.';
      await _tts.speakUrgent(text);
      sw.stop();
      final cue = NavCue(
        text:          text,
        source:        CueSource.safety,
        direction:     'stop',
        obstacleLabel: 'obstacle',
        timestamp:     DateTime.now(),
        totalLatencyMs: sw.elapsedMilliseconds,
      );
      lastCue = cue;
      return cue;
    }

    // ── SENSOR ONLY: not in danger zone, or no frame available ─────────
    if (!sensors.isDanger || frameBytes == null || !AppConfig.isApiKeySet) {
      sensorOnlyCount++;
      final cue = _buildSensorCue(sensors, sw.elapsedMilliseconds);
      lastCue = cue;
      // Only speak if something notable
      if (sensors.isCaution) await _tts.speak(cue.text);
      return cue;
    }

    // ── STAGE 1: GATE — is there an obstacle? ─────────────────────────
    gateCalledCount++;
    final gate = await _gemini.runGate(frameBytes);
    lastGate = gate;

    if (!gate.obstacleDetected) {
      // Gate says clear — sensor cue only, no Stage 2 call
      sensorOnlyCount++;
      final cue = _buildSensorCue(sensors, sw.elapsedMilliseconds);
      lastCue = cue;
      await _tts.speak(cue.text);
      return cue;
    }

    // Gate said YES — proceed to Stage 2
    gateYesCount++;

    // ── STAGE 2: CLASSIFY — what is it exactly? ───────────────────────
    classifyCount++;
    final detection = await _gemini.classify(frameBytes);
    lastDetection   = detection;
    sw.stop();

    if (!detection.success) {
      apiErrorCount++;
      final cue = _buildSensorCue(sensors, sw.elapsedMilliseconds);
      lastCue = cue;
      await _tts.speak(cue.text);
      return cue;
    }

    // Build rich cue: AI label + sensor direction
    final cue = _buildRichCue(detection, sensors, sw.elapsedMilliseconds);
    lastCue = cue;
    await _tts.speak(cue.text);

    // ── SCENE DESCRIPTION CHECK ───────────────────────────────────────────
    // Check if any of the 5 trigger parameters are met
    final triggerReason = _sceneDesc.checkTriggers(
      sensors:           sensors,
      lastGate:          lastGate,
      lastGateConfidence: lastGate?.confidence ?? 0.0,
    );

    if (triggerReason != null && frameBytes != null) {
      // Call scene description asynchronously — don't block navigation cue
      // Fire and forget: description will be spoken when it returns
      _sceneDesc.describe(frameBytes, triggerReason).then((description) {
        if (description != null && description.isNotEmpty) {
          // Small delay so description doesn't overlap navigation cue
          Future.delayed(const Duration(milliseconds: 800), () {
            _tts.speak(description);
          });
        }
      });
    }

    return cue;
  }

  /// Build rich cue combining Gemini detection with ultrasonic direction.
  NavCue _buildRichCue(
      DetectionResult det, SensorData sensors, int latencyMs) {
    final label     = _labelText(det.label);
    final position  = _positionText(det.position);
    final direction = sensors.safeDirection;
    final text      = '$label $position, $direction';

    return NavCue(
      text:           text,
      source:         CueSource.gemini,
      direction:      direction,
      obstacleLabel:  det.label.name,
      timestamp:      DateTime.now(),
      totalLatencyMs: latencyMs,
    );
  }

  /// Build sensor-only cue when AI is not needed or unavailable.
  NavCue _buildSensorCue(SensorData sensors, int latencyMs) {
    String text;
    String direction;

    if (sensors.center < AppConfig.dangerDistance) {
      direction = sensors.safeDirection;
      text      = 'Obstacle ahead, $direction';
    } else if (sensors.left < AppConfig.dangerDistance) {
      direction = 'move right';
      text      = 'Obstacle on your left, $direction';
    } else if (sensors.right < AppConfig.dangerDistance) {
      direction = 'move left';
      text      = 'Obstacle on your right, $direction';
    } else {
      direction = 'proceed';
      text      = 'Path is clear';
    }

    return NavCue(
      text:           text,
      source:         CueSource.sensor,
      direction:      direction,
      obstacleLabel:  'obstacle',
      timestamp:      DateTime.now(),
      totalLatencyMs: latencyMs,
    );
  }

  String _labelText(ObstacleLabel label) {
    const m = {
      ObstacleLabel.person:       'Person',
      ObstacleLabel.stairs_up:    'Stairs going up',
      ObstacleLabel.stairs_down:  'Stairs going down',
      ObstacleLabel.wall:         'Wall',
      ObstacleLabel.door_open:    'Open door',
      ObstacleLabel.door_closed:  'Closed door',
      ObstacleLabel.chair:        'Chair',
      ObstacleLabel.table:        'Table',
      ObstacleLabel.clear:        'Path clear',
      ObstacleLabel.unknown:      'Unknown obstacle',
    };
    return m[label] ?? 'Obstacle';
  }

  String _positionText(ObstaclePosition pos) {
    const m = {
      ObstaclePosition.left:    'on your left',
      ObstaclePosition.center:  'directly ahead',
      ObstaclePosition.right:   'on your right',
      ObstaclePosition.unclear: 'nearby',
    };
    return m[pos] ?? 'ahead';
  }

  /// API savings percentage — the main research finding
  double get apiSavingPercent =>
      totalFrames > 0
          ? (1.0 - classifyCount / totalFrames) * 100.0
          : 0.0;

  /// Gate trigger rate
  double get gateTriggerPercent =>
      totalFrames > 0 ? gateYesCount / totalFrames * 100.0 : 0.0;

  SceneDescriptionService get sceneDescService => _sceneDesc;
  String get lastSceneDescription => _sceneDesc.lastDescription;

  Map<String, dynamic> toStats() => {
    'total_frames':        totalFrames,
    'gate_called':         gateCalledCount,
    'gate_yes':            gateYesCount,
    'classify_called':     classifyCount,
    'sensor_only':         sensorOnlyCount,
    'safety_overrides':    safetyCount,
    'api_errors':          apiErrorCount,
    'api_saving_percent':  apiSavingPercent.toStringAsFixed(1),
    'gate_trigger_percent': gateTriggerPercent.toStringAsFixed(1),
  };
}
