import 'package:chatgpt_bridge_client/main.dart';
import 'package:chatgpt_bridge_client/src/state/chat_controller.dart';
import 'package:chatgpt_bridge_client/src/storage/secure_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'full app shell renders before initialization',
    (WidgetTester tester) async {
      final controller = ChatController(store: SecureStore());
      await tester.pumpWidget(ChatBridgeApp(controller: controller));

      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      controller.dispose();
    },
  );
}
