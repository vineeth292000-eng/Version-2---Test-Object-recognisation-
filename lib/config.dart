/// Central configuration for the NavAssist app.
/// API key and thresholds can be changed from the Settings screen
/// and are persisted in SharedPreferences.

class AppConfig {
  // ── CHANGE THIS to your Gemini API key ──────────────────────────────────
  // Get a free key at: https://aistudio.google.com
  // Free tier: 1,500 requests/day — more than enough for this project
  static String geminiApiKey = 'YOUR_GEMINI_API_KEY_HERE';
  // ────────────────────────────────────────────────────────────────────────

  // Gemini API endpoint
  static const String geminiEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent';

  // Safety distances (cm)
  static double criticalDistance = 40.0;   // STOP immediately — no AI
  static double dangerDistance   = 80.0;   // Run full AI cascade
  static double cautionDistance  = 150.0;  // Monitor but don't speak

  // Pipeline timing
  static int frameIntervalMs   = 500;   // Capture frame every 500ms
  static int geminiTimeoutSecs = 6;     // Gemini API timeout

  // Arduino serial
  static const int arduinoBaudRate = 9600;

  // Scene description trigger thresholds
  static const double sceneDescProximityThreshold = 120.0; // cm
  static const double sceneDescAmbiguousLow       = 0.35;  // gate confidence
  static const double sceneDescAmbiguousHigh      = 0.65;  // gate confidence
  static const int sceneDescStationarySeconds     = 4;     // seconds to detect stationary
  static const int sceneDescPeriodicSeconds       = 20;    // seconds between ambient calls

  // Whether API key has been configured
  static bool get isApiKeySet =>
      geminiApiKey.isNotEmpty && geminiApiKey != 'YOUR_GEMINI_API_KEY_HERE';
}
