import 'package:herdr_mobile/data/services/notifier.dart';

/// A [Notifier] that only remembers what it was asked, in order.
class FakeNotifier implements Notifier {
  FakeNotifier({this.granted = true});

  /// What [permission] and [requestPermission] answer.
  bool granted;

  /// Whether [setWatching] succeeds for a count above zero.
  bool watchingWorks = true;

  /// While set, [show], [cancel], [cancelAll] and [setWatching] throw.
  bool failing = false;

  /// Every call, in order: `show:<id>`, `cancel:<id>`, `cancelAll`, `watching:<n>`.
  final List<String> log = [];

  /// Every notification passed to [show], oldest first.
  final List<AgentNotification> shown = [];

  /// What [cancel] and [cancelAll] have not removed since it was shown: what
  /// the person would see in the shade.
  final Map<int, AgentNotification> active = {};

  /// The counts passed to [setWatching], in order.
  final List<int> watching = [];

  /// What [setWatching] was told, in order: agents watched and how many of
  /// them are blocked.
  final List<({int count, int blocked})> glances = [];

  int cancelAllCount = 0;
  int permissionReads = 0;
  void Function(String link)? opened;
  AnswerHandler? answered;

  /// Active notifications, oldest first.
  List<AgentNotification> get visible => active.values.toList();

  /// The active notification with this title.
  AgentNotification? titled(String title) {
    for (final n in active.values) {
      if (n.title == title) return n;
    }
    return null;
  }

  /// How many times [show] was called with notification [id].
  int showsOf(int id) => shown.where((n) => n.id == id).length;

  @override
  Future<NotifyPermission> permission() async {
    permissionReads++;
    return granted ? NotifyPermission.granted : NotifyPermission.denied;
  }

  @override
  Future<NotifyPermission> requestPermission() => permission();

  @override
  Future<void> show(AgentNotification notification) async {
    log.add('show:${notification.id}');
    if (failing) throw StateError('cannot post');
    shown.add(notification);
    active.remove(notification.id);
    active[notification.id] = notification;
  }

  @override
  Future<void> cancel(int id) async {
    log.add('cancel:$id');
    if (failing) throw StateError('cannot cancel');
    active.remove(id);
  }

  @override
  Future<void> cancelAll() async {
    log.add('cancelAll');
    cancelAllCount++;
    if (failing) throw StateError('cannot cancel');
    active.clear();
  }

  @override
  Future<bool> setWatching(int count, {int blocked = 0}) async {
    log.add('watching:$count');
    if (failing) throw StateError('cannot start');
    watching.add(count);
    glances.add((count: count, blocked: blocked));
    return count > 0 && watchingWorks;
  }

  @override
  void onOpen(void Function(String link) handler) => opened = handler;

  @override
  void onAnswer(AnswerHandler handler) => answered = handler;

  /// The person presses [answer]'s button on notification [id]: Android takes
  /// the notification away, then the app hears of the press.
  Future<void> press(NotificationAnswer answer, int id) {
    active.remove(id);
    return answered!(answer, id);
  }

  /// The first button of the active notification [id].
  NotificationAnswer button(int id, [int n = 0]) => active[id]!.answers[n];
}
