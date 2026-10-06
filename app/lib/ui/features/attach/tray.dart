import 'package:flutter/foundation.dart';

import '../../../data/acp/prompt_content.dart' show relativeToCwd;
import '../../../data/services/image_prep.dart' show PreparedImage;
import '../../../data/services/phone_gallery.dart';

/// One thing picked in the attach sheet, from any tab.
sealed class TrayItem {
  const TrayItem();

  /// Identifies the pick across tabs: selecting it twice is selecting it once.
  String get key;

  /// The file's name as the chip shows it.
  String get name;

  /// Bytes, when known.
  int? get size;
}

/// A picture from the phone's gallery. [thumb] is the thumbnail the grid drew
/// (the chip shows the same bytes, already decoded); [work] is the encoding
/// started the moment it was picked.
final class GalleryPick extends TrayItem {
  GalleryPick(this.asset, {this.thumb}) : work = ImageWork();

  final GalleryAsset asset;
  final Uint8List? thumb;
  final ImageWork work;

  @override
  String get key => 'g:${asset.id}';

  @override
  String get name => asset.name ?? 'Photo ${asset.id}';

  @override
  int? get size => null;
}

/// A file of the phone chosen with the system picker or from the recent list;
/// it goes to the host as an upload.
final class PhonePick extends TrayItem {
  const PhonePick({required this.path, required this.name, required this.size});

  final String path;

  @override
  final String name;

  @override
  final int size;

  @override
  String get key => 'p:$path';
}

/// A file that already lies on the host (picked in the Host tab, or a recent
/// phone file whose copy is still there): attached as a link, nothing is sent.
final class HostPick extends TrayItem {
  const HostPick({required this.path, required this.name, this.size, this.fromPhone = false});

  final String path;

  @override
  final String name;

  @override
  final int? size;

  /// An earlier upload of a phone file, attached again without sending it.
  final bool fromPhone;

  @override
  String get key => 'h:$path';

  /// `lib/main.dart` for a file below [cwd], else the absolute path.
  String detail(String cwd) => relativeToCwd(path, cwd);
}

/// The encoding of a picked photo, started speculatively and abandoned when
/// the pick is undone. [future] is null until it starts.
class ImageWork {
  Future<PreparedImage>? future;
  var _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// What was picked in one opening of the sheet, shared by every tab: the
/// count on the Attach button is the sum of the tabs, and a tile's number is
/// its place in this list.
///
/// Tiles do not each hold a notifier: they listen to the tray and rebuild only
/// when their own number changed ([numberOf]).
class AttachTray extends ChangeNotifier {
  AttachTray({required this.capacity, this.onAdded, this.onRemoved, this.onFull});

  /// How many more the message takes (five, less what is already attached).
  final int capacity;

  /// A pick was added (the gallery starts encoding it).
  final void Function(TrayItem item)? onAdded;

  /// A pick was taken out again.
  final void Function(TrayItem item)? onRemoved;

  /// A pick was refused: the message is full.
  final VoidCallback? onFull;

  final _items = <TrayItem>[];

  List<TrayItem> get items => List.unmodifiable(_items);
  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;
  bool get full => _items.length >= capacity;

  /// 1-based place of [key], or null when not picked.
  int? numberOf(String key) {
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].key == key) return i + 1;
    }
    return null;
  }

  bool contains(String key) => numberOf(key) != null;

  /// Picks [item]; false when the message is full.
  bool add(TrayItem item) {
    if (contains(item.key)) return true;
    if (full) {
      onFull?.call();
      return false;
    }
    _items.add(item);
    onAdded?.call(item);
    notifyListeners();
    return true;
  }

  void remove(String key) {
    final i = _items.indexWhere((e) => e.key == key);
    if (i < 0) return;
    final item = _items.removeAt(i);
    onRemoved?.call(item);
    notifyListeners();
  }

  /// Picks [item], or takes it out when it is picked. False when it is refused.
  bool toggle(TrayItem item) {
    if (contains(item.key)) {
      remove(item.key);
      return true;
    }
    return add(item);
  }

  void clear() {
    if (_items.isEmpty) return;
    final gone = [..._items];
    _items.clear();
    for (final item in gone) {
      onRemoved?.call(item);
    }
    notifyListeners();
  }

  /// The picks go to the message: ownership passes, nothing is cancelled.
  List<TrayItem> take() {
    final out = [..._items];
    _items.clear();
    return out;
  }
}
