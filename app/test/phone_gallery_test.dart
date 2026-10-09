// The phone's library as the plugin reads it, over a fake MediaStore that
// filters like Android's does: a picture taken while the app runs (the
// screenshot the person just took) is in the next query.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/phone_gallery.dart';

const _channel = MethodChannel('com.fluttercandies/photo_manager');

/// MediaStore's images, honouring the creation-date bound of each query the
/// way `CommonFilterOption.addDateCond` does on Android.
class _MediaStore {
  final pictures = <({String id, int createdMs})>[];

  List<({String id, int createdMs})> _query(Object? args) {
    // The filter travels as `{type, child: {createDate: {min, max, ignore}}}`;
    // a query without one would be a plugin change this fake must not hide.
    final date = (((args as Map)['option'] as Map)['child'] as Map)['createDate'] as Map;
    final kept = [
      for (final p in pictures)
        if (date['ignore'] == true || (p.createdMs >= (date['min'] as int) && p.createdMs <= (date['max'] as int)))
          p,
    ]..sort((a, b) => b.createdMs.compareTo(a.createdMs));
    return kept;
  }

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'getAssetPathList':
        return {
          'data': [
            {'id': 'all', 'name': 'Recent', 'isAll': true, 'assetCount': _query(call.arguments).length},
          ],
        };
      case 'getAssetCountFromPath':
        return _query(call.arguments).length;
      case 'getAssetListRange':
        final args = call.arguments as Map;
        final all = _query(args);
        final end = (args['end'] as int).clamp(0, all.length);
        return {
          'data': [
            for (final p in all.sublist((args['start'] as int).clamp(0, end), end))
              {'id': p.id, 'type': 1, 'width': 1080, 'height': 2400, 'createDt': p.createdMs ~/ 1000, 'title': '${p.id}.png'},
          ],
        };
    }
    return null;
  }
}

Future<List<String>> _recentIds(PhoneGallery gallery) async {
  final albums = await gallery.albums(onlyRecent: true);
  final recent = albums.single;
  final assets = await gallery.assets(recent.id, start: 0, count: 120);
  return [for (final a in assets) a.id];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MediaStore store;

  setUp(() {
    store = _MediaStore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, store.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  });

  test('a screenshot taken after the gallery was first read is in the next read, newest first', () async {
    store.pictures.add((id: 'old', createdMs: DateTime.now().millisecondsSinceEpoch - 60000));
    final gallery = PhotoManagerGallery();
    expect(await _recentIds(gallery), ['old']);

    await Future<void>.delayed(const Duration(milliseconds: 20));
    store.pictures.add((id: 'screenshot', createdMs: DateTime.now().millisecondsSinceEpoch));

    expect(await _recentIds(gallery), ['screenshot', 'old']);
  });
}
