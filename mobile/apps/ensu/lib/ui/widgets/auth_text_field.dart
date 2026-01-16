import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Standard text field for auth screens (email, password).
class AuthTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final TextInputType keyboardType;
  final bool autofocus;
  final bool obscureText;
  final Widget? suffixIcon;
  final String? Function(String?)? validator;
  final void Function(String)? onChanged;
  final void Function(String)? onFieldSubmitted;
  final bool isValid;
  final Color? validFillColor;

  const AuthTextField({
    super.key,
    required this.controller,
    required this.hintText,
    this.keyboardType = TextInputType.text,
    this.autofocus = false,
    this.obscureText = false,
    this.suffixIcon,
    this.validator,
    this.onChanged,
    this.onFieldSubmitted,
    this.isValid = false,
    this.validFillColor,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final effectiveValidColor = validFillColor ?? const Color.fromRGBO(45, 194, 98, 0.2);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        autofocus: autofocus,
        obscureText: obscureText,
        style: Theme.of(context).textTheme.titleMedium,
        decoration: InputDecoration(
          fillColor: isValid ? effectiveValidColor : colorScheme.primaryContainer,
          filled: true,
          hintText: hintText,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
          border: UnderlineInputBorder(
            borderSide: BorderSide.none,
            borderRadius: BorderRadius.circular(6),
          ),
          suffixIcon: suffixIcon ??
              (isValid
                  ? Icon(
                      Icons.check,
                      size: 20,
                      color: colorScheme.primary,
                    )
                  : null),
        ),
        validator: validator,
        onChanged: onChanged,
        onFieldSubmitted: onFieldSubmitted,
      ),
    );
  }
}

/// Password text field with visibility toggle.
class AuthPasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;
  final bool autofocus;
  final void Function(String)? onFieldSubmitted;

  const AuthPasswordField({
    super.key,
    required this.controller,
    this.hintText = 'Password',
    this.autofocus = false,
    this.onFieldSubmitted,
  });

  @override
  State<AuthPasswordField> createState() => _AuthPasswordFieldState();
}

class _AuthPasswordFieldState extends State<AuthPasswordField> {
  bool _obscurePassword = true;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: TextFormField(
        controller: widget.controller,
        obscureText: _obscurePassword,
        autofocus: widget.autofocus,
        style: Theme.of(context).textTheme.titleMedium,
        decoration: InputDecoration(
          fillColor: colorScheme.primaryContainer,
          filled: true,
          hintText: widget.hintText,
          contentPadding: const EdgeInsets.all(20),
          border: UnderlineInputBorder(
            borderSide: BorderSide.none,
            borderRadius: BorderRadius.circular(6),
          ),
          suffixIcon: IconButton(
            icon: Icon(
              _obscurePassword ? Icons.visibility : Icons.visibility_off,
              size: 20,
            ),
            onPressed: () {
              setState(() => _obscurePassword = !_obscurePassword);
            },
          ),
        ),
        onFieldSubmitted: widget.onFieldSubmitted,
      ),
    );
  }
}

/// OTP/2FA code entry field with centered styling.
class AuthCodeField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final int maxLength;
  final bool autofocus;
  final void Function(String)? onChanged;

  const AuthCodeField({
    super.key,
    required this.controller,
    this.hintText = '• • • • • •',
    this.maxLength = 6,
    this.autofocus = true,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
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
        ),
        decoration: InputDecoration(
          fillColor: colorScheme.primaryContainer,
          filled: true,
          hintText: hintText,
          hintStyle: GoogleFonts.inter(
            fontSize: 24,
            letterSpacing: 8,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          counterText: '',
          border: UnderlineInputBorder(
            borderSide: BorderSide.none,
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        onChanged: onChanged,
      ),
    );
  }
}
