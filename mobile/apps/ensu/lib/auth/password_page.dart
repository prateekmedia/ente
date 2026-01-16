import 'package:dio/dio.dart';
import 'package:ensu/auth/auth_service.dart';
import 'package:ensu/auth/passkey_page.dart';
import 'package:ensu/auth/two_factor_page.dart';
import 'package:ensu/ui/screens/home_page.dart';
import 'package:ensu/ui/widgets/dismiss_keyboard.dart';
import 'package:ensu/ui/widgets/locker_auth_components.dart';
import 'package:ente_ui/theme/ente_theme.dart';
import 'package:flutter/material.dart';

/// Password page for standard SRP flow (no email MFA).
class PasswordPage extends StatefulWidget {
  final String email;
  final ServerSrpAttributes srpAttributes;

  const PasswordPage({
    super.key,
    required this.email,
    required this.srpAttributes,
  });

  @override
  State<PasswordPage> createState() => _PasswordPageState();
}

class _PasswordPageState extends State<PasswordPage> {
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _hasPassword = false;

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(_onPasswordChanged);
  }

  @override
  void dispose() {
    _passwordController.removeListener(_onPasswordChanged);
    _passwordController.dispose();
    super.dispose();
  }

  void _onPasswordChanged() {
    final hasPassword = _passwordController.text.isNotEmpty;
    if (_hasPassword != hasPassword) {
      setState(() => _hasPassword = hasPassword);
    }
  }

  Future<void> _login() async {
    if (_passwordController.text.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      final password = _passwordController.text;
      final result = await AuthService.instance.loginWithSrp(
        email: widget.email,
        password: password,
        srpAttributes: widget.srpAttributes,
      );

      if (!mounted) return;

      if (result.requiresPasskey) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => PasskeyLoginPage(
              email: widget.email,
              srpAttributes: widget.srpAttributes,
              sessionId: result.passkeySessionId!,
              accountsUrl: result.accountsUrl ?? 'https://accounts.ente.io',
              twoFactorSessionId: result.twoFactorSessionId,
              password: password,
            ),
          ),
        );
        return;
      }

      if (result.requiresTwoFactor) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => TwoFactorPage(
              email: widget.email,
              srpAttributes: widget.srpAttributes,
              sessionId: result.twoFactorSessionId!,
              password: password,
            ),
          ),
        );
        return;
      }

      // Navigate to home and clear back stack
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const HomePage()),
        (route) => false,
      );
    } on DioException catch (e) {
      if (mounted) {
        final message = e.response?.data?['message'] ??
            'Login failed: ${e.response?.statusCode} - ${e.message}';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
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
              child: AutofillGroup(
                child: ListView(
                  children: [
                    const LockerAuthHeader(title: 'Enter password'),
                    LockerAuthSubtitle(text: widget.email),
                    const SizedBox(height: 24),
                    LockerPasswordField(
                      controller: _passwordController,
                      autofocus: true,
                      onFieldSubmitted: (_) => _login(),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
            LockerAuthBottomButton(
              text: 'Log in',
              onPressed: _login,
              isLoading: _isLoading,
              isEnabled: _hasPassword,
            ),
          ],
        ),
      ),
    );
  }
}

/// Password page for email MFA flow (after OTP verification).
class PasswordAfterMfaPage extends StatefulWidget {
  final String email;
  final ServerSrpAttributes srpAttributes;
  final ServerKeyAttributes keyAttributes;
  final String? encryptedToken;
  final String? plainToken;
  final int userId;

  const PasswordAfterMfaPage({
    super.key,
    required this.email,
    required this.srpAttributes,
    required this.keyAttributes,
    this.encryptedToken,
    this.plainToken,
    required this.userId,
  });

  @override
  State<PasswordAfterMfaPage> createState() => _PasswordAfterMfaPageState();
}

class _PasswordAfterMfaPageState extends State<PasswordAfterMfaPage> {
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _hasPassword = false;

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(_onPasswordChanged);
  }

  @override
  void dispose() {
    _passwordController.removeListener(_onPasswordChanged);
    _passwordController.dispose();
    super.dispose();
  }

  void _onPasswordChanged() {
    final hasPassword = _passwordController.text.isNotEmpty;
    if (_hasPassword != hasPassword) {
      setState(() => _hasPassword = hasPassword);
    }
  }

  Future<void> _login() async {
    if (_passwordController.text.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      await AuthService.instance.loginAfterEmailMfa(
        email: widget.email,
        password: _passwordController.text,
        srpAttributes: widget.srpAttributes,
        keyAttributes: widget.keyAttributes,
        encryptedToken: widget.encryptedToken,
        plainToken: widget.plainToken,
        userId: widget.userId,
      );

      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (context) => const HomePage()),
          (route) => false,
        );
      }
    } on DioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.response?.data?['message'] ?? 'Login failed',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Incorrect password: $e')),
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
              child: AutofillGroup(
                child: ListView(
                  children: [
                    const LockerAuthHeader(title: 'Enter password'),
                    LockerAuthSubtitle(text: widget.email),
                    const SizedBox(height: 24),
                    LockerPasswordField(
                      controller: _passwordController,
                      autofocus: true,
                      onFieldSubmitted: (_) => _login(),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
            LockerAuthBottomButton(
              text: 'Log in',
              onPressed: _login,
              isLoading: _isLoading,
              isEnabled: _hasPassword,
            ),
          ],
        ),
      ),
    );
  }
}
