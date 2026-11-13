import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mpx_capture/mpx_capture.dart';

void main() => runApp(const CaptureExampleApp());

class CaptureExampleApp extends StatelessWidget {
  const CaptureExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'mpx_capture',
    theme: ThemeData(colorSchemeSeed: Colors.teal),
    home: const CompressPage(),
  );
}

/// Compresses the bundled clip at a chosen step and shows the job's reports.
class CompressPage extends StatefulWidget {
  const CompressPage({super.key});

  @override
  State<CompressPage> createState() => _CompressPageState();
}

class _CompressPageState extends State<CompressPage> {
  static const _transcoder = PlatformTranscoder();
  CompressionPreset _preset = CompressionPreset.medium;
  CaptureJob? _job;
  CaptureProgress? _progress;
  String _status = 'Idle';

  Future<String> _source() async {
    final path = '${Directory.systemTemp.path}/mpx_capture_source.mp4';
    final bytes = await rootBundle.load('assets/source.mp4');
    File(path).writeAsBytesSync(bytes.buffer.asUint8List());
    return path;
  }

  Future<void> _compress() async {
    final source = await _source();
    final job = _transcoder.compress(
      TranscodeRequest(
        sourcePath: source,
        outputPath: '${Directory.systemTemp.path}/mpx_capture_out.mp4',
        preset: _preset,
      ),
    );
    setState(() {
      _job = job;
      _status = 'Compressing';
    });
    job.progress.listen((p) => setState(() => _progress = p));
    try {
      final output = await job.output;
      setState(() => _status = '$output');
    } on CaptureException catch (error) {
      setState(() => _status = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _job != null && !_job!.isDone;
    return Scaffold(
      appBar: AppBar(title: const Text('Compression')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<CompressionPreset>(
            segments: [
              for (final preset in CompressionPreset.values)
                ButtonSegment(value: preset, label: Text('${preset.maxSide}')),
            ],
            selected: {_preset},
            onSelectionChanged: busy
                ? null
                : (selection) => setState(() => _preset = selection.single),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton(
                onPressed: busy ? null : _compress,
                child: const Text('Compress'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: busy ? _job!.cancel : null,
                child: const Text('Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: _progress?.fraction ?? 0),
          const SizedBox(height: 8),
          Text('${_progress ?? 'No progress yet'}'),
          const SizedBox(height: 8),
          Text(_status),
        ],
      ),
    );
  }
}
