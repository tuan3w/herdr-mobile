import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/auth_notice.dart';

void main() {
  group('approvalUrlFrom', () {
    test('finds the link in a real Tailscale SSH check banner', () {
      const banner = '# Tailscale SSH requires an additional check.\n'
          '# To authenticate, visit: https://login.tailscale.com/a/l3503a0535f1bf\n';

      expect(approvalUrlFrom(banner), 'https://login.tailscale.com/a/l3503a0535f1bf');
    });

    test('drops sentence punctuation that follows the link', () {
      expect(approvalUrlFrom('visit https://login.tailscale.com/a/abc.'),
          'https://login.tailscale.com/a/abc');
      expect(approvalUrlFrom('(see https://login.tailscale.com/a/abc)'),
          'https://login.tailscale.com/a/abc');
    });

    test('keeps a query string', () {
      expect(approvalUrlFrom('https://login.example.com/a/b?x=1&y=2'),
          'https://login.example.com/a/b?x=1&y=2');
    });

    // The banner text is chosen by the machine. A hostile or compromised host
    // must not be able to make the app open anything but a plain web link.
    test('never returns anything but an https link', () {
      for (final hostile in [
        'http://login.tailscale.com/a/abc',
        'javascript:alert(1)',
        'intent://scan/#Intent;scheme=zxing;end',
        'file:///etc/passwd',
        'tel:+123456789',
        'ftp://example.com/x',
        'HTTPS//no-colon',
        'https://',
        'https:// spaces.example.com',
      ]) {
        expect(approvalUrlFrom(hostile), isNull, reason: hostile);
      }
    });

    test('ignores text with no link, and absurdly long links', () {
      expect(approvalUrlFrom('Welcome to the machine'), isNull);
      expect(approvalUrlFrom(''), isNull);
      expect(approvalUrlFrom('https://example.com/${'a' * 3000}'), isNull);
    });

    test('returns the first link when several are present', () {
      expect(approvalUrlFrom('https://a.example/1 then https://b.example/2'),
          'https://a.example/1');
    });
  });
}
