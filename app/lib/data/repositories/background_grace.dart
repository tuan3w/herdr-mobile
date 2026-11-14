/// How long the app may stay in the background before it lets go of what it
/// holds (connections, chats, a followed log). A function, read when the app
/// goes away, so the person's choice (`AppSettings.backgroundHold`) applies
/// from the next absence without rebuilding the repositories and sessions that
/// were made before it changed.
typedef BackgroundGrace = Duration Function();

/// The grace of a repository that was handed no choice: 90 s, what the app
/// always did before the person could choose.
Duration defaultBackgroundGrace() => const Duration(seconds: 90);
