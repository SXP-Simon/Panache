import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerBundledLicenses() {
  LicenseRegistry.addLicense(() async* {
    const licenses = {
      'handwriting-web': 'project-MIT.txt',
      'handright / handwriting-core': 'handright-BSD-3-Clause.txt',
      '霞鹜文楷 / LXGW WenKai': 'lxgw-wenkai-OFL.txt',
      '霞鹜漫黑 / LXGW Marker Gothic': 'lxgw-marker-gothic-OFL.txt',
      '悠哉手写体 / Yozai': 'yozai-OFL.txt',
      '志莽行书 / Zhi Mang Xing': 'zhimangxing-OFL.txt',
    };
    for (final entry in licenses.entries) {
      var text = await rootBundle.loadString(
        'packages/handwriting_assets/licenses/${entry.value}',
      );
      if (entry.value == 'handright-BSD-3-Clause.txt') {
        final notice = await rootBundle.loadString(
          'packages/handwriting_assets/licenses/handright-NOTICE.txt',
        );
        text = '$notice\n$text';
      }
      yield LicenseEntryWithLineBreaks([entry.key], text);
    }
  });
}
