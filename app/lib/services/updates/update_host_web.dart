import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import 'update_model.dart';
import 'update_deployment.dart';

UpdateHost createUpdateHost() => BrowserUpdateHost();

class BrowserUpdateHost implements UpdateHost {
  @override
  Future<InstalledApp> installed() async => const InstalledApp(
    String.fromEnvironment('PANACHE_APP_VERSION'),
    UpdateTarget('web', ''),
  );
  @override
  Future<DeployedApp?> deployedVersion() async {
    final client = http.Client();
    try {
      return await loadDeployedVersion(
        client,
        deployedVersionUri(Uri.parse(web.document.baseURI), Uri.base),
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<String> download(
    VerifiedPackage package,
    DownloadCancellation cancellation,
    void Function(int, int) progress,
  ) async => throw const UpdateException(UpdateProblem.unsupportedPlatform);
  @override
  Future<void> open(String path, int buildNumber) async =>
      throw const UpdateException(UpdateProblem.unsupportedPlatform);
  @override
  void reload() => web.window.location.reload();
}
