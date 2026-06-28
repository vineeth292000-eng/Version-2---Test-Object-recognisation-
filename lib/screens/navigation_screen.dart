Row(
  mainAxisAlignment: MainAxisAlignment.spaceAround,
  children: [
    Text(
      'Frame: ${_lastFrameBytes}B'
      '${_lastFrameTime != null ? " @${_lastFrameTime!.second}s" : ""}',
      style: TextStyle(
        fontSize: 12,
        color: _lastFrameBytes > 0 ? Colors.green : Colors.red,
      ),
    ),
    Text(
      'Cam err: ${_camera.errorCount}  '
      'overlap: ${_camera.skippedOverlapCount}',
      style: TextStyle(
        fontSize: 12,
        color: (_camera.errorCount + _camera.skippedOverlapCount) > 0
            ? Colors.orange
            : Colors.grey,
      ),
    ),
  ],
),
