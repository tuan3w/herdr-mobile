import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/auth_notice.dart';

void main() {
  _refusalTests();
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

void _refusalTests() {
  // Banners captured from real Tailscale SSH servers that refused a login.
  group('refusalReasonFrom', () {
    test('reads the reason Tailscale gives for a refused user', () {
      expect(
        refusalReasonFrom('tailscale: tailnet policy does not permit you to SSH as user "admin"'),
        'tailnet policy does not permit you to SSH as user "admin"',
      );
      expect(refusalReasonFrom('failed to look up admin\n'), 'failed to look up admin');
    });

    test('is not the approval prompt, which carries a link', () {
      expect(
        refusalReasonFrom('# Tailscale SSH requires an additional check.\n'
            '# To authenticate, visit: https://login.tailscale.com/a/abc'),
        isNull,
      );
    });

    // The text is the machine's: shown as plain words, never as terminal output.
    test('drops escape sequences and control characters, and cuts a long text', () {
      expect(refusalReasonFrom('\x1B[31mAccess\x07 denied\x1B[0m\r\n'), 'Access denied');
      expect(refusalReasonFrom('\x1B[2J\n  \t'), isNull);
      expect(refusalReasonFrom(''), isNull);
      expect(refusalReasonFrom('x' * 500)!.length, 200);
    });
  });
}
