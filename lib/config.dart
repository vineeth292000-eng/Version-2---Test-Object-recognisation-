import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  static String geminiApiKey = 'YOUR_GEMINI_API_KEY_HERE';
  static const String placeholderKey = 'YOUR_GEMINI_API_KEY_HERE';

  // Gemini REST API. The v1beta surface is the one documented for
  // gemini-2.0-flash with inline image input, and it is what the
  // official AI Studio keys are issued against.
  static const String geminiApiBase =
      'https://generativelanguage.googleapis.com/v1beta';
  static const String geminiModel = 'gemini-2.0-flash';

  static String get geminiEndpoint =>
      '$geminiApiBase/models/$geminiModel:generateContent';

  // Lightweight endpoint used purely to validate an API key — no image,
  // no generation, so it can never fail for content/safety reasons.
  static String get geminiModelsEndpoint => '$geminiApiBase/models';

  // Safety distances (cm)
  static double criticalDistance = 40.0;
  static double dangerDistance   = 100.0;
  static double cautionDistance  = 180.0;

  // Pipeline timing
  static int frameIntervalMs    = 2500;
  static int geminiTimeoutSecs  = 12;  // slightly more headroom for 2.0-flash

  // TTS cooldowns (ms). Tuned calmer for cramped indoor spaces where
  // almost everything is within caution range — avoids talking nonstop.
  static const int ttsSameCueCooldownMs     = 7000;  // repeat the same state
  static const int ttsAnyCueCooldownMs      = 3000;  // gap between any cues
  static const int ttsSceneDescCooldownMs   = 1200;
  static const int ttsUrgentRepeatMs        = 3000;  // re-issue a stop cue
  // Re-announce an unchanged sensor situation only this often.
  static const int sensorCueRefreshMs       = 8000;

  // Importance ranking thresholds
  static const int importanceHighMs    = 0;
  static const int importanceMediumMs  = 500;
  static const int importanceLowMs     = 1200;

  // Arduino serial
  static const int arduinoBaudRate = 9600;

  // Velocity tracking
  static const int velocityHistoryCount        = 5;
  static const double movingVelocityThreshold  = 15.0;

  // Scene description triggers
  static const double sceneDescProximityThreshold  = 150.0;
  static const double sceneDescAmbiguousLow        = 0.35;
  static const double sceneDescAmbiguousHigh       = 0.65;
  static const int    sceneDescStationarySeconds   = 5;
  static const int    sceneDescPeriodicSeconds     = 25;
  static const int    sceneDescMinGapSeconds       = 5;
  static const int    sceneDescCrowdedMinGap       = 18;
  static const int    sceneDescComplexMinGap       = 30;
  static const double complexSceneMultiObstacleCount = 2;
  static const int    complexSceneNarrowCm           = 80;

  static bool get isApiKeySet =>
      geminiApiKey.isNotEmpty && geminiApiKey != placeholderKey;

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    final savedKey = prefs.getString('gemini_api_key');
    if (savedKey != null && savedKey.trim().isNotEmpty) {
      geminiApiKey = savedKey.trim();
    }

    final savedCritical = prefs.getDouble('critical_distance');
    if (savedCritical != null) criticalDistance = savedCritical;

    final savedDanger = prefs.getDouble('danger_distance');
    if (savedDanger != null) dangerDistance = savedDanger;

    final savedFrameInterval = prefs.getInt('frame_interval_ms');
    if (savedFrameInterval != null) frameIntervalMs = savedFrameInterval;
  }
}
