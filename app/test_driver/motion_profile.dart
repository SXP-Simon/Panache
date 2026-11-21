import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    await writeResponseData(data, testOutputFilename: 'workbench_motion');
    // Read the VM's existing ring buffer after the measured actions finish.
    final trace = Platform.environment['PANACHE_MOTION_TIMELINE'];
    if (trace == null) return;
    final service = Uri.parse(Platform.environment['VM_SERVICE_URL']!);
    final client = HttpClient();
    try {
      final url = service.replace(
        scheme: service.scheme == 'ws' ? 'http' : service.scheme,
        path: service.path.replaceFirst(
          RegExp(r'(?:/ws)?/?$'),
          '/getVMTimeline',
        ),
      );
      final result = await (await client.getUrl(url)).close();
      if (result.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Timeline request returned ${result.statusCode}',
          uri: url,
        );
      }
      await result.pipe(File(trace).openWrite());
    } finally {
      client.close(force: true);
    }
  },
);
