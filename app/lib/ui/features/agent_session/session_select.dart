import 'package:flutter/widgets.dart';

import '../../../data/repositories/agent_session.dart';

/// Called with the name of a region (`screen`, `select`, `transcript`,
/// `bottom`) each time its `build` runs. Tests use it to prove that the
/// keyboard moving rebuilds none of them.
@visibleForTesting
ValueSetter<String>? debugRegionBuilt;

/// Reports a region build to [debugRegionBuilt].
void notifyRegionBuilt(String region) => debugRegionBuilt?.call(region);

/// Rebuilds [builder] only when what [select] reads from [session] changes.
///
/// A session notifies for every batch of chunks; the regions of the screen
/// (bar, plan, docks, composer) each care about a different slice, so each one
/// selects its own and a streaming answer rebuilds none of the others. Values
/// compare with [same] (default `==`; lists in the session state are replaced
/// whole when they change, so identity is the right test for them).
class SessionSelect<T> extends StatefulWidget {
  const SessionSelect({
    super.key,
    required this.session,
    required this.select,
    required this.builder,
    this.same,
  });

  final AgentSessionView session;
  final T Function(AgentSessionView session) select;
  final Widget Function(BuildContext context, T value) builder;
  final bool Function(T a, T b)? same;

  @override
  State<SessionSelect<T>> createState() => _SessionSelectState<T>();
}

class _SessionSelectState<T> extends State<SessionSelect<T>> {
  late T _value = widget.select(widget.session);

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSession);
  }

  @override
  void didUpdateWidget(SessionSelect<T> old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
    }
    _value = widget.select(widget.session);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    final next = widget.select(widget.session);
    final same = widget.same;
    if (same == null ? next == _value : same(next, _value)) return;
    setState(() => _value = next);
  }

  @override
  Widget build(BuildContext context) {
    notifyRegionBuilt('select');
    return widget.builder(context, _value);
  }
}
