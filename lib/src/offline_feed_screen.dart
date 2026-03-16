import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

import 'feed_mixer.dart';
import 'local_video_page.dart';

enum _FeedState { loading, permissionNeeded, empty, ready, error }

class OfflineFeedScreen extends StatefulWidget {
  const OfflineFeedScreen({super.key});

  @override
  State<OfflineFeedScreen> createState() => _OfflineFeedScreenState();
}

class _OfflineFeedScreenState extends State<OfflineFeedScreen>
    with SingleTickerProviderStateMixin {
  static const int _initialBatchSize = 200;
  static const int _backgroundBatchSize = 200;

  final PageController _forYouController = PageController();
  final PageController _likedController = PageController();
  late final TabController _tabController;

  _FeedState _state = _FeedState.loading;
  List<MixedVideo> _videos = const [];
  final Set<String> _favoriteIds = <String>{};
  int _forYouIndex = 0;
  int _likedIndex = 0;
  bool _clearMode = false;
  bool _soundOn = true;
  bool _isLoadingMore = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadFeed();
  }

  @override
  void dispose() {
    _forYouController.dispose();
    _likedController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _resetToFirstPage(PageController controller) {
    if (!controller.hasClients) {
      return;
    }

    controller.jumpToPage(0);
  }

  Future<void> _loadFeed() async {
    setState(() {
      _state = _FeedState.loading;
      _errorMessage = null;
      _isLoadingMore = false;
    });

    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.hasAccess) {
        setState(() {
          _state = _FeedState.permissionNeeded;
        });
        return;
      }

      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.video,
        hasAll: true,
      );

      final seen = <String>{};
      final initialAssets = <AssetEntity>[];
      final deferredAlbums = <AssetPathEntity>[];

      for (final album in albums) {
        final total = await album.assetCountAsync;
        if (total == 0) {
          continue;
        }

        final rangeEnd = min(total, _initialBatchSize);
        final items = await album.getAssetListRange(start: 0, end: rangeEnd);
        for (final asset in items) {
          if (seen.add(asset.id)) {
            initialAssets.add(asset);
          }
        }

        if (total > rangeEnd) {
          deferredAlbums.add(album);
        }
      }

      if (initialAssets.isEmpty) {
        setState(() {
          _videos = const [];
          _state = _FeedState.empty;
        });
        return;
      }

      final mix = buildOfflineMix(initialAssets);
      if (!mounted) {
        return;
      }

      _favoriteIds.removeWhere(
        (assetId) => mix.every((video) => video.asset.id != assetId),
      );

      setState(() {
        _videos = mix;
        _forYouIndex = 0;
        _likedIndex = 0;
        _state = _FeedState.ready;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _resetToFirstPage(_forYouController);
        _resetToFirstPage(_likedController);
      });

      if (deferredAlbums.isNotEmpty) {
        unawaited(
          _loadRemainingVideos(
            albums: deferredAlbums,
            existingAssets: initialAssets,
            seen: seen,
          ),
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _state = _FeedState.error;
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _loadRemainingVideos({
    required List<AssetPathEntity> albums,
    required List<AssetEntity> existingAssets,
    required Set<String> seen,
  }) async {
    if (albums.isEmpty) {
      return;
    }

    if (mounted) {
      setState(() {
        _isLoadingMore = true;
      });
    }

    final allAssets = [...existingAssets];

    try {
      for (final album in albums) {
        final total = await album.assetCountAsync;
        var start = _initialBatchSize;

        while (start < total) {
          final end = min(start + _backgroundBatchSize, total);
          final items = await album.getAssetListRange(start: start, end: end);
          var appended = false;

          for (final asset in items) {
            if (seen.add(asset.id)) {
              allAssets.add(asset);
              appended = true;
            }
          }

          if (appended && mounted) {
            _applyExpandedFeed(allAssets);
          }

          start = end;
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
        });
      }
    }
  }

  void _applyExpandedFeed(List<AssetEntity> allAssets) {
    final currentAssetId = _videos.isNotEmpty && _forYouIndex < _videos.length
        ? _videos[_forYouIndex].asset.id
        : null;

    final remixed = buildOfflineMix(allAssets);
    final remixedIndex = currentAssetId == null
        ? 0
        : remixed.indexWhere((video) => video.asset.id == currentAssetId);

    setState(() {
      _videos = remixed;
      _forYouIndex = remixedIndex < 0 ? 0 : remixedIndex;
      _normalizeLikedIndex();
    });
  }

  void _reshuffle() {
    if (_videos.isEmpty) {
      return;
    }

    final random = Random(DateTime.now().millisecondsSinceEpoch);
    final shuffled = [..._videos]..shuffle(random);
    setState(() {
      _videos = shuffled;
      _forYouIndex = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _resetToFirstPage(_forYouController);
    });
  }

  void _normalizeLikedIndex() {
    final count = _likedVideos.length;
    if (count == 0) {
      _likedIndex = 0;
      return;
    }
    _likedIndex = _likedIndex.clamp(0, count - 1);
  }

  void _toggleFavorite(String assetId) {
    setState(() {
      if (!_favoriteIds.add(assetId)) {
        _favoriteIds.remove(assetId);
      }
      _normalizeLikedIndex();
    });
  }

  void _likeFromDoubleTap(String assetId) {
    if (_favoriteIds.contains(assetId)) {
      return;
    }
    setState(() {
      _favoriteIds.add(assetId);
      _normalizeLikedIndex();
    });
  }

  Future<void> _shareVideo(MixedVideo video) async {
    try {
      final file = await video.asset.file;
      if (!mounted) {
        return;
      }

      if (file == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This video file is not available.')),
        );
        return;
      }

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: video.asset.title ?? 'Offline TikTok video',
        ),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to share this video right now.')),
      );
    }
  }

  List<MixedVideo> get _likedVideos {
    return _videos
        .where((video) => _favoriteIds.contains(video.asset.id))
        .toList(growable: false);
  }

  Widget _buildFeed({
    required List<MixedVideo> videos,
    required PageController controller,
    required int currentIndex,
    required ValueChanged<int> onPageChanged,
    required String emptyTitle,
    required String emptyBody,
  }) {
    if (videos.isEmpty) {
      return _SimpleEmptyState(title: emptyTitle, body: emptyBody);
    }

    return PageView.builder(
      controller: controller,
      scrollDirection: Axis.vertical,
      itemCount: videos.length,
      onPageChanged: onPageChanged,
      itemBuilder: (context, index) {
        final video = videos[index];
        return LocalVideoPage(
          key: ValueKey('${video.asset.id}-${_clearMode ? 'clear' : 'full'}'),
          video: video,
          active: index == currentIndex,
          isFavorite: _favoriteIds.contains(video.asset.id),
          clearMode: _clearMode,
          soundOn: _soundOn,
          onToggleFavorite: () => _toggleFavorite(video.asset.id),
          onDoubleTapLike: () => _likeFromDoubleTap(video.asset.id),
          onShare: () => _shareVideo(video),
          onToggleClearMode: () {
            setState(() {
              _clearMode = !_clearMode;
            });
          },
          onToggleSound: () {
            setState(() {
              _soundOn = !_soundOn;
            });
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: switch (_state) {
        _FeedState.loading => _StatusView(
          title: 'Building your offline mix',
          body:
              'Scanning downloaded videos on this phone and preparing a fun swipe feed.',
          actionLabel: null,
          onPressed: null,
        ),
        _FeedState.permissionNeeded => _StatusView(
          title: 'Gallery access is required',
          body:
              'Allow video access so the app can find downloaded TikTok clips stored on your device.',
          actionLabel: 'Open settings',
          onPressed: PhotoManager.openSetting,
        ),
        _FeedState.empty => _StatusView(
          title: 'No local videos found',
          body:
              'Download or copy TikTok videos into your gallery, then refresh to build an offline feed.',
          actionLabel: 'Refresh scan',
          onPressed: _loadFeed,
        ),
        _FeedState.error => _StatusView(
          title: 'Something went wrong',
          body:
              _errorMessage ??
              'The app could not read your local video library.',
          actionLabel: 'Try again',
          onPressed: _loadFeed,
        ),
        _FeedState.ready => DefaultTabController(
          length: 2,
          child: Stack(
            children: [
              TabBarView(
                controller: _tabController,
                physics: _clearMode
                    ? const NeverScrollableScrollPhysics()
                    : null,
                children: [
                  _buildFeed(
                    videos: _videos,
                    controller: _forYouController,
                    currentIndex: _forYouIndex,
                    onPageChanged: (index) {
                      setState(() {
                        _forYouIndex = index;
                      });
                    },
                    emptyTitle: 'No local videos found',
                    emptyBody:
                        'Download or copy TikTok videos into your gallery to build your For You feed.',
                  ),
                  _buildFeed(
                    videos: _likedVideos,
                    controller: _likedController,
                    currentIndex: _likedIndex,
                    onPageChanged: (index) {
                      setState(() {
                        _likedIndex = index;
                      });
                    },
                    emptyTitle: 'No liked videos yet',
                    emptyBody:
                        'Double tap or tap the heart on any clip to collect it in your liked feed.',
                  ),
                ],
              ),
              if (!_clearMode)
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            const _AppLogo(),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Offline TikTok',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(fontWeight: FontWeight.w900),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${_videos.length} local videos${_isLoadingMore ? ' · loading more' : ''} · ${_favoriteIds.length} liked',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(color: Colors.white70),
                                  ),
                                ],
                              ),
                            ),
                            _HeaderButton(
                              icon: _soundOn
                                  ? Icons.volume_up_rounded
                                  : Icons.volume_off_rounded,
                              onPressed: () {
                                setState(() {
                                  _soundOn = !_soundOn;
                                });
                              },
                            ),
                            const SizedBox(width: 12),
                            _HeaderButton(
                              icon: Icons.refresh_rounded,
                              onPressed: _loadFeed,
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Container(
                          decoration: BoxDecoration(
                            color: const Color(0x99102232),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: TabBar(
                            controller: _tabController,
                            indicator: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              gradient: const LinearGradient(
                                colors: [Color(0xFFFF7A18), Color(0xFFFF5678)],
                              ),
                            ),
                            dividerColor: Colors.transparent,
                            labelColor: Colors.white,
                            unselectedLabelColor: Colors.white70,
                            tabs: const [
                              Tab(text: 'For You'),
                              Tab(text: 'Liked'),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            _PillButton(
                              label: 'Shuffle',
                              icon: Icons.shuffle_rounded,
                              onPressed: _reshuffle,
                            ),
                            const SizedBox(width: 10),
                            _PillButton(
                              label: 'Clear View',
                              icon: Icons.crop_free_rounded,
                              onPressed: () {
                                setState(() {
                                  _clearMode = true;
                                });
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      },
    );
  }
}

class _AppLogo extends StatelessWidget {
  const _AppLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF7A18), Color(0xFFFF5678), Color(0xFF00C2A8)],
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x55FF7A18), blurRadius: 18, spreadRadius: 1),
        ],
      ),
      child: const Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: 7,
            left: 8,
            child: Icon(
              Icons.play_arrow_rounded,
              size: 16,
              color: Colors.black,
            ),
          ),
          Positioned(
            right: 8,
            bottom: 6,
            child: Icon(Icons.bolt_rounded, size: 18, color: Colors.black),
          ),
          Icon(Icons.favorite_rounded, size: 16, color: Colors.white),
        ],
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x99102232),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white24),
      ),
      child: IconButton(onPressed: onPressed, icon: Icon(icon)),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xCC102232),
        foregroundColor: Colors.white,
      ),
    );
  }
}

