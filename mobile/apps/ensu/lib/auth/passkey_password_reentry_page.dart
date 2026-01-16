import 'package:ensu/auth/auth_service.dart';
import 'package:ensu/ui/screens/home_page.dart';
import 'package:ensu/ui/widgets/dismiss_keyboard.dart';
import 'package:ensu/ui/widgets/locker_auth_components.dart';
import 'package:ente_ui/theme/ente_theme.dart';
import 'package:flutter/material.dart';

class PasskeyPasswordReentryPage extends StatefulWidget {
  final String email;
  final ServerSrpAttributes srpAttributes;
  final Map<String, dynamic> authResponse;

  const PasskeyPasswordReentryPage({
    super.key,
    required this.email,
    required this.srpAttributes,
    required this.authResponse,
  });

  @override
  State<PasskeyPasswordReentryPage> createState() =>
      _PasskeyPasswordReentryPageState();
}

class _PasskeyPasswordReentryPageState extends State<PasskeyPasswordReentryPage> {
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

  Future<void> _continue() async {
    if (_passwordController.text.isEmpty || _isLoading) return;

    final userId = widget.authResponse['id'];
    final keyAttributes = widget.authResponse['keyAttributes'];
    if (userId is! int || keyAttributes is! Map) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid passkey response.')),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      await AuthService.instance.loginAfterEmailMfa(
        email: widget.email,
        password: _passwordController.text,
        srpAttributes: widget.srpAttributes,
        keyAttributes: ServerKeyAttributes.fromMap(
          Map<String, dynamic>.from(keyAttributes),
        ),
        encryptedToken: widget.authResponse['encryptedToken'] as String?,
        plainToken: widget.authResponse['token'] as String?,
        userId: userId,
      );

      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const HomePage()),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Incorrect password: $e')),
      );
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
                      onFieldSubmitted: (_) => _continue(),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
            LockerAuthBottomButton(
              text: 'Continue',
              onPressed: _continue,
              isLoading: _isLoading,
              isEnabled: _hasPassword,
            ),
          ],
        ),
      ),
    );
  }
}
