import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sloppa/main.dart';
import 'package:sloppa/src/state/chat_controller.dart';
import 'package:sloppa/src/storage/secure_store.dart';

void main() {
  test(
    'bridge health readiness accepts explicit readiness and startup states',
    () {
      expect(
        ChatController.bridgeHealthReady(<String, dynamic>{
          'ready_for_requests': true,
        }),
        isTrue,
      );
      expect(
        ChatController.bridgeHealthReady(<String, dynamic>{
          'status': 'starting',
        }),
        isTrue,
      );
      expect(
        ChatController.bridgeHealthReady(<String, dynamic>{
          'status': 'healthy',
        }),
        isTrue,
      );
    },
  );

  test('bridge health readiness rejects unknown or empty states', () {
    expect(
      ChatController.bridgeHealthReady(<String, dynamic>{'status': 'degraded'}),
      isFalse,
    );
    expect(ChatController.bridgeHealthReady(<String, dynamic>{}), isFalse);
  });

  test('disposed controller ignores late listener notifications', () {
    final controller = ChatController(store: SecureStore());
    controller.dispose();

    expect(controller.notifyListeners, returnsNormally);
  });

  testWidgets('full app shell renders before initialization', (
    WidgetTester tester,
  ) async {
    final controller = ChatController(store: SecureStore());
    await tester.pumpWidget(SloppaApp(controller: controller));

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    controller.dispose();
  });
}
