import 'package:herdr_mobile/l10n/l10n_context.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../support/open_link.dart';

/// "Open sign-in page": sends the person to the link a machine's login banner
/// asked them to approve (Tailscale SSH check mode). The connection is waiting
/// and continues on its own once it is approved.
///
/// Sits on a tinted panel, so it is the quiet secondary kind: the panel
/// already carries the urgency.
class ApprovalButton extends StatelessWidget {
  const ApprovalButton({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) => AppButton(
    label: context.l10n.uiOpenSignInPage,
    icon: LucideIcons.externalLink,
    kind: AppButtonKind.secondary,
    compact: true,
    onPressed: () async {
      final toaster = Toaster.of(context);
      final openFailed = context.l10n.uiCouldnTOpenOnThisPhoneNoBrowserCould;
      if (!await openInBrowser(url)) {
        toaster.show(openFailed, kind: ToastKind.failed);
      }
    },
  );
}
