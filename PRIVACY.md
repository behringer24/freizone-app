# Privacy Policy

**Last updated: 2026-07-23**

This Privacy Policy describes how the Freizone application ("Freizone," "the App," "we," "us") handles information. Freizone is currently available for Android, with an iOS release planned; this Policy applies to Freizone regardless of platform.

Please read Section 1 first. It describes a distinction that is unusual for most applications but is central to how Freizone works, and it governs how the rest of this Policy should be understood.

## 1. How Freizone Is Structured, and Who Processes Your Data

Freizone is a self-hosted, federated communication application. There is no single central service operated by us that all users connect to. Instead, each user connects the App to a Freizone server of their own choosing, and it is that server's operator — not us, in our capacity as the App's publisher — who receives and processes the data described in this Policy.

We might, separately, also operate certain Freizone server instances ourselves — for example, a private instance for personal use and/or a publicly available instance. Operating a server is a distinct role from publishing the App, and it applies only to the specific instance(s) we operate, never to Freizone as a whole. Even where we act as a server operator, end-to-end encryption (described in Section 3) means we cannot read the content of any message on that server; our visibility there is limited to the same account and routing information any Freizone server operator necessarily has, described below.

In short: whichever server you connect to — one you operate yourself, one operated by someone you trust, one operated by an unrelated third party, or one we happen to operate — that server's operator is the party responsible for processing your data. Their own privacy practices, data retention policies, and legal obligations are outside our control and outside the scope of this Policy. Please contact that operator directly for information about how they handle your data.

If you exchange messages with a user on a different server (see Section 4, Federation), that other server's operator also receives data relating to that exchange, in the same capacity described above.

## 2. Information Collected

### 2.1 Information Stored on Your Device

- **Cryptographic identity.** When you create an account, the App generates a cryptographic key pair on your device. Your account address is derived from this key; no email address, phone number, or other personally identifying information is required or requested to use Freizone.
- **Message history, contacts, and preferences.** This information is stored locally within the App's private storage on your device. It is not additionally protected by a separate passphrase; it relies on the security of your device (such as your device lock and storage encryption), consistent with standard practice for locally stored application data.
- Uninstalling the App removes this locally stored information. We do not maintain a backup copy of it.

### 2.2 Information Processed by the Server You Connect To

- Your account's public key and device credentials, which allow other users to verify your identity.
- End-to-end encrypted message content. Messages are encrypted on your device before transmission using established end-to-end encryption techniques; the server you connect to stores and forwards this content without being able to read it.
- Limited technical metadata the server requires to operate, such as which device a message is intended for and when it was sent.
- If enabled, a push-notification identifier used solely to signal that new content is available (see Section 5).
- Any administrative information your server's operator maintains about your account, such as its status or role.

As described in Section 1, this information is processed by the operator of the server you have chosen, and is not accessible to us as the App's publisher.

## 3. End-to-End Encryption

Messages sent through Freizone are encrypted on the sending device and can only be decrypted by the intended recipient's device. Servers, including any we may operate ourselves, store and relay this content without the ability to read it.

## 4. Federation

Freizone allows communication between users on different, independently operated servers. When you message a user on another server, your message is delivered directly to that server. The operator of that server receives the encrypted content and related technical metadata described in Section 2.2, in the same capacity as your own server's operator. A server operator may also choose to disable this capability, in which case communication with users on other servers is unavailable.

## 5. Push Notifications

To alert you to new messages while the App is not actively running, Freizone may use a push-notification service appropriate to your device's platform (for example, services provided by Google on Android, or by Apple on iOS, where applicable), or an independent, non-affiliated notification relay you choose to install. Regardless of mechanism, the notification itself carries no message content, sender information, or other personal data — it serves only as a signal for the App to check with your server for new information. Where a platform-provided push service is used, that platform provider's own privacy practices govern their handling of the notification token and delivery infrastructure. We do not use any analytics, crash-reporting, or advertising functionality associated with these platform services.

## 6. Permissions

Depending on your device's platform, Freizone may request access to:

- **Camera**, used solely to scan an optional invite code when you choose to do so. No image or video is stored or transmitted.
- **Notifications**, to alert you to new messages.
- **Network access**, required to communicate with the server you configure.

Freizone does not request access to your location, contacts, microphone, or stored files, and requests no permission beyond those necessary for the functionality described above.

## 7. What We Do Not Do

We do not integrate analytics, advertising, or tracking services into the App. We do not sell or share personal information for marketing purposes. As described in Section 1, we do not receive user data in our capacity as the App's publisher in the first place.

## 8. Data Retention and Deletion

Uninstalling the App removes all information stored on your device. The App also provides an in-app option to delete your account; on our own reference server software, this permanently removes the account and associated data from that server. The completeness of this action on any particular server depends on the software and practices of that server's operator, since the deletion itself is performed by the server, not by the App.

## 9. Children's Privacy

Freizone is not directed to children, and the App does not perform age verification. Any concern regarding a child's information on a particular server should be directed to that server's operator, consistent with Section 1.

## 10. Your Rights

Depending on your jurisdiction, you may have rights regarding your personal information, such as the right to access, correct, or delete it. Because the servers you use are operated by parties other than us (except where we act as an operator ourselves, in that separate capacity), such requests should generally be directed to the operator of the relevant server. For questions specifically about the App itself, you may contact us using the details in Section 12.

## 11. Transparency

The source code of the Freizone application, and of the reference server software it connects to, is published publicly and available for independent review.

## 12. Changes to This Policy

We may update this Policy from time to time. Any changes will be published at the same location referenced by the App, with an updated "Last updated" date above.

## 13. Contact

For questions about this Policy or the Freizone application itself, please contact:

Andreas Behringer
info@behringer24.de
