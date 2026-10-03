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
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Object {
    return false;
  }
}
