import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/services/herdr_api.dart';
import '../../../data/services/herdr_transport.dart';

/// Live tail of one pane plus the ability to type into it.
class PaneViewModel extends ChangeNotifier {
  PaneViewModel({
    required this._api,
    required this.paneId,
    this.pollInterval = const Duration(seconds: 1),
    this.lines = 300,
  }) {
    refresh();
    _timer = Timer.periodic(pollInterval, (_) => refresh());
  }

  final HerdrApi _api;
  final String paneId;
  final Duration pollInterval;
  final int lines;

  Timer? _timer;
  bool _busy = false;
  bool _disposed = false;
  String _text = '';
  String? _error;
  bool _sending = false;

  String get text => _text;
  String? get error => _error;
  bool get sending => _sending;

  Future<void> refresh() async {
    if (_busy || _disposed) return;
    _busy = true;
    try {
      final read = await _api.readPane(paneId, lines: lines);
      _error = null;
      if (read.text != _text) _text = read.text;
    } on HerdrApiException catch (e) {
      _error = e.toString();
    } on HerdrTransportException catch (e) {
      _error = e.message;
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Types [text] and presses enter.
  Future<bool> sendLine(String text) => _send(() => _api.sendLine(paneId, text));

  /// Sends herdr key-combo strings (`esc`, `ctrl+c`, `up` …).
  Future<bool> sendKeys(List<String> keys) =>
      _send(() => _api.sendKeys(paneId, keys));

  Future<bool> _send(Future<void> Function() action) async {
    _sending = true;
    notifyListeners();
    try {
      await action();
      _error = null;
      unawaited(refresh());
      return true;
    } on HerdrApiException catch (e) {
      _error = e.toString();
      return false;
    } on HerdrTransportException catch (e) {
      _error = e.message;
      return false;
    } finally {
      _sending = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
