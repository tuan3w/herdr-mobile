import 'package:flutter/widgets.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/session_state.dart';
import '../../../data/repositories/agent_session.dart';
import '../files/file_format.dart';
import '../photos/photo_item.dart';
import '../photos/photo_viewer.dart';
import 'content_image_cache.dart';
import 'content_target.dart';
import 'visible_text.dart';

/// A picture in a conversation and where it came from.
class ThreadPhoto {
  const ThreadPhoto({required this.block, required this.origin});

  final ImageBlock block;

  /// `Sent by omp · May 20, 2026 at 09:30`, `Tool result · Read chart.png`,
  /// `You attached it`: what makes the picture recognisable as the right one.
  final String origin;
}

/// The pictures of [state], in the order the conversation shows them: the
/// ones inside messages (yours and the agent's) and the ones tools returned.
/// Only blocks that carry data are listed (a bare uri is a link, not a
/// picture). [agentLabel] names the sender of the agent's own.
List<ThreadPhoto> threadPhotos(AgentSessionState state, {required String agentLabel}) {
  final out = <ThreadPhoto>[];
  for (final item in state.items) {
    switch (item) {
      case TranscriptMessage(:final role, :final blocks, :final at):
        final when = at == null ? '' : ' · ${formatExactTime(at)}';
        final from = switch (role) {
          MessageRole.user => 'You attached it$when',
          MessageRole.agent => 'Sent by ${visibleText(agentLabel)}$when',
          MessageRole.thought => '${visibleText(agentLabel)} thinking$when',
        };
        for (final block in blocks) {
          if (block is ImageBlock && block.data.isNotEmpty) out.add(ThreadPhoto(block: block, origin: from));
        }
      case TranscriptTool(:final call):
        final title = visibleText(call.title.isNotEmpty ? call.title : (call.name ?? 'tool'));
        for (final part in call.content) {
          if (part is ToolContentBlock) {
            final block = part.block;
            if (block is ImageBlock && block.data.isNotEmpty) {
              out.add(ThreadPhoto(block: block, origin: 'Tool result · $title'));
            }
          }
        }
      case TranscriptStop() || TranscriptNote():
        break;
    }
  }
  return out;
}

/// What a tap on a picture in the transcript can page through: the session
/// whose transcript it is. Read when the tap happens, never while the rows
/// are drawn.
class ThreadPhotos extends InheritedWidget {
  const ThreadPhotos({super.key, required this.session, required super.child});

  final AgentSessionView session;

  static ThreadPhotos? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<ThreadPhotos>();

  @override
  bool updateShouldNotify(ThreadPhotos old) => false;
}

/// `png` for `image/png`; `jpg` for an unknown or odd type (the bytes decide
/// what it is, the name only has to be something a receiving app accepts).
String imageExtension(String mime) => switch (mime.toLowerCase().split(';').first.trim()) {
  'image/png' => 'png',
  'image/gif' => 'gif',
  'image/webp' => 'webp',
  'image/bmp' => 'bmp',
  _ => 'jpg',
};

/// The viewer's item for a picture of the conversation: [number] is its
/// 1-based place among the thread's pictures, for a name when the agent gave
/// none.
PhotoItem chatPhotoItem(ThreadPhoto photo, int number, {ImagePreviewCache? cache}) {
  final block = photo.block;
  final uri = block.uri?.trim() ?? '';
  final given = uri.isEmpty ? '' : visibleText(contentBaseName(uri));
  final previews = cache ?? ImagePreviewCache.shared;
  return PhotoItem(
    id: 'chat:$number',
    name: given.isNotEmpty ? given : 'image-$number.${imageExtension(block.mimeType)}',
    mime: block.mimeType.isEmpty ? null : block.mimeType,
    origin: photo.origin,
    source: MemoryPhotoSource(
      () => decodeImageDataFor(block),
      size: base64DecodedLength(block.data),
    ),
    placeholder: () => previews.cloneOf(block),
  );
}

/// Opens [block] in the viewer, among the other pictures of the conversation
/// when the tap came from a transcript (the viewer pages through them). The
/// composer lets go of the focus first: Back would otherwise give it the
/// keyboard again, over the history someone is reading.
Future<void> showContentImage(BuildContext context, ImageBlock block, {String? origin}) {
  FocusManager.instance.primaryFocus?.unfocus();
  final scope = ThreadPhotos.maybeOf(context);
  var photos = <ThreadPhoto>[];
  if (scope != null) {
    photos = threadPhotos(scope.session.state, agentLabel: scope.session.agentLabel);
  }
  var at = photos.indexWhere((p) => identical(p.block, block));
  if (at < 0) {
    // Not part of the transcript the scope sees (a sub-agent's, a live copy):
    // the picture alone.
    photos = [ThreadPhoto(block: block, origin: origin ?? 'Sent in the conversation')];
    at = 0;
  }
  return openPhotoViewer(
    context,
    items: [for (final (i, p) in photos.indexed) chatPhotoItem(p, i + 1)],
    initialIndex: at,
  );
}
