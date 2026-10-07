import 'package:herdr_mobile/data/services/dictation.dart';

/// A speech engine that says what it is told to, and records what it is asked.
class FakeEngine implements SpeechEngine {
  bool initOk = true;
  bool permitted = true;

  /// Reported through the error callback while initializing, as the plugin does for a refusal.
  String? initError;
  List<DictationLanguage> languagesAvailable = const [
    DictationLanguage('vi_VN', 'Tiếng Việt (Việt Nam)'),
    DictationLanguage('en_US', 'English (United States)'),
    DictationLanguage('fr_FR', 'français (France)'),
  ];
  final listenedIn = <String?>[];
  int stops = 0;
  int cancels = 0;
  Object? listenFailure;

  late void Function(String, bool) onError;
  late void Function(bool) onListening;
  void Function(String, bool)? onWords;

  @override
  Future<bool> initialize({required void Function(String error, bool permanent) onError, required void Function(bool listening) onListening}) async {
    this.onError = onError;
    this.onListening = onListening;
    if (initError case final e?) onError(e, true);
    return initOk;
  }

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<List<DictationLanguage>> languages() async => languagesAvailable;

  @override
  Future<void> listen({required String? languageId, required void Function(String words, bool isFinal) onWords}) async {
    if (listenFailure case final f?) throw f;
    listenedIn.add(languageId);
    this.onWords = onWords;
    onListening(true);
  }

  @override
  Future<void> stop() async {
    stops++;
    onListening(false);
  }

  @override
  Future<void> cancel() async {
    cancels++;
    onListening(false);
  }

  void hear(String words, {bool isFinal = false}) => onWords!(words, isFinal);
}

class MemoryDictationStore implements DictationStore {
  MemoryDictationStore([this.saved]);
  String? saved;

  @override
  Future<String?> read() async => saved;

  @override
  Future<void> write(String? languageId) async => saved = languageId;
}
