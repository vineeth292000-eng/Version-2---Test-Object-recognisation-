import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/sensor_data.dart';
import '../models/detection_result.dart';

enum SceneComplexity { simple, detailed, complex }

class SceneDescriptionService {

  DateTime _lastAnyDescription   = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastProximityTrigger = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastAmbiguousTrigger = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastInconsistency    = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastStationary       = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastComplexTrigger   = DateTime.fromMillisecondsSinceEpoch(0);

  final List<bool>   _gateHistory     = [];
  final List<double> _centerHistory   = [];
  final List<double> _leftHistory     = [];
  final List<double> _rightHistory    = [];
  final List<String> _crowdingHistory = [];
  final List<String> _labelHistory    = [];

  String          _lastDescription = '';
  String          _lastTrigger     = '';
  SceneComplexity _lastComplexity  = SceneComplexity.simple;
  bool            _isLoading       = false;

  int totalCalls         = 0;
  int simpleCalls        = 0;
  int detailedCalls      = 0;
  int complexCalls       = 0;
  int proximityCount     = 0;
  int ambiguousCount     = 0;
  int inconsistencyCount = 0;
  int stationaryCount    = 0;
  int periodicCount      = 0;
  int crowdedCount       = 0;
  int movingObjectCount  = 0;
  int complexSceneCount  = 0;

  String get lastDescription => _lastDescription;
  String get lastTrigger     => _lastTrigger;
  bool   get isLoading       => _isLoading;
  SceneComplexity get lastComplexity => _lastComplexity;

  static const String _simplePrompt = '''
You are describing an environment to a blind person navigating on foot.
Respond in exactly 2 natural spoken sentences.
Write directly — do not start with "I can see" or "The image shows".
Describe: the type of space, how busy it is, and any key navigation features.
Write for text-to-speech — natural spoken English only.
''';

  static const String _detailedPrompt = '''
You are a navigation assistant for a blind person with a chest-mounted camera.
Describe the scene in 3 sentences for text-to-speech.

Sentence 1: What type of space is this and how busy is it?
Sentence 2: What is the most important thing to know for navigation right now?
Sentence 3: What is directly ahead and what action should the person take?

Rules:
- Use actual object names, not "obstacle" or "thing"
- Include approximate distances (one metre, two metres, nearby, far ahead)
- Mention if passage is narrow or wide
- If people are present, describe what they are doing
- Write as calm natural speech — no bullet points, no lists
- Do not start with "I can see" or "The image shows"
''';

  static const String _complexPrompt = '''
You are providing full situational awareness to a blind person navigating
in a complex indoor environment. This is called when the scene is
particularly challenging — crowded, confusing, or has multiple hazards.

Respond in 3-4 sentences of natural spoken English for text-to-speech.

Cover ALL of these in your response:
1. The type of space and overall layout (open, narrow, corridor, room, etc.)
2. Where people are, what they are doing, and if any are moving toward the user
3. The most immediate navigation challenge and exactly how to handle it
4. What lies ahead beyond the immediate obstacle — is the path clear further on?

Be specific:
- Name actual objects (chair, glass door, staircase, reception desk)
- Use distance language (about one metre, two or three metres ahead, far end)
- If a passage is narrow, say so and estimate how tight it is
- If multiple hazards exist, prioritise the most dangerous one first

Do NOT:
- Start with "I can see" or "The image shows"
- Say "obstacle" — always name the actual object
- Mention colours unless critical
- List things — write flowing natural sentences
''';

