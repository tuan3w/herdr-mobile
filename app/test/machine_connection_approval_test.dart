import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'support/fake_transport.dart';

const _profile = MachineProfile(
  id: 'm',
  label: 'dec',
  host: 'dec-tuannd12.tailc33c7.ts.net',
  username: 'tuannd12',
  auth: SshAuth.none,
);

const _banner = '# Tailscale SSH requires an additional check.\n'
    '# To authenticate, visit: https://login.tailscale.com/a/l3503a0535f1bf';

MachineConnection _connection() => MachineConnection(
      profile: _profile,
      api: HerdrApi(FakeTransport()),
      backoff: (_) => const Duration(milliseconds: 10),
      pollInterval: const Duration(hours: 1),
    );

void main() {
  late MachineConnection c;
  tearDown(() => c.dispose());

  test('a sign-in banner puts the machine in "waiting for approval" with the link', () {
    c = _connection();

    c.onAuthNotice(_banner);

    expect(c.state, LinkState.approval);
    expect(c.approvalUrl, 'https://login.tailscale.com/a/l3503a0535f1bf');
  });

  test('a banner without a sign-in link changes nothing', () {
    c = _connection();

    c.onAuthNotice('Welcome to dec-tuannd12. Unauthorised use is prohibited.');
    c.onAuthNotice('javascript:alert(1)');
    c.onAuthNotice('http://login.tailscale.com/a/abc');

    expect(c.state, LinkState.connecting);
    expect(c.approvalUrl, isNull);
  });

  test('a fresh link replaces the old one and notifies listeners', () {
    c = _connection();
    c.onAuthNotice(_banner);
    var notified = 0;
    c.addListener(() => notified++);

    c.onAuthNotice('visit https://login.tailscale.com/a/second');

    expect(c.approvalUrl, 'https://login.tailscale.com/a/second');
    expect(notified, 1);
  });

  test('the same link twice does not notify twice', () {
    c = _connection();
    c.onAuthNotice(_banner);
    var notified = 0;
    c.addListener(() => notified++);

    c.onAuthNotice(_banner);

    expect(notified, 0);
  });

  test('once approved and connected, the link is gone', () async {
    c = _connection();
    c.onAuthNotice(_banner);

    c.start();
    await eventually(() => c.isLive, reason: 'connects after approval');

    expect(c.state, LinkState.online);
    expect(c.approvalUrl, isNull);
  });
}
