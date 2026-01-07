import 'package:dio/dio.dart';
import 'package:email_validator/email_validator.dart';
import 'package:ensu/auth/auth_service.dart';
import 'package:ensu/auth/otp_verification_page.dart';
import 'package:ensu/auth/password_page.dart';
import 'package:ensu/ui/widgets/dismiss_keyboard.dart';
import 'package:ensu/ui/widgets/locker_auth_components.dart';
import 'package:ente_ui/theme/ente_theme.dart';
import 'package:flutter/material.dart';

class EmailEntryPage extends StatefulWidget {
  const EmailEntryPage({super.key});

  @override
  State<EmailEntryPage> createState() => _EmailEntryPageState();
}

class _EmailEntryPageState extends State<EmailEntryPage> {
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

  Future<void> _continue() async {
    if (!_emailIsValid) return;

    setState(() => _isLoading = true);

    try {
      final email = _emailController.text.trim();

      // First, get SRP attributes to check auth flow
      final srpAttributes = await AuthService.instance.getSrpAttributes(email);

      if (!mounted) return;

      if (srpAttributes.isEmailMfaEnabled) {
        // Email MFA flow: send OTP first
        await AuthService.instance.sendOtp(email);

        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => OtpVerificationPage(
                email: email,
                srpAttributes: srpAttributes,
              ),
            ),
          );
        }
      } else {
        // Standard SRP flow: go directly to password
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PasswordPage(
              email: email,
              srpAttributes: srpAttributes,
            ),
          ),
        );
      }
    } on DioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.response?.data?['message'] ?? 'Failed to get account info',
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
    final isKeypadOpen = MediaQuery.of(context).viewInsets.bottom > 100;

    return Scaffold(
      backgroundColor: colorScheme.backgroundBase,
      resizeToAvoidBottomInset: isKeypadOpen,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: colorScheme.backgroundBase,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colorScheme.textBase),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: DismissKeyboard(
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              Expanded(
                child: AutofillGroup(
                  child: ListView(
                    children: [
                      const LockerAuthHeader(title: 'Welcome back'),
                      const SizedBox(height: 8),
                      LockerEmailField(
                        controller: _emailController,
                        autofocus: true,
                        isValid: _emailIsValid,
                        onChanged: _updateEmailValidity,
                        onFieldSubmitted: (_) => _continue(),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
              LockerAuthBottomButton(
                text: 'Log in',
                onPressed: _continue,
                isLoading: _isLoading,
                isEnabled: _emailIsValid,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
