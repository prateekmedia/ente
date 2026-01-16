import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:ensu/auth/auth_service.dart';
import 'package:ensu/auth/passkey_password_reentry_page.dart';
import 'package:ensu/auth/two_factor_page.dart';
import 'package:ensu/core/configuration.dart';
import 'package:ensu/ui/screens/home_page.dart';
import 'package:ensu/ui/widgets/locker_auth_components.dart';
import 'package:ente_ui/theme/ente_theme.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher_string.dart';

class PasskeyLoginPage extends StatefulWidget {
  final String email;
  final ServerSrpAttributes srpAttributes;
  final String sessionId;
  final String accountsUrl;
  final String? twoFactorSessionId;
  final String? password;

  const PasskeyLoginPage({
    super.key,
    required this.email,
    required this.srpAttributes,
    required this.sessionId,
    required this.accountsUrl,
    this.twoFactorSessionId,
    this.password,
  });

  @override
  State<PasskeyLoginPage> createState() => _PasskeyLoginPageState();
}

class _PasskeyLoginPageState extends State<PasskeyLoginPage> {
  static const _redirectUrl = 'enteensu://passkey';
  static const _clientPackage = 'io.ente.ensu';

  final _logger = Logger('PasskeyLoginPage');
  StreamSubscription<String>? _linkSubscription;
  bool _isChecking = false;

  @override
  void initState() {
    super.initState();
    if (widget.password != null && widget.password!.isNotEmpty) {
      Configuration.instance.setVolatilePassword(widget.password!);
    }
    _launchPasskey();
    _initDeepLinks();
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  Future<void> _launchPasskey() async {
    final url =
        '${widget.accountsUrl}/passkeys/verify?passkeySessionID=${widget.sessionId}'
        '&redirect=$_redirectUrl'
        '&clientPackage=$_clientPackage';
    try {
      final launched = await launchUrlString(
        url,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        _showMessage('Unable to open passkey verification.');
      }
    } catch (e, s) {
      _logger.severe('Failed to launch passkey URL', e, s);
      if (mounted) {
        _showMessage('Unable to open passkey verification.');
      }
    }
  }

  void _initDeepLinks() {
    final appLinks = AppLinks();
    _linkSubscription = appLinks.stringLinkStream.listen(
      _handleDeepLink,
      onError: (err) => _logger.severe('Passkey deeplink error', err),
    );
  }

  Future<void> _handleDeepLink(String? link) async {
    if (!mounted ||
        link == null ||
        Configuration.instance.hasConfiguredAccount()) {
      return;
    }

    final normalized = link.toLowerCase();
    if (!normalized.startsWith(_redirectUrl.toLowerCase())) {
      return;
    }

    try {
      final parsedUri = Uri.parse(link);
      final sessionId = parsedUri.queryParameters['passkeySessionID'];
      if (sessionId != widget.sessionId) {
        _showMessage('Session ID mismatch.');
        return;
      }

      final responseParam = parsedUri.queryParameters['response'];
      if (responseParam == null || responseParam.isEmpty) {
        _showMessage('Missing passkey response.');
        return;
      }

      String base64String = responseParam;
      while (base64String.length % 4 != 0) {
        base64String += '=';
      }
      final decoded = utf8.decode(base64.decode(base64String));
      final json = jsonDecode(decoded) as Map<String, dynamic>;
      await _handleAuthResponse(json);
    } catch (e, s) {
      _logger.severe('Passkey deeplink handling failed', e, s);
      if (mounted) {
        _showMessage('Failed to verify passkey.');
      }
    }
  }

  Future<void> _handleAuthResponse(Map<String, dynamic> response) async {
    if (!mounted || Configuration.instance.hasConfiguredAccount()) {
      return;
    }

    final passwordFromWidget = widget.password;
    final password = (passwordFromWidget != null && passwordFromWidget.isNotEmpty)
        ? passwordFromWidget
        : Configuration.instance.getVolatilePassword();

    if (password == null || password.isEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => PasskeyPasswordReentryPage(
            email: widget.email,
            srpAttributes: widget.srpAttributes,
            authResponse: response,
          ),
        ),
      );
      return;
    }

    final userId = response['id'];
    final keyAttributes = response['keyAttributes'];
    if (userId is! int || keyAttributes is! Map) {
      _showMessage('Invalid passkey response.');
      return;
    }

    await AuthService.instance.loginAfterEmailMfa(
      email: widget.email,
      password: password,
      srpAttributes: widget.srpAttributes,
      keyAttributes: ServerKeyAttributes.fromMap(
        Map<String, dynamic>.from(keyAttributes),
      ),
      encryptedToken: response['encryptedToken'] as String?,
      plainToken: response['token'] as String?,
      userId: userId,
    );

    if (!mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const HomePage()),
      (route) => false,
    );
  }

  Future<void> _checkStatus() async {
    if (_isChecking) return;
    setState(() => _isChecking = true);
    try {
      final response = await AuthService.instance.getTokenForPasskeySession(
        widget.sessionId,
      );
      await _handleAuthResponse(response);
    } on PasskeySessionNotVerifiedException {
      _showMessage('Passkey verification is still pending.');
    } on PasskeySessionExpiredException {
      _showMessage('Login session expired.');
      if (mounted) Navigator.pop(context);
    } catch (e, s) {
      _logger.severe('Failed to check passkey status', e, s);
      _showMessage('Failed to check passkey status.');
    } finally {
      if (mounted) {
        setState(() => _isChecking = false);
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _goToTwoFactor() {
    final sessionId = widget.twoFactorSessionId;
    if (sessionId == null || sessionId.isEmpty) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => TwoFactorPage(
          email: widget.email,
          srpAttributes: widget.srpAttributes,
          sessionId: sessionId,
          password: widget.password,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);

    return Scaffold(
      backgroundColor: colorScheme.backgroundBase,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: colorScheme.backgroundBase,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colorScheme.textBase),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                const LockerAuthHeader(
                  title: 'Passkey verification',
                  subtitle:
                      'Complete passkey verification in your browser, then return to continue.',
                ),
                const SizedBox(height: 8),
                Center(
                  child: LockerTextLink(
                    text: 'Open passkey again',
                    onPressed: _launchPasskey,
                  ),
                ),
                const SizedBox(height: 12),
                if (widget.twoFactorSessionId?.isNotEmpty == true)
                  Center(
                    child: LockerTextLink(
                      text: 'Use authenticator code instead',
                      onPressed: _goToTwoFactor,
                    ),
                  ),
              ],
            ),
          ),
          LockerAuthBottomButton(
            text: 'Check status',
            onPressed: _checkStatus,
            isLoading: _isChecking,
            isEnabled: !_isChecking,
          ),
        ],
      ),
    );
  }
}
