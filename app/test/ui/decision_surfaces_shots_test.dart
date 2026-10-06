// Renders the decision surfaces to PNGs for review (light and dark, 412x892,
// 320x640 and 320x640 at 1.6 text): the dock with a diff, with a 400-line plan,
// omp's plan question, the dangerous-mode chip, chips that overflow, long
// titles and the compact layout. Off by default; it writes files:
//
//   DECISION_SHOTS=1 flutter test test/ui/decision_surfaces_shots_test.dart
//
// Output: $DECISION_SHOTS_DIR (default /tmp/decision_shots)/<case>-<light|dark>-<w>x<h>[-x1.6].png
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;

const _said = 'I will move the call below `normalize()` and add a regression test for Hà Nội.';

final _plan = [
  '# Sửa lỗi định dạng Hà Nội',
  '',
  'Nguyên nhân: `parse()` hạ chữ thường **trước khi** bỏ dấu.',
  '',
  for (var i = 1; i <= 100; i++) ...['## Bước $i', '', 'Sửa `lib/feature/step_$i.dart` rồi chạy `flutter test`.', ''],
].join('\n');

const _ompPlan =
    'Approve plan "Fix the Hà Nội parser" and start implementation?\n\n'
    '# Fix the parser\n\n1. Move the call below `normalize()`\n2. Add a regression test for `Hà Nội`\n'
    '3. Run `flutter test`\n4. Update the changelog\n5. Bump the patch version\n6. Tag it\n7. Push it\n8. Open the PR\n'
    '9. Ask for review\n10. Merge when green\n11. Delete the branch\n12. Close the issue\n\u2026';

final _questionRequest = ElicitationRequest.parse({
  'mode': 'form',
  'message': _ompPlan,
  'requestedSchema': {
    'type': 'object',
    'properties': {
      'value': {
        'type': 'string',
        'enum': ['Approve and execute', 'Refine plan'],
      },
    },
  },
});

SelectConfigOption _mode(String value, String name) => SelectConfigOption(
  id: 'mode',
  name: 'Mode',
  category: 'mode',
  value: value,
  choices: [ConfigChoice(value: value, name: name)],
);

const _model = SelectConfigOption(
  id: 'model',
  name: 'Model',
  category: 'model',
  value: 'm',
  choices: [ConfigChoice(value: 'm', name: 'claude-sonnet-5-5')],
);
const _effort = SelectConfigOption(
  id: 'effort',
  name: 'Effort',
  category: 'thought_level',
  value: 'high',
  choices: [ConfigChoice(value: 'high', name: 'High')],
);

List<TranscriptItem> _history() => [
  userMsg('u1', 'Fix the Hà Nội locale bug in the parser and add a test.'),
  toolItem('t0', title: 'Read lib/feature/parse.dart', kind: ToolKind.read),
  agentMsg('a1', _said),
];

