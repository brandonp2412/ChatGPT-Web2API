import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sloppa/main.dart' as app;
import 'package:sloppa/src/state/chat_controller.dart';
import 'package:sloppa/src/storage/secure_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('core browser chat flow works end to end', (
    WidgetTester tester,
  ) async {
    final controller = ChatController(store: SecureStore());
    await tester.pumpWidget(app.SloppaApp(controller: controller));
    await controller.initialize();
    await tester.pumpAndSettle(const Duration(seconds: 3));

    expect(find.text('New chat'), findsWidgets);
    expect(find.byTooltip('Settings'), findsOneWidget);

    final menu = find.byIcon(Icons.menu);
    if (menu.evaluate().isNotEmpty) {
      await tester.tap(menu.first);
      await tester.pumpAndSettle();
    }

    expect(find.text('Welcome to Sloppa'), findsOneWidget);
    await tester.tap(find.text('Welcome to Sloppa'));
    await tester.pumpAndSettle();

    expect(find.text('Show me the deterministic E2E fixture.'), findsOneWidget);
    expect(
      find.text('This conversation is served by the local Sloppa E2E bridge.'),
      findsOneWidget,
    );

    final composer = find.widgetWithText(TextField, 'Message ChatGPT');
    expect(composer, findsOneWidget);
    await tester.enterText(composer, 'Browser E2E ping');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    expect(find.text('Browser E2E ping'), findsOneWidget);
    expect(find.textContaining('Stub reply: Browser E2E ping'), findsOneWidget);
  });
}
