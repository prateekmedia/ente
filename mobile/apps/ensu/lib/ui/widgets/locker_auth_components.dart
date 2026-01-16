import 'package:ensu/ui/theme/ensu_theme.dart';
import 'package:ente_ui/components/buttons/gradient_button.dart';
import 'package:ente_ui/components/loading_widget.dart';
import 'package:ente_ui/components/text_input_widget.dart';
import 'package:ente_ui/theme/ente_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Auth page header using Locker's design system with serif headings.
/// Uses Ensu's custom text theme which has serif fonts for headings.
class LockerAuthHeader extends StatelessWidget {
  final String title;
  final String? subtitle;

  const LockerAuthHeader({
    super.key,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnsuTextTheme(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: textTheme.h2Bold.copyWith(
              color: colorScheme.textBase,
              height: 1.2,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 12),
            Text(
              subtitle!,
              style: textTheme.body.copyWith(
                color: colorScheme.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Email subtitle shown below headers (e.g., on password page).
class LockerAuthSubtitle extends StatelessWidget {
  final String text;

  const LockerAuthSubtitle({
    super.key,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Text(
        text,
        style: textTheme.body.copyWith(color: colorScheme.textMuted),
      ),
    );
  }
}

/// Email text field using Locker's design system.
class LockerEmailField extends StatefulWidget {
  final TextEditingController controller;
  final bool autofocus;
  final void Function(String)? onChanged;
  final void Function(String)? onFieldSubmitted;
  final bool isValid;

  const LockerEmailField({
    super.key,
    required this.controller,
    this.autofocus = false,
    this.onChanged,
    this.onFieldSubmitted,
    this.isValid = false,
  });

  @override
  State<LockerEmailField> createState() => _LockerEmailFieldState();
}

class _LockerEmailFieldState extends State<LockerEmailField> {
  void _syncController(String value) {
    if (widget.controller.text == value) {
      return;
    }
    widget.controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  Future<void> _handleSubmit(String value) async {
    widget.onFieldSubmitted?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: TextInputWidget(
        label: 'Email',
        hintText: 'Enter your email',
        initialValue: widget.controller.text,
        autoFocus: widget.autofocus,
        keyboardType: TextInputType.emailAddress,
        autofillHints: const [AutofillHints.email],
        textInputAction: TextInputAction.done,
        autocorrect: false,
        enableSuggestions: false,
        shouldSurfaceExecutionStates: false,
        onChange: (value) {
          _syncController(value);
          widget.onChanged?.call(value);
        },
        onSubmit: _handleSubmit,
      ),
    );
  }
}

/// Password text field using Locker's design system.
class LockerPasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String? label;
  final String? hintText;
  final bool autofocus;
  final void Function(String)? onFieldSubmitted;
  final void Function(String)? onChanged;

  const LockerPasswordField({
    super.key,
    required this.controller,
    this.label = 'Password',
    this.hintText = 'Enter your password',
    this.autofocus = false,
    this.onFieldSubmitted,
    this.onChanged,
  });

  @override
  State<LockerPasswordField> createState() => _LockerPasswordFieldState();
}

class _LockerPasswordFieldState extends State<LockerPasswordField> {
  void _syncController(String value) {
    if (widget.controller.text == value) {
      return;
    }
    widget.controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  Future<void> _handleSubmit(String value) async {
    widget.onFieldSubmitted?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: TextInputWidget(
        label: widget.label,
        hintText: widget.hintText,
        initialValue: widget.controller.text,
        autoFocus: widget.autofocus,
        keyboardType: TextInputType.visiblePassword,
        autofillHints: const [AutofillHints.password],
        textInputAction: TextInputAction.done,
        autocorrect: false,
        enableSuggestions: false,
        isPasswordInput: true,
        shouldSurfaceExecutionStates: false,
        onChange: (value) {
          _syncController(value);
          widget.onChanged?.call(value);
        },
        onSubmit: _handleSubmit,
      ),
    );
  }
}

/// OTP/Code entry field using Locker's design system.
class LockerCodeField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final int maxLength;
  final bool autofocus;
  final void Function(String)? onChanged;

  const LockerCodeField({
    super.key,
    required this.controller,
    this.hintText = '• • • • • •',
    this.maxLength = 6,
    this.autofocus = true,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: TextFormField(
        controller: controller,
        keyboardType: TextInputType.number,
        autofocus: autofocus,
        maxLength: maxLength,
        textAlign: TextAlign.center,
        style: GoogleFonts.inter(
          fontSize: 28,
          fontWeight: FontWeight.w500,
          letterSpacing: 8,
          color: colorScheme.textBase,
        ),
        decoration: InputDecoration(
          fillColor: colorScheme.fillFaint,
          filled: true,
          hintText: hintText,
          hintStyle: GoogleFonts.inter(
            fontSize: 24,
            letterSpacing: 8,
            color: colorScheme.textMuted,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          counterText: '',
          border: OutlineInputBorder(
            borderSide: BorderSide.none,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        onChanged: onChanged,
      ),
    );
  }
}

/// Primary action button using Locker's gradient button style.
class LockerPrimaryButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final bool isEnabled;

  const LockerPrimaryButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isLoading = false,
    this.isEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final bool showEnabledStyle = isEnabled;
    final bool shouldAbsorb = isLoading || !isEnabled;

    return AbsorbPointer(
      absorbing: shouldAbsorb,
      child: Stack(
        alignment: Alignment.center,
        children: [
          GradientButton(
            text: isLoading ? '' : text,
            onTap: showEnabledStyle ? onPressed : null,
          ),
          if (isLoading)
            const EnteLoadingWidget(
              color: Colors.white,
              size: 20,
              padding: 0,
            ),
        ],
      ),
    );
  }
}

/// Bottom button container that hides when keyboard is open.
class LockerAuthBottomButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final bool isEnabled;

  const LockerAuthBottomButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isLoading = false,
    this.isEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final isKeypadOpen = MediaQuery.of(context).viewInsets.bottom > 100;

    if (isKeypadOpen) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: LockerPrimaryButton(
        text: text,
        onPressed: onPressed,
        isLoading: isLoading,
        isEnabled: isEnabled,
      ),
    );
  }
}

/// Text link button styled like Locker's secondary actions.
class LockerTextLink extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;

  const LockerTextLink({
    super.key,
    required this.text,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);

    return TextButton(
      onPressed: onPressed,
      child: Text(
        text,
        style: textTheme.bodyBold.copyWith(
          color: colorScheme.primary500,
          decoration: TextDecoration.underline,
          decorationColor: colorScheme.primary500,
        ),
      ),
    );
  }
}
