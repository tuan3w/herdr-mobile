import 'dart:typed_data';

import '../models/remote_file.dart';
import '../models/remote_search.dart';

/// Where a machine's files are read from: the agent helper's `fs` service
/// (`HostFiles`) when the machine has it, SFTP (`SftpFiles`) as the read-only
/// fallback when it has not. Both answer with the same models and the same
/// [RemoteFileException]s, so nothing above them knows which one it talks to.
///
/// Every method throws [RemoteFileException] for a file-level problem
/// (`notFound`, `permission`, `notADirectory`, `notAFile`, …) and
/// `HerdrTransportException` when the connection itself is the problem.
abstract interface class RemoteFileBackend {
  /// What is at [path], links followed.
  Future<RemoteStat> stat(String path);

  /// The entries of the folder [path] (never `.` or `..`), in the order the
  /// machine gives them.
  Future<List<RemoteEntry>> list(String path);

  /// Up to [length] bytes of [path] from [offset]; fewer at the end of the
  /// file, none past it. [length] is at most [remoteReadCap].
  ///
  /// With [ifMatch] the read only happens when the file still has that size and
  /// modification time, else it throws [RemoteFileChanged]. A backend that
  /// cannot check (SFTP) ignores it: see [checksIdentity].
  Future<Uint8List> read(String path, int offset, int length, {RemoteStat? ifMatch});

  /// The absolute path [path] really is (`~` expanded, links resolved).
  Future<String> realPath(String path);

  /// [path] now and whenever it changes, until the subscription is cancelled:
  /// the first event is the state at the time of listening, null when nothing
  /// is there. A failure to look (a blip) is an error event, then the stream
  /// closes; the listener decides whether to listen again.
  Stream<RemoteStat?> watch(String path);

  /// Whether [read] honours `ifMatch`.
  bool get checksIdentity;

  /// A small JPEG of the picture at [path], its longest side [maxPx] (never
  /// enlarged, EXIF orientation applied), made where the file is so that a
  /// photo is not carried over the radio to draw a few dozen pixels. With
  /// [expect] (the file as it was listed) the thumbnail is only made when the
  /// file still has that size and time.
  ///
  /// Null when no thumbnail can be had: the backend cannot make one (SFTP, an
  /// older agent helper), the file is not a picture it can read, it is too
  /// large, it changed, or [cancelled] completed first. Never an error: the
  /// caller keeps whatever it did without this (read the file itself, or show a
  /// glyph). [cancelled] completes when the caller no longer wants the
  /// answer; the host stops decoding.
  Future<Uint8List?> thumbnail(String path, {int maxPx = 256, RemoteStat? expect, Future<void>? cancelled});

  /// The entries below [FileSearchSpec.root] that match [spec], in batches as
  /// they are found (shallow ones first), then one [FileSearchDone]. The agent
  /// helper searches where the files are; a machine without it is walked
  /// folder by folder with the same rules and tighter limits ([walkSearch]).
  ///
  /// Cancelling the subscription stops the search. A failure of the root
  /// (`notFound`, `permission`, `notADirectory`) or of the connection ends the
  /// stream with it; a folder inside that cannot be read is skipped.
  Stream<FileSearchEvent> search(FileSearchSpec spec);
}
