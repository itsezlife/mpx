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
    home: DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('mpx_capture'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Compression'),
              Tab(text: 'Round video'),
            ],
          ),
        ),
        body: const TabBarView(children: [CompressPage(), RoundVideoPage()]),
      ),
    ),
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
    return ListView(
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
    );
  }
}

/// Records a round video: preview, pause, camera switch, stop and cancel.
class RoundVideoPage extends StatefulWidget {
  const RoundVideoPage({super.key});

  @override
  State<RoundVideoPage> createState() => _RoundVideoPageState();
}

class _RoundVideoPageState extends State<RoundVideoPage> {
  static const _recorder = PlatformRoundVideoRecorder();
  RoundVideoRecording? _recording;
  CaptureProgress? _progress;
  String _status = 'Idle';

  bool get _recordingNow => _recording != null && !_recording!.job.isDone;

  Future<void> _start() async {
    if (!await _recorder.requestPermission()) {
      setState(() => _status = 'Camera or microphone not allowed');
      return;
    }
    try {
      final recording = await _recorder.start(
        outputPath: '${Directory.systemTemp.path}/mpx_round.mp4',
      );
      setState(() {
        _recording = recording;
        _status = 'Recording';
      });
      recording.job.progress.listen((p) => setState(() => _progress = p));
      final output = await recording.job.output;
      setState(() => _status = '$output');
    } on CaptureException catch (error) {
      setState(() => _status = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final recording = _recording;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: SizedBox.square(
            dimension: 240,
            child: recording != null && _recordingNow
                ? RoundVideoPreview(recording: recording)
                : const DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black12,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: _recordingNow ? null : _start,
              child: const Text('Record'),
            ),
            OutlinedButton(
              onPressed: _recordingNow
                  ? () async {
                      if (recording!.isPaused) {
                        await recording.resume();
                      } else {
                        await recording.pause();
                      }
                      setState(() {});
                    }
                  : null,
              child: Text(recording?.isPaused ?? false ? 'Resume' : 'Pause'),
            ),
            OutlinedButton(
              onPressed: _recordingNow
                  ? () async {
                      await recording!.switchCamera();
                      setState(() {});
                    }
                  : null,
              child: const Text('Switch camera'),
            ),
            OutlinedButton(
              onPressed: _recordingNow ? recording!.stop : null,
              child: const Text('Stop'),
            ),
            OutlinedButton(
              onPressed: _recordingNow ? recording!.job.cancel : null,
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
    );
  }
}
