import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../config/env.dart';
import '../models/chat_message.dart';

/// Dr. AI conversation. Messages are stored per user; replies come from the
/// `chatWithAssistant` function, which calls Gemini with the user's medication plan.
class ChatService {
  ChatService({FirebaseFirestore? db, FirebaseFunctions? fn})
      : _db = db ?? FirebaseFirestore.instance,
        _fn = fn ?? functions();

  final FirebaseFirestore _db;
  final FirebaseFunctions _fn;

  CollectionReference<Map<String, dynamic>> _messages(String uid) => _db.collection('users/$uid/messages');

  Stream<List<ChatMessage>> messages(String uid) => _messages(uid)
      .orderBy('createdAt')
      .limitToLast(100)
      .snapshots()
      .map((s) => s.docs.map(ChatMessage.fromDoc).toList());

  Future<String> send(String text) async {
    final result = await _fn
        .httpsCallable('chatWithAssistant', options: HttpsCallableOptions(timeout: const Duration(seconds: 70)))
        .call({'message': text.trim()});
    return (result.data as Map)['reply'] as String? ?? '';
  }

  Future<void> clear(String uid) async {
    final docs = await _messages(uid).get();
    final batch = _db.batch();
    for (final d in docs.docs) {
      batch.delete(d.reference);
    }
    await batch.commit();
  }
}
