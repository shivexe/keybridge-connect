import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keybridge_android/main.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class Camera extends MobileScannerPlatform {
  final stream = StreamController<BarcodeCapture>.broadcast();
  int starts = 0, stops = 0;
  @override
  Stream<BarcodeCapture?> get barcodesStream => stream.stream;
  @override
  Stream<TorchState> get torchStateStream =>
      Stream.value(TorchState.unavailable);
  @override
  Stream<double> get zoomScaleStateStream => Stream.value(1);
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts++;
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.unavailable,
      size: Size(1920, 1080),
      numberOfCameras: 1,
    );
  }

  @override
  Widget buildCameraView() => const SizedBox();
  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() => stream.close();
  @override
  Future<void> updateScanWindow(Rect? window) async {}
}

void main() {
  testWidgets(
    'Unrelated and expired codes keep scanning; valid code returns once',
    (tester) async {
      final camera = Camera();
      final original = MobileScannerPlatform.instance;
      MobileScannerPlatform.instance = camera;
      addTearDown(() => MobileScannerPlatform.instance = original);
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await Navigator.push<String>(
                  context,
                  MaterialPageRoute(builder: (_) => const ScanScreen()),
                );
              },
              child: const Text('Scan'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Scan'));
      await tester.pumpAndSettle();
      final scanner = tester.widget<MobileScanner>(find.byType(MobileScanner));
      expect(scanner.scanWindow, isNull);
      expect(scanner.controller!.autoZoom, isTrue);
      camera.stream.add(
        const BarcodeCapture(
          barcodes: [Barcode(rawValue: 'https://example.com')],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ScanScreen), findsOneWidget);
      expect(result, isNull);
      final invitation = {
        'version': 1,
        'vaultId': '11111111-1111-4111-8111-111111111111',
        'pairId': '22222222-2222-4222-8222-222222222222',
        'desktopName': 'Test Mac',
        'url': 'https://192.168.1.2:49443',
        'expiresAt': 1,
        for (final key in ['secret', 'publicKey', 'certificateSha256'])
          key: base64Encode(List.filled(32, 1)),
      };
      camera.stream.add(
        BarcodeCapture(barcodes: [Barcode(rawValue: jsonEncode(invitation))]),
      );
      await tester.pumpAndSettle();
      expect(result, isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(camera.starts, 2);
      invitation['expiresAt'] =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300;
      final code = jsonEncode(invitation);
      camera.stream.add(
        BarcodeCapture(
          barcodes: [
            Barcode(rawValue: code),
            Barcode(rawValue: code),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(result, code);
      expect(find.byType(ScanScreen), findsNothing);
    },
  );
}
