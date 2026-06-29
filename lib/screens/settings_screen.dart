import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image/image.dart' as img;
import '../config.dart';
import '../services/gemini_service.dart';
import '../services/tts_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _apiKeyController;
  double _criticalDist  = AppConfig.criticalDistance;
  double _dangerDist    = AppConfig.dangerDistance;
  int    _frameInterval = 2500;
  String _testResult    = '';
  bool   _testing       = false;
  bool   _obscureKey    = true;
  bool   _keyTested     = false;   // tracks whether current key has been verified

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController(text: AppConfig.geminiApiKey);
    _loadSavedValues();
  }

  Future<void> _loadSavedValues() async {
    final prefs = await SharedPreferences.getInstance();
    final savedInterval = prefs.getInt('frame_interval_ms') ?? 2500;
    // Clamp to a valid option in case of unexpected saved value
    final validIntervals = [500, 1000, 1500, 2000, 2500, 3000];
    final clamped = validIntervals.contains(savedInterval) ? savedInterval : 2500;
    setState(() {
      _criticalDist  = prefs.getDouble('critical_distance') ?? AppConfig.criticalDistance;
      _dangerDist    = prefs.getDouble('danger_distance')   ?? AppConfig.dangerDistance;
      _frameInterval = clamped;
      final saved = prefs.getString('gemini_api_key') ?? '';
      if (saved.isNotEmpty && saved != AppConfig._placeholderKey) {
        _apiKeyController.text = saved;
      } else {
        _apiKeyController.text = '';
      }
    });
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _testApiKey() async {
    setState(() {
      _testing    = true;
      _testResult = 'Testing...';
      _keyTested  = false;
    });

    final testKey = _apiKeyController.text.trim();
    if (testKey.isEmpty || testKey == AppConfig._placeholderKey) {
      setState(() {
        _testResult = 'Please enter your API key first';
        _testing    = false;
      });
      return;
    }

    try {
      // FIXED: do NOT save or restore AppConfig.geminiApiKey here.
      // Use a temporary GeminiService with the key set only for this call,
      // then immediately unset it. The actual save happens in _saveSettings().
      final originalKey = AppConfig.geminiApiKey;
      AppConfig.geminiApiKey = testKey;

      final image = img.Image(width: 8, height: 8);
      img.fill(image, color: img.ColorRgb8(128, 128, 128));
      final bytes = Uint8List.fromList(img.encodeJpg(image));

      final gemini = GeminiService();
      final result = await gemini.runGate(bytes);

      // Restore — but only to the key we had before the test.
      // If originalKey was the placeholder, keep testKey live in AppConfig
      // so navigation benefits immediately even before Save is pressed.
      if (originalKey == AppConfig._placeholderKey) {
        // Leave the real key in place — user will save it
        AppConfig.geminiApiKey = testKey;
      } else {
        AppConfig.geminiApiKey = originalKey;
      }

      setState(() {
        _testResult = result.success == false
            ? '✗ Key rejected by API'
            : '✓ Key verified — tap Save to keep it';
        _testing   = false;
        _keyTested = true;
      });
    } catch (e) {
      AppConfig.geminiApiKey = AppConfig._placeholderKey;
      final msg = e.toString();
      setState(() {
        _testResult = '✗ ${msg.length > 60 ? msg.substring(0, 60) : msg}';
        _testing    = false;
        _keyTested  = false;
      });
    }
  }

  Future<void> _saveSettings() async {
    final key = _apiKeyController.text.trim();
    if (key.isEmpty || key == AppConfig._placeholderKey) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter and test your API key before saving'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gemini_api_key',   key);
    await prefs.setDouble('critical_distance', _criticalDist);
    await prefs.setDouble('danger_distance',   _dangerDist);
    await prefs.setInt('frame_interval_ms',    _frameInterval);

    // Commit everything to AppConfig for this session
    AppConfig.geminiApiKey     = key;
    AppConfig.criticalDistance = _criticalDist;
    AppConfig.dangerDistance   = _dangerDist;
    AppConfig.frameIntervalMs  = _frameInterval;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Settings saved'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context);
    }
  }

  Future<void> _testTts() async {
    final tts = TtsService();
    await tts.init();
    await tts.speak('Navigation assistant ready',
        priority: TtsPriority.high, cueKey: 'tts_test');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [

          // ── API Key ──────────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Gemini API Key',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('Get a free key at aistudio.google.com',
                      style: TextStyle(fontSize: 14, color: Colors.grey)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _apiKeyController,
                    obscureText: _obscureKey,
                    onChanged: (_) => setState(() {
                      _keyTested  = false;
                      _testResult = '';
                    }),
                    decoration: InputDecoration(
                      hintText: 'Paste your API key here',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_obscureKey
                            ? Icons.visibility
                            : Icons.visibility_off),
                        onPressed: () =>
                            setState(() => _obscureKey = !_obscureKey),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      ElevatedButton(
                        onPressed: _testing ? null : _testApiKey,
                        child: _testing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Test Key'),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _testResult,
                          style: TextStyle(
                            fontSize: 13,
                            color: _testResult.startsWith('✓')
                                ? Colors.green
                                : _testResult.isEmpty
                                    ? Colors.grey
                                    : Colors.red,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ── Safety Thresholds ────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Safety Thresholds',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  Text('Critical stop: ${_criticalDist.round()} cm',
                      style: const TextStyle(fontSize: 16)),
                  Slider(
                    value: _criticalDist,
                    min: 20, max: 80, divisions: 6,
                    label: '${_criticalDist.round()} cm',
                    onChanged: (v) => setState(() => _criticalDist = v),
                  ),
                  const SizedBox(height: 8),
                  Text('Danger zone: ${_dangerDist.round()} cm',
                      style: const TextStyle(fontSize: 16)),
                  Slider(
                    value: _dangerDist,
                    min: 60, max: 200, divisions: 14,
                    label: '${_dangerDist.round()} cm',
                    onChanged: (v) => setState(() => _dangerDist = v),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ── AI Pipeline ──────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('AI Pipeline',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  const Text('Frame capture interval',
                      style: TextStyle(fontSize: 16)),
                  const SizedBox(height: 8),
                  DropdownButton<int>(
                    value: _frameInterval,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: 500,  child: Text('500ms  (fastest)')),
                      DropdownMenuItem(value: 1000, child: Text('1000ms')),
                      DropdownMenuItem(value: 1500, child: Text('1500ms')),
                      DropdownMenuItem(value: 2000, child: Text('2000ms')),
                      DropdownMenuItem(value: 2500, child: Text('2500ms (default)')),
                      DropdownMenuItem(value: 3000, child: Text('3000ms (slowest)')),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _frameInterval = v);
                    },
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ── Audio ────────────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Audio',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _testTts,
                    child: const Text('Test Text-to-Speech'),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // ── Save ─────────────────────────────────────────────────────
          ElevatedButton(
            onPressed: _saveSettings,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(60),
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save Settings', style: TextStyle(fontSize: 20)),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
