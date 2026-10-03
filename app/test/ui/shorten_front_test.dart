import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';

void main() {
  const style = TextStyle(fontSize: 12, fontFamily: 'Ahem');
  // Ahem is one em wide per glyph: 12 px per character.
  double w(String s) => s.length * 12.0;

  test('a path that fits is untouched', () {
    expect(shortenFront('/a/b/c.go', 200, style, TextScaler.noScaling), '/a/b/c.go');
  });

  test('a long path loses its beginning, keeps its end, and fits', () {
    const path = '/Users/maya/code/payments-api/services/ledger/';
    final out = shortenFront(path, 220, style, TextScaler.noScaling);
    expect(out.startsWith('…'), isTrue);
    expect(out.endsWith('ledger/'), isTrue);
    expect(w(out), lessThanOrEqualTo(220));
  });

  test('cuts at a separator when one is near, so no folder name is torn', () {
    const path = '/home/dev/projects/some-long-project-name/src/';
    final out = shortenFront(path, 200, style, TextScaler.noScaling);
    expect(out.substring(1).startsWith('/'), isTrue, reason: out);
  });

  test('an unbounded width never shortens', () {
    expect(shortenFront('/a/b', double.infinity, style, TextScaler.noScaling), '/a/b');
  });
}
