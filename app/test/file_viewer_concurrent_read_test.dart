import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_view_model.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';

void main() {
  test('Load more and Copy asked together read each piece of the file once', () async {
    final text = List.generate(400, (i) => 'line ${i + 1}').join('\n');
    final fs = FakeFs()..addFile('/h/log.txt', text);
    final vm = FileViewerViewModel(
      files: RemoteFiles(FakeTransport()..fs = fs),
      stat: await fs.stat('/h/log.txt'),
      firstChunk: 1000,
      formatJson: (raw) async => raw,
    );
    addTearDown(vm.dispose);
    await vm.load();
    expect(vm.hasMore, isTrue);

    fs.gate = Completer<void>();
    final more = vm.loadMore();
    final copy = vm.textForCopy();
    fs.gate!.complete();
    await more;
    final copied = (await copy)!;

    expect(copied.text, text);
    expect(vm.document!.lines, text.split('\n'));
    expect(utf8.encode(copied.text).length, utf8.encode(text).length);
  });
}
