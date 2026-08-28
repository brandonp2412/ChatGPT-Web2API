import 'package:flutter/material.dart';

import 'src/state/chat_controller.dart';
import 'src/storage/secure_store.dart';
import 'src/ui/chat_home.dart';
import 'src/voice/voice_overlay.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = ChatController(store: SecureStore());
  runApp(SloppaApp(controller: controller));
  await controller.initialize();
}

class SloppaApp extends StatelessWidget {
  const SloppaApp({required this.controller, super.key});

  final ChatController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sloppa',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF10A37F),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF10A37F),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: VoiceOverlay(
        controller: controller,
        child: ChatHome(controller: controller),
      ),
    );
  }
}
