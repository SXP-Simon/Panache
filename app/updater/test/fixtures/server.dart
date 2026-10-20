import 'dart:io';

Future<void> main() async {
  stdout.writeln('READY');
  await stdin.drain<void>();
}
