import 'package:flutter/material.dart';

import '../../data/models/herdr_models.dart';
import '../../data/repositories/machine_connection.dart';

extension AgentStatusStyle on AgentStatus {
  /// Colour is meaning: amber = needs you.
  Color get color => switch (this) {
        AgentStatus.blocked => const Color(0xFFF59E0B),
        AgentStatus.working => const Color(0xFF3B82F6),
        AgentStatus.done => const Color(0xFF22C55E),
        AgentStatus.idle => const Color(0xFF9CA3AF),
        AgentStatus.unknown => const Color(0xFF6B7280),
      };

  IconData get icon => switch (this) {
        AgentStatus.blocked => Icons.front_hand_rounded,
        AgentStatus.working => Icons.autorenew_rounded,
        AgentStatus.done => Icons.check_circle_rounded,
        AgentStatus.idle => Icons.pause_circle_outline_rounded,
        AgentStatus.unknown => Icons.help_outline_rounded,
      };

  String get label => switch (this) {
        AgentStatus.blocked => 'Needs you',
        AgentStatus.working => 'Working',
        AgentStatus.done => 'Done',
        AgentStatus.idle => 'Idle',
        AgentStatus.unknown => 'Unknown',
      };
}

extension LinkStateStyle on LinkState {
  Color get color => switch (this) {
        LinkState.online => const Color(0xFF22C55E),
        LinkState.connecting || LinkState.reconnecting => const Color(0xFF3B82F6),
        LinkState.attention => const Color(0xFFF59E0B),
        LinkState.disabled => const Color(0xFF9CA3AF),
      };

  String get label => switch (this) {
        LinkState.online => 'Online',
        LinkState.connecting => 'Connecting…',
        LinkState.reconnecting => 'Reconnecting…',
        LinkState.attention => 'Needs attention',
        LinkState.disabled => 'Disabled',
      };
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 10});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}
