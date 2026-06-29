import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/detection_result.dart';

class GeminiService {

  // Track consecutive failures to detect camera/API issues
  int _consecutiveFailures = 0;
  int totalGateCalls    = 0;
  int totalClassifyCalls = 0;
  int totalFailures     = 0;
  String? lastError;

  static const String _gatePrompt = '''
You are the first stage of a navigation system for a blind person.
Look at this image and answer ONE question: is there anything this
person needs to know about to navigate safely?

IMPORTANT: This is a chest-mounted camera on a person who is walking.
You will see a first-person view of whatever is in front of them.

Answer ONLY with this exact JSON, nothing else, no markdown:
{"obstacle_detected": true, "confidence": 0.85}

obstacle_detected is TRUE if you see ANY of:
- A person, animal, child, or pet
- Any furniture: chair, table, sofa, desk, bed, shelf, counter
- A door (open or closed), including glass doors
- Stairs going up or down, or any step or kerb
- A wall, pillar, or barrier within 4 metres
- A narrow corridor or tight passage
- Wet floor sign, cables, or floor hazard
- Any vehicle or bicycle
- Any object a walking person could collide with

obstacle_detected is FALSE ONLY if:
- The path ahead is completely open for at least 3 metres
- You can see clear floor with nothing to walk into

confidence: 0.0 to 1.0 — how certain you are
No markdown. No explanation. Only the JSON object.
''';

  static const String _classifyPrompt = '''
You are a navigation assistant for a blind person walking with a
chest-mounted camera. Your job is to identify EXACTLY what is in
front of them so they know what to avoid.

CRITICAL RULES:
1. ALWAYS name the specific object — NEVER say "obstacle" or "object"
2. The "specifics" field must describe what you actually see
3. The "navigation_instruction" must be a complete spoken sentence
4. If you are unsure, say what it LOOKS LIKE, not "unknown object"

Respond ONLY with this exact JSON, nothing else, no markdown:
{
  "primary_obstacle": {
    "type": "CHAIR",
    "specifics": "wooden chair with armrests blocking path",
    "position": "center",
    "distance_estimate": "close",
    "moving": false,
    "moving_direction": "stationary"
  },
  "secondary_obstacles": [],
  "environment": {
    "setting": "indoor office",
    "crowding": "low",
    "lighting": "good",
    "floor_hazards": false,
    "narrow_passage": false
  },
  "navigation_instruction": "There is a wooden chair directly ahead about one metre away. Step to your left to go around it.",
  "urgency": "medium",
  "confidence": 0.9,
  "uncertainty_reason": ""
}

FIELD RULES:

primary_obstacle.type — pick the BEST match from this list:
PERSON, GROUP_OF_PEOPLE, CHILD, ANIMAL, CHAIR, TABLE, SOFA,
DESK, BED, DOOR_OPEN, DOOR_CLOSED, STAIRS_UP, STAIRS_DOWN,
STEP_UP, STEP_DOWN, WALL, PILLAR, GLASS_DOOR, VEHICLE,
BICYCLE, SHOPPING_CART, TROLLEY, WET_FLOOR, NARROW_PASSAGE,
COUNTER, SHELF, CLEAR

primary_obstacle.specifics — REQUIRED. Describe what you see
in 3-8 words. Be specific. Examples:
  "wooden office chair with wheels"
  "glass door partially open inward"
  "steep concrete staircase going down"
  "elderly man with walking frame"
  "low coffee table with sharp corners"
  "shopping trolley blocking left side"
  "sofa pushed against the wall"
  "large desk with computer monitor"
  "child running from left to right"
  "metal pillar in corridor center"
If you are truly unsure what it is, describe its shape/size:
  "large dark rectangular object"
  "small cylindrical object on floor"

primary_obstacle.position — left, center, or right

primary_obstacle.distance_estimate:
  "very close" = under 1 metre
  "close"      = 1 to 2 metres
  "nearby"     = 2 to 4 metres
  "ahead"      = 4 to 6 metres
  "far"        = over 6 metres

primary_obstacle.moving — true ONLY for people or animals
that appear to be actively walking or running

primary_obstacle.moving_direction — if moving is true:
  "toward you", "away from you",
  "crossing left to right", "crossing right to left"
  Otherwise: "stationary"

secondary_obstacles — other things visible that could
also be navigation hazards. Can be empty [].

environment.setting — 2-3 words describing the space:
  "home living room", "office corridor", "busy supermarket",
  "outdoor footpath", "stairwell", "restaurant", "classroom"

environment.crowding — "empty", "low", "moderate", "crowded"
environment.lighting — "dark", "dim", "adequate", "good", "bright"
environment.floor_hazards — true if cables, wet patches,
  uneven surface, steps, or anything to trip on
environment.narrow_passage — true if path is under 1 metre wide

navigation_instruction — THE MOST IMPORTANT FIELD.
Write one or two complete natural spoken sentences.
Rules:
- Use the actual object name from specifics
- Say where it is (left, right, ahead, center)
- Say how far (one metre, two metres, nearby, close)
- Say what to do (step left, move right, stop, slow down)
- Do NOT say "obstacle" or "object"
- Do NOT just say "move left" — explain why

GOOD examples:
"A wooden chair is directly ahead about one metre. Step to your
 left to walk around it."

"There are stairs going down directly ahead, about two metres
 away. Slow down and reach for the handrail on your right."

"A person is walking toward you from the center. Stop and wait
 for them to pass, then continue forward."

"A glass door is ahead on your left, about one metre. It appears
 partially open — you can pass through carefully."

"A low coffee table is on your right, close. Continue forward
 staying to the left."

BAD examples — never do this:
"Obstacle ahead, move left."
"Object detected nearby."
"Move right." (no context)
"Unknown obstacle ahead."

urgency:
  "critical" — stairs down, very close moving person, step down
  "high"     — approaching person, open door, step, close object
  "medium"   — furniture nearby, narrow passage, door closed
  "low"      — something far away, not blocking path

confidence: 0.0 to 1.0

uncertainty_reason: if confidence below 0.6, explain briefly.
Otherwise leave as empty string "".
''';

