import 'package:flutter/material.dart';

import 'open_link.dart';

/// "Open sign-in page": sends the person to the link a machine's login banner
/// asked them to approve (Tailscale SSH check mode). The connection is waiting
/// and continues on its own once it is approved.
class ApprovalButton extends StatelessWidget {
  const ApprovalButton({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
        onPressed: () async {
          final messenger = ScaffoldMessenger.of(context);
          if (!await openInBrowser(url)) {
            messenger.showSnackBar(
              const SnackBar(content: Text('No browser could open the link.')),
            );
          }
        },
        icon: const Icon(Icons.open_in_new_rounded, size: 18),
        label: const Text('Open sign-in page'),
      );
}
