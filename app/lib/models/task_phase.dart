enum TaskPhase {
  pending,
  processing,
  cancelling,
  completed,
  failed,
  cancelled;

  /// Older engines report failure as "error" and use "status" instead of
  /// "task_status". Unknown states are not evidence that a worker has exited.
  static TaskPhase? fromWire(Object? value) {
    if (value == 'error') return failed;
    return values.where((phase) => phase.name == value).firstOrNull;
  }

  bool get terminal => this == completed || this == failed || this == cancelled;
}