  Future<GateResult> runGate(Uint8List imageBytes) async {
    final sw = Stopwatch()..start();
    totalGateCalls++;
    try {
      final raw  = await _callApi(_gatePrompt, imageBytes);
      sw.stop();
      final json = _cleanAndParse(raw);
      _consecutiveFailures = 0;
      return GateResult(
        obstacleDetected: json['obstacle_detected'] as bool? ?? true,
        confidence:       ((json['confidence'] as num?) ?? 0.5).toDouble(),
        latencyMs:        sw.elapsedMilliseconds,
      );
    } catch (e) {
      sw.stop();
      _consecutiveFailures++;
      totalFailures++;
      lastError = e.toString();
      print('[gemini] Gate error (#$_consecutiveFailures): $e');
      return GateResult.error();
    }
  }

  Future<DetectionResult> classify(Uint8List imageBytes) async {
    final sw = Stopwatch()..start();
    totalClassifyCalls++;
    try {
      final raw  = await _callApi(_classifyPrompt, imageBytes);
      sw.stop();
      final json = _cleanAndParse(raw);
      _consecutiveFailures = 0;

      final primary = json['primary_obstacle'] as Map<String, dynamic>? ?? {};
      final label   = _parseLabel(primary['type'] as String? ?? 'UNKNOWN');
      final pos     = _parsePosition(
          primary['position'] as String? ?? 'unclear');

      final secondaryList = json['secondary_obstacles'] as List? ?? [];
      final secondaries   = secondaryList.map((s) {
        final m = s as Map<String, dynamic>;
        return SecondaryObstacle(
          type:             m['type']              as String? ?? 'UNKNOWN',
          position:         m['position']          as String? ?? 'unclear',
          distanceEstimate: m['distance_estimate'] as String? ?? 'nearby',
        );
      }).toList();

      final env     = json['environment'] as Map<String, dynamic>? ?? {};
      final envInfo = EnvironmentInfo(
        setting:       env['setting']        as String? ?? 'unknown',
        crowding:      env['crowding']       as String? ?? 'unknown',
        lighting:      env['lighting']       as String? ?? 'unknown',
        floorHazards:  env['floor_hazards']  as bool?   ?? false,
        narrowPassage: env['narrow_passage'] as bool?   ?? false,
      );

      // Ensure specifics is never empty — fall back to label name
      var specifics = primary['specifics'] as String? ?? '';
      if (specifics.trim().isEmpty) {
        specifics = _labelToSpecifics(label);
      }

      return DetectionResult(
        label:                 label,
        specifics:             specifics,
        position:              pos,
        distanceEstimate:      primary['distance_estimate']
                                   as String? ?? 'nearby',
        isMoving:              primary['moving']           as bool?   ?? false,
        movingDirection:       primary['moving_direction'] as String? ?? 'stationary',
        secondaryObstacles:    secondaries,
        environment:           envInfo,
        navigationInstruction: json['navigation_instruction']
                                   as String? ?? '',
        urgency:               json['urgency']             as String? ?? 'medium',
        confidence:            ((json['confidence'] as num?) ?? 0.0)
                                   .toDouble().clamp(0.0, 1.0),
        uncertaintyReason:     json['uncertainty_reason']  as String? ?? '',
        latencyMs:             sw.elapsedMilliseconds,
        success:               true,
        rawResponse:           raw,
      );

    } catch (e) {
      sw.stop();
      _consecutiveFailures++;
      totalFailures++;
      lastError = e.toString();
      print('[gemini] Classify error (#$_consecutiveFailures): $e');
      return DetectionResult.fallback(e.toString().substring(
          0, e.toString().length.clamp(0, 80)));
    }
  }

