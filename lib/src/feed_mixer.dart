import 'dart:math';

import 'package:photo_manager/photo_manager.dart';

class MixedVideo {
  const MixedVideo({
    required this.asset,
    required this.score,
    required this.label,
  });

  final AssetEntity asset;
  final double score;
  final String label;
}

List<MixedVideo> buildOfflineMix(List<AssetEntity> assets, {DateTime? now}) {
  final currentTime = now ?? DateTime.now();
  final seed =
      currentTime.year * 1000 + currentTime.month * 100 + currentTime.day;
  final random = Random(seed);

  final scored = assets.map((asset) {
    final freshness = _freshnessScore(asset, currentTime);
    final durationScore = _durationScore(asset.duration);
    final surprise = Random(_hash(asset.id) ^ seed).nextDouble();
    final ratioScore = _ratioScore(asset.width, asset.height);
    final score =
        freshness * 0.35 +
        durationScore * 0.25 +
        surprise * 0.25 +
        ratioScore * 0.15;

    return MixedVideo(
      asset: asset,
      score: score,
      label: _labelFor(freshness, durationScore, surprise),
    );
  }).toList()..sort((left, right) => right.score.compareTo(left.score));

  final fresh = <MixedVideo>[];
  final classics = <MixedVideo>[];
  final freshCutoff = currentTime.subtract(const Duration(days: 10));

  for (final video in scored) {
    final bucket = video.asset.modifiedDateTime.isAfter(freshCutoff)
        ? fresh
        : classics;
    bucket.add(video);
  }

  fresh.shuffle(random);
  classics.shuffle(Random(seed ^ 0x5F3759DF));

  final feed = <MixedVideo>[];
  while (fresh.isNotEmpty || classics.isNotEmpty) {
    if (fresh.isNotEmpty) {
      feed.add(fresh.removeLast());
    }
    if (fresh.isNotEmpty && random.nextDouble() > 0.35) {
      feed.add(fresh.removeLast());
    }
    if (classics.isNotEmpty) {
      feed.add(classics.removeLast());
    }
    if (classics.isNotEmpty && random.nextDouble() > 0.78) {
      feed.add(classics.removeLast());
    }
  }

  return feed;
}

double _freshnessScore(AssetEntity asset, DateTime now) {
  final age = now.difference(asset.modifiedDateTime);
  final ageInDays = age.inHours / 24;
  return (1 - (ageInDays / 30)).clamp(0.0, 1.0);
}

double _durationScore(int durationInSeconds) {
  if (durationInSeconds <= 0) {
    return 0;
  }

  final sweetSpot = 24;
  final distance = (durationInSeconds - sweetSpot).abs();
  return (1 - distance / sweetSpot).clamp(0.0, 1.0);
}

double _ratioScore(int width, int height) {
  if (width == 0 || height == 0) {
    return 0.2;
  }

  final ratio = height / width;
  final distance = (ratio - (16 / 9)).abs();
  return (1 - distance / 1.5).clamp(0.0, 1.0);
}

String _labelFor(double freshness, double durationScore, double surprise) {
  if (surprise > 0.8) {
    return 'Wildcard';
  }
  if (freshness > 0.7) {
    return 'Fresh drop';
  }
  if (durationScore > 0.7) {
    return 'Quick hit';
  }
  return 'Throwback';
}

int _hash(String value) {
  var hash = 2166136261;
  for (final code in value.codeUnits) {
    hash ^= code;
    hash *= 16777619;
  }
  return hash & 0x7fffffff;
}
