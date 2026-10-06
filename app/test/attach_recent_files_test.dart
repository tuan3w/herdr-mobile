// The list of phone files that were attached: newest first, a file attached
// twice once, ten at most, and a damaged save does not break the sheet.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/recent_phone_files.dart';
import 'package:herdr_mobile/data/services/attach_limits.dart';

import 'support/attach_fakes.dart';

RecentPhoneFile file(int i) => RecentPhoneFile(name: 'f$i.pdf', size: 100 + i);

void main() {
  test('newest first, a file attached again moves to the top and is listed once', () async {
    final store = MemoryRecentStore();
    final recents = RecentPhoneFiles(store);
    await recents.add(file(1));
    await recents.add(file(2));
    await recents.add(file(1));
    expect(recents.files.map((f) => f.name), ['f1.pdf', 'f2.pdf']);
    expect(store.files, recents.files, reason: 'saved');
  });

  test('keeps the last ten', () async {
    final recents = RecentPhoneFiles(MemoryRecentStore());
    for (var i = 0; i < 14; i++) {
      await recents.add(file(i));
    }
    expect(recents.files, hasLength(RecentPhoneFiles.maxCount));
    expect(recents.files.first.name, 'f13.pdf');
    expect(recents.files.last.name, 'f4.pdf');
  });

  test('a saved list longer than the cap is cut on load', () async {
    final recents = RecentPhoneFiles(MemoryRecentStore([for (var i = 0; i < 30; i++) file(i)]));
    await recents.load();
    expect(recents.files, hasLength(10));
  });

  test('remove forgets one entry', () async {
    final store = MemoryRecentStore([file(1), file(2)]);
    final recents = RecentPhoneFiles(store);
    await recents.remove(file(1));
    expect(recents.files, [file(2)]);
    expect(store.files, [file(2)]);
  });

  test('only names, sizes and the host copy are kept', () {
    const f = RecentPhoneFile(name: 'a.pdf', size: 5, machineId: 'm', hostPath: '/h/a.pdf');
    expect(f.toJson().keys.toSet(), {'name', 'size', 'machine', 'path'});
    expect(RecentPhoneFile.fromJson(f.toJson()), f);
  });

  test('damaged entries are skipped, not fatal', () {
    expect(RecentPhoneFile.fromJson('x'), isNull);
    expect(RecentPhoneFile.fromJson({'name': '', 'size': 1}), isNull);
    expect(RecentPhoneFile.fromJson({'name': 'a', 'size': 'big'}), isNull);
    expect(RecentPhoneFile.fromJson({'name': 'a', 'size': 1, 'path': 5})?.hostPath, isNull);
  });

  test('size verdicts: ok to 25 MB, a warning to 200 MB, refused above', () {
    expect(sizeVerdict(0), SizeVerdict.ok);
    expect(sizeVerdict(attachWarnBytes), SizeVerdict.ok);
    expect(sizeVerdict(attachWarnBytes + 1), SizeVerdict.large);
    expect(sizeVerdict(attachRefuseBytes), SizeVerdict.large);
    expect(sizeVerdict(attachRefuseBytes + 1), SizeVerdict.tooLarge);
  });
}