  /// Fallback specifics when Gemini returns empty — uses label name
  String _labelToSpecifics(ObstacleLabel label) {
    const m = {
      ObstacleLabel.person:          'person ahead',
      ObstacleLabel.group_of_people: 'group of people',
      ObstacleLabel.child:           'child ahead',
      ObstacleLabel.animal:          'animal ahead',
      ObstacleLabel.chair:           'chair blocking path',
      ObstacleLabel.table:           'table ahead',
      ObstacleLabel.sofa:            'sofa ahead',
      ObstacleLabel.desk:            'desk ahead',
      ObstacleLabel.bed:             'bed ahead',
      ObstacleLabel.door_open:       'open door',
      ObstacleLabel.door_closed:     'closed door',
      ObstacleLabel.stairs_up:       'stairs going up',
      ObstacleLabel.stairs_down:     'stairs going down',
      ObstacleLabel.step_up:         'step up',
      ObstacleLabel.step_down:       'step down',
      ObstacleLabel.wall:            'wall ahead',
      ObstacleLabel.pillar:          'pillar in path',
      ObstacleLabel.glass_door:      'glass door',
      ObstacleLabel.vehicle:         'vehicle nearby',
      ObstacleLabel.bicycle:         'bicycle in path',
      ObstacleLabel.shopping_cart:   'shopping trolley',
      ObstacleLabel.trolley:         'trolley blocking path',
      ObstacleLabel.wet_floor:       'wet floor area',
      ObstacleLabel.narrow_passage:  'narrow passage ahead',
      ObstacleLabel.counter:         'counter ahead',
      ObstacleLabel.shelf:           'shelf in path',
      ObstacleLabel.clear:           'clear path',
      ObstacleLabel.unknown:         'unidentified object',
    };
    return m[label] ?? 'object in path';
  }

  bool get hasConsecutiveFailures => _consecutiveFailures >= 3;
  int  get consecutiveFailures    => _consecutiveFailures;

