class UpdaterFailure implements Exception {
  const UpdaterFailure(this.code, {this.osError});
  final int? osError;
  final String code;
  @override
  String toString() =>
      'UpdaterFailure($code${osError == null ? '' : ', osError: $osError'})';
}

Never reject(String code, {int? osError}) =>
    throw UpdaterFailure(code, osError: osError);
