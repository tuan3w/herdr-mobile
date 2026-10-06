import 'package:flutter/material.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/services/remote_files.dart';
import '../photos/photo_item.dart';
import '../photos/photo_viewer.dart';
import 'file_listing.dart';
import 'file_kind.dart';
import 'file_viewer_screen.dart';
import 'photo_thumbs.dart';

/// Whether a file called [name] opens in the photo viewer: the picture
/// formats the engine decodes (PNG, JPEG, GIF, WebP, BMP). SVG is not one (it
/// is text, and nothing here draws it).
bool isPhotoName(String name) => typeForName(name).kind == FileKind.image;

/// The pictures among [entries], in the order a person looks through a folder
/// (case-insensitive natural order: `IMG_2` before `IMG_10`). Folders, links
/// that lead to folders and everything that is not a picture are left out.
List<RemoteEntry> photoEntries(Iterable<RemoteEntry> entries) =>
    FileListing(entries.where((e) => e.isFile && isPhotoName(e.name))).view(
      sort: FileSort.name,
      foldersFirst: true,
      showHidden: true,
    );

/// One picture file as the viewer shows it. The thumbnail the folder grid
/// already made (if any) stands in while the picture is read.
PhotoItem remotePhotoItem(
  RemoteFiles files, {
  required String path,
  required int? size,
  DateTime? modified,
  PhotoThumbs? thumbs,
}) => PhotoItem(
  id: path,
  name: RemotePath.basename(path),
  path: path,
  modified: modified,
  source: RemotePhotoSource(files, path, size: size),
  placeholder: () => (thumbs ?? PhotoThumbs.shared).peek(path),
);

PhotoItem remotePhotoItemOf(RemoteFiles files, RemoteEntry e, {PhotoThumbs? thumbs}) =>
    remotePhotoItem(files, path: e.path, size: e.size, modified: e.modified, thumbs: thumbs);

/// The pictures next to [opened] in its folder, listed from the machine (one
/// `list`, at the moment the viewer is already on screen). Dotfiles are left
/// out unless the opened picture is one itself.
Future<List<PhotoItem>> siblingPhotoItems(RemoteFiles files, RemoteStat opened) async {
  final folder = RemotePath.parent(opened.path);
  final listed = await files.list(folder);
  final showHidden = RemotePath.basename(opened.path).startsWith('.');
  final pictures = photoEntries(listed.where((e) => showHidden || !e.isHidden || e.path == opened.path));
  return [
    for (final e in pictures)
      // The opened one keeps the stat the caller already had (fresh size).
      e.path == opened.path
          ? remotePhotoItem(files, path: e.path, size: opened.size ?? e.size, modified: opened.modified ?? e.modified)
          : remotePhotoItemOf(files, e),
  ];
}

/// Opens the viewer on the pictures of one folder, [images] (from
/// [photoEntries]) starting at [index]. The viewer pages through exactly these.
Future<void> openFolderPhotos(
  BuildContext context,
  MachineConnection machine,
  List<RemoteEntry> images,
  int index,
) => openPhotoViewer(
  context,
  items: [for (final e in images) remotePhotoItemOf(machine.files, e)],
  initialIndex: index,
);

/// The photo viewer's route for the picture at [stat]. The folder's other
/// pictures are [siblings] when the caller has the listing already, else they
/// are listed from the machine once the viewer is open ([listSiblings] false
/// leaves the viewer on this picture alone). A file whose bytes are not a
/// picture offers "View as text".
Route<T> photoRoute<T>(
  MachineConnection machine,
  RemoteStat stat, {
  List<RemoteEntry>? siblings,
  bool listSiblings = true,
}) {
  final files = machine.files;
  final here = remotePhotoItem(files, path: stat.path, size: stat.size, modified: stat.modified);
  final known = siblings == null ? null : photoEntries(siblings);
  final at = known?.indexWhere((e) => e.path == stat.path) ?? -1;
  final withFolder = known != null && at >= 0;
  return photoViewerRoute<T>(
    items: withFolder ? [for (final e in known) e.path == stat.path ? here : remotePhotoItemOf(files, e)] : [here],
    initialIndex: withFolder ? at : 0,
    moreItems: withFolder || !listSiblings ? null : () => siblingPhotoItems(files, stat),
    viewAsText: () => FileViewerScreen(machine: machine, stat: stat, asText: true),
  );
}

/// The route for the file at [stat]: the immersive photo viewer for a picture
/// (see [photoRoute]), the file viewer for everything else. [line] is the line
/// of a text file to show.
Route<T> fileViewerRoute<T>(
  MachineConnection machine,
  RemoteStat stat, {
  int? line,
  List<RemoteEntry>? siblings,
}) => isPhotoName(stat.name)
    ? photoRoute<T>(machine, stat, siblings: siblings)
    : MaterialPageRoute<T>(builder: (_) => FileViewerScreen(machine: machine, stat: stat, line: line));
