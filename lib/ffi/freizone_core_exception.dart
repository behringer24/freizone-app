/// Thrown when a native core call returns `{"ok": false, "error": "..."}`.
class FreizoneCoreException implements Exception {
  FreizoneCoreException(this.message);

  final String message;

  @override
  String toString() => 'FreizoneCoreException: $message';
}
