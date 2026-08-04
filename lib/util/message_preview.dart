// The one-line form of a message, for the places that reference one in a
// single row of text.
import '../state/chat_target.dart';

/// One-line label for a message referenced somewhere compact (the pinned bar,
/// the reply preview). Same reasoning as Conversation.lastMessagePreview: a
/// picture with no caption would otherwise render as a blank line. No emoji
/// marker here, unlike the chat list -- these bars show the actual thumbnail
/// next to this text.
String messageReferenceLabel(StoredMessage message) {
  if (message.text.isNotEmpty) return message.text;
  if (!message.hasAttachments) return message.text;
  return message.attachments.first.isImage ? 'Photo' : 'Attachment';
}
