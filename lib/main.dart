import 'package:flutter/material.dart';

import 'src/offline_feed_screen.dart';

void main() {
  runApp(const OfflineTikTokApp());
}

class OfflineTikTokApp extends StatelessWidget {
  const OfflineTikTokApp({super.key});

  @override
  Widget build(BuildContext context) {
    const canvas = Color(0xFF07111A);
    const accent = Color(0xFFFF7A18);
    const secondary = Color(0xFF00C2A8);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Offline TikTok',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: canvas,
        colorScheme:
            ColorScheme.fromSeed(
              seedColor: accent,
              brightness: Brightness.dark,
            ).copyWith(
              primary: accent,
              secondary: secondary,
              surface: const Color(0xFF102232),
            ),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(fontWeight: FontWeight.w800),
          titleLarge: TextStyle(fontWeight: FontWeight.w700),
          bodyMedium: TextStyle(height: 1.35),
        ),
      ),
      home: const OfflineFeedScreen(),
    );
  }
}
