import '../acp/acp_models.dart';
import '../services/picture_store.dart';

/// A picture of a terminal-log chat (Claude Code, Codex, omp), as far as the
/// phone knows where its bytes are. The host strips them from the log it sends
/// (a picture is 100 KB to several MB of base64), so a chat from a log shows
/// the picture only when the person asks for it: [LogImageBlock] carries the
/// reference and the screen fetches the bytes on a tap, or finds them in the
/// [PictureStore] when it already has.
sealed class LogPictureRef {
  const LogPictureRef();

  /// What the [PictureStore] keeps the picture under: the content (a hash),
  /// never where it was seen, so the same picture is stored once.
  String get key;

  /// The size of the picture when the log's note says it; null when unknown.
  int? get bytes;
}

/// A picture the keeper dropped from a log line and can send again: its note
/// said `ref=<start>.<hash>` (see `keeperBlobCommand`).
final class KeeperPictureRef extends LogPictureRef {
  const KeeperPictureRef({required this.start, required this.hash, this.bytes});

  /// The byte offset where the log line begins.
  final int start;

  /// 16 hex digits naming the payload in that line.
  final String hash;

  @override
  final int? bytes;

  @override
  String get key => PictureStore.logKey(hash);
}

/// An omp picture: the log holds `blob:sha256:<hex>`, and the bytes are a plain
/// file in the agent's `blobs/` folder.
final class OmpPictureRef extends LogPictureRef {
  const OmpPictureRef({required this.sha256, this.bytes});

  final String sha256;

  @override
  final int? bytes;

  @override
  String get key => PictureStore.ompKey(sha256);
}

/// An [ImageBlock] with no data of its own: [ref] says where to get it. Being
/// an [ImageBlock], every place that lists a conversation's pictures keeps
/// matching it; [data] stays empty, so nothing mistakes it for inline data.
class LogImageBlock extends ImageBlock {
  const LogImageBlock({required super.mimeType, required this.ref}) : super(data: '');

  final LogPictureRef ref;

  String get key => ref.key;
}

final _keeperMarker = RegExp(r'^(?:data:[^,]*,)?\[(\d+) bytes of data not sent; ref=(\d+)\.([0-9a-f]{16})\]$');

/// The reference in a note the keeper left where it dropped a picture
/// (`[N bytes of data not sent; ref=<start>.<hash>]`, also after the
/// `data:<mime>;base64,` of a data URI). Null for anything else: a note from
/// an older keeper that carries no reference, or text that is not one.
KeeperPictureRef? parseKeeperMarker(String s) {
  final m = _keeperMarker.firstMatch(s);
  if (m == null) return null;
  final chars = int.tryParse(m[1]!);
  final start = int.tryParse(m[2]!);
  if (chars == null || start == null) return null;
  return KeeperPictureRef(start: start, hash: m[3]!, bytes: chars * 3 ~/ 4);
}

final _ompBlob = RegExp(r'^blob:sha256:([0-9a-f]{64})$');

/// The reference in an omp image's `data` (`blob:sha256:<64 hex>`); null for
/// anything else.
OmpPictureRef? parseOmpBlob(String s) {
  final m = _ompBlob.firstMatch(s);
  return m == null ? null : OmpPictureRef(sha256: m[1]!);
}

/// The most of a log picture that is fetched and shown: the same bound as the
/// store's per-picture limit, the preview decoder's and the viewer's preload.
const logPictureLimit = 12 * 1024 * 1024;

/// A log picture that cannot be had, in words for the person.
class LogPictureException implements Exception {
  const LogPictureException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The picture is over [logPictureLimit]: refused before any transfer when the
/// size is known up front.
class LogPictureTooLarge extends LogPictureException {
  const LogPictureTooLarge(this.bytes) : super('Too large to show here.');

  final int bytes;
}

/// The picture is not on the machine any more (the log or the file moved on).
const logPictureGone = LogPictureException('The picture is no longer on the machine.');
