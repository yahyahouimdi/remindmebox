import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chat_message.dart';
import '../../services/chat_service.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../utils/errors.dart';
import '../../widgets/common.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final ChatService _chat = context.read<ChatService>();
  late final String _uid = context.read<Session>().uid;
  late final Stream<List<ChatMessage>> _messages = _chat.messages(_uid);

  /// Question being answered: shown until the stored conversation includes it.
  String? _pending;

  static const _suggestions = [
    'What do I take tonight?',
    'I forgot my morning pill, what should I do?',
    'شنوة الأعراض الجانبية متاع الباراسيتامول؟',
  ];

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _pending != null) return;
    _input.clear();
    setState(() => _pending = text);
    _scrollToEnd();
    try {
      await _chat.send(text);
    } catch (e) {
      if (mounted) {
        _input.text = text;
        showSnack(context, friendlyError(e), error: true);
      }
    } finally {
      if (mounted) setState(() => _pending = null);
      _scrollToEnd();
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _clear() async {
    final yes = await confirm(context, title: 'Clear conversation?', message: 'Dr. AI will forget this chat.', ok: 'Clear');
    if (yes && mounted) await runGuarded(context, () => _chat.clear(_uid));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dr. AI'),
        actions: [IconButton(tooltip: 'Clear conversation', onPressed: _clear, icon: const Icon(Icons.delete_sweep_outlined))],
      ),
      body: Column(children: [
        Expanded(
          child: StreamBuilder<List<ChatMessage>>(
            stream: _messages,
            builder: (context, snap) {
              final messages = snap.data ?? const [];
              if (snap.hasData) _scrollToEnd();
              if (messages.isEmpty && _pending == null) {
                return EmptyState(
                  icon: Icons.chat_bubble_outline,
                  title: 'Start chatting with Dr. AI',
                  message: 'Ask about your medications, side effects or what to do after a missed dose. '
                      'Dr. AI does not replace your doctor.',
                  action: Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                    for (final s in _suggestions) ActionChip(label: Text(s), onPressed: () => _send(s)),
                  ]),
                );
              }
              return ListView(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                children: [
                  for (final m in messages) _Bubble(text: m.text, isUser: m.isUser),
                  if (_pending != null) ...[
                    _Bubble(text: _pending!, isUser: true),
                    const _Bubble(text: 'Dr. AI is typing…', isUser: false, typing: true),
                  ],
                ],
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            color: Colors.white,
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: 'Enter your message…',
                    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _pending == null ? _send : null,
                icon: const Icon(Icons.send),
                style: IconButton.styleFrom(backgroundColor: AppColors.primary),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, required this.isUser, this.typing = false});

  final String text;
  final bool isUser;
  final bool typing;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isUser ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .8),
        decoration: BoxDecoration(
          color: isUser ? AppColors.primary : Colors.white,
          border: isUser ? null : Border.all(color: AppColors.primaryLight),
          borderRadius: BorderRadius.circular(16),
        ),
        child: SelectableText(
          text,
          style: TextStyle(
            color: isUser ? Colors.white : Colors.black87,
            fontStyle: typing ? FontStyle.italic : null,
          ),
        ),
      ),
    );
  }
}
