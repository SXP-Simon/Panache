abstract interface class TextPreparationJob {
  Future<String> get result;
  Future<void> cancel();
}

class TextPreparationCancelled implements Exception {
  const TextPreparationCancelled();
}
