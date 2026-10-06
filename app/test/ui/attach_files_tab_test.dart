// The Files tab of the attach sheet: files of the phone. Choose files, the
// picks, the recent list with its host copies, and the worst cases.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/repositories/recent_phone_files.dart';
import 'package:herdr_mobile/data/services/phone_files.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/attach/files_tab.dart';
import 'package:herdr_mobile/ui/features/attach/selection_circle.dart';
import 'package:herdr_mobile/ui/features/attach/sheet_frame.dart';
import 'package:herdr_mobile/ui/features/attach/tray.dart';

import '../support/attach_fakes.dart';
import '../support/fake_agent_session.dart';
import '../support/fake_fs.dart';
import '../support/files_support.dart';
import '../support/shot.dart';

const _mb = 1024 * 1024;

/// A sheet position at full height around [child], as the sheet gives it.
class _Host extends StatefulWidget {
  const _Host({required this.child});

  final Widget child;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final SheetPosition position = SheetPosition(vsync: this, reduced: () => false, onDismiss: () {});

  @override
  void initState() {
    super.initState();
    position
      ..layout(full: 892, half: 450)
      ..expand();
  }

  @override
  void dispose() {
    position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SheetScope(
    position: position,
    bottomClearance: 120,
    child: Material(type: MaterialType.transparency, child: widget.child),
  );
}

class _Rig {
  _Rig({List<RecentPhoneFile> recents = const [], FakeFs? fs, int capacity = 5, bool images = true, FakePhoneFilePicker? picker})
    : kit = FakeKit(store: MemoryRecentStore(recents), picker: picker),
      fs = fs ?? FakeFs() {
    session = FakeAgentSession(machine: machineWithFiles(this.fs))..imagesAccepted = images;
    tray = AttachTray(capacity: capacity, onFull: () => full++);
  }

  final FakeKit kit;
  final FakeFs fs;
  late final FakeAgentSession session;
  late final AttachTray tray;
  final problems = <String>[];
  var full = 0;

  Widget get tab => _Host(
    child: FilesTab(kit: kit.kit, session: session, tray: tray, onProblem: problems.add),
  );

  FakePhoneFilePicker get picker => kit.picker;
}

Future<void> _pumpTab(WidgetTester tester, _Rig rig) async {
  tester.view
    ..physicalSize = const Size(412, 892) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: rig.tab));
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester) async {
  await tester.tap(find.text('Choose files…'));
  await tester.pumpAndSettle();
}

PhoneFile phoneFile(String name, int size) => PhoneFile(path: '/cache/file_picker/1/$name', name: name, size: size);

RecentPhoneFile recent(String name, {int size = 2 * _mb, String? path, String machine = 'm'}) =>
    RecentPhoneFile(name: name, size: size, machineId: path == null ? null : machine, hostPath: path);

List<int?> circleNumbers(WidgetTester tester) => [for (final c in tester.widgetList<SelectionCircle>(find.byType(SelectionCircle))) c.number];

