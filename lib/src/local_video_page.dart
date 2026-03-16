import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'feed_mixer.dart';

class LocalVideoPage extends StatefulWidget {
  const LocalVideoPage({
    super.key,
    required this.video,
    required this.active,
    required this.isFavorite,
    required this.clearMode,
    required this.soundOn,
    required this.onToggleFavorite,
    required this.onDoubleTapLike,
    required this.onShare,
    required this.onToggleClearMode,
    required this.onToggleSound,
  });

  final MixedVideo video;
  final bool active;
  final bool isFavorite;
  final bool clearMode;
  final bool soundOn;
  final VoidCallback onToggleFavorite;
  final VoidCallback onDoubleTapLike;
  final VoidCallback onShare;
  final VoidCallback onToggleClearMode;
  final VoidCallback onToggleSound;

  @override
  State<LocalVideoPage> createState() => _LocalVideoPageState();
}

class _LocalVideoPageState extends State<LocalVideoPage> {
  VideoPlayerController? _controller;
  String? _error;
  bool _initializing = true;
  bool _showHeartBurst = false;
  int _heartBurstId = 0;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  @override
  void didUpdateWidget(covariant LocalVideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.asset.id != widget.video.asset.id) {
      _disposeController();
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

    if (widget.active) {
      controller.play();
    } else {
      controller.pause();
    }
  }

  Future<void> _setup() async {
    setState(() {
      _initializing = true;
      _error = null;
    });

    try {
      final file = await widget.video.asset.file;
      if (file == null || !await File(file.path).exists()) {
        throw Exception('This video is no longer available on the device.');
      }

      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(widget.soundOn ? 1 : 0);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      _controller = controller;
      if (widget.active) {
        await controller.play();
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
    _burstHeart();
    if (!widget.isFavorite) {
      widget.onDoubleTapLike();
    }
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
    final controller = _controller;
    _controller = null;
    await controller?.dispose();
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
      onDoubleTap: _handleDoubleTap,
      onTap: widget.clearMode ? widget.onToggleClearMode : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Colors.black,
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: controller.value.size.width,
                height: controller.value.size.height,
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
                            widget.video.label,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          widget.video.asset.title?.trim().isNotEmpty == true
                              ? widget.video.asset.title!
                              : 'Offline video',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Mix score ${(widget.video.score * 100).round()} · double tap to like',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
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
              ),
            ),
        ],
      ),
    );
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
  final VoidCallback onToggleFavorite;
  final VoidCallback onShare;
  final VoidCallback onToggleClearMode;
  final VoidCallback onToggleSound;

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
