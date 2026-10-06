final _link = RegExp(r'https://[^\s<>"]+');
final _trailingPunctuation = RegExp(r'[.,;:!?)\]}]+$');

/// The sign-in link in an SSH login banner, or null.
///
/// Tailscale SSH in check mode answers a login with a banner such as
/// `# Tailscale SSH requires an additional check. To authenticate, visit:
/// https://login.tailscale.com/a/abc123` and then waits for the person to
/// approve it in a browser.
///
/// Banner text is chosen by the server, so only a plain `https` link with a
/// host is ever returned: a hostile or compromised machine must not be able to
/// make the app open any other kind of link.
String? approvalUrlFrom(String banner) {
  final match = _link.firstMatch(banner);
  if (match == null) return null;
  final url = match.group(0)!.replaceFirst(_trailingPunctuation, '');
  if (url.length > 2048) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  return uri.toString();
}
