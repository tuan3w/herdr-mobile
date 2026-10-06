import 'package:url_launcher/url_launcher.dart';

/// Opens [url] in the phone's browser, outside the app. Returns false when no
/// browser could handle it.
///
/// Only `https` links are opened. The links this is used for come from the text
/// a remote machine sends (a login banner), so anything else is refused here
/// as well as where the link is extracted.
Future<bool> openInBrowser(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
  return _launch(uri);
}

/// Opens a link the user tapped in terminal output: `http` and `https`.
///
/// Plain `http` is allowed here and nowhere else because this is only called
/// from an explicit tap, on a screen that shows the whole address first.
Future<bool> openTappedLink(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return false;
  if (uri.scheme != 'https' && uri.scheme != 'http') return false;
  return _launch(uri);
}

Future<bool> _launch(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Object {
    return false;
  }
}

/// Whether [url] points at the machine the output came from rather than at
/// somewhere the phone can reach: `localhost`, a loopback or unspecified
/// address, or a `.local` name. Opening it on the phone would reach the phone
/// (or nothing).
bool isMachineLocalUrl(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase();
  if (host == null || host.isEmpty) return false;
  if (host == 'localhost' || host.endsWith('.localhost')) return true;
  if (host == '::1' || host == '::' || host == '0.0.0.0') return true;
  if (host.endsWith('.local')) return true;
  return RegExp(r'^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(host);
}
