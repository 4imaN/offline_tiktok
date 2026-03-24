import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'feed_mixer.dart';
import 'local_video_page.dart';
import 'nearby_watch_service.dart';

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
  static const String _favoriteIdsStorageKey = 'favorite_asset_ids';

  final PageController _forYouController = PageController();
  final PageController _likedController = PageController();
  late final TabController _tabController;
  late final Future<SharedPreferences> _preferences;
  late final NearbyWatchService _nearbyWatchService;
  StreamSubscription<RemoteWatchSnapshot>? _remoteSyncSubscription;

  _FeedState _state = _FeedState.loading;
  List<MixedVideo> _videos = const [];
  final Set<String> _favoriteIds = <String>{};
  int _forYouIndex = 0;
  int _likedIndex = 0;
  bool _clearMode = false;
  bool _soundOn = true;
  String? _errorMessage;
  bool? _partyPlaybackOverride;
  int _partySyncTick = 0;
  String? _partyMessage;
  String? _remoteStreamUrl;
  String? _remoteVideoTitle;

  @override
  void initState() {
    super.initState();
    _preferences = SharedPreferences.getInstance();
    _tabController = TabController(length: 2, vsync: this);
    _nearbyWatchService = NearbyWatchService();
    _remoteSyncSubscription = _nearbyWatchService.remoteSyncStream.listen(
      _applyRemoteSnapshot,
    );
    unawaited(_restoreFavorites());
    _loadFeed();
  }

  @override
  void dispose() {
    _remoteSyncSubscription?.cancel();
    _nearbyWatchService.dispose();
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

      final favoriteCountBeforePrune = _favoriteIds.length;
      _favoriteIds.removeWhere(
        (assetId) => mix.every((video) => video.asset.id != assetId),
      );
      if (favoriteCountBeforePrune != _favoriteIds.length) {
        unawaited(_persistFavorites());
      }

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
    } finally {}
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
    _broadcastCurrentSnapshot();
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
    unawaited(_persistFavorites());
  }

  String get _deviceLabel {
    final suffix = DateTime.now().millisecondsSinceEpoch % 1000;
    return 'Phone $suffix';
  }

  Future<void> _startHostingNearby() async {
    try {
      await _nearbyWatchService.startHosting(displayName: _deviceLabel);
      if (!mounted) {
        return;
      }
      setState(() {
        _partyMessage =
            'Nearby watch party is live on this Wi-Fi network. Joined phones will stream the clip you are currently watching.';
      });
      unawaited(_broadcastCurrentSnapshot());
    } catch (error) {
      _showSnack('Unable to start hosting right now: $error');
    }
  }

  Future<void> _startLookingForNearby() async {
    try {
      await _nearbyWatchService.startDiscovery(displayName: _deviceLabel);
      if (!mounted) {
        return;
      }
      setState(() {
        _partyMessage =
            'Looking for nearby watch parties on this Wi-Fi network.';
      });
    } catch (error) {
      _showSnack('Unable to search for nearby sessions: $error');
    }
  }

  Future<void> _joinNearby(NearbySessionAnnouncement session) async {
    try {
      await _nearbyWatchService.joinSession(session);
      if (!mounted) {
        return;
      }
      setState(() {
        _partyMessage =
            'Joined ${session.hostName}. Video will stream directly from the host over Wi-Fi.';
      });
    } catch (error) {
      _showSnack('Unable to join that session: $error');
    }
  }

  Future<void> _stopNearbyWatchParty() async {
    await _nearbyWatchService.stop();
    if (!mounted) {
      return;
    }
    setState(() {
      _partyMessage = null;
      _partyPlaybackOverride = null;
      _partySyncTick++;
      _remoteStreamUrl = null;
      _remoteVideoTitle = null;
    });
  }

  void _applyRemoteSnapshot(RemoteWatchSnapshot snapshot) {
    if (!mounted) {
      return;
    }
    final streamUrl = _nearbyWatchService.currentStreamUrlFor(snapshot);
    if (streamUrl == null) {
      _showSnack('The nearby host did not expose a playable stream.');
      return;
    }

    setState(() {
      _remoteStreamUrl = streamUrl;
      _remoteVideoTitle = snapshot.videoTitle;
      _partyPlaybackOverride = snapshot.playing;
      _partySyncTick++;
      _partyMessage =
          'Streaming from ${_nearbyWatchService.connectedHostLabel}.';
    });
  }

  Future<void> _broadcastCurrentSnapshot() async {
    if (_nearbyWatchService.mode != NearbyWatchMode.hosting ||
        _videos.isEmpty) {
      return;
    }

    final index = _forYouIndex.clamp(0, _videos.length - 1);
    final video = _videos[index];
    await _nearbyWatchService.updateHostedVideo(
      video,
      playing: _partyPlaybackOverride ?? true,
    );
  }

  void _showNearbySheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0B1A26),
      isScrollControlled: true,
      builder: (context) {
        return AnimatedBuilder(
          animation: _nearbyWatchService,
          builder: (context, _) {
            final sessions = _nearbyWatchService.discoveredSessions;
            final mode = _nearbyWatchService.mode;

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Nearby Watch Party',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Streaming version: the host serves the current clip over Wi-Fi so other nearby phones can watch even without the same local file.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                    ),
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        FilledButton.icon(
                          onPressed: _startHostingNearby,
                          icon: const Icon(Icons.wifi_tethering_rounded),
                          label: const Text('Host'),
                        ),
                        FilledButton.icon(
                          onPressed: _startLookingForNearby,
                          icon: const Icon(Icons.radar_rounded),
                          label: const Text('Find Nearby'),
                        ),
                        if (mode != NearbyWatchMode.idle)
                          OutlinedButton.icon(
                            onPressed: _stopNearbyWatchParty,
                            icon: const Icon(Icons.close_rounded),
                            label: const Text('Stop'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    if (_nearbyWatchService.statusText != null)
                      Text(
                        _nearbyWatchService.statusText!,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF9EE7DA),
                        ),
                      ),
                    if (mode == NearbyWatchMode.discovering) ...[
                      const SizedBox(height: 14),
                      if (sessions.isEmpty)
                        Text(
                          'No sessions found yet. Make sure the host is on the same Wi-Fi and has started hosting.',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: Colors.white70),
                        ),
                      for (final session in sessions)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0xFF102232),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: ListTile(
                              title: Text(session.hostName),
                              subtitle: Text(
                                '${session.address.address} · streaming enabled',
                              ),
                              trailing: FilledButton(
                                onPressed: () => _joinNearby(session),
                                child: const Text('Join'),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _likeFromDoubleTap(String assetId) {
    if (_favoriteIds.contains(assetId)) {
      return;
    }
    setState(() {
      _favoriteIds.add(assetId);
      _normalizeLikedIndex();
    });
    unawaited(_persistFavorites());
  }

  Future<void> _restoreFavorites() async {
    final preferences = await _preferences;
    final stored =
        preferences.getStringList(_favoriteIdsStorageKey) ?? const [];
    if (!mounted) {
      return;
    }

    setState(() {
      _favoriteIds
        ..clear()
        ..addAll(stored);
      _normalizeLikedIndex();
    });
  }

  Future<void> _persistFavorites() async {
    final preferences = await _preferences;
    await preferences.setStringList(
      _favoriteIdsStorageKey,
      _favoriteIds.toList(growable: false),
    );
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

  bool get _isWatchingRemote =>
      _nearbyWatchService.mode == NearbyWatchMode.connected &&
      _remoteStreamUrl != null;

  Widget _buildRemoteWatchPage() {
    if (_remoteStreamUrl == null) {
      return const _SimpleEmptyState(
        title: 'Waiting for host video',
        body:
            'Join a nearby host and wait for them to open a clip. The stream will appear here automatically.',
      );
    }

    return LocalVideoPage(
      key: ValueKey(_remoteStreamUrl),
      streamUrl: _remoteStreamUrl,
      titleOverride: _remoteVideoTitle ?? 'Nearby stream',
      labelOverride: 'Watch Party',
      showActions: false,
      active: true,
      clearMode: _clearMode,
      soundOn: _soundOn,
      syncedPlaying: _partyPlaybackOverride,
      syncTick: _partySyncTick,
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
          key: ValueKey(video.asset.id),
          video: video,
          active: index == currentIndex,
          isFavorite: _favoriteIds.contains(video.asset.id),
          clearMode: _clearMode,
          soundOn: _soundOn,
          syncedPlaying: index == _forYouIndex ? _partyPlaybackOverride : null,
          syncTick: index == _forYouIndex ? _partySyncTick : 0,
          onToggleFavorite: () => _toggleFavorite(video.asset.id),
          onDoubleTapLike: () => _likeFromDoubleTap(video.asset.id),
          onShare: () => _shareVideo(video),
          onPlaybackStateChanged: (playing) {
            if (index != _forYouIndex) {
              return;
            }
            _partyPlaybackOverride = playing;
            unawaited(_broadcastCurrentSnapshot());
          },
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
                  _isWatchingRemote
                      ? _buildRemoteWatchPage()
                      : _buildFeed(
                          videos: _videos,
                          controller: _forYouController,
                          currentIndex: _forYouIndex,
                          onPageChanged: (index) {
                            setState(() {
                              _forYouIndex = index;
                            });
                            unawaited(_broadcastCurrentSnapshot());
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
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TabBar(
                          controller: _tabController,
                          isScrollable: true,
                          tabAlignment: TabAlignment.center,
                          indicatorColor: const Color(0xFFFF7A18),
                          indicatorWeight: 3,
                          indicatorSize: TabBarIndicatorSize.label,
                          dividerColor: Colors.transparent,
                          labelColor: Colors.white,
                          unselectedLabelColor: Colors.white70,
                          labelStyle: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                          unselectedLabelStyle: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                          overlayColor: WidgetStateProperty.all(
                            Colors.transparent,
                          ),
                          tabs: const [
                            Tab(text: 'For You'),
                            Tab(text: 'Liked'),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _PillButton(
                              label: 'Shuffle',
                              icon: Icons.shuffle_rounded,
                              onPressed: _reshuffle,
                            ),
                            const SizedBox(width: 10),
                            _PillButton(
                              label: 'Nearby',
                              icon: Icons.groups_rounded,
                              onPressed: _showNearbySheet,
                            ),
                          ],
                        ),
                        if (_partyMessage != null) ...[
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xB30D2C39),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: Text(
                              _partyMessage!,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: Colors.white70),
                            ),
                          ),
                        ],
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
