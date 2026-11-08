import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/connection.dart';
import 'theme.dart';

class InternetExchangePanel extends StatefulWidget {
  const InternetExchangePanel({
    super.key,
    required this.link,
    required this.ending,
    required this.onCopied,
  });
  final LineConnection link;
  final bool ending;
  final void Function(String) onCopied;
  @override
  State<InternetExchangePanel> createState() => _InternetExchangePanelState();
}

class _InternetExchangePanelState extends State<InternetExchangePanel> {
  final responseInput = TextEditingController();
  String? responseError;
  @override
  void dispose() {
    responseInput.dispose();
    super.dispose();
  }

  Widget _credential(String label, String value) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: softSurface,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 9, letterSpacing: 1, color: muted),
        ),
        const SizedBox(height: 6),
        SelectableText(
          value,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.4,
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          link.isSender
              ? '1. Send your invitation and temporary code to the receiver.'
              : 'Send this response back to the sender. They paste it into their waiting room to connect.',
          style: const TextStyle(color: muted, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 18),
        _credential('ROOM NAME', link.room!),
        if (link.isSender) ...[
          const SizedBox(height: 12),
          _credential('TEMPORARY CODE', link.code!),
        ],
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: widget.ending
              ? null
              : () async {
                  await Clipboard.setData(
                    ClipboardData(text: link.invitation!),
                  );
                  widget.onCopied(
                    link.isSender
                        ? 'Invitation copied. Share the temporary code separately.'
                        : 'Response copied. Return it to the sender.',
                  );
                },
          icon: const Icon(Icons.copy_rounded, size: 16),
          label: Text(link.isSender ? 'Copy invitation' : 'Copy response'),
        ),
        if (link.isSender) ...[
          const SizedBox(height: 24),
          const Text(
            '2. Paste the response returned by the receiver.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: responseInput,
            minLines: 2,
            maxLines: 4,
            autocorrect: false,
            enableSuggestions: false,
            enabled: !widget.ending && !link.processingResponse,
            decoration: InputDecoration(
              labelText: 'Connection response',
              hintText: 'Paste the complete response from Line',
              errorText: responseError,
              errorMaxLines: 3,
            ),
            onChanged: (_) {
              if (responseError != null) setState(() => responseError = null);
            },
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: widget.ending || link.processingResponse
                ? null
                : () async {
                    setState(() => responseError = null);
                    try {
                      await link.applyAnswer(responseInput.text);
                    } on FormatException catch (e) {
                      if (mounted && widget.link == link) {
                        setState(() => responseError = e.message.toString());
                      }
                    }
                  },
            icon: const Icon(Icons.link_rounded, size: 17),
            label: Text(
              link.processingResponse
                  ? 'Checking response…'
                  : 'Connect devices',
            ),
          ),
        ],
        const SizedBox(height: 16),
        const Text(
          'Keep both apps open and return the response promptly. Create a new room if either network changes. The invitation expires after 10 minutes.',
          style: TextStyle(fontSize: 11, color: muted, height: 1.5),
        ),
        const SizedBox(height: 8),
        const Text(
          'Free discovery only. No relay or central file storage. Some networks cannot establish a direct connection.',
          style: TextStyle(fontSize: 11, color: muted, height: 1.5),
        ),
      ],
    );
  }
}
