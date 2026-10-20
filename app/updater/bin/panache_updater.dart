import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:panache_updater/installation.dart';
import 'package:panache_updater/protocol.dart';
import 'package:panache_updater/platform_files.dart';
import 'package:panache_updater/transaction.dart';

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.length == 1 && arguments.single == '--self-check') {
      stdout.writeln('PANACHE_UPDATER_PROTOCOL 1');
      return;
    }
    if (arguments.isEmpty && Platform.isWindows) {
      await launchWindows(p.dirname(Platform.resolvedExecutable));
      return;
    }
    if (arguments.length != 3 ||
        !{'--prepare', '--recover'}.contains(arguments[0])) {
      reject('invalid_arguments');
    }
    requireUnprivilegedProcess();
    final directory = p.normalize(p.absolute(arguments[1])),
        token = arguments[2];
    final plan = UpdatePlan.read(directory, token);
    final transaction = UpdateTransaction(directory, plan);
    final recovering = arguments[0] == '--recover';

    try {
      if (recovering) {
        transaction.prepareRecovery();
      } else {
        await transaction.prepare();
      }
      stdout.writeln('PANACHE_UPDATE_READY $token');
      await stdout.flush();
      var armed = false, aborted = false;
      await for (final line
          in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line == 'ARM $token') {
          armed = true;
        } else {
          aborted = true;
          break;
        }
      }
      if (!armed || aborted) {
        if (recovering) {
          transaction.cancelRecovery();
        } else {
          await transaction.abort();
        }
        return;
      }
      if (recovering) {
        await transaction.recover();
      } else {
        await transaction.applyAfterExit();
      }
      exit(0);
    } catch (error) {
      final reason = error is UpdaterFailure ? error.code : 'update_failed';
      try {
        File(p.join(directory, 'update.log')).writeAsStringSync(
          '${DateTime.now().toUtc().toIso8601String()} failure $error\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (_) {
        /* Recovery remains mandatory when diagnostics cannot be written. */
      }
      if (recovering) {
        transaction.cancelRecovery();
      } else if (transaction.ownsInstallation &&
          (transaction.parentConfirmedExited || transaction.isApplied())) {
        await transaction.rollback(reason);
      } else {
        await transaction.abort();
      }
      rethrow;
    }
  } catch (error) {
    if (error is UpdaterFailure && error.osError != null) {
      stderr.writeln('PANACHE_UPDATE_OS_ERROR ${error.code} ${error.osError}');
    }
    stderr.writeln(
      'PANACHE_UPDATE_ERROR ${error is UpdaterFailure ? error.code : 'update_failed'}',
    );
    exit(1);
  }
}
