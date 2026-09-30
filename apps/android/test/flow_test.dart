import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keybridge_android/main.dart';

void main() {
  const channel = MethodChannel('dev.keybridge.connect/native');
  TestWidgetsFlutterBinding.ensureInitialized();
  var state = <String, dynamic>{};
  var cancelAuth = false;
  Completer<void>? slowSync;
  Completer<List>? slowPage;
  var calls = <String>[];
  var rows = <Map<String, dynamic>>[];
  setUp(() {
    state = {'unlocked': false, 'deviceSecure': true};
    cancelAuth = false;
    slowSync = null;
    slowPage = null;
    calls = [];
    rows = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'sync':
              if (slowSync != null) await slowSync!.future;
              return null;
            case 'status':
              return jsonEncode(state);
            case 'list':
              if (call.arguments['offset'] > 0 && slowPage != null) {
                return jsonEncode(await slowPage!.future);
              }
              return jsonEncode(rows);
            case 'setAuthenticateEveryTime':
              if (cancelAuth) {
                throw PlatformException(
                  code: 'authentication_cancelled',
                  message: 'Authentication cancelled. Setting unchanged.',
                );
              }
              state['authenticateEveryTime'] = call.arguments['enabled'];
              return null;
            case 'authorizeSelection':
              if (cancelAuth) {
                throw PlatformException(
                  code: 'authentication_cancelled',
                  message: 'Authentication cancelled.',
                );
              }
              return null;
            case 'unlock':
              state['unlocked'] = true;
              return null;
            default:
              return null;
          }
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  testWidgets('Unlock leads directly to pairing, without network entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const KeybridgeApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unlock Keybridge'));
    await tester.pumpAndSettle();
    expect(find.text('Scan pairing code'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Passwords'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Paired empty vault directs user to Mac and settings fit a phone',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      state = {'unlocked': true, 'paired': true, 'generation': 1, 'count': 0};
      await tester.pumpWidget(const KeybridgeApp());
      await tester.pumpAndSettle();
      expect(find.text('Ready for your passwords'), findsOneWidget);
      expect(find.textContaining('generation'), findsNothing);
      expect(find.text('Load more'), findsNothing);
      expect(find.text('Scan pairing code'), findsNothing);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Enable autofill'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Autofill setup is visible until Android confirms it is enabled',
    (tester) async {
      state = {
        'unlocked': true,
        'paired': true,
        'generation': 1,
        'autofillEnabled': false,
      };
      await tester.pumpWidget(const KeybridgeApp());
      await tester.pumpAndSettle();
      expect(find.text('Use your passwords in other apps'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state['autofillEnabled'] = true;
      await tester.pumpWidget(const KeybridgeApp());
      await tester.pumpAndSettle();
      expect(find.text('Use your passwords in other apps'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('Revealed password clears when the app leaves the foreground', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PasswordDetails(
          row: {
            'title': 'Test account',
            'username': 'test@example.com',
            'urls': ['https://example.com'],
            'state': 'active',
          },
          reveal: () async => 'SYNTHETIC_PASSWORD',
          copy: () async {},
        ),
      ),
    );
    await tester.tap(find.byTooltip('Show password'));
    await tester.pumpAndSettle();
    expect(find.text('SYNTHETIC_PASSWORD'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('SYNTHETIC_PASSWORD'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('App stays dark when Android is light', (tester) async {
    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.light;
    addTearDown(
      tester.binding.platformDispatcher.clearPlatformBrightnessTestValue,
    );
    await tester.pumpWidget(const KeybridgeApp());
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(VaultScreen))).brightness,
      Brightness.dark,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Authentication preference changes only after native success', (
    tester,
  ) async {
    state = {'unlocked': true, 'paired': true, 'authenticateEveryTime': false};
    await tester.pumpWidget(const KeybridgeApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    cancelAuth = true;
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(calls.where((call) => call == 'setAuthenticateEveryTime').length, 2);
    expect(
      find.text('Authentication cancelled. Setting unchanged.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Cancelled account selection does not open details', (
    tester,
  ) async {
    state = {'unlocked': true, 'paired': true, 'authenticateEveryTime': true};
    rows = [
      {
        'id': 'test',
        'title': 'Example',
        'username': 'test@example.com',
        'urls': ['https://example.com'],
        'state': 'active',
      },
    ];
    cancelAuth = true;
    await tester.pumpWidget(const KeybridgeApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Example'));
    await tester.pumpAndSettle();
    expect(calls, contains('authorizeSelection'));
    expect(find.byType(PasswordDetails), findsNothing);
    cancelAuth = false;
    await tester.tap(find.text('Example'));
    await tester.pumpAndSettle();
    expect(find.byType(PasswordDetails), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Settings refresh provider status after returning from Android settings',
    (tester) async {
      state = {'unlocked': true, 'paired': true, 'autofillEnabled': false};
      await tester.pumpWidget(const KeybridgeApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Choose Keybridge in Android settings'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      state['autofillEnabled'] = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Keybridge is your autofill provider'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('A late reveal cannot display a password after backgrounding', (
    tester,
  ) async {
    final response = Completer<String?>();
    await tester.pumpWidget(
      MaterialApp(
        home: PasswordDetails(
          row: {
            'title': 'Test',
            'username': 'test',
            'urls': [],
            'state': 'active',
          },
          reveal: () => response.future,
          copy: () async {},
        ),
      ),
    );
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    response.complete('SYNTHETIC_SECRET');
    await tester.pumpAndSettle();
    expect(find.text('SYNTHETIC_SECRET'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Waiting for a computer does not block saved account selection', (
    tester,
  ) async {
    state = {'unlocked': true, 'paired': true};
    rows = [
      {
        'id': 'test',
        'title': 'Offline account',
        'username': 'test@example.com',
        'urls': [],
        'state': 'active',
      },
    ];
    slowSync = Completer<void>();
    await tester.pumpWidget(const KeybridgeApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Sync now'));
    await tester.pump();
    await tester.tap(find.text('Offline account'));
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(PasswordDetails), findsOneWidget);
    slowSync!.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('A stale next page cannot replace new search results', (
    tester,
  ) async {
    state = {'unlocked': true, 'paired': true};
    rows = List.generate(
      100,
      (i) => {
        'id': '$i',
        'title': 'Old $i',
        'username': 'test',
        'urls': [],
        'state': 'active',
      },
    );
    await tester.pumpWidget(const KeybridgeApp());
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Load more'),
      500,
      scrollable: find.byType(Scrollable).last,
    );
    slowPage = Completer<List>();
    await tester.tap(find.text('Load more'));
    await tester.pump();
    rows = [
      {
        'id': 'new',
        'title': 'New result',
        'username': 'test',
        'urls': [],
        'state': 'active',
      },
    ];
    await tester.enterText(find.byType(TextField).first, 'New');
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    slowPage!.complete([
      {
        'id': 'stale',
        'title': 'Stale page',
        'username': 'test',
        'urls': [],
        'state': 'active',
      },
    ]);
    await tester.pumpAndSettle();
    expect(find.text('New result'), findsOneWidget);
    expect(find.text('Stale page'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
