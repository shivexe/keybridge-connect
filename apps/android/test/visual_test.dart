import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keybridge_android/main.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Render the actual phone screens with synthetic accounts', (
    tester,
  ) async {
    final font = FontLoader('Roboto')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            File(
              '../../.tools/flutter/engine/src/flutter/txt/third_party/fonts/Roboto-Regular.ttf',
            ).readAsBytesSync(),
          ),
        ),
      );
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            File(
              '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytesSync(),
          ),
        ),
      );
    await icons.load();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = <String, dynamic>{
      'unlocked': true,
      'paired': true,
      'generation': 3,
      'count': 4,
      'autofillEnabled': true,
      'lastConfirmed': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
    final rows = [
      {
        'id': '1',
        'title': 'GitHub',
        'username': 'shivansh@example.com',
        'urls': ['https://github.com'],
        'state': 'active',
      },
      {
        'id': '2',
        'title': 'Google',
        'username': 'shivansh@example.com',
        'urls': ['https://accounts.google.com'],
        'state': 'active',
      },
      {
        'id': '3',
        'title': 'Proton VPN',
        'username': 'shivansh@proton.me',
        'urls': ['https://account.protonvpn.com'],
        'state': 'active',
      },
      {
        'id': '4',
        'title': 'GitHub',
        'username': 'work.account@example.com',
        'urls': ['https://github.com'],
        'state': 'active',
      },
    ];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.keybridge.connect/native'),
      (call) async {
        if (call.method == 'status') return jsonEncode(state);
        if (call.method == 'list') return jsonEncode(rows);
        return null;
      },
    );
    final key = GlobalKey();
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('../../.work/ui-review')
          ..createSync(recursive: true);
        File(
          '${dir.path}/$name.png',
        ).writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final mode in [Brightness.light, Brightness.dark]) {
      binding.platformDispatcher.platformBrightnessTestValue = mode;
      await tester.pumpWidget(
        RepaintBoundary(key: key, child: const KeybridgeApp()),
      );
      await capture('android-passwords-${mode.name}');
      await tester.tap(find.text('Proton VPN'));
      await capture('android-details-${mode.name}');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await capture('android-settings-${mode.name}');
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await capture('android-security-${mode.name}');
      await tester.pumpWidget(const SizedBox());
    }
    state['paired'] = false;
    await tester.pumpWidget(
      RepaintBoundary(key: key, child: const KeybridgeApp()),
    );
    await capture('android-pairing');
    await tester.pumpWidget(const SizedBox());
    state['unlocked'] = false;
    binding.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpWidget(
      RepaintBoundary(key: key, child: const KeybridgeApp()),
    );
    await capture('android-locked');
    await tester.pumpWidget(const SizedBox());
    binding.platformDispatcher.clearPlatformBrightnessTestValue();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.keybridge.connect/native'),
      null,
    );
  });
}
