import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/web_bridge.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/web_preview.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../support/open_link.dart';
import '../web/web_navigation.dart' show needsOwnBrowser;
import '../web/web_preview_screen.dart';

/// What a tapped web link offers: the whole address (selectable, so nothing
/// is hidden behind a shortened label), then open or copy.
///
/// Every page opens in herdr (`Open page`, [WebPreviewScreen]), so following a
/// link never puts herdr in the background, where Android drops its SSH
/// connections: an `https` page of the web over the phone's own network, and a
/// page on a known [machine] through its SSH connection. That is an address on the
/// machine itself (`localhost`, a loopback address; a `.local` name is not
/// reachable at all) and the address an agent announces for it, the machine's own host
/// (`http://100.87.64.16:8792`: [WebPreview.ownHostLink]). The phone's browser
/// stays for what only it can do (`Open in browser`: a sign-in, [needsOwnBrowser])
/// and for plain `http` to another host, which cleartext rules keep out of the
/// view. A plain `http` link is opened only from here, after being shown.
Future<void> showLinkSheet(BuildContext context, String url, {MachineConnection? machine}) {
  final toaster = Toaster.of(context);
  void toast(String text, {ToastKind kind = ToastKind.info}) => toaster.show(text, kind: kind);

  final local = isMachineLocalUrl(url);
  final uri = Uri.tryParse(url);
  final host = uri?.host ?? '';
  final plain = url.toLowerCase().startsWith('http://');
  final https = url.toLowerCase().startsWith('https://');
  // What the machine serves: its own `localhost`, or the address an agent gave
  // for it. Null when the page is not the machine's.
  final served = machine == null || uri == null
      ? null
      : WebPreview.ownHostLink(machine.profile.host, uri) ?? (local && WebPreview.canPreview(url) ? uri : null);
  final previewable = served != null;
  final signIn = uri != null && https && needsOwnBrowser(uri);
  // A page of the web: any `https` one that is not the machine's and not a sign-in.
  final site = uri != null && https && !local && !previewable && !signIn;

  return showAppSheet<void>(
    context,
    builder: (ctx) {
      final ds = ctx.ds;
      void copy() {
        Navigator.of(ctx).pop();
        copyText(context, url, what: 'Link copied');
      }

      Future<void> open() async {
        Navigator.of(ctx).pop();
        if (!await openTappedLink(url)) {
          toast('Couldn’t open on this phone: no browser could open it.', kind: ToastKind.failed);
        }
      }

      // The sheet goes first, then the page's screen, which asks the
      // connection itself and says there if it fails.
      void openOnPhone() {
        Navigator.of(ctx).pop();
        unawaited(openWebPreview(context, machine!, ServerPage(served!)));
      }

      void openSite() {
        Navigator.of(ctx).pop();
        unawaited(openWebsite(context, uri!));
      }

      Widget note(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(top: Gap.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: Gap.hair),
              child: Icon(icon, size: IconSize.row, color: ds.textSecondary),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(text, style: Type.secondary.copyWith(color: ds.textSecondary)),
            ),
          ],
        ),
      );

      return SheetScaffold(
        title: host.isEmpty ? 'Link' : host,
        kind: SheetKind.message,
        actions: [
          if (previewable)
            AppButton(label: 'Open page', icon: LucideIcons.smartphone, expand: true, onPressed: openOnPhone)
          else if (site)
            AppButton(label: 'Open page', icon: LucideIcons.smartphone, expand: true, onPressed: openSite),
          if (!local && !previewable)
            AppButton(
              label: 'Open in browser',
              icon: LucideIcons.externalLink,
              kind: site ? AppButtonKind.secondary : AppButtonKind.primary,
              expand: true,
              onPressed: open,
            ),
          AppButton(
            label: 'Copy link',
            icon: LucideIcons.copy,
            kind: local && !previewable ? AppButtonKind.primary : AppButtonKind.secondary,
            expand: true,
            onPressed: copy,
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: Gap.xs),
            Panel(
              child: SelectableText(url, style: Mono.input.copyWith(color: ds.text)),
            ),
            if (previewable)
              note(
                HerdrIcons.machines,
                'This address is on ${machine!.profile.label}. Open page shows it in herdr, over your SSH connection.',
              )
            else if (local && https)
              note(HerdrIcons.machines, 'HTTPS on the machine can’t be opened on the phone yet.')
            else if (local)
              note(HerdrIcons.machines, 'This address is on the machine, not your phone.')
            else if (signIn)
              note(LucideIcons.lock, 'This is a sign-in. Your browser opens it, and herdr waits in the background.')
            else if (plain)
              note(LucideIcons.triangleAlert, 'This link isn’t encrypted.'),
          ],
        ),
      );
    },
  );
}
