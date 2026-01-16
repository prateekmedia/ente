import 'package:dio/dio.dart';
import 'package:ensu/auth/auth_service.dart';
import 'package:ensu/auth/passkey_page.dart';
import 'package:ensu/auth/password_page.dart';
import 'package:ensu/auth/two_factor_page.dart';
import 'package:ensu/ui/widgets/dismiss_keyboard.dart';
import 'package:ensu/ui/widgets/locker_auth_components.dart';
import 'package:ente_ui/theme/ente_theme.dart';
import 'package:flutter/material.dart';

/// OTP verification page for email MFA flow.
class OtpVerificationPage extends StatefulWidget {
  final String email;
  final ServerSrpAttributes srpAttributes;

  const OtpVerificationPage({
    super.key,
    required this.email,
    required this.srpAttributes,
  });

  @override
  State<OtpVerificationPage> createState() => _OtpVerificationPageState();
}

class _OtpVerificationPageState extends State<OtpVerificationPage> {
  final _otpController = TextEditingController();
  bool _isLoading = false;
  bool _hasValidCode = false;

  @override
  void initState() {
    super.initState();
    _otpController.addListener(_onCodeChanged);
  }

  @override
  void dispose() {
    _otpController.removeListener(_onCodeChanged);
    _otpController.dispose();
    super.dispose();
  }

  void _onCodeChanged() {
    final hasValidCode = _otpController.text.length == 6;
    if (_hasValidCode != hasValidCode) {
      setState(() => _hasValidCode = hasValidCode);
    }
  }

  Future<void> _verifyOtp() async {
    if (_otpController.text.length < 6) return;

    setState(() => _isLoading = true);

    try {
      final result = await AuthService.instance.verifyOtp(
        widget.email,
        _otpController.text.trim(),
      );

      if (!mounted) return;

      if (result.isNewUser) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'New user signup not implemented. Please use an existing account.',
            ),
          ),
        );
        return;
      }

      if (result.requiresPasskey) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => PasskeyLoginPage(
              email: widget.email,
              srpAttributes: widget.srpAttributes,
              sessionId: result.passkeySessionId!,
              accountsUrl: result.accountsUrl,
              twoFactorSessionId: result.twoFactorSessionId,
            ),
          ),
        );
        return;
      }

      if (result.requiresTwoFactor) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => TwoFactorPage(
              email: widget.email,
              srpAttributes: widget.srpAttributes,
              sessionId: result.twoFactorSessionId!,
            ),
          ),
        );
        return;
      }

      // Go to password page (email MFA flow)
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => PasswordAfterMfaPage(
            email: widget.email,
            srpAttributes: widget.srpAttributes,
            keyAttributes: result.keyAttributes!,
            encryptedToken: result.encryptedToken,
            plainToken: result.plainToken,
            userId: result.id,
          ),
        ),
      );
    } on DioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.response?.data?['message'] ?? 'Invalid verification code',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _resendOtp() async {
    try {
      await AuthService.instance.sendOtp(widget.email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Verification code sent')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to resend code')),
        );
      }
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
        child: Column(
          children: [
            Expanded(
              child: ListView(
                children: [
                  LockerAuthHeader(
                    title: 'Verify email',
                    subtitle: 'Enter the code sent to ${widget.email}',
                  ),
                  LockerCodeField(
                    controller: _otpController,
                    onChanged: (value) {
                      if (value.length == 6) _verifyOtp();
                    },
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: LockerTextLink(
                      text: 'Resend code',
                      onPressed: _resendOtp,
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
            LockerAuthBottomButton(
              text: 'Verify',
              onPressed: _verifyOtp,
              isLoading: _isLoading,
              isEnabled: _hasValidCode,
            ),
          ],
        ),
      ),
    );
  }
}
