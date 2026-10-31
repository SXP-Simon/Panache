/// Transport-independent failure information exposed to task state and UI.
class EngineFailure implements Exception {
  const EngineFailure(this.message, {this.code, this.retryAfterSeconds});
  final String message;
  final String? code;
  final int? retryAfterSeconds;

  @override
  String toString() => message;
}