  /// Validates an API key without sending an image or running generation.
  /// Returns `null` when the key is valid, otherwise a short, human-readable
  /// error message (never raw HTML).
  Future<String?> validateApiKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty || trimmed == AppConfig.placeholderKey) {
      return 'Please enter your API key first';
    }
    try {
      final response = await http.get(
        Uri.parse('${AppConfig.geminiModelsEndpoint}?key=$trimmed'),
        headers: {'Accept': 'application/json'},
      ).timeout(Duration(seconds: AppConfig.geminiTimeoutSecs));

      if (response.statusCode == 200) {
        _consecutiveFailures = 0;
        return null;
      }
      final msg = _humanError(response.statusCode, response.body);
      lastError = msg;
      return msg;
    } catch (e) {
      final msg = _humanError(null, e.toString());
      lastError = msg;
      return msg;
    }
  }

  /// Turns an HTTP/error body into a short, readable message.
  /// Extracts the Gemini JSON error message when present and never
  /// returns HTML markup (Google's error pages are HTML).
  String _humanError(int? statusCode, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map &&
          decoded['error'] is Map &&
          decoded['error']['message'] is String) {
        return decoded['error']['message'] as String;
      }
    } catch (_) {
      // body was not JSON (e.g. an HTML error page) — fall through
    }
    if (statusCode != null) {
      return 'Request failed (HTTP $statusCode).';
    }
    final oneLine = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length > 120
        ? '${oneLine.substring(0, 120)}…'
        : oneLine;
  }

  Future<String> _callApi(String prompt, Uint8List imageBytes) async {
    if (!AppConfig.isApiKeySet) {
      throw Exception('Gemini API key not set');
    }

    final body = jsonEncode({
      'contents': [{
        'parts': [
          {'text': prompt},
          {
            'inline_data': {
              'mime_type': 'image/jpeg',
              'data':      base64Encode(imageBytes),
            }
          }
        ]
      }],
      'generationConfig': {
        'temperature':     0.1,
        'maxOutputTokens': 1024,
        'topP':            0.8,
      },
      'safetySettings': [
        {
          'category':  'HARM_CATEGORY_DANGEROUS_CONTENT',
          'threshold': 'BLOCK_NONE',
        }
      ],
    });

    final response = await http.post(
      Uri.parse(
          '${AppConfig.geminiEndpoint}?key=${AppConfig.geminiApiKey}'),
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Accept':       'application/json',
      },
      body:    body,
    ).timeout(Duration(seconds: AppConfig.geminiTimeoutSecs));

    if (response.statusCode != 200) {
      throw Exception(_humanError(response.statusCode, response.body));
    }

    Map<String, dynamic> respJson;
    try {
      respJson = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('Unexpected non-JSON response from Gemini.');
    }

    // The whole prompt can be rejected before any candidate is produced.
    final feedback = respJson['promptFeedback'] as Map<String, dynamic>?;
    if (feedback != null && feedback['blockReason'] != null) {
      throw Exception('Request blocked: ${feedback['blockReason']}');
    }

    final candidates = respJson['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('No candidates in response');
    }

    final candidate = candidates[0] as Map<String, dynamic>;
    final content   = candidate['content'] as Map<String, dynamic>?;
    final parts     = content?['parts'] as List?;
    if (parts == null || parts.isEmpty) {
      final reason = candidate['finishReason'] ?? 'unknown';
      throw Exception('Empty response (finishReason: $reason)');
    }

    final text = parts[0]['text'] as String?;
    if (text == null) {
      throw Exception('Response contained no text');
    }
    return text.trim();
  }

  Map<String, dynamic> _cleanAndParse(String raw) {
    var clean = raw.trim();
    if (clean.startsWith('```')) {
      clean = clean
          .replaceAll(RegExp(r'^```json\s*', multiLine: true), '')
          .replaceAll(RegExp(r'^```\s*',      multiLine: true), '')
          .trim();
    }
    // Sometimes Gemini adds trailing text after the JSON — strip it
    final start = clean.indexOf('{');
    final end   = clean.lastIndexOf('}');
    if (start >= 0 && end > start) {
      clean = clean.substring(start, end + 1);
    }
    return jsonDecode(clean) as Map<String, dynamic>;
  }

  ObstacleLabel _parseLabel(String raw) {
    switch (raw.toUpperCase().trim()) {
      case 'PERSON':          return ObstacleLabel.person;
      case 'GROUP_OF_PEOPLE': return ObstacleLabel.group_of_people;
      case 'CHILD':           return ObstacleLabel.child;
      case 'ANIMAL':          return ObstacleLabel.animal;
      case 'CHAIR':           return ObstacleLabel.chair;
      case 'TABLE':           return ObstacleLabel.table;
      case 'SOFA':            return ObstacleLabel.sofa;
      case 'DESK':            return ObstacleLabel.desk;
      case 'BED':             return ObstacleLabel.bed;
      case 'DOOR_OPEN':       return ObstacleLabel.door_open;
      case 'DOOR_CLOSED':     return ObstacleLabel.door_closed;
      case 'STAIRS_UP':       return ObstacleLabel.stairs_up;
      case 'STAIRS_DOWN':     return ObstacleLabel.stairs_down;
      case 'STEP_UP':         return ObstacleLabel.step_up;
      case 'STEP_DOWN':       return ObstacleLabel.step_down;
      case 'WALL':            return ObstacleLabel.wall;
      case 'PILLAR':          return ObstacleLabel.pillar;
      case 'GLASS_DOOR':      return ObstacleLabel.glass_door;
      case 'VEHICLE':         return ObstacleLabel.vehicle;
      case 'BICYCLE':         return ObstacleLabel.bicycle;
      case 'SHOPPING_CART':   return ObstacleLabel.shopping_cart;
      case 'TROLLEY':         return ObstacleLabel.trolley;
      case 'WET_FLOOR':       return ObstacleLabel.wet_floor;
      case 'NARROW_PASSAGE':  return ObstacleLabel.narrow_passage;
      case 'COUNTER':         return ObstacleLabel.counter;
      case 'SHELF':           return ObstacleLabel.shelf;
      case 'CLEAR':           return ObstacleLabel.clear;
      default:                return ObstacleLabel.unknown;
    }
  }

  ObstaclePosition _parsePosition(String raw) {
    switch (raw.toLowerCase().trim()) {
      case 'left':   return ObstaclePosition.left;
      case 'center': return ObstaclePosition.center;
      case 'right':  return ObstaclePosition.right;
      default:       return ObstaclePosition.unclear;
    }
  }
}
