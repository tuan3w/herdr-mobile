import 'package:flutter/foundation.dart';

import 'herdr_models.dart' show AgentStatus;

/// When an agent entered its current status, as far as this app knows.
///
/// herdr exposes no status timestamp, so the app dates a change when it sees
/// it. [exact] is a change seen as it happened (the event stream was live):
/// the state began at [at]. Otherwise the change was found after a gap (the
/// app was suspended, offline or restarted) and [at] is the last moment the
/// pane was seen in its previous status: the change came after it, so the state
/// is at most that old. The board shows that as `≤ 25m`, never as `<1m`.
@immutable
class StatusTime {
  const StatusTime.exact(this.at) : exact = true;

  const StatusTime.after(this.at) : exact = false;

  final DateTime at;
  final bool exact;

  /// How far back the state reaches at [now]: the length of the state when
  /// [exact], the gap it was discovered after otherwise. Never negative (a
  /// device clock set back).
  Duration since(DateTime now) {
    final d = now.difference(at);
    return d.isNegative ? Duration.zero : d;
  }

  /// Milliseconds since the epoch: a moment, not a wall-clock reading, so a
  /// time-zone or daylight-saving change cannot shift it. (Older records wrote
  /// the local time as ISO text without an offset; [fromJson] still reads them.)
  Map<String, Object> toJson() => {'at': at.millisecondsSinceEpoch, if (!exact) 'bound': true};

  static StatusTime? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final parsed = momentFromJson(raw['at']);
    if (parsed == null) return null;
    return raw['bound'] == true ? StatusTime.after(parsed) : StatusTime.exact(parsed);
  }

  /// Equal when it is the same moment, however the [DateTime] was made (a
  /// restored one is local, a test's may be UTC).
  @override
  bool operator ==(Object other) =>
      other is StatusTime && other.at.isAtSameMomentAs(at) && other.exact == exact;

  @override
  int get hashCode => Object.hash(at.millisecondsSinceEpoch, exact);

  @override
  String toString() => exact ? 'StatusTime.exact($at)' : 'StatusTime.after($at)';
}

/// One pane's status as last observed, with what is known of its start.
typedef ObservedStatus = ({AgentStatus status, StatusTime? since});

/// What a connection has learned about its panes' status times, kept beside
/// the cached snapshot so a restart does not forget it.
@immutable
class ObservedStatuses {
  const ObservedStatuses({required this.seenAt, required this.panes});

  /// The last time a live snapshot was taken: every pane in [panes] was in
  /// the status recorded for it then.
  final DateTime seenAt;
  final Map<String, ObservedStatus> panes;

  Map<String, Object> toJson() => {
        'seen': seenAt.millisecondsSinceEpoch,
        'panes': {
          for (final MapEntry(:key, :value) in panes.entries)
            key: {
              's': value.status.name,
              if (value.since case final since?) 't': since.toJson(),
            },
        },
      };

  /// Null for anything that is not what [toJson] writes.
  static ObservedStatuses? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final seenAt = momentFromJson(raw['seen']);
    final panes = raw['panes'];
    if (seenAt == null || panes is! Map) return null;
    final out = <String, ObservedStatus>{};
    for (final MapEntry(:key, :value) in panes.entries) {
      if (key is! String || value is! Map) continue;
      out[key] = (status: AgentStatus.parse(value['s']), since: StatusTime.fromJson(value['t']));
    }
    return ObservedStatuses(seenAt: seenAt, panes: out);
  }
}

/// A moment as [StatusTime.toJson] and [ObservedStatuses.toJson] write it:
/// epoch milliseconds, or, in records written by early development builds,
/// local ISO text.
/// Null for anything else.
DateTime? momentFromJson(Object? raw) => switch (raw) {
      final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
      final String text => DateTime.tryParse(text),
      _ => null,
    };
