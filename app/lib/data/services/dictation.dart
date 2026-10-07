import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// A language the phone's speech service can listen in.
class DictationLanguage {
  const DictationLanguage(this.id, this.name);

  /// `en_US`, `vi_VN`: what the recognizer is asked for.
  final String id;

  /// How the phone names it (`Tiếng Việt (Việt Nam)`).
  final String name;
}

/// One listen, as the app needs it. The plugin is behind this so the rest of
/// the app (and its tests) never import it.
abstract interface class SpeechEngine {
  /// Asks for the microphone on the first call and prepares the recognizer.
  /// False when it is denied or the phone has no speech service.
  Future<bool> initialize({required void Function(String error, bool permanent) onError, required void Function(bool listening) onListening});

  Future<List<DictationLanguage>> languages();

  /// Whether the microphone is allowed. Does not ask.
  Future<bool> hasPermission();

  /// Starts a listen in [languageId] (null: the phone's language). [onWords] gets the
  /// words so far, `isFinal` once the recognizer settled on them.
  Future<void> listen({required String? languageId, required void Function(String words, bool isFinal) onWords});

  Future<void> stop();

  Future<void> cancel();
}

class PluginSpeechEngine implements SpeechEngine {
  final _speech = SpeechToText();

  @override
  Future<bool> initialize({required void Function(String error, bool permanent) onError, required void Function(bool listening) onListening}) =>
      _speech.initialize(
        onError: (SpeechRecognitionError e) => onError(e.errorMsg, e.permanent),
        onStatus: (status) => onListening(status == 'listening'),
      );

  @override
  Future<List<DictationLanguage>> languages() async => [
        for (final l in await _speech.locales()) DictationLanguage(l.localeId, l.name),
      ];

  @override
  Future<bool> hasPermission() => _speech.hasPermission;

  @override
  Future<void> listen({required String? languageId, required void Function(String words, bool isFinal) onWords}) =>
      _speech.listen(
        onResult: (r) => onWords(r.recognizedWords, r.finalResult),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          listenMode: ListenMode.dictation,
          cancelOnError: true,
          localeId: languageId,
          // A pause this long ends the listen: the person has stopped talking.
          pauseFor: const Duration(seconds: 4),
          listenFor: const Duration(minutes: 1),
        ),
      );

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();
}

/// Where the chosen language is kept.
abstract interface class DictationStore {
  Future<String?> read();

  Future<void> write(String? languageId);
}

class PrefsDictationStore implements DictationStore {
  static const _key = 'dictation.language.v1';

  @override
  Future<String?> read() async => (await SharedPreferences.getInstance()).getString(_key);

  @override
  Future<void> write(String? languageId) async {
    final prefs = await SharedPreferences.getInstance();
    if (languageId == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, languageId);
    }
  }
}

/// Why a listen did not start or ended badly, in words for the person: what
/// happened and what to do next. Null when nothing is wrong.
enum DictationProblem {
  denied('Microphone is off for herdr. Allow it in Android settings > Apps > herdr > Permissions.'),
  unavailable('This phone has no speech service. Install or enable Google speech services.'),
  language('The speech service does not have this language. Pick another one with a long press on the mic.'),
  offline('Speech needs a connection, or an offline language installed in the speech service.'),
  silence('Heard nothing. Tap the mic and speak.'),
  failed('Dictation stopped. Tap the mic to try again.');

  const DictationProblem(this.message);

  final String message;
}

/// Dictation for the message boxes: one listen at a time on the whole app,
/// in the language the person picked (or the phone's).
///
/// Android's recognizer listens in ONE language per listen, so a sentence that
/// mixes Vietnamese and English is not understood in both: the person picks the
/// language that matters, with a long press on the mic. It may send the audio
/// to Google unless an offline language is installed in the phone's speech
/// service; the picker says so.
class Dictation extends ChangeNotifier {
  Dictation(this._engine, this._store);

  final SpeechEngine _engine;
  final DictationStore _store;

  String? _languageId;
  bool _listening = false;
  bool _ready = false;
  DictationProblem? _problem;
  void Function(DictationProblem)? _onProblem;

  /// The language asked for; null means the phone's language.
  String? get languageId => _languageId;

  bool get listening => _listening;

  Future<void> load() async {
    try {
      _languageId = await _store.read();
    } on Object {
      _languageId = null;
    }
    notifyListeners();
  }

  Future<bool> _prepare() async {
    if (_ready) return true;
    try {
      _ready = await _engine.initialize(
        onError: _engineError,
        onListening: (on) {
          if (on == _listening) return;
          _listening = on;
          notifyListeners();
        },
      );
    } on Object {
      _ready = false;
    }
    return _ready;
  }

  void _engineError(String error, bool permanent) {
    final problem = switch (error) {
      'error_no_match' || 'error_speech_timeout' => DictationProblem.silence,
      'error_permission' => DictationProblem.denied,
      'error_language_not_supported' || 'error_language_unavailable' => DictationProblem.language,
      'error_network' || 'error_network_timeout' || 'error_server' => DictationProblem.offline,
      _ => DictationProblem.failed,
    };
    _problem = problem;
    if (_listening) {
      _listening = false;
      notifyListeners();
    }
    _onProblem?.call(problem);
  }

  /// The languages to choose from: those of the phone's speech service, the
  /// person's own ones first (English and Vietnamese) and the rest by name.
  /// Empty when there is no speech service or no permission.
  Future<List<DictationLanguage>> languages() async {
    if (!await _prepare()) return const [];
    final all = await _engine.languages();
    int rank(DictationLanguage l) {
      final id = l.id.toLowerCase();
      if (id.startsWith('en')) return 0;
      if (id.startsWith('vi')) return 1;
      return 2;
    }

    return [...all]..sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : a.name.compareTo(b.name);
      });
  }

  Future<void> setLanguage(String? id) async {
    _languageId = id;
    notifyListeners();
    try {
      await _store.write(id);
    } on Object {
      // Kept for this run; the choice is asked again next launch.
    }
  }

  /// Starts listening. [onWords] gets what was heard so far (`isFinal` when it
  /// is settled); [onProblem] is told why a listen ended badly. Returns false,
  /// after telling [onProblem], when it could not start.
  Future<bool> start({
    required void Function(String words, bool isFinal) onWords,
    required void Function(DictationProblem problem) onProblem,
  }) async {
    if (_listening) return true;
    _onProblem = onProblem;
    _problem = null;
    if (!await _prepare()) {
      // The recognizer reports a denial itself only sometimes: ask it, so the
      // person is told to allow the microphone, not that nothing is installed.
      if (_problem == null) {
        onProblem(await _engine.hasPermission() ? DictationProblem.unavailable : DictationProblem.denied);
      }
      return false;
    }
    try {
      _listening = true;
      notifyListeners();
      await _engine.listen(languageId: _languageId, onWords: onWords);
    } on Object {
      _listening = false;
      notifyListeners();
      onProblem(DictationProblem.failed);
      return false;
    }
    return true;
  }

  /// Ends the listen and lets the recognizer settle what it heard.
  Future<void> stop() async {
    if (!_listening) return;
    await _engine.stop();
    _listening = false;
    notifyListeners();
  }

  /// Ends the listen and drops what is unsettled (the screen is going away).
  Future<void> cancel() async {
    if (!_listening) return;
    await _engine.cancel();
    _listening = false;
    notifyListeners();
  }
}