void main() {
  if (Platform.environment['DECISION_SHOTS'] == null) {
    test('decision shots are off (set DECISION_SHOTS=1)', () {}, skip: 'set DECISION_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['DECISION_SHOTS_DIR'] ?? '/tmp/decision_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  Future<void> shoot(
    WidgetTester tester,
    String name,
    FakeAgentSession session,
    Size size,
    Brightness brightness, {
    double scale = 1,
    double keyboard = 0,
    Future<void> Function()? then,
  }) async {
    const dpr = 2.625;
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    tester.view.viewPadding = tester.view.padding;
    if (keyboard > 0) tester.view.viewInsets = FakeViewPadding(bottom: keyboard * dpr);
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: key, child: child!),
        ),
        home: AgentSessionScreen(key: ObjectKey(session), session: session),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(tapGuard);
    await then?.call();
    await tester.pump(const Duration(milliseconds: 600));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final tag = '${size.width.toInt()}x${size.height.toInt()}${scale == 1 ? '' : '-x$scale'}';
      await File('$out/$name-${brightness.name}-$tag.png').writeAsBytes(data!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull, reason: '$name ${brightness.name} $size');
  }

  final cases = <String, FakeAgentSession Function()>{
    'dock-diff': () => FakeAgentSession(
      state: stateWith(
        items: _history(),
        options: [_mode('default', 'Default'), _model, _effort],
        turnActive: true,
        pending: [
          PendingPermission(
            7,
            permissionRequest(
              title: 'Edit lib/feature/parse.dart',
              kind: ToolKind.edit,
              rawInput: {'file_path': 'lib/feature/parse.dart', 'old_string': 'lower(s)', 'new_string': 'fold(s)'},
              content: [
                {
                  'type': 'diff',
                  'path': 'lib/feature/parse.dart',
                  'oldText': '${[for (var i = 0; i < 30; i++) 'final line$i = $i;'].join('\n')}\nString parse(String s) => lower(s);\n',
                  'newText':
                      '${[for (var i = 0; i < 30; i++) 'final line$i = $i;'].join('\n')}\nString parse(String s) => fold(normalize(s));\nString fold(String s) => s;\n',
                },
                {'type': 'diff', 'path': 'test/parse_test.dart', 'newText': 'void main() {\n  test(\'Hà Nội\', () {});\n}\n'},
              ],
            ),
          ),
        ],
      ),
    ),
    'dock-plan': () => FakeAgentSession(
      state: stateWith(
        items: _history(),
        options: [_mode('plan', 'Plan'), _model],
        turnActive: true,
        pending: [
          PendingPermission(
            7,
            permissionRequest(
              title: 'Approve Plan',
              rawInput: {'plan': _plan},
              options: const [
                PermissionOption(optionId: 'a', name: 'Yes, and bypass permissions', kind: PermissionOptionKind.allowAlways),
                PermissionOption(optionId: 'b', name: 'Yes, manually approve edits', kind: PermissionOptionKind.allowOnce),
                PermissionOption(optionId: 'c', name: 'No, keep planning', kind: PermissionOptionKind.rejectOnce),
              ],
            ),
          ),
        ],
      ),
    ),
    'omp-plan': () => FakeAgentSession(
      state: stateWith(
        items: _history(),
        options: [_mode('plan', 'Plan'), _model],
        turnActive: true,
        pending: [PendingQuestion(9, _questionRequest)],
      ),
    ),
    'danger-chip': () => FakeAgentSession(
      title: 'Sửa lỗi định dạng ngày tháng ở màn hình thanh toán',
      state: stateWith(
        items: [..._history(), TranscriptNote(key: 'n1', text: 'Mode changed to Bypass Permissions', modeId: 'bypassPermissions')],
        options: [_mode('bypassPermissions', 'Bypass Permissions'), _model, _effort, const BooleanConfigOption(id: 'fast', name: 'Fast', value: true)],
      ),
    ),
    'chips-overflow': () => FakeAgentSession(
      title: 'payments-api',
      state: stateWith(
        items: _history(),
        options: [
          _mode('acceptEdits', 'Accept edits'),
          _model,
          _effort,
          const BooleanConfigOption(id: 'fast', name: 'Fast', value: false),
          const BooleanConfigOption(id: 'web', name: 'Web search', value: true),
          const BooleanConfigOption(id: 'cache', name: 'Prompt caching', value: true),
        ],
      ),
    ),
    'long-title': () => FakeAgentSession(
      title: 'Sửa lỗi định dạng ngày tháng ở màn hình thanh toán của khách hàng doanh nghiệp lớn nhất',
      cwd: '/home/dev/thư-mục-rất-dài-của-dự-án',
      state: stateWith(
        items: _history(),
        options: [
          _mode('x', 'Chế độ tự động phê duyệt mọi thay đổi'),
          const SelectConfigOption(
            id: 'model',
            name: 'Model',
            category: 'model',
            value: 'm',
            choices: [ConfigChoice(value: 'm', name: 'Mô hình ngôn ngữ lớn thế hệ mới nhất của nhà cung cấp')],
          ),
        ],
      ),
    ),
  };

  for (final brightness in Brightness.values) {
    for (final (size, scale) in const [(Size(412, 892), 1.0), (Size(320, 640), 1.0), (Size(320, 640), 1.6)]) {
      for (final entry in cases.entries) {
        testWidgets('${entry.key} ${brightness.name} ${size.width.toInt()} x$scale', (tester) async {
          await shoot(tester, entry.key, entry.value(), size, brightness, scale: scale);
        });
      }
    }
    testWidgets('compact ${brightness.name}', (tester) async {
      await shoot(
        tester,
        'compact',
        cases['danger-chip']!(),
        const Size(892, 412),
        brightness,
        keyboard: 180,
      );
    });
    testWidgets('landscape ${brightness.name}', (tester) async {
      await shoot(tester, 'landscape', cases['danger-chip']!(), const Size(892, 412), brightness);
    });
  }
}
