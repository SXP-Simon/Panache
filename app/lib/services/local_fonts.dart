import 'dart:convert';

import 'api.dart';

enum LocalFontSource { system, user }

typedef LocalFont = ({String id, String name, String filename});

typedef LocalFontPage = ({
  List<LocalFont> fonts,
  int? nextOffset,
  String directory,
});

extension LocalFonts on HandwritingApi {
  Future<LocalFontPage> listLocalFonts({
    required LocalFontSource source,
    required String query,
    int offset = 0,
    bool refresh = false,
  }) async {
    final response = await checked(
      client.post(
        uri('/api/local_fonts'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'source': source.name,
          'query': query,
          'offset': offset,
          'limit': 30,
          'refresh': refresh,
        }),
      ),
    );
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    return (
      fonts: [
        for (final row in data['fonts'] as List)
          (
            id: row['id'] as String,
            name: row['name'] as String,
            filename: row['filename'] as String,
          ),
      ],
      nextOffset: data['next_offset'] as int?,
      directory: data['user_dir'] as String,
    );
  }

  Future<Upload> readLocalFont(LocalFont font) async {
    final response = await checked(
      client.post(
        uri('/api/local_fonts/read'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'id': font.id}),
      ),
    );
    return Upload(font.filename, response.bodyBytes);
  }
}
