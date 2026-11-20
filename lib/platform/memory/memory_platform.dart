abstract class MemoryPlatform {
  static MemoryPlatform create() => NoopMemoryPlatform();
  void listen(Future<bool> Function(bool kill) handler);
  void dispose();
  Future<String?> readRecovery();
  Future<void> writeRecovery(String content);
  Future<void> clearRecovery();
}

class NoopMemoryPlatform implements MemoryPlatform {
  @override
  void listen(Future<bool> Function(bool kill) handler) {}
  @override
  void dispose() {}
  @override
  Future<String?> readRecovery() async => null;
  @override
  Future<void> writeRecovery(String content) async {
    throw UnsupportedError('Memory recovery is unavailable on this platform');
  }

  @override
  Future<void> clearRecovery() async {}
}
