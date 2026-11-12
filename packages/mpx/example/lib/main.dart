import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mpx/mpx.dart';

void main() => runApp(const SignalsApp());

/// Lists the device signals and updates as they change on the device.
class SignalsApp extends StatefulWidget {
  const SignalsApp({super.key});

  @override
  State<SignalsApp> createState() => _SignalsAppState();
}

class _SignalsAppState extends State<SignalsApp> {
  final _signals = DeviceSignals();

  @override
  void dispose() {
    _signals.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Device signals')),
      body: ListView(
        children: [
          _SignalTile(label: 'Network', listenable: _signals.network),
          _SignalTile(label: 'Power saving', listenable: _signals.powerSaving),
          _SignalTile(label: 'Thermal', listenable: _signals.thermal),
        ],
      ),
    ),
  );
}

class _SignalTile extends StatelessWidget {
  const _SignalTile({required this.label, required this.listenable});

  final String label;
  final ValueListenable<Object> listenable;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: listenable,
    builder: (context, value, _) => ListTile(
      title: Text(label),
      trailing: Text(switch (value) {
        Enum(:final name) => name,
        _ => '$value',
      }),
    ),
  );
}
