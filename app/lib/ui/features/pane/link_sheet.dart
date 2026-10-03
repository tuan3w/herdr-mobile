import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/open_link.dart';
import '../../core/theme.dart';

/// What a tapped web link offers: the whole address (selectable, so nothing
/// is hidden behind a shortened label), then open or copy.
///
/// An address on the machine itself (`localhost`, a loopback address, a
/// `.local` name) is not reachable from the phone, so it only offers copy and
/// says why. A plain `http` link is opened only from here, after being shown.
Future<void> showLinkSheet(BuildContext context, String url) {
  final messenger = ScaffoldMessenger.of(context);
  void toast(String text) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));

  final local = isMachineLocalUrl(url);
  final host = Uri.tryParse(url)?.host ?? '';
  final plain = url.toLowerCase().startsWith('http://');

  return showAppSheet<void>(
    context,
    builder: (ctx) {
      final ds = ctx.ds;
      Future<void> copy() async {
        Navigator.of(ctx).pop();
        await Clipboard.setData(ClipboardData(text: url));
        await HapticFeedback.selectionClick();
        toast('Link copied');
      }

      Future<void> open() async {
        Navigator.of(ctx).pop();
        if (!await openTappedLink(url)) toast('No browser could open the link.');
      }

      Widget note(IconData icon, String text) => Padding(
            padding: const EdgeInsets.only(top: Gap.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(icon, size: 16, color: ds.textSecondary),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(text, style: Type.secondary.copyWith(color: ds.textSecondary)),
                ),
              ],
            ),
          );

      return Padding(
        padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.xl, Gap.gutter, Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                host.isEmpty ? 'Link' : host,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Type.title.copyWith(color: ds.text),
              ),
            ),
            const SizedBox(height: Gap.md),
            Container(
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: ds.fill,
                borderRadius: BorderRadius.circular(Radii.row),
              ),
              child: SelectableText(
                url,
                style: TextStyle(
                  fontFamily: monoFamily,
                  fontSize: 13,
                  height: 1.45,
                  color: ds.text,
                ),
              ),
            ),
            if (local)
              note(LucideIcons.server, 'This address is on the machine, not your phone.')
            else if (plain)
              note(LucideIcons.triangleAlert, 'This link is not encrypted.'),
            const SizedBox(height: Gap.xl),
            if (!local) ...[
              AppButton(
                label: 'Open in browser',
                icon: LucideIcons.externalLink,
                expand: true,
                onPressed: open,
              ),
              const SizedBox(height: Gap.sm),
            ],
            AppButton(
              label: 'Copy link',
              icon: LucideIcons.copy,
              kind: local ? AppButtonKind.primary : AppButtonKind.secondary,
              expand: true,
              onPressed: copy,
            ),
          ],
        ),
      );
    },
  );
}
