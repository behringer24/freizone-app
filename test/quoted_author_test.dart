// Who a group reply's quote names (APP-17). The chain has four outcomes and
// the wrong one is a confidently mislabelled quote -- in a group, the quote is
// the only thing saying who is being answered.
import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/chat_target.dart';
import 'package:freizone/state/contact_store.dart';
import 'package:freizone/state/group_conversation.dart';
import 'package:freizone/util/quoted_author.dart';

const me = 'qme00000000000000000a';
const clara = 'qclara00000000000000a';
const ben = 'qben000000000000000b0';

/// A device that has named nobody -- the state every branch of the chain has to
/// resolve in, since a name only changes how an id is *labelled*, never which id
/// is found.
final noNames = ContactStore.inMemory();

void main() {
  GroupConversation chatWith(List<StoredMessage> messages) {
    final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
    chat.messages.addAll(messages);
    return chat;
  }

  StoredMessage original({
    required String id,
    bool mine = false,
    String? author,
  }) => StoredMessage(
    id: id,
    text: 'Samstag?',
    mine: mine,
    timestamp: DateTime.utc(2026, 8, 4, 12),
    senderAccountId: author,
  );

  StoredMessage reply({
    String? authorId,
    bool? previewMine,
    String replyToId = 'm1',
  }) => StoredMessage(
    text: 'passt',
    mine: false,
    timestamp: DateTime.utc(2026, 8, 4, 13),
    senderAccountId: ben,
    replyToId: replyToId,
    replyPreviewText: 'Samstag?',
    replyPreviewMine: previewMine,
    replyPreviewAuthorId: authorId,
  );

  group('resolveQuotedAuthor', () {
    test('takes the sender at their word when they state an author', () {
      final resolved = resolveQuotedAuthor(
        reply: reply(authorId: clara),
        chat: chatWith([]),
        myAccountId: me,
        contacts: noNames,
      );
      expect(resolved.label, 'qclar');
      expect(resolved.accountId, clara);
    });

    test('says "You" when the stated author is this account', () {
      // And offers no colour: there is nobody to tell apart from whom.
      final resolved = resolveQuotedAuthor(
        reply: reply(authorId: me),
        chat: chatWith([]),
        myAccountId: me,
        contacts: noNames,
      );
      expect(resolved.label, 'You');
      expect(resolved.accountId, isNull);
    });

    test('falls back to local history for a reply from an older build', () {
      final resolved = resolveQuotedAuthor(
        reply: reply(previewMine: false),
        chat: chatWith([original(id: 'm1', author: clara)]),
        myAccountId: me,
        contacts: noNames,
      );
      expect(resolved.label, 'qclar');
      expect(resolved.accountId, clara);
    });

    test('recognizes my own quoted message in history, which stores no author', () {
      // senderAccountId is null on our own messages, so the fallback has to
      // read `mine` rather than treat that null as an unknown author.
      final resolved = resolveQuotedAuthor(
        reply: reply(previewMine: true),
        chat: chatWith([original(id: 'm1', mine: true)]),
        myAccountId: me,
        contacts: noNames,
      );
      expect(resolved.label, 'You');
    });

    test('uses `mine` when there is no id to be had anywhere', () {
      // Older build, and the quoted message is not on this device. `mine` is
      // the receiver's perspective, already flipped by the sender.
      final resolved = resolveQuotedAuthor(
        reply: reply(previewMine: true),
        chat: chatWith([]),
        myAccountId: me,
        contacts: noNames,
      );
      expect(resolved.label, 'You');
      expect(resolved.accountId, isNull);
    });

    test('says nothing rather than guessing when nothing identifies the author', () {
      // The case APP-17 exists for: `mine: false` among N members says only
      // "not you", and the original is gone. No author line at all.
      final resolved = resolveQuotedAuthor(
        reply: reply(previewMine: false),
        chat: chatWith([]),
        myAccountId: me,
        contacts: noNames,
      );
      expect(resolved.label, isNull);
      expect(resolved.accountId, isNull);
    });

    test('labels a named author with the name and keeps the id (APP-18)', () {
      // The reason the quote takes the store at all: in a group the quote is
      // the only thing saying who is being answered, and `qclar` does not say
      // it.
      final resolved = resolveQuotedAuthor(
        reply: reply(authorId: clara),
        chat: chatWith([]),
        myAccountId: me,
        contacts: ContactStore.inMemory(
          contacts: const [Contact(accountId: clara, name: 'Clara')],
        ),
      );
      expect(resolved.label, 'Clara (qclar)');
      // Unchanged by the name: the colour is keyed to the person, not to how
      // this device happens to label them.
      expect(resolved.accountId, clara);
    });

    test('still says "You" for my own message, name or no name', () {
      // Naming yourself is possible -- your own address can be a contact -- and
      // must not turn the one label that needs no id into one that has one.
      final resolved = resolveQuotedAuthor(
        reply: reply(authorId: me),
        chat: chatWith([]),
        myAccountId: me,
        contacts: ContactStore.inMemory(
          contacts: const [Contact(accountId: me, name: 'Me, work')],
        ),
      );
      expect(resolved.label, 'You');
    });

    test('a stated author wins over local history', () {
      // They are the same person in practice; when they disagree, the sender's
      // statement is about *their* transcript and ours may hold a different
      // message under that id.
      final resolved = resolveQuotedAuthor(
        reply: reply(authorId: clara),
        chat: chatWith([original(id: 'm1', author: ben)]),
        myAccountId: me,
        contacts: noNames,
      );
      expect(resolved.accountId, clara);
    });
  });
}
