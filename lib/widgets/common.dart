import 'package:flutter/material.dart';

import '../theme.dart';
import '../utils/errors.dart';

/// Teal curved header with the logo, as in the app design.
class BrandHeader extends StatelessWidget {
  const BrandHeader({super.key, this.subtitle = 'Smart Pill Management System', this.compact = false});

  final String subtitle;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final logo = compact ? 64.0 : 112.0;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(24, MediaQuery.paddingOf(context).top + 24, 24, 32),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [AppColors.primaryLight, AppColors.primary],
        ),
        borderRadius: BorderRadius.only(bottomLeft: Radius.circular(36), bottomRight: Radius.circular(36)),
      ),
      child: Column(children: [
        Container(
          width: logo,
          height: logo,
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          child: ClipOval(child: Image.asset('assets/logo.png', fit: BoxFit.cover)),
        ),
        const SizedBox(height: 12),
        Text('RemindMeBox',
            style: TextStyle(fontSize: compact ? 24 : 30, fontWeight: FontWeight.bold, color: Colors.white)),
        Text(subtitle, style: const TextStyle(color: Colors.white70)),
      ]),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 72, color: AppColors.primary),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
          if (message != null) ...[
            const SizedBox(height: 8),
            Text(message!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
          ],
          if (action != null) ...[const SizedBox(height: 24), action!],
        ]),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 6),
      child: Row(children: [
        Expanded(
          child: Text(text,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        ),
        ?trailing,
      ]),
    );
  }
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message),
    behavior: SnackBarBehavior.floating,
    backgroundColor: error ? AppColors.missed : null,
  ));
}

/// Runs [action] and reports failures in a SnackBar. Returns true on success.
Future<bool> runGuarded(BuildContext context, Future<void> Function() action, {String? success}) async {
  try {
    await action();
    if (success != null && context.mounted) showSnack(context, success);
    return true;
  } catch (e) {
    if (context.mounted) showSnack(context, friendlyError(e), error: true);
    return false;
  }
}

Future<bool> confirm(BuildContext context, {required String title, required String message, String ok = 'OK'}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(ok)),
      ],
    ),
  );
  return result ?? false;
}

/// A button that shows a spinner while its async callback runs.
class BusyButton extends StatefulWidget {
  const BusyButton({super.key, required this.label, required this.onPressed, this.icon});

  final String label;
  final IconData? icon;
  final Future<void> Function()? onPressed;

  @override
  State<BusyButton> createState() => _BusyButtonState();
}

class _BusyButtonState extends State<BusyButton> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    try {
      await widget.onPressed!();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = _busy
        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
        : Text(widget.label);
    final onPressed = widget.onPressed == null || _busy ? null : _run;
    if (widget.icon != null && !_busy) {
      return ElevatedButton.icon(onPressed: onPressed, icon: Icon(widget.icon), label: child);
    }
    return ElevatedButton(onPressed: onPressed, child: child);
  }
}
