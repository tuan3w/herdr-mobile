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

final _escape = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');
final _control = RegExp(r'[\x00-\x1F\x7F]+');
final _tailscalePrefix = RegExp(r'^(#\s*)?tailscale:\s*', caseSensitive: false);

/// Why the machine refused a sign-in, from the banner it sent first, or null.
///
/// Tailscale SSH does not answer a refusal with an error code; it sends the
/// reason as a banner (`tailscale: tailnet policy does not permit you to SSH as
/// user "admin"`, `failed to look up admin`) and closes or fails the login. A
/// banner with a link is the approval prompt ([approvalUrlFrom]), not a refusal.
///
/// The text is the machine's own, so it is shown as plain text only: escape
/// sequences and control characters are dropped, whitespace is collapsed and a
/// long text is cut.
String? refusalReasonFrom(String banner) {
  if (approvalUrlFrom(banner) != null) return null;
  var text = banner
      .replaceAll(_escape, '')
      .replaceAll(_control, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceFirst(_tailscalePrefix, '')
      .replaceFirst(RegExp(r'[.\s]+$'), '');
  if (text.isEmpty) return null;
  if (text.length > 200) text = '${text.substring(0, 199)}…';
  return text;
}
