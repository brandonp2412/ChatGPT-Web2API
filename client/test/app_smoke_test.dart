import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sloppa/main.dart';
import 'package:sloppa/src/state/chat_controller.dart';
import 'package:sloppa/src/storage/secure_store.dart';

void main() {
  testWidgets(
    'full app shell renders before initialization',
    (WidgetTester tester) async {
      final controller = ChatController(store: SecureStore());
      await tester.pumpWidget(SloppaApp(controller: controller));

      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      controller.dispose();
    },
  );
}
