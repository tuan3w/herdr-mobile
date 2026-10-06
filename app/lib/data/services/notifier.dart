/// Whether Android lets the app post notifications (Android 13 asks at run
/// time; older versions always allow).
enum NotifyPermission { granted, denied }

/// Which channel a notification goes to. `needsYou` is the one that matters
/// (an agent is blocked on a question); `finished` is opt-in.
enum NotifyKind { needsYou, finished }

/// One notification about one agent. [id] is stable per agent (see
/// [notificationIdFor]) so a later change replaces or cancels the same one.
class AgentNotification {
  const AgentNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.link,
    this.collapsed,
    this.answers = const [],
  });

  final int id;
  final NotifyKind kind;
  final String title;

  /// The whole text. A notification with [answers] puts here what the buttons
  /// approve (the question and the command), so the person can read it before
  /// pressing one.
  final String body;

  /// The one line shown while the notification is collapsed (a heads-up
  /// shows only this); null means [body] is short enough.
  final String? collapsed;

  /// A `herdr://` link the tap opens: `herdr://agent/<machine>/<pane>` for a
  /// terminal agent, `herdr://session/<machine>/<keeper>` for an agent
  /// session.
  final String link;

  /// Buttons that answer the agent's question without opening the app, at most
  /// [maxNotificationAnswers]. Never an answer that asks for a second tap.
  final List<NotificationAnswer> answers;
}

/// Most answer buttons one notification carries.
const maxNotificationAnswers = 2;

/// One answer button: which option of which question of which pane, as the
/// notification saw it. It travels through the system as [actionId] and comes
/// back to [Notifier.onAnswer] when the button is pressed; whoever acts on it
/// must read the pane's question again and send nothing unless it still is
/// the one [digest] names.
class NotificationAnswer {
  const NotificationAnswer({
    required this.machineId,
    required this.paneId,
    required this.digest,
    required this.index,
    required this.nonce,
    this.label = '',
  });

  final String machineId;
  final String paneId;

  /// Fingerprint of the question this notification showed (`promptDigest`).
  final String digest;

  /// Position of the option in the question's answers, in on-screen order.
  final int index;

  /// Unique per posted notification: an action delivered twice answers once.
  final String nonce;

  /// The button's text (not part of [actionId]).
  final String label;

  static const _tag = 'answer';

  /// What the platform hands back when the button is pressed.
  String get actionId => [
        _tag,
        Uri.encodeComponent(machineId),
        Uri.encodeComponent(paneId),
        digest,
        index,
        Uri.encodeComponent(nonce),
      ].join('|');

  /// Reads an [actionId] back; null for anything else.
  static NotificationAnswer? tryParse(String? actionId) {
    if (actionId == null) return null;
    final parts = actionId.split('|');
    if (parts.length != 6 || parts[0] != _tag) return null;
    final index = int.tryParse(parts[4]);
    if (index == null || index < 0 || parts[3].isEmpty) return null;
    try {
      return NotificationAnswer(
        machineId: Uri.decodeComponent(parts[1]),
        paneId: Uri.decodeComponent(parts[2]),
        digest: parts[3],
        index: index,
        nonce: Uri.decodeComponent(parts[5]),
      );
    } on ArgumentError {
      return null;
    }
  }
}

/// Runs when an answer button is pressed: the answer, and the id of the
/// notification it was on. Android has already taken that notification away
/// by then.
typedef AnswerHandler = Future<void> Function(NotificationAnswer answer, int notificationId);

/// What a notification says when its answer was not sent, with the tap that
/// opens the agent. [Notifier]s outside the app's main isolate use it too.
const answerNotSentTitle = 'Answer not sent';

/// Local notifications and the quiet "watching" notice that keeps the process
/// alive while agents work. Everything is local: nothing leaves the phone.
abstract interface class Notifier {
  Future<NotifyPermission> permission();

  /// Shows the system dialog when the permission is not yet decided.
  Future<NotifyPermission> requestPermission();

  Future<void> show(AgentNotification notification);

  Future<void> cancel(int id);

  /// Cancels every agent notification (not the watching notice).
  Future<void> cancelAll();

  /// Runs (when [count] > 0) or stops (0) a quiet foreground notice, "Watching
  /// N agents" over "2 need you · 3 working" ([blocked] of the [count] wait
  /// for the person, the rest work), so Android keeps the connection alive
  /// while the app is in the background. False when Android refused to start
  /// it. Asked again with the same numbers it does nothing.
  Future<bool> setWatching(int count, {int blocked = 0});

  /// Registers who handles a tap: the link of the tapped notification, also
  /// for a tap that launched the app (delivered once the handler is set).
  void onOpen(void Function(String link) handler);

  /// Registers who handles a press on an answer button.
  void onAnswer(AnswerHandler handler);
}

/// Where tests and platforms without notifications end up.
class NullNotifier implements Notifier {
  const NullNotifier();

  @override
  Future<NotifyPermission> permission() async => NotifyPermission.denied;

  @override
  Future<NotifyPermission> requestPermission() async => NotifyPermission.denied;

  @override
  Future<void> show(AgentNotification notification) async {}

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> cancelAll() async {}

  @override
  Future<bool> setWatching(int count, {int blocked = 0}) async => false;

  @override
  void onOpen(void Function(String link) handler) {}

  @override
  void onAnswer(AnswerHandler handler) {}
}

/// A positive 31-bit id for [key] (FNV-1a), the same on every run, so a
/// notification can be replaced or cancelled by the agent it is about.
int notificationIdFor(String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}
