import 'package:flutter/material.dart';

import '../../../data/repositories/machine_connection.dart';
import 'past_sessions_screen.dart';

/// Opens the Past sessions screen: what the agents remember, to bring one back.
/// On [machine] when given (the one used last otherwise); with [cwd], the
/// `This folder` chip filters on it.
Future<void> openPastSessions(BuildContext context, {MachineConnection? machine, String? cwd}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PastSessionsScreen(machineId: machine?.profile.id, cwd: cwd)),
    );
