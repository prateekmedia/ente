import 'package:ensu/ui/theme/ensu_theme.dart';
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
  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Email',
            style: textTheme.bodyBold.copyWith(color: colorScheme.textBase),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: widget.controller,
            autofillHints: const [AutofillHints.email],
            autofocus: widget.autofocus,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            style: textTheme.body.copyWith(color: colorScheme.textBase),
            decoration: InputDecoration(
              hintText: 'Enter your email',
              hintStyle: textTheme.body.copyWith(color: colorScheme.textMuted),
              fillColor: widget.isValid
                  ? colorScheme.primary500.withValues(alpha: 0.1)
                  : colorScheme.fillFaint,
              filled: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              border: OutlineInputBorder(
                borderSide: BorderSide.none,
                borderRadius: BorderRadius.circular(8),
              ),
              suffixIcon: widget.isValid
                  ? Icon(
                      Icons.check,
                      size: 20,
                      color: colorScheme.primary500,
                    )
                  : null,
            ),
            onChanged: widget.onChanged,
            onFieldSubmitted: widget.onFieldSubmitted,
          ),
        ],
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
  bool _passwordVisible = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.label != null) ...[
            Text(
              widget.label!,
              style: textTheme.bodyBold.copyWith(color: colorScheme.textBase),
            ),
            const SizedBox(height: 8),
          ],
          TextFormField(
            controller: widget.controller,
            autofillHints: const [AutofillHints.password],
            autofocus: widget.autofocus,
            obscureText: !_passwordVisible,
            autocorrect: false,
            keyboardType: TextInputType.visiblePassword,
            style: textTheme.body.copyWith(color: colorScheme.textBase),
            decoration: InputDecoration(
              hintText: widget.hintText,
              hintStyle: textTheme.body.copyWith(color: colorScheme.textMuted),
              fillColor: colorScheme.fillFaint,
              filled: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              border: OutlineInputBorder(
                borderSide: BorderSide.none,
                borderRadius: BorderRadius.circular(8),
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  _passwordVisible
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: colorScheme.textMuted,
                  size: 20,
                ),
                onPressed: () {
                  setState(() {
                    _passwordVisible = !_passwordVisible;
                  });
                },
              ),
            ),
            onChanged: widget.onChanged,
            onFieldSubmitted: widget.onFieldSubmitted,
          ),
        ],
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

  static const TextStyle _textStyle = TextStyle(
    color: Colors.white,
    fontWeight: FontWeight.w600,
    fontFamily: 'Inter',
    fontSize: 18,
  );

  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final bool effectiveEnabled = isEnabled && !isLoading;
    final Color backgroundColor =
        effectiveEnabled ? colorScheme.primary500 : colorScheme.fillFaint;
    final Color textColor =
        effectiveEnabled ? Colors.white : colorScheme.textMuted;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Material(
        color: backgroundColor,
        child: InkWell(
          onTap: effectiveEnabled ? onPressed : null,
          splashColor: effectiveEnabled ? null : Colors.transparent,
          highlightColor: effectiveEnabled ? null : Colors.transparent,
          child: SizedBox(
            height: 56,
            child: Center(
              child: isLoading
                  ? SizedBox(
                      height: 24,
                      width: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation<Color>(textColor),
                      ),
                    )
                  : Text(
                      text,
                      style: _textStyle.copyWith(color: textColor),
                    ),
            ),
          ),
        ),
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
