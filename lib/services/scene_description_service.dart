import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../config.dart';
import '../models/sensor_data.dart';
import '../models/detection_result.dart';

/// Manages when and how to call Gemini for full scene description.
/// Scene description is a separate, richer call from the cascade pipeline.
/// It produces natural language like:
/// "A person walking toward you from the left, open door ahead."
/// instead of just "Person ahead, move right."

class SceneDescriptionService {

  // ── Trigger cooldowns ─────────────────────────────────────────────────
  DateTime _lastDescriptionTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastProximityTrigger      = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastAmbiguousTrigger      = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastInconsistencyTrigger  = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastStationaryTrigger     = DateTime.fromMillisecondsSinceEpoch(0);

  // ── State tracking for triggers ───────────────────────────────────────
  final List<bool> _recentGateResults = []; // last 4 gate YES/NO results
  final List<double> _recentCenterReadings = []; // last readings for stationary
  final List<double> _recentLeftReadings   = [];
  final List<double> _recentRightReadings  = [];

  String  _lastDescription = '';
  int     totalCalls       = 0;
  int     proximityTriggerCount     = 0;
  int     ambiguousTriggerCount     = 0;
  int     inconsistencyTriggerCount = 0;
  int     stationaryTriggerCount    = 0;
  int     periodicTriggerCount      = 0;

  // ── The Gemini prompt for scene description ────────────────────────────
  static const String _descriptionPrompt = '''
You are describing a scene to a blind person who is navigating on foot.
Describe what you see in 1-2 natural sentences maximum.

Focus on:
- People and their positions and directions of movement
- Obstacles, furniture, or objects that affect navigation
- Doors (open or closed), stairs, corridors, walls
- Approximate distances where visible (nearby, a few metres, far away)
- Lighting or environmental conditions if critically relevant

Do NOT mention: colours, decorative details, text on walls,
brand names, anything not relevant to safe navigation.

Respond with ONLY the description sentence or sentences.
No prefix like "I see" or "The image shows" or "In this image".
Start directly with what matters to a blind navigator.
If the path is completely clear with nothing notable, respond with exactly:
"Path ahead is clear."
''';

  /// Check all 5 trigger parameters and return which triggered (or null).
  /// Call this every frame BEFORE deciding whether to call Gemini.
  String? checkTriggers({
    required SensorData sensors,
    required GateResult? lastGate,
    required double lastGateConfidence,
  }) {
    final now = DateTime.now();

    // Update rolling state
    _updateRollingState(sensors, lastGate);

    // ── PARAMETER 1: Proximity trigger ────────────────────────────────
    final secsSinceProximity =
        now.difference(_lastProximityTrigger).inSeconds;
    if (sensors.center < 120.0 && secsSinceProximity >= 8) {
      return 'proximity';
    }

    // ── PARAMETER 2: Ambiguous gate trigger ───────────────────────────
    final secsSinceAmbiguous =
        now.difference(_lastAmbiguousTrigger).inSeconds;
    if (lastGateConfidence >= 0.35 &&
        lastGateConfidence <= 0.65 &&
        secsSinceAmbiguous >= 5) {
      return 'ambiguous';
    }

    // ── PARAMETER 3: Detection inconsistency trigger ──────────────────
    final secsSinceInconsistency =
        now.difference(_lastInconsistencyTrigger).inSeconds;
    if (_recentGateResults.length >= 4 && secsSinceInconsistency >= 10) {
      // Count how many different results in last 4 (YES vs NO alternating)
      int switches = 0;
      for (int i = 1; i < _recentGateResults.length; i++) {
        if (_recentGateResults[i] != _recentGateResults[i - 1]) switches++;
      }
      if (switches >= 3) {
        return 'inconsistency';
      }
    }

    // ── PARAMETER 4: Stationary awareness trigger ─────────────────────
    final secsSinceStationary =
        now.difference(_lastStationaryTrigger).inSeconds;
    if (_recentCenterReadings.length >= 4 && secsSinceStationary >= 12) {
      final centerVariance = _variance(_recentCenterReadings);
      final leftVariance   = _variance(_recentLeftReadings);
      final rightVariance  = _variance(_recentRightReadings);
      final isStationary   =
          centerVariance < 25.0 && // < 5cm std dev
          leftVariance   < 25.0 &&
          rightVariance  < 25.0;
      if (isStationary) {
        return 'stationary';
      }
    }

    // ── PARAMETER 5: Periodic ambient trigger ─────────────────────────
    final secsSinceLast = now.difference(_lastDescriptionTime).inSeconds;
    final noImmediateDanger =
        sensors.center > 150.0 &&
        sensors.left   > 150.0 &&
        sensors.right  > 150.0;
    if (secsSinceLast >= 20 && noImmediateDanger) {
      return 'periodic';
    }

    return null; // No trigger fired
  }

