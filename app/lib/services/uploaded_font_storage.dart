import 'font_storage_contract.dart';
import 'uploaded_font_storage_native.dart'
    if (dart.library.js_interop) 'uploaded_font_storage_web.dart'
    as platform;

export 'font_storage_contract.dart';

UploadedFontStorage createUploadedFontStorage() => platform.FontStorage();
