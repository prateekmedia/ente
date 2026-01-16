import 'package:dio/dio.dart';
import 'package:email_validator/email_validator.dart';
import 'package:ensu/auth/auth_service.dart';
import 'package:ensu/ui/theme/ensu_theme.dart';
import 'package:ente_ui/theme/ente_theme.dart';
import 'package:flutter/material.dart';

/// Dialog for changing email address.
/// Uses Locker's design system with serif headings via Ensu's custom text theme.
class ChangeEmailDialog extends StatefulWidget {
  const ChangeEmailDialog({super.key});

  @override
  State<ChangeEmailDialog> createState() => _ChangeEmailDialogState();
}

class _ChangeEmailDialogState extends State<ChangeEmailDialog> {
  final _emailController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  bool _emailIsValid = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  void _updateEmailValidity(String value) {
    final email = value.trim();
    final isValid = email.isNotEmpty && EmailValidator.validate(email);
    if (_emailIsValid != isValid) {
      setState(() => _emailIsValid = isValid);
    }
  }

  Future<void> _changeEmail() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final email = _emailController.text.trim();
      await AuthService.instance.sendOtp(email);

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Verification code sent to $email'),
          ),
        );
      }
    } on DioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.response?.data?['message'] ??
                  'Failed to send verification code',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnsuTextTheme(context);

    return Dialog(
      backgroundColor: colorScheme.backgroundElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Serif heading using Ensu's custom text theme
              Text(
                'Change email',
                style: textTheme.h3Bold.copyWith(
                  color: colorScheme.textBase,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Enter your new email address',
                style: textTheme.body.copyWith(color: colorScheme.textMuted),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                autofocus: true,
                style: textTheme.body.copyWith(color: colorScheme.textBase),
                decoration: InputDecoration(
                  fillColor: _emailIsValid
                      ? colorScheme.primary500.withValues(alpha: 0.1)
                      : colorScheme.fillFaint,
                  filled: true,
                  hintText: 'New email address',
                  hintStyle:
                      textTheme.body.copyWith(color: colorScheme.textMuted),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  border: OutlineInputBorder(
                    borderSide: BorderSide.none,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  suffixIcon: _emailIsValid
                      ? Icon(
                          Icons.check,
                          size: 20,
                          color: colorScheme.primary500,
                        )
                      : null,
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your new email';
                  }
                  if (!EmailValidator.validate(value)) {
                    return 'Please enter a valid email';
                  }
                  return null;
                },
                onChanged: _updateEmailValidity,
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      'Cancel',
                      style: textTheme.bodyBold.copyWith(
                        color: colorScheme.textMuted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _DialogButton(
                    text: 'Send code',
                    onPressed: _changeEmail,
                    isLoading: _isLoading,
                    isEnabled: _emailIsValid,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dialog button styled like Locker's buttons.
class _DialogButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final bool isEnabled;

  const _DialogButton({
    required this.text,
    this.onPressed,
    this.isLoading = false,
    this.isEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final bool effectiveEnabled = isEnabled && !isLoading;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Material(
        color: effectiveEnabled ? colorScheme.primary500 : colorScheme.fillFaint,
        child: InkWell(
          onTap: effectiveEnabled ? onPressed : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: isLoading
                ? SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        effectiveEnabled ? Colors.white : colorScheme.textMuted,
                      ),
                    ),
                  )
                : Text(
                    text,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'Inter',
                      color: effectiveEnabled
                          ? Colors.white
                          : colorScheme.textMuted,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Helper function to show the change email dialog.
Future<void> showChangeEmailDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const ChangeEmailDialog(),
  );
}