  /// Call Gemini and get a scene description.
  /// Returns the description string, or null on error.
  Future<String?> describe(Uint8List imageBytes, String triggerReason) async {
    if (!AppConfig.isApiKeySet) return null;

    final sw = Stopwatch()..start();
    try {
      final body = jsonEncode({
        'contents': [{
          'parts': [
            {'text': _descriptionPrompt},
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Encode(imageBytes),
              }
            }
          ]
        }],
        'generationConfig': {
          'temperature':     0.2,
          'maxOutputTokens': 120, // Keep descriptions concise
          'topP':            0.9,
        },
      });

      final response = await http.post(
        Uri.parse(
          '${AppConfig.geminiEndpoint}?key=${AppConfig.geminiApiKey}'
        ),
        headers: {'Content-Type': 'application/json; charset=UTF-8'},
        body: body,
      ).timeout(const Duration(seconds: 6));

      sw.stop();

      if (response.statusCode != 200) {
        print('[scene] API error ${response.statusCode}');
        return null;
      }

      final respJson = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = respJson['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) return null;

      final text = (candidates[0]['content']['parts'][0]['text'] as String)
          .trim();

      // Update state
      _lastDescription      = text;
      _lastDescriptionTime  = DateTime.now();
      totalCalls++;

      // Update trigger-specific cooldowns and counters
      _updateTriggerCooldown(triggerReason);

      print('[scene] [$triggerReason] ${sw.elapsedMilliseconds}ms: $text');
      return text;

    } catch (e) {
      sw.stop();
      print('[scene] describe() error: $e');
      return null;
    }
  }

  void _updateRollingState(SensorData sensors, GateResult? gate) {
    // Rolling sensor readings (keep last 8 for stationary detection)
    _recentCenterReadings.add(sensors.center);
    _recentLeftReadings.add(sensors.left);
    _recentRightReadings.add(sensors.right);
    if (_recentCenterReadings.length > 8) {
      _recentCenterReadings.removeAt(0);
      _recentLeftReadings.removeAt(0);
      _recentRightReadings.removeAt(0);
    }

    // Rolling gate results (keep last 4 for inconsistency detection)
    if (gate != null) {
      _recentGateResults.add(gate.obstacleDetected);
      if (_recentGateResults.length > 4) _recentGateResults.removeAt(0);
    }
  }

  void _updateTriggerCooldown(String reason) {
    final now = DateTime.now();
    switch (reason) {
      case 'proximity':
        _lastProximityTrigger = now;
        proximityTriggerCount++;
        break;
      case 'ambiguous':
        _lastAmbiguousTrigger = now;
        ambiguousTriggerCount++;
        break;
      case 'inconsistency':
        _lastInconsistencyTrigger = now;
        inconsistencyTriggerCount++;
        break;
      case 'stationary':
        _lastStationaryTrigger = now;
        stationaryTriggerCount++;
        break;
      case 'periodic':
        periodicTriggerCount++;
        break;
    }
  }

  double _variance(List<double> values) {
    if (values.length < 2) return 0.0;
    final mean = values.reduce((a, b) => a + b) / values.length;
    final squaredDiffs = values.map((v) => (v - mean) * (v - mean));
    return squaredDiffs.reduce((a, b) => a + b) / values.length;
  }

  String get lastDescription => _lastDescription;

  /// Stats for Results screen — how often each trigger fires
  Map<String, dynamic> toStats() => {
    'total_scene_calls':      totalCalls,
    'proximity_triggers':     proximityTriggerCount,
    'ambiguous_triggers':     ambiguousTriggerCount,
    'inconsistency_triggers': inconsistencyTriggerCount,
    'stationary_triggers':    stationaryTriggerCount,
    'periodic_triggers':      periodicTriggerCount,
  };
}
