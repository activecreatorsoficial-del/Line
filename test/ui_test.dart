import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:line/main.dart';
import 'package:line/core/room_invitation.dart';
import 'package:line/core/connection.dart';
import 'package:line/ui/internet_exchange_panel.dart';
import 'package:line/ui/theme.dart';
import 'package:line/ui/transfer_progress.dart';
import 'package:line/ui/brand.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

Future<void> readyBrand(WidgetTester tester, {bool settle = true}) async {
  final context = tester.element(find.byType(ShareScreen));
  await tester.runAsync(() async {
    await Future.wait(
      [
        acDarkAsset,
        acLightAsset,
        acBannerAsset,
      ].map((path) => precacheImage(AssetImage(path), context)),
    );
  });
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final font = FontLoader('Inter')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            await File('assets/fonts/Inter.ttf').readAsBytes(),
          ),
        ),
      );
    await font.load();
    final flutterRoot =
        Platform.environment['FLUTTER_ROOT'] ??
        p.normalize(
          p.join(
            p.dirname(Platform.resolvedExecutable),
            '..',
            '..',
            '..',
            '..',
            '..',
          ),
        );
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            await File(
              p.join(
                flutterRoot,
                'bin',
                'cache',
                'artifacts',
                'material_fonts',
                'MaterialIcons-Regular.otf',
              ),
            ).readAsBytes(),
          ),
        ),
      );
    await icons.load();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding
        .instance
        .platformDispatcher
        .accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      disableAnimations: true,
    );
  });
  tearDown(
    () => TestWidgetsFlutterBinding.instance.platformDispatcher
        .clearAccessibilityFeaturesTestValue(),
  );

  testWidgets('desktop layout and receive form validation', (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const LineApp());
    await readyBrand(tester);
    expect(find.text('Choose files'), findsOneWidget);
    expect(find.text('Create sharing room'), findsNothing);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/desktop.png'),
    );
    await tester.tap(find.text('Receive'));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.text('Send'));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.text('Receive'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/desktop-receive.png'),
    );
    await tester.tap(find.text('Join room'));
    await tester.pumpAndSettle();
    expect(
      find.text('Paste the invitation copied by the sender.'),
      findsOneWidget,
    );
    expect(find.text('The code must contain 8 digits.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('internet hosting is explicit, explained and preserved', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const LineApp());
    await readyBrand(tester);
    expect(
      tester
          .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
          .selected,
      {false},
    );
    await tester.tap(find.text('Internet'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Exchange an invitation and a response.'),
      findsOneWidget,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/desktop-internet.png'),
    );
    await tester.tap(find.text('Receive'));
    await tester.pumpAndSettle();
    expect(find.text('Room invitation'), findsOneWidget);
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
          .selected,
      {true},
    );
    expect(
      (await SharedPreferences.getInstance()).getBool('internetHosting'),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Internet response forms remain usable on a small phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sender = LineConnection()
      ..isExchange = true
      ..phase = LinkPhase.waiting
      ..room = 'LINE-1234ABCD'
      ..code = '123456789012'
      ..invitation = 'line://connect/ui-fixture';
    final receiver = LineConnection()
      ..isExchange = true
      ..isSender = false
      ..phase = LinkPhase.waiting
      ..room = 'LINE-1234ABCD'
      ..invitation = 'line://connect/ui-response';
    addTearDown(() async {
      await sender.close();
      await receiver.close();
      sender.dispose();
      receiver.dispose();
    });
    Widget screen(LineConnection link, String key) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: lineTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: InternetExchangePanel(
            key: ValueKey(key),
            link: link,
            ending: false,
            onCopied: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpWidget(screen(sender, 'sender'));
    await tester.pumpAndSettle();
    expect(find.text('123456789012'), findsOneWidget);
    expect(find.text('Connection response'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/internet-offer-mobile.png'),
    );
    await tester.ensureVisible(find.text('Connect devices'));
    await tester.tap(find.text('Connect devices'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Create a new Internet room'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(screen(receiver, 'receiver'));
    await tester.pumpAndSettle();
    expect(find.text('Copy response'), findsOneWidget);
    expect(find.text('ROOM NAME'), findsOneWidget);
    expect(find.text('Connect devices'), findsNothing);
    expect(find.text('TEMPORARY CODE'), findsNothing);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/internet-response-mobile.png'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry reopens the room using the existing invitation', (
    tester,
  ) async {
    const rtc = MethodChannel('FlutterWebRTC.Method');
    const events = MethodChannel('FlutterWebRTC.Event');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      events,
      (_) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        events,
        null,
      ),
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(rtc, (
      call,
    ) async {
      if (call.method == 'initialize') return null;
      throw PlatformException(code: 'unavailable');
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        rtc,
        null,
      ),
    );
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const LineApp());
    await readyBrand(tester);
    await tester.tap(find.text('Receive'));
    await tester.pumpAndSettle();
    final invitation = RoomInvitation(
      room: 'LINE-1234ABCD',
      fingerprint: '0' * 64,
      addresses: [Uri.parse('wss://127.0.0.1:1/ws')],
      expires: DateTime.now().add(const Duration(minutes: 5)),
    ).encode();
    await tester.enterText(find.byType(TextFormField).at(0), invitation);
    await tester.enterText(find.byType(TextFormField).at(1), '12345678');
    await tester.tap(find.text('Join room'));
    await tester.pumpAndSettle();
    expect(find.text('Retry connection'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/connection-error.png'),
    );
    await tester.tap(find.text('Retry connection'));
    await tester.pumpAndSettle();
    expect(find.text('Join room'), findsNothing);
    expect(find.text('Retry connection'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('New transfer'));
    await tester.pumpAndSettle();
    expect(find.text('Join room'), findsOneWidget);
  });

  testWidgets(
    'motion pauses, resumes, survives rapid input and respects system changes',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures();
      await tester.pumpWidget(const LineApp());
      await readyBrand(tester, settle: false);
      await tester.pump(const Duration(milliseconds: 180));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/motion-enter.png'),
      );
      await tester.pump(const Duration(milliseconds: 1100));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/motion-running.png'),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(find.byIcon(Icons.play_arrow_rounded)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/motion-hover.png'),
      );
      await mouse.removePointer();
      expect(tester.binding.hasScheduledFrame, isTrue);

      await tester.tap(find.byTooltip('Pause animations'));
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(find.byTooltip('Resume animations'), findsOneWidget);
      await tester.tap(find.byTooltip('Resume animations'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue);

      await tester.tap(find.text('Receive'));
      await tester.pump(const Duration(milliseconds: 40));
      final invite = RoomInvitation(
        room: 'LINE-A1B2C3D4',
        fingerprint: 'a' * 64,
        addresses: [Uri.parse('wss://127.0.0.1:8790/ws')],
        expires: DateTime.now().add(const Duration(minutes: 10)),
      ).encode();
      await tester.enterText(find.byType(TextFormField).first, invite);
      await tester.enterText(find.byType(TextFormField).last, '1234');
      await tester.tap(find.text('Send'));
      await tester.pump(const Duration(milliseconds: 35));
      await tester.tap(find.text('Receive'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(TextFormField), findsNWidgets(2));
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        invite,
      );
      await tester.tap(find.text('Join room'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('The code must contain 8 digits.'), findsOneWidget);

      await tester.tap(find.text('Settings'));
      await tester.pump(const Duration(milliseconds: 320));
      expect(find.byType(SettingsDialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 320));
      expect(find.byType(SettingsDialog), findsNothing);

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(find.byTooltip('Animations reduced by system'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('progress shows actual totals and a readable completion state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: lineTheme(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: const TransferProgress(
                progress: 1 / 3,
                transferred: 1024 * 1024 * 1024,
                total: 3 * 1024 * 1024 * 1024,
                speed: 12 * 1024 * 1024,
                complete: false,
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('33%'), findsOneWidget);
    expect(find.text('1.0 GB of 3.0 GB'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/progress.png'),
    );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: lineTheme(),
        home: Scaffold(
          body: const TransferProgress(
            progress: 1,
            transferred: 3 * 1024 * 1024 * 1024,
            total: 3 * 1024 * 1024 * 1024,
            speed: 0,
            complete: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Transfer complete'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small phone, landscape, and scaled text remain usable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in [
      const Size(375, 900),
      const Size(844, 390),
      const Size(768, 1024),
      const Size(1050, 680),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(const LineApp());
      await readyBrand(tester);
      expect(tester.takeException(), isNull);
      if (size.width == 375) {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/mobile.png'),
        );
      }
      await tester.pumpWidget(const SizedBox());
    }
    tester.view.physicalSize = const Size(375, 900);
    await tester.pumpWidget(
      MaterialApp(
        theme: lineTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            textScaler: TextScaler.linear(1.7),
            disableAnimations: true,
          ),
          child: const ShareScreen(),
        ),
      ),
    );
    await readyBrand(tester);
    expect(tester.takeException(), isNull);
  });
}