  String? checkTriggers({
    required SensorData       sensors,
    required GateResult?      lastGate,
    required DetectionResult? lastDetection,
    required VelocityTracker  velocity,
  }) {
    _updateState(sensors, lastGate, lastDetection);
    final now = DateTime.now();
    final secsSinceLast = now.difference(_lastAnyDescription).inSeconds;

    if (secsSinceLast < AppConfig.sceneDescMinGapSeconds) return null;

    // TRIGGER 1: PROXIMITY
    if (sensors.center < AppConfig.sceneDescProximityThreshold &&
        now.difference(_lastProximityTrigger).inSeconds >= 10) {
      return 'proximity';
    }

    // TRIGGER 2: MOVING OBJECT APPROACHING
    if (velocity.isApproaching && secsSinceLast >= 8) {
      movingObjectCount++;
      return 'moving_object';
    }

    // TRIGGER 3: AMBIGUOUS GATE
    final gateConf = lastGate?.confidence ?? 1.0;
    if (gateConf >= AppConfig.sceneDescAmbiguousLow &&
        gateConf <= AppConfig.sceneDescAmbiguousHigh &&
        now.difference(_lastAmbiguousTrigger).inSeconds >= 8) {
      return 'ambiguous';
    }

    // TRIGGER 4: DETECTION INCONSISTENCY
    if (_gateHistory.length >= 4 &&
        now.difference(_lastInconsistency).inSeconds >= 12) {
      int switches = 0;
      for (int i = 1; i < _gateHistory.length; i++) {
        if (_gateHistory[i] != _gateHistory[i - 1]) switches++;
      }
      if (switches >= 3) return 'inconsistency';
    }

    // TRIGGER 5: STATIONARY
    if (_centerHistory.length >= 4 &&
        now.difference(_lastStationary).inSeconds >= 15) {
      final cVar = _variance(_centerHistory);
      final lVar = _variance(_leftHistory);
      final rVar = _variance(_rightHistory);
      if (cVar < 25.0 && lVar < 25.0 && rVar < 25.0) {
        return 'stationary';
      }
    }

    // TRIGGER 6: CROWDED
    if (_crowdingHistory.length >= 3 &&
        secsSinceLast >= AppConfig.sceneDescCrowdedMinGap) {
      final recentCrowded = _crowdingHistory
          .where((c) => c == 'crowded' || c == 'moderate')
          .length;
      if (recentCrowded >= 2) return 'crowded';
    }

    // TRIGGER 7: COMPLEX SCENE
    if (_labelHistory.length >= 3 &&
        now.difference(_lastComplexTrigger).inSeconds >=
            AppConfig.sceneDescComplexMinGap) {
      final uniqueTypes = _labelHistory.toSet().length;
      if (uniqueTypes >= AppConfig.complexSceneMultiObstacleCount) {
        complexSceneCount++;
        return 'complex_scene';
      }
    }

    // TRIGGER 8: NARROW PASSAGE
    if (lastDetection?.environment.narrowPassage == true &&
        secsSinceLast >= 10) {
      return 'narrow_passage';
    }

    // TRIGGER 9: FLOOR HAZARD
    if (lastDetection?.environment.floorHazards == true &&
        secsSinceLast >= 8) {
      return 'floor_hazard';
    }

    // TRIGGER 10: PERIODIC
    final allClear = sensors.center > 150 &&
                     sensors.left   > 120 &&
                     sensors.right  > 120;
    if (allClear &&
        secsSinceLast >= AppConfig.sceneDescPeriodicSeconds) {
      return 'periodic';
    }

    return null;
  }

  SceneComplexity _complexityForTrigger(String reason) {
    switch (reason) {
      case 'complex_scene':
      case 'crowded':
      case 'inconsistency':
        return SceneComplexity.complex;
      case 'moving_object':
      case 'stationary':
      case 'narrow_passage':
      case 'floor_hazard':
        return SceneComplexity.detailed;
      default:
        return SceneComplexity.simple;
    }
  }

  String _promptForComplexity(SceneComplexity complexity) {
    switch (complexity) {
      case SceneComplexity.complex:  return _complexPrompt;
      case SceneComplexity.detailed: return _detailedPrompt;
      case SceneComplexity.simple:   return _simplePrompt;
    }
  }

  int _maxTokensForComplexity(SceneComplexity complexity) {
    switch (complexity) {
      case SceneComplexity.complex:  return 250;
      case SceneComplexity.detailed: return 180;
      case SceneComplexity.simple:   return 100;
    }
  }

