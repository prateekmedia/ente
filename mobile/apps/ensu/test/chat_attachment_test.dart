import 'package:ensu/models/chat_attachment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('serializes encrypted_name in attachments', () {
    const attachment = ChatAttachment(
      id: 'att-1',
      kind: ChatAttachmentKind.image,
      size: 512,
      extension: 'png',
      encryptedName: 'enc:v1:payload',
    );

    final json = attachment.toJson();
    expect(json['encrypted_name'], 'enc:v1:payload');

    final decoded = ChatAttachment.fromJson(json);
    expect(decoded.id, attachment.id);
    expect(decoded.encryptedName, attachment.encryptedName);
    expect(decoded.kind, attachment.kind);
    expect(decoded.size, attachment.size);
  });
}
