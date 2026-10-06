/// A file over this is attached with a warning: the upload takes a while over
/// a phone's link.
const attachWarnBytes = 25 * 1024 * 1024;

/// A file over this is refused: it would tie the link up for minutes and fill
/// the host's inbox.
const attachRefuseBytes = 200 * 1024 * 1024;

enum SizeVerdict { ok, large, tooLarge }

/// What to do with a file of [bytes]: attach it, attach it and say it is
/// large, or refuse it.
SizeVerdict sizeVerdict(int bytes) {
  if (bytes > attachRefuseBytes) return SizeVerdict.tooLarge;
  if (bytes > attachWarnBytes) return SizeVerdict.large;
  return SizeVerdict.ok;
}
