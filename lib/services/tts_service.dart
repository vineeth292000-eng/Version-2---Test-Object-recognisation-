import 'package:flutter_tts/flutter_tts.dart';
import '../config.dart';

enum TtsPriority { critical, high, medium, low }

class _TtsQueueItem {
  final String text;
  final TtsPriority priority;
  final int delayMs;
  final String cueKey;
  _TtsQueueItem(this.text, this.priority, this.delayMs, this.cueKey);
}

class TtsService {
  final FlutterTts _tts = FlutterTts();

  bool _ready = false;
  bool _speaking = false;
  TtsPriority? _currentPriority;
  String? _lastCueKey;
  DateTime _lastSpokeForKey = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastSpokeAny    = DateTime.fromMillisecondsSinceEpoch(0);

  int totalSpoken       = 0;
  int duplicatesSkipped = 0;
  int cooldownSkipped   = 0;
  int urgentSpoken      = 0;
  int interruptedCount  = 0;

  final List<_TtsQueueItem> _queue = [];

  bool get isSpeaking => _speaking;
  TtsPriority? get currentPriority => _currentPriority;

  Future<void> init() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.44);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(false);

    _tts.setCompletionHandler(() {
      _speaking = false;
      _currentPriority = null;
      _processQueue();
    });

    _ready = true;
  }

  /// Speak [text]. [cueKey] identifies the *meaning* of the cue
  /// (e.g. "sensor_center_b1", "gemini_chair_center_b0") so that small
  /// changes in the spoken sentence — like a fluctuating cm reading —
  /// don't bypass dedup/cooldown. Defaults to [text] if omitted.
  Future<void> speak(
    String text, {
    TtsPriority priority = TtsPriority.medium,
    String? cueKey,
  }) async {
    if (!_ready) await init();
    final key = cueKey ?? text;
    final now = DateTime.now();

    // Minimum gap between ANY two cues, scaled by priority.
    final minGapMs = _minGapForPriority(priority);
    if (now.difference(_lastSpokeAny).inMilliseconds < minGapMs) {
      cooldownSkipped++;
      return;
    }

    // Same meaning spoken too recently — skip.
    if (key == _lastCueKey &&
        now.difference(_lastSpokeForKey).inMilliseconds 
            AppConfig.ttsSameCueCooldownMs) {
      duplicatesSkipped++;
      return;
    }

    final outranksCurrent = _currentPriority == null ||
        priority.index < _currentPriority!.index;

    if (_speaking && !outranksCurrent) {
      _queue.removeWhere((item) =>
          item.priority == TtsPriority.low ||
          item.priority == TtsPriority.medium);
      _queue.add(_TtsQueueItem(text, priority, 0, key));
      _queue.sort((a, b) => a.priority.index.compareTo(b.priority.index));
      return;
    }

    if (_speaking && outranksCurrent) {
      interruptedCount++;
      _queue.clear();
      await _tts.stop();
      _speaking = false;
    }

    final delayMs = switch (priority) {
      TtsPriority.critical => AppConfig.importanceHighMs,
      TtsPriority.high     => AppConfig.importanceHighMs,
      TtsPriority.medium   => AppConfig.importanceMediumMs,
      TtsPriority.low      => AppConfig.importanceLowMs,
    };

    _queue.add(_TtsQueueItem(text, priority, delayMs, key));
    _queue.sort((a, b) => a.priority.index.compareTo(b.priority.index));

    if (!_speaking) _processQueue();
  }

  int _minGapForPriority(TtsPriority p) {
    switch (p) {
      case TtsPriority.critical: return 0;
      case TtsPriority.high:     return 1200;
      case TtsPriority.medium:   return AppConfig.ttsAnyCueCooldownMs;
      case TtsPriority.low:      return AppConfig.ttsAnyCueCooldownMs;
    }
  }

  void _processQueue() async {
    if (_queue.isEmpty || _speaking) return;

    final item = _queue.removeAt(0);
    _speaking         = true;
    _currentPriority  = item.priority;
    _lastCueKey       = item.cueKey;
    _lastSpokeForKey  = DateTime.now();
    _lastSpokeAny     = DateTime.now();
    totalSpoken++;

    if (item.delayMs > 0) {
      await Future.delayed(Duration(milliseconds: item.delayMs));
    }

    await _tts.speak(item.text);
  }

  /// Speak immediately for safety-critical "stop" events.
  /// Will NOT restart itself if a critical message is already
  /// mid-utterance — lets it finish instead of looping forever.
  Future<void> speakUrgent(
    String text, {
    String cueKey = 'critical_stop',
  }) async {
    if (!_ready) await init();

    if (_speaking && _currentPriority == TtsPriority.critical) {
      // Already mid-"stop" — don't cut it off and restart.
      return;
    }

    _queue.clear();
    urgentSpoken++;
    totalSpoken++;
    await _tts.stop();
    _speaking        = true;
    _currentPriority = TtsPriority.critical;
    _lastCueKey      = cueKey;
    _lastSpokeForKey = DateTime.now();
    _lastSpokeAny    = DateTime.now();
    await _tts.speak(text);
  }

  Future<void> stop() async {
    _queue.clear();
    _speaking = false;
    _currentPriority = null;
    await _tts.stop();
  }

  void dispose() {
    _queue.clear();
    _tts.stop();
  }

  Map<String, int> get stats => {
    'total_spoken':       totalSpoken,
    'duplicates_skipped': duplicatesSkipped,
    'cooldown_skipped':   cooldownSkipped,
    'urgent_spoken':      urgentSpoken,
    'interrupted':        interruptedCount,
  };
}
