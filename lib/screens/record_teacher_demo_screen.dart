import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/piece.dart';
import '../services/audio_score_auto_aligner.dart';
import '../services/providers.dart';
import '../services/teacher_recording_capture.dart';

enum _Stage { initializing, preview, recording, aligning, error }

/// Full-screen capture flow: live camera preview → record (video-only) +
/// mic (WAV) together → run the same DTW alignment the bundled Play Along
/// tracks use ([AudioScoreAutoAligner]) → persist, or offer a re-record if
/// the alignment looks uncertain. See teacher_recording_capture_base.dart
/// for why this is iOS/Android only.
class RecordTeacherDemoScreen extends ConsumerStatefulWidget {
  final Piece piece;

  const RecordTeacherDemoScreen({super.key, required this.piece});

  @override
  ConsumerState<RecordTeacherDemoScreen> createState() =>
      _RecordTeacherDemoScreenState();
}

class _RecordTeacherDemoScreenState
    extends ConsumerState<RecordTeacherDemoScreen> {
  final _capture = TeacherRecordingCapture();
  _Stage _stage = _Stage.initializing;
  String? _errorMessage;
  Duration _elapsed = Duration.zero;
  Timer? _elapsedTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (!_capture.isSupported) {
      setState(() {
        _stage = _Stage.error;
        _errorMessage =
            'Recording a teacher demo is only available on iOS and Android.';
      });
      return;
    }
    try {
      await _capture.initialize();
      if (!mounted) return;
      setState(() => _stage = _Stage.preview);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _errorMessage = '$e';
      });
    }
  }

  Future<void> _flip() async {
    await _capture.flipCamera();
    if (mounted) setState(() {});
  }

  Future<void> _startRecording() async {
    await _capture.start(widget.piece.id);
    if (!mounted) return;
    _elapsed = Duration.zero;
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
    setState(() => _stage = _Stage.recording);
  }

  Future<void> _stopRecording() async {
    _elapsedTimer?.cancel();
    setState(() => _stage = _Stage.aligning);
    try {
      final result = await _capture.stop();
      final parsed = await ref.read(parsedPieceProvider.future);
      if (parsed == null || !mounted) return;

      final aligner =
          AudioScoreAutoAligner(midiGenerator: ref.read(midiGeneratorProvider));
      final aligned = aligner.align(parsed, result.wavBytes);
      if (!mounted) return;

      if (aligned.hasCompressedAnchors) {
        final keep = await _showReviewDialog();
        if (keep != true) {
          // Discard this take and let the user try again from a fresh preview.
          if (mounted) setState(() => _stage = _Stage.preview);
          return;
        }
      }

      await ref.read(teacherRecordingStoreProvider).save(
            widget.piece.id,
            videoPath: result.videoPath,
            audioPath: result.audioPath,
            avOffsetMs: result.avOffsetMs,
            anchors: aligned.anchors,
            generationBpm: aligned.generationBpm,
            hasCompressedAnchors: aligned.hasCompressedAnchors,
          );
      ref.invalidate(hasTeacherRecordingProvider(widget.piece.id));
      ref.invalidate(teacherRecordingServiceProvider);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _errorMessage = '$e';
      });
    }
  }

  Future<bool?> _showReviewDialog() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Alignment may be off'),
        content: const Text(alignmentReviewMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Re-record'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Keep anyway'),
          ),
        ],
      ),
    );
  }

  String _formatElapsed(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _capture.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('Record teacher demo — ${widget.piece.title}'),
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    switch (_stage) {
      case _Stage.initializing:
        return const Center(
          child: CircularProgressIndicator(color: Colors.white),
        );

      case _Stage.error:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.videocam_off, color: Colors.white54, size: 48),
                const SizedBox(height: 16),
                Text(
                  _errorMessage ?? 'Recording is unavailable.',
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        );

      case _Stage.aligning:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 12),
              Text('Aligning…', style: TextStyle(color: Colors.white)),
            ],
          ),
        );

      case _Stage.preview:
      case _Stage.recording:
        final recording = _stage == _Stage.recording;
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: _capture.buildPreview()),
            if (recording)
              Positioned(
                top: 16,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.fiber_manual_record,
                            color: Colors.red, size: 14),
                        const SizedBox(width: 6),
                        Text(_formatElapsed(_elapsed),
                            style: const TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                ),
              ),
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!recording) ...[
                    IconButton(
                      icon: const Icon(Icons.cameraswitch,
                          color: Colors.white, size: 32),
                      tooltip: 'Switch camera',
                      onPressed: _flip,
                    ),
                    const SizedBox(width: 32),
                    _RecordButton(recording: false, onTap: _startRecording),
                  ] else
                    _RecordButton(recording: true, onTap: _stopRecording),
                ],
              ),
            ),
          ],
        );
    }
  }
}

class _RecordButton extends StatelessWidget {
  final bool recording;
  final VoidCallback onTap;

  const _RecordButton({required this.recording, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: Center(
          child: recording
              ? const Icon(Icons.stop, color: Colors.red, size: 32)
              : const CircleAvatar(radius: 26, backgroundColor: Colors.red),
        ),
      ),
    );
  }
}
