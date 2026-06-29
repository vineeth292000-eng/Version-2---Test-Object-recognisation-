import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  static String geminiApiKey = 'YOUR_GEMINI_API_KEY_HERE';
  static const String _placeholderKey = 'YOUR_GEMINI_API_KEY_HERE';

  static const String geminiEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent';

  // Safety distances (cm)
  static double criticalDistance = 40.0;
  static double dangerDistance   = 100.0;
  static double cautionDistance  = 180.0;

  // Pipeline timing
  static int frameIntervalMs    = 2500;
  static int geminiTimeoutSecs  = 8;

  // TTS cooldowns (ms)
  static const int ttsSameCueCooldownMs     = 4000;
  static const int ttsAnyCueCooldownMs      = 2000;
  static const int ttsSceneDescCooldownMs   = 1200;

  // Importance ranking thresholds
  static const int importanceHighMs    = 0;
  static const int importanceMediumMs  = 500;
  static const int importanceLowMs     = 1200;

  // Arduino serial
  static const int arduinoBaudRate = 9600;

  // Velocity tracking
  static const int velocityHistoryCount   = 5;
  static const double movingVelocityThreshold = 15.0;

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

  /// FIXED: compares against a separate placeholder constant, not itself.
  static bool get isApiKeySet =>
      geminiApiKey.isNotEmpty && geminiApiKey != _placeholderKey;

  /// NEW: call this once at app startup, before runApp().
  /// Restores anything the user saved in Settings, since previously
  /// nothing loaded SharedPreferences values back into AppConfig
  /// at launch — they were saved but never read back in.
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