void main() {
  setUpAll(loadAppFonts);

  testWidgets('Choose files puts the picks in the tray in order and the rows show 1 and 2', (tester) async {
    final rig = _Rig();
    rig.picker.queued.add([phoneFile('notes.pdf', 3 * _mb), phoneFile('photo.jpg', 400 * 1024)]);
    await _pumpTab(tester, rig);
    expect(find.text('Picked'), findsNothing);

    await choose(tester);

    expect(rig.tray.items.map((e) => e.name), ['notes.pdf', 'photo.jpg']);
    expect(rig.tray.items.every((e) => e is PhonePick), isTrue);
    expect(find.text('Picked'), findsOneWidget);
    expect(circleNumbers(tester), [1, 2]);
    expect(find.text('3 MB'), findsOneWidget);
    expect(find.text('400 KB'), findsOneWidget);
    expect(rig.problems, isEmpty);
  });

  testWidgets('a file over 200 MB is refused with the exact message and the others still go in', (tester) async {
    final rig = _Rig();
    rig.picker.queued.add([phoneFile('movie.mp4', 4 * 1024 * _mb), phoneFile('ok.txt', 10)]);
    await _pumpTab(tester, rig);
    await choose(tester);

    expect(rig.problems, ['movie.mp4 is 4 GB. Files up to 200 MB can be attached.']);
    expect(rig.tray.items.map((e) => e.name), ['ok.txt']);
    expect(find.text('0 B'), findsNothing);
    expect(find.text('10 B'), findsOneWidget);
  });

  testWidgets('a 30 MB file is added and its row says it is large; a 0-byte file is plain', (tester) async {
    final rig = _Rig();
    rig.picker.queued.add([phoneFile('clip.mov', 30 * _mb), phoneFile('empty.txt', 0)]);
    await _pumpTab(tester, rig);
    await choose(tester);

    expect(rig.tray.length, 2);
    expect(find.text('30 MB · large, uploading may take a while'), findsOneWidget);
    expect(find.text('0 B'), findsOneWidget);
    expect(rig.problems, isEmpty);
  });

  testWidgets('a picture for an agent that takes no images says it is sent as a file', (tester) async {
    final rig = _Rig(images: false);
    rig.picker.queued.add([phoneFile('shot.png', 2 * _mb), phoneFile('a.txt', 5)]);
    await _pumpTab(tester, rig);
    await choose(tester);

    expect(find.text('2 MB · sent as a file'), findsOneWidget);
    expect(find.text('5 B'), findsOneWidget);
  });

  testWidgets('the same file chosen twice stays once', (tester) async {
    final rig = _Rig();
    rig.picker.queued
      ..add([phoneFile('a.txt', 5)])
      ..add([phoneFile('a.txt', 5), phoneFile('b.txt', 6)]);
    await _pumpTab(tester, rig);
    await choose(tester);
    await choose(tester);

    expect(rig.tray.items.map((e) => e.name), ['a.txt', 'b.txt']);
    expect(circleNumbers(tester), [1, 2]);
  });

  testWidgets('a failed picker says why and changes nothing', (tester) async {
    final rig = _Rig();
    rig.picker.failure = const PhoneFileException('The file picker could not be opened.');
    await _pumpTab(tester, rig);
    await choose(tester);

    expect(rig.problems, ['The file picker could not be opened.']);
    expect(rig.tray.isEmpty, isTrue);
    // And it works again afterwards.
    rig.picker
      ..failure = null
      ..queued.add([phoneFile('a.txt', 5)]);
    await choose(tester);
    expect(rig.tray.length, 1);
  });

  testWidgets('a person who backs out of the picker changes nothing', (tester) async {
    final rig = _Rig();
    await _pumpTab(tester, rig);
    await choose(tester);
    expect(rig.picker.opened, 1);
    expect(rig.tray.isEmpty, isTrue);
    expect(rig.problems, isEmpty);
  });

  testWidgets('a second tap while the picker is open does not open another', (tester) async {
    final gate = Completer<void>();
    final picker = _SlowPicker(gate.future);
    final rig = _Rig(picker: picker);
    await _pumpTab(tester, rig);
    await tester.tap(find.text('Choose files…'));
    await tester.pump();
    await tester.tap(find.text('Choose files…'));
    await tester.pump();
    expect(picker.opened, 1);
    gate.complete();
    await tester.pumpAndSettle();
    expect(rig.tray.length, 1);
  });

  testWidgets('with the tray full, the fifth pick does not go in and the tray says so once', (tester) async {
    final rig = _Rig(capacity: 4);
    rig.picker.queued.add([for (var i = 1; i <= 6; i++) phoneFile('f$i.txt', i)]);
    await _pumpTab(tester, rig);
    await choose(tester);

    expect(rig.tray.length, 4);
    expect(rig.tray.items.map((e) => e.name), ['f1.txt', 'f2.txt', 'f3.txt', 'f4.txt']);
    expect(rig.full, 1, reason: 'the tray speaks once; the tab stops asking');
  });

  testWidgets('a picked row and its circle both take the pick out again, and the others renumber', (tester) async {
    final handle = tester.ensureSemantics();
    final rig = _Rig();
    rig.picker.queued.add([phoneFile('a.txt', 1), phoneFile('b.txt', 2), phoneFile('c.txt', 3)]);
    await _pumpTab(tester, rig);
    await choose(tester);
    expect(circleNumbers(tester), [1, 2, 3]);

    await tester.tap(find.bySemanticsLabel('Deselect a.txt'));
    await tester.pumpAndSettle();
    expect(rig.tray.items.map((e) => e.name), ['b.txt', 'c.txt']);
    expect(circleNumbers(tester), [1, 2]);

    await tester.tap(find.text('c.txt'));
    await tester.pumpAndSettle();
    expect(rig.tray.items.map((e) => e.name), ['b.txt']);
    handle.dispose();
  });

  group('recent files', () {
    testWidgets('are listed newest first and at most ten', (tester) async {
      final rig = _Rig(recents: [for (var i = 0; i < 12; i++) recent('file$i.pdf')]);
      await _pumpTab(tester, rig);

      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('file9.pdf'), findsOneWidget);
      expect(find.text('file10.pdf'), findsNothing);
      expect(find.text('file11.pdf'), findsNothing);
      final ys = [for (var i = 0; i < 10; i++) tester.getTopLeft(find.text('file$i.pdf')).dy];
      expect(ys, [...ys]..sort());
      expect(find.byType(SelectionCircle), findsNWidgets(10));
      expect(find.text('Files you attach from the phone are listed here.'), findsNothing);
    });

    testWidgets('none: a quiet line says where files will be listed', (tester) async {
      final rig = _Rig();
      await _pumpTab(tester, rig);
      expect(find.text('Recent'), findsNothing);
      expect(find.text('Files you attach from the phone are listed here.'), findsOneWidget);
      expect(find.text('Choose files…'), findsOneWidget);
      expect(find.text('Opens the phone\'s file picker'), findsOneWidget);
    });

    testWidgets('a copy on this host says so; any other says to choose it again', (tester) async {
      final rig = _Rig(
        recents: [
          recent('here.pdf', path: '/inbox/here.pdf'),
          recent('other.pdf', path: '/inbox/other.pdf', machine: 'someone-else'),
          recent('never.pdf'),
        ],
        fs: FakeFs()..addFile('/inbox/here.pdf', 'x'),
      );
      await _pumpTab(tester, rig);
      expect(find.text('2 MB · already on the host'), findsOneWidget);
      expect(find.text('2 MB · choose it again'), findsNWidgets(2));
    });

    testWidgets('a copy that is still on the host attaches without the picker, and a second tap takes it out', (tester) async {
      final rig = _Rig(
        recents: [recent('here.pdf', path: '/inbox/here.pdf')],
        fs: FakeFs()..addFile('/inbox/here.pdf', 'x'),
      );
      await _pumpTab(tester, rig);

      await tester.tap(find.text('here.pdf'));
      await tester.pumpAndSettle();
      expect(rig.picker.opened, 0);
      final pick = rig.tray.items.single as HostPick;
      expect(pick.path, '/inbox/here.pdf');
      expect(pick.fromPhone, isTrue);
      expect(pick.name, 'here.pdf');
      expect(pick.size, 2 * _mb);
      expect(find.text('Picked'), findsOneWidget, reason: 'an upload of the phone, attached again, is a pick of this tab');
      expect(circleNumbers(tester), [1, 1], reason: 'the pick and the recent entry it came from');

      await tester.tap(find.text('here.pdf').last);
      await tester.pumpAndSettle();
      expect(rig.tray.isEmpty, isTrue);
    });

    testWidgets('a quick second tap while the host is asked toggles nothing twice', (tester) async {
      final fs = FakeFs()..addFile('/inbox/here.pdf', 'x');
      final rig = _Rig(recents: [recent('here.pdf', path: '/inbox/here.pdf')], fs: fs);
      await _pumpTab(tester, rig);
      fs.gate = Completer<void>();

      await tester.tap(find.text('here.pdf'));
      await tester.pump();
      await tester.tap(find.text('here.pdf'));
      await tester.pump();
      fs.gate!.complete();
      await tester.pumpAndSettle();

      expect(rig.tray.length, 1);
      expect(fs.calls.where((c) => c.startsWith('stat')), hasLength(1));
    });

    testWidgets('a copy that is gone says so and leaves the list', (tester) async {
      final rig = _Rig(recents: [recent('gone.pdf', path: '/inbox/gone.pdf'), recent('kept.pdf')]);
      await _pumpTab(tester, rig);

      await tester.tap(find.text('gone.pdf'));
      await tester.pumpAndSettle();

      expect(rig.problems, ['That copy is gone from the host. Choose the file again.']);
      expect(rig.tray.isEmpty, isTrue);
      expect(find.text('gone.pdf'), findsNothing);
      expect(find.text('kept.pdf'), findsOneWidget);
      expect(rig.kit.store.files.map((f) => f.name), ['kept.pdf'], reason: 'the saved list drops it too');
    });

    testWidgets('a dropped link says why but keeps the entry', (tester) async {
      final fs = FakeFs()..addFile('/inbox/here.pdf', 'x');
      final rig = _Rig(recents: [recent('here.pdf', path: '/inbox/here.pdf')], fs: fs);
      await _pumpTab(tester, rig);
      fs.fail = RemoteFileException(RemoteFileErrorKind.network, 'Connection lost');

      await tester.tap(find.text('here.pdf'));
      await tester.pumpAndSettle();

      expect(rig.problems, ['Connection lost']);
      expect(find.text('here.pdf'), findsOneWidget);
      expect(rig.tray.isEmpty, isTrue);
    });

    testWidgets('a file with no copy here opens the picker, and what it returns is picked', (tester) async {
      final rig = _Rig(recents: [recent('never.pdf')]);
      rig.picker.queued.add([phoneFile('never.pdf', 2 * _mb)]);
      await _pumpTab(tester, rig);

      await tester.tap(find.text('never.pdf'));
      await tester.pumpAndSettle();

      expect(rig.picker.opened, 1);
      expect(rig.tray.items.single, isA<PhonePick>());
    });

    testWidgets('the x forgets one entry; it is a 44 dp target of its own', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = _Rig(recents: [recent('a.pdf'), recent('b.pdf')]);
      await _pumpTab(tester, rig);

      final x = find.bySemanticsLabel('Remove a.pdf from recent files');
      final box = tester.getSize(x);
      expect(box.width, greaterThanOrEqualTo(kMinTap));
      expect(box.height, greaterThanOrEqualTo(kMinTap));
      await tester.tap(x);
      await tester.pumpAndSettle();

      expect(find.text('a.pdf'), findsNothing);
      expect(find.text('b.pdf'), findsOneWidget);
      expect(rig.kit.store.files.map((f) => f.name), ['b.pdf']);
      expect(rig.picker.opened, 0);
      handle.dispose();
    });
  });

  testWidgets('each row is one node: name, size, selection; the circle has its own name', (tester) async {
    final handle = tester.ensureSemantics();
    final rig = _Rig(recents: [recent('plan.pdf', size: 12 * _mb)]);
    rig.picker.queued.add([phoneFile('notes.pdf', 3 * _mb)]);
    await _pumpTab(tester, rig);

    expect(find.bySemanticsLabel('plan.pdf, 12 MB, choose it again, not selected'), findsOneWidget);
    expect(find.bySemanticsLabel('Select plan.pdf'), findsOneWidget);
    expect(find.bySemanticsLabel('plan.pdf'), findsNothing, reason: 'the name is not read a second time');

    await choose(tester);
    expect(find.bySemanticsLabel('notes.pdf, 3 MB, selected'), findsOneWidget);
    expect(find.bySemanticsLabel('Deselect notes.pdf'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('every row is at least 56 dp and every target at least 44 dp', (tester) async {
    final rig = _Rig(recents: [recent('a.pdf'), recent('b.pdf', size: 0)]);
    rig.picker.queued.add([phoneFile('c.pdf', 1)]);
    await _pumpTab(tester, rig);
    await choose(tester);

    for (final name in ['Choose files…', 'a.pdf', 'b.pdf', 'c.pdf']) {
      final row = find.ancestor(of: find.text(name), matching: find.byType(PressBuilder)).first;
      expect(tester.getSize(row).height, greaterThanOrEqualTo(56), reason: name);
    }
    for (final c in find.byType(SelectionCircle).evaluate()) {
      final size = tester.getSize(find.byWidget(c.widget));
      expect(size.width, greaterThanOrEqualTo(kMinTap));
      expect(size.height, greaterThanOrEqualTo(kMinTap));
    }
  });

  testWidgets('the list ends clear of the floating bars, and worst-case names do not overflow', (tester) async {
    final long = 'Báo cáo tổng kết quý bốn năm hai nghìn hai mươi sáu của phòng kế hoạch và đầu tư — bản cuối cùng đã chỉnh sửa ${'rất dài ' * 10}.docx';
    expect(long.length, greaterThan(120));
    final rig = _Rig(
      recents: [for (var i = 0; i < 10; i++) recent(i == 3 ? long : 'Ảnh chụp màn hình $i.png', size: i * 7 * _mb)],
    );
    rig.picker.queued.add([phoneFile(long, 31 * _mb), phoneFile('\u202Etxt.exe', 5)]);
    await _pumpTab(tester, rig);
    await choose(tester);

    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final last = find.text('Ảnh chụp màn hình 9.png');
    expect(last, findsOneWidget);
    expect(tester.getBottomLeft(last).dy, lessThanOrEqualTo(892 - 120), reason: 'the last row clears the 120 dp of bars');
    expect(find.textContaining('‹U+202E›'), findsOneWidget, reason: 'hidden characters in a name show as escapes');
  });

  testWidgets('light and dark shots', (tester) async {
    for (final dark in [false, true]) {
      final rig = _Rig(
        recents: [
          recent('Báo cáo tổng kết quý bốn năm 2026 của phòng kế hoạch và đầu tư — bản cuối cùng.docx', size: 1536 * 1024),
          recent('IMG_2031.jpg', size: 4 * _mb, path: '/home/dev/.herdr-mobile/inbox/abc/IMG_2031.jpg'),
          recent('release-notes.md', size: 3 * 1024),
          recent('Ảnh màn hình 2026-05-20.png', size: 812 * 1024),
          recent('backup.tar.gz', size: 180 * _mb),
          recent('empty.txt', size: 0),
        ],
        fs: FakeFs()..addFile('/home/dev/.herdr-mobile/inbox/abc/IMG_2031.jpg', 'x'),
      );
      rig.picker.queued.add([phoneFile('screen-recording.mp4', 30 * _mb), phoneFile('Hợp đồng thuê nhà.pdf', 2 * _mb)]);
      await shoot(
        tester,
        rig.tab,
        '/tmp/attach_files_tab_${dark ? 'dark' : 'light'}.png',
        brightness: dark ? Brightness.dark : Brightness.light,
        pump: (tester) async {
          await tester.pumpAndSettle();
          await choose(tester);
        },
      );
    }
  });
}

class _SlowPicker extends FakePhoneFilePicker {
  _SlowPicker(this._gate);

  final Future<void> _gate;

  @override
  Future<List<PhoneFile>> pick() async {
    opened++;
    await _gate;
    return [phoneFile('late.txt', 4)];
  }
}
