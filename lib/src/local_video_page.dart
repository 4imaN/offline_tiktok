import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'feed_mixer.dart';

class LocalVideoPage extends StatefulWidget {
  const LocalVideoPage({
    super.key,
    this.video,
    required this.active,
    this.isFavorite = false,
    this.clearMode = false,
    this.soundOn = true,
    this.onToggleFavorite,
    this.onDoubleTapLike,
    this.onShare,
    this.onToggleClearMode,
    this.onToggleSound,
    this.syncedPlaying,
    this.syncTick = 0,
    this.onPlaybackStateChanged,
    this.streamUrl,
    this.titleOverride,
    this.labelOverride,
    this.showActions = true,
  });

  final MixedVideo? video;
  final bool active;
  final bool isFavorite;
  final bool clearMode;
  final bool soundOn;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onDoubleTapLike;
  final VoidCallback? onShare;
  final VoidCallback? onToggleClearMode;
  final VoidCallback? onToggleSound;
  final bool? syncedPlaying;
  final int syncTick;
  final ValueChanged<bool>? onPlaybackStateChanged;
  final String? streamUrl;
  final String? titleOverride;
  final String? labelOverride;
  final bool showActions;

  @override
  State<LocalVideoPage> createState() => _LocalVideoPageState();
}

class _LocalVideoPageState extends State<LocalVideoPage> {
  static const Duration _doubleTapWindow = Duration(milliseconds: 280);
  static const Duration _pauseDelay = Duration(milliseconds: 140);
  static const Duration _autoplayRecoveryDelay = Duration(milliseconds: 220);

