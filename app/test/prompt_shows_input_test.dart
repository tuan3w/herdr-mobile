import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/observed_session.dart';

void main() {
  group('promptShowsInput', () {
    test('a dialog that shows the call\'s command is that call, whatever the wrapping', () {
      expect(promptShowsInput('git status\n  --short', {'command': 'git status --short', 'description': 'x'}), isTrue);
    });

    test('Codex draws a command as `\$ cmd`', () {
      expect(promptShowsInput(r'$ curl -sI https://example.com | head -1', {'command': 'curl -sI https://example.com | head -1'}), isTrue);
    });

    test('a cut command is the start of a longer one, but a longer dialog than the call is another call', () {
      expect(promptShowsInput('npm run build…', {'command': 'npm run build --prod'}), isTrue);
      expect(promptShowsInput('npm run build --prod now', {'command': 'npm run build --prod'}), isFalse);
      expect(promptShowsInput('rm -rf a', {'command': 'rm -rf b'}), isFalse);
    });
  });
}
