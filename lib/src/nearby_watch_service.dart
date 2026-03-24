import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'feed_mixer.dart';

enum NearbyWatchMode { idle, hosting, discovering, connected }

class NearbySessionAnnouncement {
  const NearbySessionAnnouncement({
    required this.sessionId,
    required this.hostName,
    required this.address,
    required this.controlPort,
    required this.mediaPort,
    required this.updatedAt,
  });

  final String sessionId;
  final String hostName;
  final InternetAddress address;
  final int controlPort;
  final int mediaPort;
  final DateTime updatedAt;

  NearbySessionAnnouncement copyWith({
    String? sessionId,
    String? hostName,
    InternetAddress? address,
    int? controlPort,
    int? mediaPort,
    DateTime? updatedAt,
  }) {
    return NearbySessionAnnouncement(
      sessionId: sessionId ?? this.sessionId,
      hostName: hostName ?? this.hostName,
      address: address ?? this.address,
      controlPort: controlPort ?? this.controlPort,
      mediaPort: mediaPort ?? this.mediaPort,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class RemoteWatchSnapshot {
  const RemoteWatchSnapshot({
    required this.syncId,
    required this.playing,
    required this.videoTitle,
    required this.streamVersion,
  });

  final String syncId;
  final bool playing;
  final String videoTitle;
  final int streamVersion;
}

class NearbyWatchService extends ChangeNotifier {
  static const int discoveryPort = 45454;
  static const Duration _announceInterval = Duration(seconds: 2);
  static const Duration _staleAfter = Duration(seconds: 7);

  final StreamController<RemoteWatchSnapshot> _remoteSyncController =
      StreamController<RemoteWatchSnapshot>.broadcast();

  NearbyWatchMode _mode = NearbyWatchMode.idle;
  NearbyWatchMode get mode => _mode;

  String? _displayName;
  String? _sessionId;
  String? _connectedHostLabel;
  String? get connectedHostLabel => _connectedHostLabel;
  String? _statusText;
  String? get statusText => _statusText;

  List<NearbySessionAnnouncement> _discoveredSessions =
      const <NearbySessionAnnouncement>[];
  List<NearbySessionAnnouncement> get discoveredSessions => _discoveredSessions;

  Stream<RemoteWatchSnapshot> get remoteSyncStream =>
      _remoteSyncController.stream;

  ServerSocket? _controlServer;
  HttpServer? _mediaServer;
  final List<Socket> _clients = <Socket>[];
  Socket? _hostSocket;
  RawDatagramSocket? _discoverySocket;
  Timer? _announceTimer;
  Timer? _pruneTimer;

  InternetAddress? _connectedHostAddress;
  int? _connectedMediaPort;

  String? _currentSyncId;
  File? _currentStreamFile;
  String? _currentStreamTitle;
  bool _currentPlaying = true;
  int _streamVersion = 0;

  Future<void> startHosting({required String displayName}) async {
    await stop();

    _displayName = displayName;
    _sessionId = _randomId();
    _connectedHostLabel = null;

    final controlServer = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _controlServer = controlServer;
    controlServer.listen(_attachClient);

    final mediaServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _mediaServer = mediaServer;
    mediaServer.listen(_handleMediaRequest);

    final discoverySocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
      reusePort: true,
    );
    discoverySocket.broadcastEnabled = true;
    _discoverySocket = discoverySocket;

    _mode = NearbyWatchMode.hosting;
    _statusText = 'Hosting nearby watch party';
    notifyListeners();

    _announceSession();
    _announceTimer = Timer.periodic(_announceInterval, (_) {
      _announceSession();
    });
  }

  Future<void> startDiscovery({required String displayName}) async {
    await stop();

    _displayName = displayName;
    _connectedHostLabel = null;

    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
      reusePort: true,
    );
    socket.broadcastEnabled = true;
    socket.listen(_handleDiscoveryEvent);
    _discoverySocket = socket;

    _mode = NearbyWatchMode.discovering;
    _statusText = 'Looking for nearby watch parties';
    _discoveredSessions = const <NearbySessionAnnouncement>[];
    notifyListeners();

    _pruneTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _pruneStaleSessions();
    });
  }

  Future<void> joinSession(NearbySessionAnnouncement session) async {
    if (_mode != NearbyWatchMode.discovering) {
      return;
    }

    _statusText = 'Joining ${session.hostName}';
    notifyListeners();

    final socket = await Socket.connect(session.address, session.controlPort);
    _hostSocket = socket;
    _connectedHostLabel = session.hostName;
    _connectedHostAddress = session.address;
    _connectedMediaPort = session.mediaPort;
    _mode = NearbyWatchMode.connected;
    _statusText = 'Watching with ${session.hostName}';
    notifyListeners();

    socket.setOption(SocketOption.tcpNoDelay, true);
    utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .listen(
          _handleSocketMessage,
          onDone: _handleHostDisconnected,
          onError: (_) => _handleHostDisconnected(),
        );

    _sendJson(socket, <String, Object?>{
      'type': 'hello',
      'viewer': _displayName ?? 'Viewer',
    });
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _pruneTimer?.cancel();
    _announceTimer = null;
    _pruneTimer = null;

    for (final client in [..._clients]) {
      await client.close();
    }
    _clients.clear();

    await _hostSocket?.close();
    _hostSocket = null;
    await _controlServer?.close();
    _controlServer = null;
    await _mediaServer?.close(force: true);
    _mediaServer = null;
    _discoverySocket?.close();
    _discoverySocket = null;

    _mode = NearbyWatchMode.idle;
    _sessionId = null;
    _statusText = null;
    _connectedHostLabel = null;
    _connectedHostAddress = null;
    _connectedMediaPort = null;
    _currentSyncId = null;
    _currentStreamFile = null;
    _currentStreamTitle = null;
    _currentPlaying = true;
    _discoveredSessions = const <NearbySessionAnnouncement>[];
    notifyListeners();
  }

  Future<void> updateHostedVideo(
    MixedVideo video, {
    required bool playing,
  }) async {
    if (_mode != NearbyWatchMode.hosting) {
      return;
    }

    final file = await video.asset.file;
    if (file == null || !await file.exists()) {
      return;
    }

    final switchedVideo = _currentSyncId != video.syncId;
    _currentSyncId = video.syncId;
    _currentStreamFile = file;
    _currentStreamTitle = video.asset.title ?? 'Offline video';
    _currentPlaying = playing;

    if (switchedVideo) {
      _streamVersion++;
    }

    final snapshot = RemoteWatchSnapshot(
      syncId: video.syncId,
      playing: playing,
      videoTitle: _currentStreamTitle!,
      streamVersion: _streamVersion,
    );

    for (final client in [..._clients]) {
      _sendJson(client, <String, Object?>{
        'type': 'snapshot',
        'syncId': snapshot.syncId,
        'playing': snapshot.playing,
        'videoTitle': snapshot.videoTitle,
        'streamVersion': snapshot.streamVersion,
      });
    }
  }

  String? currentStreamUrlFor(RemoteWatchSnapshot snapshot) {
    final hostAddress = _connectedHostAddress;
    final mediaPort = _connectedMediaPort;
    if (hostAddress == null || mediaPort == null) {
      return null;
    }
    return Uri(
      scheme: 'http',
      host: hostAddress.address,
      port: mediaPort,
      path: '/stream/current',
      queryParameters: <String, String>{'v': '${snapshot.streamVersion}'},
    ).toString();
  }

  void _attachClient(Socket socket) {
    _clients.add(socket);
    socket.setOption(SocketOption.tcpNoDelay, true);
    utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .listen(
          _handleSocketMessage,
          onDone: () => _removeClient(socket),
          onError: (_) => _removeClient(socket),
        );
    final currentSyncId = _currentSyncId;
    final currentStreamTitle = _currentStreamTitle;
    if (currentSyncId != null && currentStreamTitle != null) {
      _sendJson(socket, <String, Object?>{
        'type': 'snapshot',
        'syncId': currentSyncId,
        'playing': _currentPlaying,
        'videoTitle': currentStreamTitle,
        'streamVersion': _streamVersion,
      });
    }
    _statusText = 'Hosting nearby watch party (${_clients.length} joined)';
    notifyListeners();
  }

  void _removeClient(Socket socket) {
    _clients.remove(socket);
    socket.destroy();
    if (_mode == NearbyWatchMode.hosting) {
      _statusText = _clients.isEmpty
          ? 'Hosting nearby watch party'
          : 'Hosting nearby watch party (${_clients.length} joined)';
      notifyListeners();
    }
  }

  void _handleHostDisconnected() {
    _hostSocket?.destroy();
    _hostSocket = null;
    _mode = NearbyWatchMode.discovering;
    _connectedHostLabel = null;
    _connectedHostAddress = null;
    _connectedMediaPort = null;
    _statusText = 'Host disconnected. Looking again.';
    notifyListeners();
  }

  void _handleDiscoveryEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _mode != NearbyWatchMode.discovering) {
      return;
    }

    final datagram = _discoverySocket?.receive();
    if (datagram == null) {
      return;
    }

    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map<String, dynamic> || decoded['type'] != 'announce') {
        return;
      }

      final session = NearbySessionAnnouncement(
        sessionId: decoded['sessionId'] as String,
        hostName: decoded['hostName'] as String,
        address: datagram.address,
        controlPort: decoded['controlPort'] as int,
        mediaPort: decoded['mediaPort'] as int,
        updatedAt: DateTime.now(),
      );

      final next = [..._discoveredSessions];
      final index = next.indexWhere(
        (item) => item.sessionId == session.sessionId,
      );
      if (index >= 0) {
        next[index] = next[index].copyWith(
          address: session.address,
          controlPort: session.controlPort,
          mediaPort: session.mediaPort,
          updatedAt: session.updatedAt,
          hostName: session.hostName,
        );
      } else {
        next.add(session);
      }
      next.sort((a, b) => a.hostName.compareTo(b.hostName));
      _discoveredSessions = next;
      notifyListeners();
    } catch (_) {
      return;
    }
  }

  void _handleSocketMessage(String message) {
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      if (decoded['type'] == 'snapshot') {
        _remoteSyncController.add(
          RemoteWatchSnapshot(
            syncId: decoded['syncId'] as String,
            playing: decoded['playing'] as bool,
            videoTitle: decoded['videoTitle'] as String,
            streamVersion: decoded['streamVersion'] as int,
          ),
        );
      }
    } catch (_) {
      return;
    }
  }

  Future<void> _handleMediaRequest(HttpRequest request) async {
    if (request.uri.path != '/stream/current') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final file = _currentStreamFile;
    if (file == null || !await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final totalLength = await file.length();
    final extension = file.path.split('.').last.toLowerCase();
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.contentType = _contentTypeForExtension(extension);

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader == null) {
      request.response.headers.contentLength = totalLength;
      await request.response.addStream(file.openRead());
      await request.response.close();
      return;
    }

    final match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(rangeHeader);
    if (match == null) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await request.response.close();
      return;
    }

    final startText = match.group(1);
    final endText = match.group(2);

    var start = startText == null || startText.isEmpty
        ? 0
        : int.parse(startText);
    var end = endText == null || endText.isEmpty
        ? totalLength - 1
        : int.parse(endText);

    if (start >= totalLength) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$totalLength',
      );
      await request.response.close();
      return;
    }

    end = min(end, totalLength - 1);
    start = min(start, end);

    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/$totalLength',
    );
    request.response.headers.contentLength = end - start + 1;
    await request.response.addStream(file.openRead(start, end + 1));
    await request.response.close();
  }

  void _announceSession() {
    final socket = _discoverySocket;
    final controlServer = _controlServer;
    final mediaServer = _mediaServer;
    if (socket == null ||
        controlServer == null ||
        mediaServer == null ||
        _sessionId == null) {
      return;
    }

    final payload = jsonEncode(<String, Object?>{
      'type': 'announce',
      'sessionId': _sessionId,
      'hostName': _displayName ?? 'Host',
      'controlPort': controlServer.port,
      'mediaPort': mediaServer.port,
    });

    socket.send(
      utf8.encode(payload),
      InternetAddress('255.255.255.255'),
      discoveryPort,
    );
  }

  void _pruneStaleSessions() {
    final cutoff = DateTime.now().subtract(_staleAfter);
    final retained = _discoveredSessions
        .where((session) => session.updatedAt.isAfter(cutoff))
        .toList(growable: false);
    if (retained.length != _discoveredSessions.length) {
      _discoveredSessions = retained;
      notifyListeners();
    }
  }

  void _sendJson(Socket socket, Map<String, Object?> payload) {
    socket.add(utf8.encode('${jsonEncode(payload)}\n'));
  }

  ContentType _contentTypeForExtension(String extension) {
    return switch (extension) {
      'mp4' => ContentType('video', 'mp4'),
      'mov' => ContentType('video', 'quicktime'),
      'webm' => ContentType('video', 'webm'),
      _ => ContentType.binary,
    };
  }

  String _randomId() {
    final random = Random();
    final value = random.nextInt(0xFFFFFF);
    return value.toRadixString(16).padLeft(6, '0');
  }

  @override
  void dispose() {
    unawaited(stop());
    unawaited(_remoteSyncController.close());
    super.dispose();
  }
}
