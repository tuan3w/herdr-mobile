import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

/// Tells [onChange] whether a screen is the one in front and the app is in the
/// foreground: work that only matters while a person looks at it (following a
/// file on the host, a search that is still running) starts and stops with it.
/// Another screen covering this one, the background and a closed screen all say
/// `false`; coming back says `true` again.
///
/// Call [attach] from `didChangeDependencies` and [dispose] from `dispose`.
class InFront {
  InFront(this.onChange);

  final void Function(bool front) onChange;
  ValueListenable<TickerModeData>? _front;
  AppLifecycleListener? _life;
  var _resumed = true;

  void attach(BuildContext context) {
    final front = TickerMode.getValuesNotifier(context);
    if (!identical(front, _front)) {
      _front?.removeListener(_sync);
      _front = front..addListener(_sync);
    }
    if (_life == null) {
      final state = WidgetsBinding.instance.lifecycleState;
      _resumed = state == null || state == AppLifecycleState.resumed;
      _life = AppLifecycleListener(
        onStateChange: (s) {
          _resumed = s == AppLifecycleState.resumed;
          _sync();
        },
      );
    }
    _sync();
  }

  void _sync() => onChange(_resumed && (_front?.value.enabled ?? true));

  void dispose() {
    onChange(false);
    _front?.removeListener(_sync);
    _life?.dispose();
  }
}