class _SimpleEmptyState extends StatelessWidget {
  const _SimpleEmptyState({required this.title, required this.body});

  final String title;
  final String body;

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
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.favorite_outline_rounded, size: 56),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 10),
              Text(
                body,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusView extends StatelessWidget {
  const _StatusView({
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onPressed,
  });

  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onPressed;

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
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _StatusLogo(),
                const SizedBox(height: 24),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(color: Colors.white70),
                ),
                if (actionLabel != null && onPressed != null) ...[
                  const SizedBox(height: 24),
                  FilledButton(onPressed: onPressed, child: Text(actionLabel!)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusLogo extends StatelessWidget {
  const _StatusLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [Color(0xFFFF7A18), Color(0xFFFF5678), Color(0xFF00C2A8)],
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x55FF7A18), blurRadius: 30, spreadRadius: 2),
        ],
      ),
      child: const Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: 20,
            left: 18,
            child: Icon(
              Icons.play_arrow_rounded,
              size: 24,
              color: Colors.black,
            ),
          ),
          Positioned(
            right: 18,
            bottom: 18,
            child: Icon(Icons.bolt_rounded, size: 26, color: Colors.black),
          ),
          Icon(Icons.favorite_rounded, size: 24, color: Colors.white),
        ],
      ),
    );
  }
}
