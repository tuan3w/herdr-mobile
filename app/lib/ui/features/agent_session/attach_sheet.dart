import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/repositories/agent_session.dart';
import '../../core/toast.dart';
import '../attach/attach_sheet_view.dart';
import '../attach/sheet_frame.dart';
import '../attach/tray.dart';
import 'attach_model.dart';

/// The reason shown under the picture items of an agent that takes none.
const noImagesReason = 'This agent does not take images';

/// The attach button's sheet: photos of the phone (Gallery), files of the
/// phone (Files) and files of the machine (Host), one tray for all three.
///
/// The route is pushed on the same frame as the tap: nothing is awaited before
/// it, and the tabs draw what they have (the camera tile, the bars) while the
/// library answers. What is picked becomes chips in the frame the sheet starts
/// to leave; the reading, encoding and uploading begin when it is gone. A
/// message is full at [maxAttachments]; then the sheet does not open and a
/// toast says so.
Future<void> showAttachSheet(
  BuildContext context, {
  required AgentSessionView session,
  required ComposerAttachments attachments,
}) async {
  if (attachments.full) {
    showToast(context, 'At most $maxAttachments attachments per message.');
    return;
  }
  // A second tap while the sheet is coming up is the same tap.
  if (attachments.sheetOpen) return;
  attachments.sheetOpen = true;
  final toaster = Toaster.of(context);
  final navigator = Navigator.of(context);
  final reduced = MediaQuery.disableAnimationsOf(context);
  late final AttachTray tray;
  late final AttachSheetController controller;
  late final AttachSheetRoute<AttachOutcome> route;
  AttachOutcome? outcome;
  tray = AttachTray(
    capacity: attachments.room,
    onAdded: attachments.speculate,
    onRemoved: attachments.abandon,
    onFull: () => toaster.show('At most $maxAttachments attachments per message.'),
  );
  controller = AttachSheetController(
    kit: attachments.kit,
    session: session,
    tray: tray,
    onProblem: (m) => toaster.show(m),
    finish: (o) {
      if (outcome != null) return;
      outcome = o;
      attachments.stage(tray.take());
      navigator.pop(o);
    },
  );
  route = AttachSheetRoute<AttachOutcome>(reduced: reduced, content: controller.buildBody, bars: controller.buildBars);
  unawaited(navigator.push(route));
  await route.completed;
  attachments.sheetOpen = false;
  // The sheet is gone (its animation finished): the work starts now. Picks
  // that were not attached give up the encoding begun for them.
  for (final item in tray.take()) {
    attachments.abandon(item);
  }
  tray.dispose();
  controller.dispose();
  attachments.startStaged();
  switch (outcome) {
    case AttachOutcome.camera:
      await attachments.addPhoto(camera: true);
    case AttachOutcome.systemPicker:
      await attachments.addPhoto(camera: false);
    case AttachOutcome.attached || null:
      break;
  }
}