  Future<String?> describe(
      Uint8List imageBytes, String triggerReason) async {
    if (!AppConfig.isApiKeySet) return null;

    _isLoading   = true;
    _lastTrigger = triggerReason;

    final complexity = _complexityForTrigger(triggerReason);
    _lastComplexity  = complexity;

    switch (complexity) {
      case SceneComplexity.simple:   simpleCalls++;   break;
      case SceneComplexity.detailed: detailedCalls++; break;
      case SceneComplexity.complex:  complexCalls++;  break;
    }

    try {
      final response = await http.post(
        Uri.parse(
          '${AppConfig.geminiEndpoint}?key=${AppConfig.geminiApiKey}'
        ),
        headers: {'Content-Type': 'application/json; charset=UTF-8'},
        body: jsonEncode({
          'contents': [{
            'parts': [
              {'text': _promptForComplexity(complexity)},
              {
                'inline_data': {
                  'mime_type': 'image/jpeg',
                  'data':      base64Encode(imageBytes),
                }
              }
            ]
          }],
          'generationConfig': {
            'temperature':
                complexity == SceneComplexity.complex ? 0.4 : 0.2,
            'maxOutputTokens': _maxTokensForComplexity(complexity),
            'topP': 0.9,
          },
        }),
      ).timeout(Duration(seconds: AppConfig.geminiTimeoutSecs));

      _isLoading = false;

      if (response.statusCode != 200) return null;

      final json       = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = json['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) return null;

      final text = (candidates[0]['content']['parts'][0]['text'] as String)
          .trim();

      _lastDescription    = text;
      _lastAnyDescription = DateTime.now();
      totalCalls++;
      _updateCooldown(triggerReason);

      print('[scene] [$triggerReason/${complexity.name}] $text');
      return text;

    } catch (e) {
      _isLoading = false;
      print('[scene] describe() error: $e');
      return null;
    }
  }

  void _updateState(
      SensorData s, GateResult? g, DetectionResult? d) {
    _centerHistory.add(s.center);
    _leftHistory.add(s.left);
    _rightHistory.add(s.right);
    if (_centerHistory.length > 8) {
      _centerHistory.removeAt(0);
      _leftHistory.removeAt(0);
      _rightHistory.removeAt(0);
    }

    if (g != null) {
      _gateHistory.add(g.obstacleDetected);
      if (_gateHistory.length > 4) _gateHistory.removeAt(0);
    }

    if (d != null && d.success) {
      _crowdingHistory.add(d.environment.crowding);
      if (_crowdingHistory.length > 3) _crowdingHistory.removeAt(0);
      _labelHistory.add(d.label.name);
      if (_labelHistory.length > 5) _labelHistory.removeAt(0);
    }
  }

  void _updateCooldown(String reason) {
    final now = DateTime.now();
    switch (reason) {
      case 'proximity':
        _lastProximityTrigger = now;
        proximityCount++;
        break;
      case 'ambiguous':
        _lastAmbiguousTrigger = now;
        ambiguousCount++;
        break;
      case 'inconsistency':
        _lastInconsistency = now;
        inconsistencyCount++;
        break;
      case 'stationary':
        _lastStationary = now;
        stationaryCount++;
        break;
      case 'crowded':
        crowdedCount++;
        break;
      case 'periodic':
        periodicCount++;
        break;
      case 'complex_scene':
        _lastComplexTrigger = now;
        break;
    }
  }

  double _variance(List<double> v) {
    if (v.length < 2) return 0;
    final mean = v.reduce((a, b) => a + b) / v.length;
    return v.map((x) => (x - mean) * (x - mean))
            .reduce((a, b) => a + b) / v.length;
  }

  String triggerLabel(String reason) {
    const labels = {
      'proximity':     '📍 Obstacle close',
      'moving_object': '🏃 Moving object',
      'ambiguous':     '❓ Unclear detection',
      'inconsistency': '🔄 Scene confusion',
      'stationary':    '⏸ User stopped',
      'crowded':       '👥 Crowded space',
      'complex_scene': '🧩 Complex scene',
      'narrow_passage':'🚪 Narrow passage',
      'floor_hazard':  '⚠️ Floor hazard',
      'periodic':      '👁 Ambient update',
    };
    return labels[reason] ?? reason;
  }

  Map<String, dynamic> toStats() => {
    'total_scene_calls':      totalCalls,
    'simple_calls':           simpleCalls,
    'detailed_calls':         detailedCalls,
    'complex_calls':          complexCalls,
    'proximity_triggers':     proximityCount,
    'moving_object_triggers': movingObjectCount,
    'ambiguous_triggers':     ambiguousCount,
    'inconsistency_triggers': inconsistencyCount,
    'stationary_triggers':    stationaryCount,
    'crowded_triggers':       crowdedCount,
    'complex_scene_triggers': complexSceneCount,
    'periodic_triggers':      periodicCount,
    'last_trigger':           _lastTrigger,
    'last_complexity':        _lastComplexity.name,
  };
}

