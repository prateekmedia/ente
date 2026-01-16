// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Ensu';

  @override
  String get newChat => 'New Chat';

  @override
  String get enterChatName => 'Enter chat name';

  @override
  String get cancel => 'Cancel';

  @override
  String get create => 'Create';

  @override
  String get delete => 'Delete';

  @override
  String get deleteChat => 'Delete Chat';

  @override
  String get deleteChatConfirmation =>
      'Are you sure you want to delete this chat?';

  @override
  String get noChatsYet => 'No chats yet.\nTap + to start a new chat.';

  @override
  String get noMessagesYet =>
      'No messages yet.\nSend a message to start the conversation.';

  @override
  String get typeMessage => 'Type a message...';

  @override
  String get receiveDemoMessage => 'Receive demo message';

  @override
  String get welcome => 'Welcome to Ensu';

  @override
  String get encryptedChat => 'End-to-end encrypted chat';

  @override
  String get signIn => 'Sign In';
}