  VideoPlayerController? _controller;
  Timer? _autoplayRecoveryTimer;
  Timer? _pendingPauseTimer;
  String? _error;
  bool _initializing = true;
  bool _isPausedByUser = false;
  bool _isPlaying = false;
  bool _didToggleOnLastTap = false;
  bool _wasPlayingBeforeLastTap = false;
  bool _showHeartBurst = false;
  int _heartBurstId = 0;
  DateTime? _lastTapAt;
  int _lastAppliedSyncTick = -1;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  @override
  void didUpdateWidget(covariant LocalVideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldVideoId = oldWidget.video?.asset.id;
    final newVideoId = widget.video?.asset.id;
    if (oldVideoId != newVideoId || oldWidget.streamUrl != widget.streamUrl) {
      _disposeController();
      _lastAppliedSyncTick = -1;
      _setup();
      return;
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    if (oldWidget.soundOn != widget.soundOn) {
      controller.setVolume(widget.soundOn ? 1 : 0);
    }

    if (oldWidget.syncTick != widget.syncTick) {
      _applyExternalPlaybackPreference();
    }

    if (widget.active) {
      if (!_isPausedByUser) {
        controller.play();
        _syncPlaybackState(true);
        _scheduleAutoplayRecovery();
      }
    } else {
      _autoplayRecoveryTimer?.cancel();
      controller.pause();
      _syncPlaybackState(false);
    }
  }

  Future<void> _setup() async {
    setState(() {
      _initializing = true;
      _error = null;
    });

    try {
      late final VideoPlayerController controller;

      if (widget.streamUrl != null) {
        controller = VideoPlayerController.networkUrl(
          Uri.parse(widget.streamUrl!),
        );
      } else {
        final asset = widget.video?.asset;
        if (asset == null) {
          throw Exception('No video source was provided.');
        }
        final file = await asset.file;
        if (file == null || !await File(file.path).exists()) {
          throw Exception('This video is no longer available on the device.');
        }
        controller = VideoPlayerController.file(file);
      }
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(widget.soundOn ? 1 : 0);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      _controller = controller;
      if (widget.active) {
        final shouldPlay = widget.syncedPlaying ?? true;
        if (shouldPlay) {
          await controller.play();
          _isPausedByUser = false;
          _syncPlaybackState(true);
          _scheduleAutoplayRecovery();
        } else {
          await controller.pause();
          _isPausedByUser = true;
          _syncPlaybackState(false);
        }
      } else {
        _syncPlaybackState(false);
      }
    } catch (error) {
      _error = error.toString();
    } finally {
      if (mounted) {
        setState(() {
          _initializing = false;
        });
      }
    }
  }

  void _handleDoubleTap() {
    _pendingPauseTimer?.cancel();
    _pendingPauseTimer = null;
    _restorePlaybackAfterDoubleTap();
    _burstHeart();
    if (!widget.isFavorite) {
      widget.onDoubleTapLike?.call();
    }
  }

  void _handleTapUp() {
    final now = DateTime.now();
    final lastTapAt = _lastTapAt;
    _lastTapAt = now;

    if (lastTapAt != null && now.difference(lastTapAt) <= _doubleTapWindow) {
      _lastTapAt = null;
      _handleDoubleTap();
      return;
    }

    _handleSingleTap();
  }

  void _handleSingleTap() {
    if (widget.clearMode) {
      _didToggleOnLastTap = false;
      widget.onToggleClearMode?.call();
      return;
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      _didToggleOnLastTap = false;
      return;
    }

    _wasPlayingBeforeLastTap = _isPlaying;
    _didToggleOnLastTap = false;

    if (_isPlaying) {
      _didToggleOnLastTap = true;
      _pendingPauseTimer?.cancel();
      _pendingPauseTimer = Timer(_pauseDelay, () {
        if (!mounted) {
          return;
        }
        final activeController = _controller;
        if (activeController == null || !activeController.value.isInitialized) {
          return;
        }
        activeController.pause();
        _isPausedByUser = true;
        _syncPlaybackState(false);
      });
      return;
    }

    if (!widget.active) {
      return;
    }

    controller.play();
    _isPausedByUser = false;
    _didToggleOnLastTap = true;
    _syncPlaybackState(true);
  }

  void _restorePlaybackAfterDoubleTap() {
    if (!_didToggleOnLastTap) {
      return;
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      _didToggleOnLastTap = false;
      return;
    }

    if (_wasPlayingBeforeLastTap) {
      controller.play();
      _isPausedByUser = false;
      _syncPlaybackState(true);
    } else {
      controller.pause();
      _isPausedByUser = true;
      _syncPlaybackState(false);
    }

    _didToggleOnLastTap = false;
  }

  void _burstHeart() {
    final burstId = ++_heartBurstId;
    setState(() {
      _showHeartBurst = true;
    });

    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (!mounted || burstId != _heartBurstId) {
        return;
      }
      setState(() {
        _showHeartBurst = false;
      });
    });
  }

  Future<void> _disposeController() async {
    _autoplayRecoveryTimer?.cancel();
    _pendingPauseTimer?.cancel();
    final controller = _controller;
    _controller = null;
    await controller?.dispose();
  }

  void _scheduleAutoplayRecovery() {
    _autoplayRecoveryTimer?.cancel();
    _autoplayRecoveryTimer = Timer(_autoplayRecoveryDelay, () {
      if (!mounted || !widget.active || _isPausedByUser) {
        return;
      }

      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) {
        return;
      }

      if (!controller.value.isPlaying) {
        controller.play();
      }
      _syncPlaybackState(true);
    });
  }

  void _syncPlaybackState(bool playing) {
    if (!mounted || _isPlaying == playing) {
      return;
    }
    setState(() {
      _isPlaying = playing;
    });
    widget.onPlaybackStateChanged?.call(playing);
  }

  Future<void> _applyExternalPlaybackPreference() async {
    if (_lastAppliedSyncTick == widget.syncTick) {
      return;
    }
    _lastAppliedSyncTick = widget.syncTick;

    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        !widget.active) {
      return;
    }

    final shouldPlay = widget.syncedPlaying;
    if (shouldPlay == null) {
      return;
    }

    if (shouldPlay) {
      await controller.play();
      _isPausedByUser = false;
      _syncPlaybackState(true);
      _scheduleAutoplayRecovery();
      return;
    }

    await controller.pause();
    _autoplayRecoveryTimer?.cancel();
    _isPausedByUser = true;
    _syncPlaybackState(false);
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    if (_initializing) {
      return const _VideoShell(
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null ||
        controller == null ||
        !controller.value.isInitialized) {
      return _VideoShell(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error ?? 'Unable to load this video.',
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (_) => _handleTapUp(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Colors.black,
            child: Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            ),
          ),
          if (!widget.clearMode)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xAA050B10),
                    Color(0x22050B10),
                    Color(0xCC050B10),
                  ],
                ),
              ),
            ),
          AnimatedOpacity(
            opacity: _showHeartBurst ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: const Center(
              child: Icon(
                Icons.favorite_rounded,
                size: 108,
                color: Color(0xE6FF5678),
              ),
            ),
          ),
          AnimatedOpacity(
            opacity: _isPlaying ? 0 : 1,
            duration: const Duration(milliseconds: 180),
            child: IgnorePointer(
              child: Center(
                child: Container(
                  width: 78,
                  height: 78,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0x88050B10),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 42,
                  ),
                ),
              ),
            ),
          ),
          if (!widget.clearMode)
            Positioned(
              left: 20,
              right: 20,
              bottom: 28,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xAAFF7A18),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            widget.labelOverride ??
                                widget.video?.label ??
                                'Live',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _resolvedTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _resolvedSubtitle,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  if (widget.showActions) ...[
                    const SizedBox(width: 18),
                    _ActionRail(
                      isFavorite: widget.isFavorite,
                      soundOn: widget.soundOn,
                      onToggleFavorite: widget.onToggleFavorite,
                      onShare: widget.onShare,
                      onToggleClearMode: widget.onToggleClearMode,
                      onToggleSound: widget.onToggleSound,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  String get _resolvedTitle {
    if (widget.titleOverride?.trim().isNotEmpty == true) {
      return widget.titleOverride!;
    }
    if (widget.video?.asset.title?.trim().isNotEmpty == true) {
      return widget.video!.asset.title!;
    }
    return widget.streamUrl == null ? 'Offline video' : 'Nearby stream';
  }

  String get _resolvedSubtitle {
    if (widget.streamUrl != null) {
      return 'Streaming from a nearby host on your Wi-Fi network';
    }
    final score = widget.video?.score;
    if (score == null) {
      return 'double tap to like';
    }
    return 'Mix score ${(score * 100).round()} · double tap to like';
  }
}

class _ActionRail extends StatelessWidget {
  const _ActionRail({
    required this.isFavorite,
    required this.soundOn,
    required this.onToggleFavorite,
    required this.onShare,
    required this.onToggleClearMode,
    required this.onToggleSound,
  });

  final bool isFavorite;
  final bool soundOn;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onShare;
  final VoidCallback? onToggleClearMode;
  final VoidCallback? onToggleSound;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ActionBubble(
          icon: isFavorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          label: isFavorite ? 'Liked' : 'Like',
          active: isFavorite,
          onPressed: onToggleFavorite,
        ),
        const SizedBox(height: 12),
        _ActionBubble(
          icon: Icons.share_rounded,
          label: 'Share',
          active: false,
          onPressed: onShare,
        ),
        const SizedBox(height: 12),
        _ActionBubble(
          icon: Icons.crop_free_rounded,
          label: 'Clear',
          active: false,
          onPressed: onToggleClearMode,
        ),
        const SizedBox(height: 12),
        _ActionBubble(
          icon: soundOn ? Icons.volume_up_rounded : Icons.volume_off_rounded,
          label: soundOn ? 'Sound' : 'Muted',
          active: soundOn,
          onPressed: onToggleSound,
        ),
      ],
    );
  }
}

class _ActionBubble extends StatelessWidget {
  const _ActionBubble({
    required this.icon,
    required this.label,
    required this.active,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? const Color(0xCCFF5678) : const Color(0x99102232),
            border: Border.all(color: Colors.white24),
            boxShadow: active
                ? const [
                    BoxShadow(
                      color: Color(0x55FF5678),
                      blurRadius: 22,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: IconButton(
            onPressed: onPressed,
            icon: Icon(icon),
            color: Colors.white,
            iconSize: 28,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: Colors.white70),
        ),
      ],
    );
  }
}

class _VideoShell extends StatelessWidget {
  const _VideoShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF07111A), Color(0xFF102232), Color(0xFF07111A)],
        ),
      ),
      child: child,
    );
  }
}
