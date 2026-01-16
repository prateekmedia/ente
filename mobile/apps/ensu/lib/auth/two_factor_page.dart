import 'package:dio/dio.dart';
import 'package:ensu/auth/auth_service.dart';
import 'package:ensu/auth/password_page.dart';
import 'package:ensu/ui/screens/home_page.dart';
import 'package:ensu/ui/widgets/dismiss_keyboard.dart';
import 'package:ensu/ui/widgets/locker_auth_components.dart';
import 'package:ente_ui/theme/ente_theme.dart';
import 'package:flutter/material.dart';

class TwoFactorPage extends StatefulWidget {
  final String email;
  final ServerSrpAttributes srpAttributes;
  final String sessionId;
  final String? password;

  const TwoFactorPage({
    super.key,
    required this.email,
    required this.srpAttributes,
    required this.sessionId,
    this.password,
  });

  @override
  State<TwoFactorPage> createState() => _TwoFactorPageState();
}

class _TwoFactorPageState extends State<TwoFactorPage> {
  final _codeController = TextEditingController();
  bool _isLoading = false;
  bool _hasValidCode = false;

  @override
  void initState() {
    super.initState();
    _codeController.addListener(_onCodeChanged);
  }

  @override
  void dispose() {
    _codeController.removeListener(_onCodeChanged);
    _codeController.dispose();
    super.dispose();
  }

  void _onCodeChanged() {
    final hasValidCode = _codeController.text.length == 6;
    if (_hasValidCode != hasValidCode) {
      setState(() => _hasValidCode = hasValidCode);
    }
  }

  Future<void> _verify() async {
    if (_codeController.text.length < 6) return;

    setState(() => _isLoading = true);

    try {
      final result = await AuthService.instance.verifyTwoFactor(
        sessionId: widget.sessionId,
        code: _codeController.text.trim(),
      );

      if (!mounted) return;

      if (widget.password != null) {
        await AuthService.instance.loginAfterEmailMfa(
          email: widget.email,
          password: widget.password!,
          srpAttributes: widget.srpAttributes,
          keyAttributes: result.keyAttributes,
          encryptedToken: result.encryptedToken,
          plainToken: result.plainToken,
          userId: result.id,
        );

        if (!mounted) return;

        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (context) => const HomePage()),
          (route) => false,
        );
        return;
      }

      // Go to password page with the result (email MFA flow)
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => PasswordAfterMfaPage(
            email: widget.email,
            srpAttributes: widget.srpAttributes,
            keyAttributes: result.keyAttributes,
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
              e.response?.data?['message'] ?? 'Invalid 2FA code',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Login failed: $e')),
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
        child: Column(
          children: [
            Expanded(
              child: ListView(
                children: [
                  const LockerAuthHeader(
                    title: 'Two-factor authentication',
                    subtitle: 'Enter the code from your authenticator app',
                  ),
                  LockerCodeField(
                    controller: _codeController,
                    onChanged: (value) {
                      if (value.length == 6) _verify();
                    },
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
            LockerAuthBottomButton(
              text: 'Verify',
              onPressed: _verify,
              isLoading: _isLoading,
              isEnabled: _hasValidCode,
            ),
          ],
        ),
      ),
    );
  }
}
