import 'dart:async';

import 'package:herdr_mobile/data/services/herdr_transport.dart';

import 'fake_transport.dart';

/// A [FakeTransport] whose answers can be scripted per method: `on['x'] =
/// (params) => {...}` replaces the default `{type: ok}`. Throw from the handler
/// to answer with an error. Calls are recorded in [calls] as usual.
class HerdrStub extends FakeTransport {
  HerdrStub([super.snapshot]);

  final Map<String, FutureOr<Map<String, dynamic>> Function(Map<String, dynamic> params)> on = {};

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    final handler = on[method];
    if (handler == null) return super.request(method, params);
    calls.add((method, params));
    if (failure != null) throw failure!;
    return await handler(params);
  }

  /// The params of every call to [method], in order.
  List<Map<String, dynamic>> paramsOf(String method) =>
      [for (final c in calls) if (c.$1 == method) c.$2];

  /// Names of every call, in order. The snapshot, ping, the agent list
  /// (fetched in the background by the form) and pane reads (by an open pane
  /// screen) are left out.
  List<String> get methods => [
        for (final c in calls)
          if (!const {'session.snapshot', 'ping', 'server.agent_manifests', 'pane.read'}.contains(c.$1)) c.$1,
      ];
}

/// herdr's answer to a method it does not know (verified on a live 0.8.2).
HerdrApiException unknownMethod(String method) => HerdrApiException(
      'invalid_request',
      'invalid request: unknown variant `$method`, expected one of `ping`, `server.stop`',
    );

/// A `workspace_created` result, the shape herdr returns.
Map<String, dynamic> workspaceCreated({
  String workspace = 'wN',
  String? cwd = '/work/app',
  String? label,
}) =>
    {
      'type': 'workspace_created',
      'workspace': {
        'workspace_id': workspace,
        'number': 2,
        'label': label ?? '',
        'focused': false,
        'pane_count': 1,
        'tab_count': 1,
        'agent_status': 'unknown',
      },
      'tab': {
        'tab_id': '$workspace:t1',
        'workspace_id': workspace,
        'number': 1,
        'label': '1',
        'focused': false,
        'pane_count': 1,
        'agent_status': 'unknown',
      },
      'root_pane': {
        'pane_id': '$workspace:p1',
        'workspace_id': workspace,
        'tab_id': '$workspace:t1',
        'focused': false,
        'cwd': ?cwd,
        'agent_status': 'unknown',
      },
    };

/// Adds a workspace with one pane to a `session.snapshot` payload, as herdr
/// would after `workspace.create`.
void addWorkspaceTo(
  Map<String, dynamic> snapshot, {
  String workspace = 'wN',
  String label = 'new',
  String cwd = '/work/app',
  String? agent,
  String status = 'unknown',
}) {
  (snapshot['workspaces'] as List).add({
    'workspace_id': workspace,
    'number': 2,
    'label': label,
    'focused': false,
    'pane_count': 1,
    'tab_count': 1,
    'agent_status': status,
  });
  (snapshot['tabs'] as List).add({
    'tab_id': '$workspace:t1',
    'workspace_id': workspace,
    'number': 1,
    'label': '1',
    'focused': false,
    'pane_count': 1,
    'agent_status': status,
  });
  (snapshot['panes'] as List).add({
    'pane_id': '$workspace:p1',
    'workspace_id': workspace,
    'tab_id': '$workspace:t1',
    'focused': false,
    'cwd': cwd,
    'agent_status': status,
    'revision': 1,
    'agent': ?agent,
  });
}
