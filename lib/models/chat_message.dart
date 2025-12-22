import 'package:cloud_firestore/cloud_firestore.dart';

class ChatMessage {
  const ChatMessage({required this.id, required this.text, required this.isUser, this.createdAt});

  final String id;
  final String text;
  final bool isUser;
  final DateTime? createdAt;

  factory ChatMessage.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return ChatMessage(
      id: doc.id,
      text: d['text'] as String? ?? '',
      isUser: d['role'] == 'user',
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
