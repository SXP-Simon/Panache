import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/models/detected_paper_layout.dart';

void main() {
  test('legacy top lines and corrected dimensions use the detector coordinate system', () {
    final layout = DetectedPaperLayout.fromJson({
      'lineSpacing': 9,
      'marginTop': 21,
      'marginBottom': 19,
      'marginLeft': 50,
      'marginRight': 35,
      'imageWidth': 300,
      'imageHeight': 200,
    });
    expect(layout.scaledTo(300, 200), same(layout));
    final settings = layout.scaledTo(160, 91).settings('4');
    expect(settings, {
      'width': '160',
      'height': '91',
      'top_margin': '5',
      'bottom_margin': '9',
      'left_margin': '27',
      'right_margin': '19',
      'line_spacing': '4',
      'font_size': '3',
    });
  });
}
