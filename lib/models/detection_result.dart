enum ObstacleLabel {
  person,
  stairs_up,
  stairs_down,
  wall,
  door_open,
  door_closed,
  chair,
  table,
  clear,
  unknown,
}

enum ObstaclePosition { left, center, right, unclear }

enum CueSource { safety, sensor, gate, gemini }

/// Result from Stage 1 gate call
class GateResult {
  final bool obstacleDetected;
  final double confidence;
  final int latencyMs;

  const GateResult({
    required this.obstacleDetected,
    required this.confidence,
    required this.latencyMs,
  });

  factory GateResult.error() => const GateResult(
    obstacleDetected: true,   // Assume obstacle on error (safe default)
    confidence: 0.0,
    latencyMs: 0,
  );
}

/// Result from Stage 2 full classification call
class DetectionResult {
  final ObstacleLabel label;
  final ObstaclePosition position;
  final double confidence;
  final String uncertaintyReason;
  final String recommendedAction;
  final int latencyMs;
  final bool success;
  final String rawResponse;

  const DetectionResult({
    required this.label,
    required this.position,
    required this.confidence,
    required this.uncertaintyReason,
    required this.recommendedAction,
    required this.latencyMs,
    required this.success,
    required this.rawResponse,
  });

  factory DetectionResult.fallback(String reason) => DetectionResult(
    label: ObstacleLabel.unknown,
    position: ObstaclePosition.unclear,
    confidence: 0.0,
    uncertaintyReason: reason,
    recommendedAction: 'stop',
    latencyMs: 0,
    success: false,
    rawResponse: '',
  );

  String get labelDisplay =>
      label.name.replaceAll('_', ' ').toUpperCase();
}

/// Final navigation cue combining AI + sensors
class NavCue {
  final String text;
  final CueSource source;
  final String direction;
  final String obstacleLabel;
  final DateTime timestamp;
  final int totalLatencyMs;
  final String? sceneDescription;      // ADD THIS
  final String? sceneDescTrigger;      // ADD THIS — which parameter triggered it

  const NavCue({
    required this.text,
    required this.source,
    required this.direction,
    required this.obstacleLabel,
    required this.timestamp,
    required this.totalLatencyMs,
    this.sceneDescription,             // ADD THIS
    this.sceneDescTrigger,             // ADD THIS
  });
}
