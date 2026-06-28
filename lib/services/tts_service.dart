import 'package:flutter_tts/flutter_tts.dart';
import '../config.dart';

enum TtsPriority { critical, high, medium, low }

class _TtsQueueItem {
  final String      text;
  final TtsPriority priority;
  final int         delayMs;
  _TtsQueueItem(this.text, this.priority, this.delayMs);
}

class TtsService {
  final FlutterTts _tts = FlutterTts();

  bool     _ready     = false;
  bool     _speaking  = false;
  String?  _lastText;
  DateTime _lastSpoke = DateTime.fromMillisecondsSinceEpoch(0);

  // Stats
  int totalSpoken    = 0;
  int duplicatesSkipped = 0;
  int cooldownSkipped   = 0;
  int urgentSpoken   = 0;

  final List<_TtsQueueItem> _queue = [];

  Future<void> init() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.44);   // slightly slower for clarity
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(false);

    _tts.setCompletionHandler(() {
      _speaking = false;
      _processQueue();
    });

    _ready = true;
  }

  /// Speak with priority and cooldown logic.
  /// High priority speaks sooner, low priority may be skipped if something
  /// more important is already queued.
  Future<void> speak(
    String text, {
    TtsPriority priority = TtsPriority.medium,
  }) async {
    if (!_ready) await init();

    final now     = DateTime.now();
    final elapsed = now.difference(_lastSpoke).inMilliseconds;

    // Skip exact duplicate within cooldown window
    if (text == _lastText &&
        elapsed < AppConfig.ttsSameCueCooldownMs) {
      duplicatesSkipped++;
      return;
    }

    // Skip any cue if minimum gap not met (except high/critical)
    if (priority == TtsPriority.low || priority == TtsPriority.medium) {
      if (elapsed < AppConfig.ttsAnyCueCooldownMs) {
        cooldownSkipped++;
        return;
      }
    }

    // Drop low priority items from queue if a higher one comes in
    if (priority == TtsPriority.high || priority == TtsPriority.critical) {
      _queue.removeWhere((item) =>
          item.priority == TtsPriority.low ||
          item.priority == TtsPriority.medium);
    }

    int delayMs = 0;
    switch (priority) {
      case TtsPriority.critical: delayMs = AppConfig.importanceHighMs;   break;
      case TtsPriority.high:     delayMs = AppConfig.importanceHighMs;   break;
      case TtsPriority.medium:   delayMs = AppConfig.importanceMediumMs; break;
      case TtsPriority.low:      delayMs = AppConfig.importanceLowMs;    break;
    }

    _queue.add(_TtsQueueItem(text, priority, delayMs));

    // Sort queue so highest priority speaks first
    _queue.sort((a, b) => a.priority.index.compareTo(b.priority.index));

    if (!_speaking) _processQueue();
  }

  void _processQueue() async {
    if (_queue.isEmpty || _speaking) return;

    final item = _queue.removeAt(0);
    _speaking  = true;
    _lastText  = item.text;
    _lastSpoke = DateTime.now();
    totalSpoken++;

    if (item.delayMs > 0) {
      await Future.delayed(Duration(milliseconds: item.delayMs));
    }

    await _tts.stop();
    await _tts.speak(item.text);
  }

  /// Speak immediately, interrupt everything. For STOP / safety only.
  Future<void> speakUrgent(String text) async {
    if (!_ready) await init();
    _queue.clear();
    _speaking  = false;
    urgentSpoken++;
    totalSpoken++;
    await _tts.stop();
    await _tts.speak(text);
    _lastText  = text;
    _lastSpoke = DateTime.now();
  }

  Future<void> stop() async {
    _queue.clear();
    _speaking = false;
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
  };
}


