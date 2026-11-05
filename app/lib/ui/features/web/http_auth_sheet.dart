import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

/// A user name and password for a page that asked for HTTP Basic or Digest
/// sign-in.
typedef HttpLogin = ({String user, String password});

/// Asks for the sign-in a page's server wants (a dev server or a reverse proxy
/// in front of it with Basic auth). Returns null when dismissed, which the
/// caller must answer as "cancel": the view waits for an answer and shows
/// nothing until it gets one.
///
/// [where] says whose server asks (the machine's name), [realm] is the
/// server's own words for what it protects, shown as written. What is typed
/// goes only to that page, is never kept, and is not restored after process
/// death.
Future<HttpLogin?> showHttpAuthSheet(BuildContext context, {required String where, String? realm}) =>
    showAppSheet<HttpLogin>(
      context,
      builder: (ctx) => _AuthBody(where: where, realm: realm),
    );

class _AuthBody extends StatefulWidget {
  const _AuthBody({required this.where, required this.realm});

  final String where;
  final String? realm;

  @override
  State<_AuthBody> createState() => _AuthBodyState();
}

class _AuthBodyState extends State<_AuthBody> {
  final _user = TextEditingController();
  final _password = TextEditingController();
  var _obscure = true;

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _valid => _user.text.isNotEmpty;

  void _submit() {
    if (_valid) Navigator.of(context).pop((user: _user.text, password: _password.text));
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final realm = widget.realm;
    return SheetScaffold(
      title: 'Sign in',
      kind: SheetKind.form,
      actions: [AppButton(label: 'Sign in', expand: true, onPressed: _valid ? _submit : null)],
      child: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              realm == null || realm.isEmpty
                  ? 'This page on ${widget.where} asks for a user name and password.'
                  : 'This page on ${widget.where} asks for a user name and password: $realm',
              style: Type.secondary.copyWith(color: ds.textSecondary),
            ),
            const SizedBox(height: Gap.lg),
            LabeledField(
              label: 'User name',
              controller: _user,
              autofocus: true,
              autofillHints: const [AutofillHints.username],
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
            ),
            LabeledField(
              label: 'Password',
              controller: _password,
              obscure: _obscure,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              suffix: CircleButton(
                icon: _obscure ? LucideIcons.eye : LucideIcons.eyeOff,
                tooltip: _obscure ? 'Show password' : 'Hide password',
                filled: false,
                size: CircleButton.compact,
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
