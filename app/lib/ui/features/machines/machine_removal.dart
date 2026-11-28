import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../data/models/machine_profile.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/machine_repository.dart';
import '../../../data/services/ssh_transport.dart' show hostKeyChangedMessage;

import 'package:herdr_mobile/ui/core/kit.dart';

/// Whether [machine] refused to connect because its host key is not the one
/// that was trusted. The app never replaces a trusted key, so trying again
/// fails the same way: the way out is to remove the machine and add it again
/// (the words of the failure say so), and the row and the screen offer Remove
/// where they would offer Retry.
bool hostKeyChanged(MachineConnection machine) => machine.error == hostKeyChangedMessage;

/// The one way a machine is removed: the confirm sheet names it and asks for a
/// hold, because its saved connection and credentials are deleted and cannot be
/// brought back. Completes true when it was removed.
Future<bool> confirmRemoveMachine(BuildContext context, MachineProfile machine) async {
  final repo = context.read<MachineRepository>();
  final ok = await showConfirmSheet(
    context,
    title: 'Remove ${machine.label}?',
    message:
        'The saved connection and its credentials are deleted from this '
        'phone. Agents on the machine keep running.',
    confirmLabel: 'Remove',
    hold: true,
  );
  if (ok) await repo.remove(machine.id);
  return ok;
}
