import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'core/connection.dart';
import 'core/room_invitation.dart';
import 'core/exchange_invite.dart';
import 'core/transfer.dart';
import 'ui/theme.dart';
import 'ui/illustrations.dart';
import 'ui/brand.dart';
import 'ui/motion.dart';
import 'ui/transfer_progress.dart';
import 'ui/internet_exchange_panel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LineApp());
}

class LineApp extends StatelessWidget {
  const LineApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Line',
    locale: const Locale('en'),
    debugShowCheckedModeBanner: false,
    theme: lineTheme(),
    home: const ShareScreen(),
  );
}

class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key});
  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  final settings = LineSettings();
  final selected = <TransferFile>[];
  final roomInput = TextEditingController();
  final codeInput = TextEditingController();
  final joinForm = GlobalKey<FormState>();
  LineConnection? connection;
  bool motionPaused = false;
  bool get motionAllowed =>
      !motionPaused && !MediaQuery.disableAnimationsOf(context);
  bool receiving = false;
  bool picking = false;
  bool ending = false;
  bool accepting = false;
  bool saving = false;
  String? folder;
  String? selectionError;
  String? savedMessage;
  bool get hasSession => connection != null;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSettings());
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    settings.listenPort = prefs.getInt('listenPort') ?? settings.listenPort;
    settings.publicAddress = prefs.getString('publicAddress') ?? '';
    settings.internetHosting = prefs.getBool('internetHosting') ?? false;
    final storedStun = prefs.getString('stun');
    settings.stun =
        !prefs.containsKey('roomProtocol') &&
            storedStun == 'stun:stun.l.google.com:19302'
        ? ''
        : storedStun ?? settings.stun;
    settings.turn = prefs.getString('turn') ?? '';
    settings.turnUser = prefs.getString('turnUser') ?? '';
    if (mounted) setState(() {});
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _pick() async {
    setState(() {
      picking = true;
      selectionError = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
        dialogTitle: 'Choose files to send',
      );
      if (!mounted) return;
      for (final item in result?.files ?? <PlatformFile>[]) {
        final path = item.path;
        if (path == null || selected.any((f) => f.path == path)) continue;
        if (selected.length >= maxFiles) {
          selectionError = 'You can send up to $maxFiles files per room.';
          break;
        }
        final stat = await File(path).stat();
        selected.add(
          TransferFile(
            id: '${selected.isEmpty ? 0 : int.parse(selected.last.id) + 1}',
            name: p.basename(path),
            size: stat.size,
            path: path,
          ),
        );
      }
    } catch (_) {
      selectionError = 'Unable to open the files. Please try again.';
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> _start() async {
    if (receiving && !(joinForm.currentState?.validate() ?? false)) return;
    if (!receiving && selected.isEmpty) return;
    final link = LineConnection()..addListener(_changed);
    setState(() {
      connection = link;
      savedMessage = null;
    });
    unawaited(WakelockPlus.enable().catchError((Object _) {}));
    if (receiving) {
      await link.join(settings, roomInput.text, codeInput.text);
    } else {
      await link.host(settings, List.of(selected));
    }
  }

  void _changed() {
    if (!mounted) return;
    final transfer = connection?.transfer;
    if (connection?.phase == LinkPhase.error ||
        transfer?.phase == TransferPhase.complete ||
        transfer?.phase == TransferPhase.cancelled ||
        transfer?.phase == TransferPhase.error) {
      unawaited(WakelockPlus.disable().catchError((Object _) {}));
    }
    setState(() {});
  }

  Future<void> _end() async {
    if (ending) return;
    setState(() => ending = true);
    final old = connection;
    old?.removeListener(_changed);
    try {
      await old?.close();
    } finally {
      old?.dispose();
      unawaited(WakelockPlus.disable().catchError((Object _) {}));
      if (mounted) {
        setState(() {
          connection = null;
          ending = false;
          for (final f in selected) {
            f.transferred = 0;
            f.verified = false;
          }
        });
      }
    }
  }

  Future<void> _accept() async {
    setState(() => accepting = true);
    try {
      final destination =
          folder ??
          p.join((await getApplicationDocumentsDirectory()).path, 'Line');
      await connection!.transfer!.accept(destination);
    } catch (_) {
      _toast('Unable to prepare the destination folder.');
    } finally {
      if (mounted) setState(() => accepting = false);
    }
  }

  Future<void> _saveAndroid() async {
    setState(() => saving = true);
    try {
      final files = connection!.transfer!.files;
      final result = await const MethodChannel('app.line/files')
          .invokeMethod<int>('exportFiles', {
            'paths': files.map((f) => f.path!).toList(),
          });
      if (mounted && result != null) {
        setState(
          () => savedMessage = '$result file(s) saved to the selected folder.',
        );
      }
    } on PlatformException catch (e) {
      _toast(e.message ?? 'Unable to save the files.');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _settings() async {
    final updated = await showLineDialog<LineSettings>(
      animate: motionAllowed,
      context: context,
      builder: (_) => SettingsDialog(settings: settings),
    );
    if (updated == null) return;
    settings.listenPort = updated.listenPort;
    settings.publicAddress = updated.publicAddress;
    settings.internetHosting = updated.internetHosting;
    settings.stun = updated.stun;
    settings.turn = updated.turn;
    settings.turnUser = updated.turnUser;
    settings.turnPassword = updated.turnPassword;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('listenPort', settings.listenPort);
    await prefs.setString('publicAddress', settings.publicAddress);
    await prefs.setBool('internetHosting', settings.internetHosting);
    await prefs.setInt('roomProtocol', 2);
    await prefs.setString('stun', settings.stun);
    await prefs.setString('turn', settings.turn);
    await prefs.setString('turnUser', settings.turnUser);
    if (mounted) setState(() {});
  }

  void _help() => showLineDialog<void>(
    animate: motionAllowed,
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('A direct connection.'),
      scrollable: true,
      content: const SizedBox(
        width: 450,
        child: Text(
          '1. Choose files and create a room. Nearby is for the same local network. Internet uses an invitation and a response.\n\n'
          '2. Share the full invitation and the separate temporary code through a trusted channel.\n\n'
          '3. The receiver opens Receive and pastes the invitation and code. For Internet, copy the generated response and return it to the sender.\n\n'
          '4. The sender pastes the response and selects Connect devices. Compare the security codes on both screens before accepting the files.\n\n'
          'Keep Line open on both devices. Invitations expire after 10 minutes. Internet uses free Cloudflare STUN to discover connection addresses. It does not carry the files. No account, paid fallback or relay is configured. Some networks still prevent a direct connection.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Got it'),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    roomInput.dispose();
    codeInput.dispose();
    connection?.removeListener(_changed);
    unawaited(connection?.close());
    unawaited(WakelockPlus.disable().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MotionScope(
    enabled: !motionPaused,
    child: PopScope(
      canPop: !hasSession,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_end());
      },
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final desktop = constraints.maxWidth >= 1050;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (desktop) _sidebar(),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1260),
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              desktop ? 48 : 20,
                              desktop ? 30 : 18,
                              desktop ? 48 : 20,
                              28,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                MotionReveal(child: _header(desktop)),
                                SizedBox(height: desktop ? 42 : 24),
                                _intro(desktop),
                                SizedBox(height: desktop ? 28 : 22),
                                LayoutBuilder(
                                  builder: (context, area) {
                                    final wide = area.maxWidth >= 760;
                                    final work = MotionReveal(
                                      delay: 100,
                                      child: _workPanel(),
                                    );
                                    final aside = MotionReveal(
                                      delay: 160,
                                      child: _aside(),
                                    );
                                    return wide
                                        ? Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Expanded(flex: 8, child: work),
                                              const SizedBox(width: 24),
                                              Expanded(flex: 5, child: aside),
                                            ],
                                          )
                                        : Column(
                                            children: [
                                              work,
                                              const SizedBox(height: 24),
                                              aside,
                                            ],
                                          );
                                  },
                                ),
                                const SizedBox(height: 30),
                                MotionReveal(delay: 380, child: _footer()),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _sidebar() => Container(
    width: 220,
    padding: const EdgeInsets.fromLTRB(22, 32, 22, 24),
    decoration: const BoxDecoration(
      color: sidebar,
      border: Border(right: BorderSide(color: Color(0xFF343431))),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const MotionReveal(child: LineLogo(onDark: true)),
        const SizedBox(height: 48),
        const MotionReveal(
          delay: 60,
          child: Padding(
            padding: EdgeInsets.only(left: 12),
            child: Text(
              'WORKSPACE',
              style: TextStyle(
                fontSize: 9,
                letterSpacing: 1.8,
                color: sidebarMuted,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        MotionReveal(
          delay: 100,
          child: _nav(Icons.swap_horiz_rounded, 'Share', true, () {}),
        ),
        const SizedBox(height: 8),
        MotionReveal(
          delay: 150,
          child: _nav(Icons.help_outline_rounded, 'How it works', false, _help),
        ),
        const Spacer(),
        if (MediaQuery.sizeOf(context).height > 760) ...[
          MotionReveal(
            delay: 340,
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF2D2C29),
                border: Border.all(color: const Color(0xFF44423C)),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.all_inclusive_rounded,
                    color: sidebarMuted,
                    size: 25,
                  ),
                  SizedBox(height: 20),
                  Text(
                    'Ideas travel.\nMake room.',
                    style: TextStyle(
                      fontSize: 22,
                      height: 1.12,
                      color: Colors.white,
                      letterSpacing: -.8,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  SizedBox(height: 12),
                  Text(
                    'An Active Creators product.',
                    style: TextStyle(
                      fontSize: 10,
                      color: sidebarMuted,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
        _nav(
          Icons.tune_rounded,
          'Settings',
          false,
          hasSession ? null : _settings,
        ),
        const SizedBox(height: 24),
        const Padding(
          padding: EdgeInsets.only(left: 12),
          child: Text(
            'LINE  /  0.9.0',
            style: TextStyle(
              fontSize: 9,
              letterSpacing: 1.8,
              color: sidebarMuted,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _nav(
    IconData icon,
    String label,
    bool active,
    VoidCallback? onTap,
  ) => Semantics(
    selected: active,
    child: MotionHover(
      enabled: onTap != null,
      child: Material(
        color: active ? const Color(0xFF3C3935) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 21,
                  color: active ? sidebarHighlight : sidebarMuted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: active ? Colors.white : sidebarMuted,
                    ),
                  ),
                ),
                if (active)
                  Container(
                    width: 5,
                    height: 5,
                    decoration: const BoxDecoration(
                      color: sidebarHighlight,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _motionButton() => IconButton(
    tooltip: MediaQuery.disableAnimationsOf(context)
        ? 'Animations reduced by system'
        : motionPaused
        ? 'Resume animations'
        : 'Pause animations',
    onPressed: MediaQuery.disableAnimationsOf(context)
        ? null
        : () => setState(() => motionPaused = !motionPaused),
    icon: Icon(
      motionPaused || MediaQuery.disableAnimationsOf(context)
          ? Icons.motion_photos_off_outlined
          : Icons.motion_photos_on_outlined,
      size: 20,
    ),
  );

  Widget _header(bool desktop) => Row(
    children: [
      if (!desktop)
        const LineLogo(small: true)
      else
        const Row(
          children: [
            Icon(Icons.space_dashboard_outlined, size: 17, color: muted),
            SizedBox(width: 9),
            Text('Workspace', style: TextStyle(fontSize: 12, color: muted)),
            SizedBox(width: 12),
            Text('/', style: TextStyle(fontSize: 13, color: line)),
            SizedBox(width: 12),
            Text(
              'Share',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      const Spacer(),
      if (desktop) ...[
        _motionButton(),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(
                Platform.isAndroid
                    ? Icons.phone_android_rounded
                    : Icons.desktop_windows_outlined,
                size: 16,
                color: ink,
              ),
              const SizedBox(width: 8),
              Text(
                '${Platform.isAndroid ? 'Android' : 'Windows'} / This device',
                style: const TextStyle(fontSize: 11, color: muted),
              ),
            ],
          ),
        ),
      ] else ...[
        IconButton(
          tooltip: 'How it works',
          onPressed: _help,
          icon: const Icon(Icons.help_outline_rounded, size: 21),
        ),
        IconButton(
          tooltip: 'Settings',
          onPressed: hasSession ? null : _settings,
          icon: const Icon(Icons.tune_rounded, size: 21),
        ),
      ],
    ],
  );

  Widget _intro(bool desktop) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      MotionReveal(
        delay: 50,
        child: Row(
          children: [
            Container(width: 20, height: 1, color: ink),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'LESS DISTANCE. MORE POSSIBILITY.',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1.6,
                  color: muted,
                ),
              ),
            ),
            if (!desktop) _motionButton(),
          ],
        ),
      ),
      SizedBox(height: desktop ? 15 : 8),
      MotionReveal(
        delay: 110,
        distance: 24,
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: desktop ? 'Your files. ' : 'Share without\n'),
              TextSpan(
                text: desktop ? 'No detours.' : 'the detours.',
                style: const TextStyle(
                  color: muted,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
          style: TextStyle(
            fontSize: desktop ? 46 : 35,
            height: 1.08,
            fontWeight: FontWeight.w600,
            letterSpacing: desktop ? -2 : -1.4,
          ),
        ),
      ),
      const SizedBox(height: 14),
      MotionReveal(
        delay: 180,
        child: Text(
          desktop
              ? 'One device to another. A little simpler. A lot more yours.'
              : 'From one device to another. Always yours.',
          style: const TextStyle(color: muted, fontSize: 13, height: 1.6),
        ),
      ),
    ],
  );

  Widget _workPanel() {
    final compact = MediaQuery.sizeOf(context).width < 760;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 20 : 28),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 32,
            offset: Offset(0, 12),
          ),
          BoxShadow(
            color: Color(0x03000000),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: MotionResize(
        child: MotionSwap(
          identity: hasSession
              ? 'session'
              : receiving
              ? 'receive'
              : 'send',
          child: hasSession
              ? _session()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: canvas,
                        border: Border.all(color: const Color(0xFFECECE7)),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: AnimatedAlign(
                              duration: motionAllowed
                                  ? const Duration(milliseconds: 340)
                                  : Duration.zero,
                              curve: Curves.easeOutCubic,
                              alignment: receiving
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: FractionallySizedBox(
                                widthFactor: .5,
                                heightFactor: 1,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: ink,
                                    borderRadius: BorderRadius.circular(10),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0x15000000),
                                        blurRadius: 8,
                                        offset: Offset(0, 3),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: _tab(
                                  false,
                                  Icons.north_east_rounded,
                                  'Send',
                                ),
                              ),
                              Expanded(
                                child: _tab(
                                  true,
                                  Icons.south_west_rounded,
                                  'Receive',
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                receiving
                                    ? 'On the other side.'
                                    : 'Make the next move.',
                                style: const TextStyle(
                                  fontSize: 23,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -.8,
                                  height: 1.2,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                receiving
                                    ? 'Paste the invitation and enter the temporary code.'
                                    : 'Choose your files. We will make the connection.',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: muted,
                                  height: 1.6,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (!receiving && selected.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: softSurface,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${selected.length}',
                              style: const TextStyle(
                                color: ink,
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    if (receiving)
                      _joinFields()
                    else ...[
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<bool>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: false,
                              label: Text('Nearby'),
                              icon: Icon(Icons.wifi_rounded, size: 17),
                            ),
                            ButtonSegment(
                              value: true,
                              label: Text('Internet'),
                              icon: Icon(Icons.public_rounded, size: 17),
                            ),
                          ],
                          selected: {settings.internetHosting},
                          onSelectionChanged: (value) {
                            setState(
                              () => settings.internetHosting = value.single,
                            );
                            unawaited(
                              SharedPreferences.getInstance()
                                  .then((prefs) async {
                                    await prefs.setBool(
                                      'internetHosting',
                                      settings.internetHosting,
                                    );
                                  })
                                  .catchError((Object _) {}),
                            );
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          settings.internetHosting
                              ? 'Exchange an invitation and a response. Free Cloudflare STUN helps find a direct connection. Some networks still block transfers.'
                              : 'Share files with devices on the same local network, such as the same Wi-Fi or hotspot.',
                          style: const TextStyle(
                            fontSize: 11,
                            color: muted,
                            height: 1.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      _selection(),
                    ],
                    if (receiving || selected.isNotEmpty) ...[
                      const SizedBox(height: 22),
                      MotionHover(
                        enabled: !picking,
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: picking ? null : _start,
                            icon: Icon(
                              receiving
                                  ? Icons.link_rounded
                                  : Icons.arrow_forward_rounded,
                              size: 19,
                            ),
                            label: Text(
                              receiving ? 'Join room' : 'Create sharing room',
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 22),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.lock_outline_rounded,
                          size: 13,
                          color: muted,
                        ),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            receiving
                                ? 'Nothing is received until you accept.'
                                : 'Your files stay with you until the transfer.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: muted, fontSize: 10),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _tab(bool value, IconData icon, String label) => Semantics(
    selected: receiving == value,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() {
          receiving = value;
          selectionError = null;
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 15),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedRotation(
                turns: receiving == value ? 0 : -.125,
                duration: motionAllowed
                    ? const Duration(milliseconds: 300)
                    : Duration.zero,
                child: Icon(
                  icon,
                  size: 18,
                  color: receiving == value ? Colors.white : muted,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: AnimatedDefaultTextStyle(
                  duration: motionAllowed
                      ? const Duration(milliseconds: 220)
                      : Duration.zero,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: receiving == value ? Colors.white : muted,
                  ),
                  child: Text(label, textAlign: TextAlign.center),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _selection() => MotionSwap(
    identity: selected.isEmpty,
    child: Column(
      children: [
        if (selected.isEmpty)
          MotionHover(
            enabled: !picking,
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: picking ? null : _pick,
                style: OutlinedButton.styleFrom(
                  backgroundColor: const Color(0xFFFAFAF8),
                  side: const BorderSide(color: line),
                  padding: const EdgeInsets.symmetric(
                    vertical: 28,
                    horizontal: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: Column(
                  children: [
                    const FileStack(),
                    const SizedBox(height: 8),
                    Text(
                      picking ? 'Opening files...' : 'A little of everything.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: ink,
                        letterSpacing: -.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Videos, photos, documents and more.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color: muted,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: ink,
                        borderRadius: BorderRadius.circular(11),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x19000000),
                            blurRadius: 12,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.add_rounded,
                            color: Colors.white,
                            size: 18,
                          ),
                          SizedBox(width: 9),
                          Flexible(
                            child: Text(
                              'Choose files',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else ...[
          ...selected.asMap().entries.map(
            (entry) => MotionReveal(
              key: ValueKey('selected-${entry.value.id}'),
              delay: (entry.key * 45).clamp(0, 250),
              distance: 10,
              child: _fileRow(entry.value, removable: true),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: picking ? null : _pick,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add files'),
            ),
          ),
          const Divider(height: 28),
          Row(
            children: [
              Text(
                'Files: ${selected.length}',
                style: const TextStyle(fontSize: 12, color: muted),
              ),
              const Spacer(),
              Text(
                formatBytes(selected.fold<int>(0, (n, f) => n + f.size)),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
        if (selectionError != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              selectionError!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ),
      ],
    ),
  );

  Widget _joinFields() => Form(
    key: joinForm,
    child: Column(
      children: [
        TextFormField(
          controller: roomInput,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Room invitation',
            hintText: 'Paste the complete Line invitation',
            prefixIcon: Icon(Icons.link_rounded),
          ),
          validator: (value) {
            try {
              if (ExchangeInvite.recognizes(value ?? '')) {
                return value!.length <= 98304
                    ? null
                    : 'This invitation is too long.';
              }
              RoomInvitation.parse(value ?? '');
              return null;
            } on FormatException catch (e) {
              return e.message.toString();
            }
          },
        ),
        const SizedBox(height: 20),
        TextFormField(
          controller: codeInput,
          keyboardType: TextInputType.number,
          obscureText: true,
          maxLength: 12,
          autofillHints: const [AutofillHints.oneTimeCode],
          decoration: const InputDecoration(
            labelText: 'Temporary code',
            hintText: '8 digits Nearby / 12 digits Internet',
            prefixIcon: Icon(Icons.lock_outline_rounded),
            counterText: '',
          ),
          validator: (value) {
            final digits = ExchangeInvite.recognizes(roomInput.text) ? 12 : 8;
            return RegExp('^\\d{$digits}\$').hasMatch((value ?? '').trim())
                ? null
                : 'The code must contain $digits digits.';
          },
          onFieldSubmitted: (_) => _start(),
        ),
      ],
    ),
  );

  Widget _fileRow(TransferFile file, {bool removable = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(
      children: [
        Container(
          width: 42,
          height: 46,
          decoration: BoxDecoration(
            color: canvas,
            borderRadius: BorderRadius.circular(9),
          ),
          child: AnimatedSwitcher(
            duration: motionAllowed
                ? const Duration(milliseconds: 260)
                : Duration.zero,
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: animation,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: Icon(
              file.verified
                  ? Icons.task_alt_rounded
                  : Icons.insert_drive_file_outlined,
              key: ValueKey(file.verified),
              color: accent,
              size: 22,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                file.verified
                    ? '${formatBytes(file.size)} · Verified'
                    : formatBytes(file.size),
                style: const TextStyle(fontSize: 11, color: muted),
              ),
              if (!removable && file.transferred > 0 && !file.verified) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: file.progress,
                  minHeight: 3,
                  borderRadius: BorderRadius.circular(2),
                ),
              ],
            ],
          ),
        ),
        if (removable)
          IconButton(
            tooltip: 'Remove ${file.name}',
            onPressed: () => setState(() => selected.remove(file)),
            icon: const Icon(Icons.close_rounded, size: 18, color: muted),
          ),
      ],
    ),
  );

  Widget _session() {
    final link = connection!;
    final transfer = link.transfer;
    final done = transfer?.phase == TransferPhase.complete;
    final stopped = transfer?.phase == TransferPhase.cancelled;
    final failed =
        link.phase == LinkPhase.error || transfer?.phase == TransferPhase.error;
    final waiting = link.phase == LinkPhase.waiting;
    final approval = transfer?.phase == TransferPhase.waitingApproval;
    final title = failed
        ? link.isSender && link.room == null
              ? 'Could not create the room.'
              : link.connectionAttempts.isNotEmpty
              ? 'Could not open the room.'
              : 'The connection was interrupted.'
        : done
        ? 'Your files have arrived.'
        : stopped
        ? 'Transfer cancelled.'
        : waiting
        ? link.isExchange
              ? (link.isSender
                    ? 'Send the invitation.'
                    : 'Return your response.')
              : 'Your room is ready.'
        : approval
        ? (link.isSender
              ? 'Waiting for approval.'
              : 'Files are waiting for you.')
        : link.isSender && link.phase == LinkPhase.connecting
        ? settings.internetHosting
              ? 'Preparing your invitation.'
              : 'Starting a room on this device.'
        : 'Connecting your devices.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              done
                  ? Icons.check_circle_outline_rounded
                  : failed
                  ? Icons.error_outline_rounded
                  : Icons.link_rounded,
              color: failed ? Colors.red : accent,
              size: 26,
            ),
            const Spacer(),
            Text(
              link.isSender ? 'SENDING' : 'RECEIVING',
              style: const TextStyle(
                fontSize: 10,
                letterSpacing: 1.3,
                color: muted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        MotionSwap(
          identity: transfer?.phase == TransferPhase.transferring
              ? 'transferring'
              : title,
          child: Text(
            transfer?.phase == TransferPhase.transferring
                ? 'Your files are on their way.'
                : title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        const SizedBox(height: 12),
        if (failed) ...[
          Text(
            link.error ?? transfer?.error ?? 'Please try again.',
            style: const TextStyle(color: Colors.red, fontSize: 13),
          ),
          if (link.phase == LinkPhase.error) ...[
            const SizedBox(height: 12),
            if (!link.isSender) ...[
              FilledButton.icon(
                onPressed: ending
                    ? null
                    : () async {
                        await _end();
                        await WidgetsBinding.instance.endOfFrame;
                        if (mounted) await _start();
                      },
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry connection'),
              ),
              const SizedBox(height: 10),
            ],
            OutlinedButton.icon(
              onPressed: ending
                  ? null
                  : () async {
                      await _end();
                      if (mounted) {
                        await _settings();
                      }
                    },
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: const Text('Connection settings'),
            ),
            if (link.connectionAttempts.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text(
                  'Connection details',
                  style: TextStyle(fontSize: 12),
                ),
                children: [
                  SelectableText(
                    link.connectionAttempts
                        .map((a) => a.description)
                        .join('\n\n'),
                    style: const TextStyle(
                      fontSize: 11,
                      color: muted,
                      height: 1.5,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(
                          text:
                              'Line connection check\n${link.connectionAttempts.map((a) => a.description).join('\n')}',
                        ),
                      );
                      _toast('Connection details copied.');
                    },
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: const Text('Copy connection details'),
                  ),
                ],
              ),
          ],
        ] else if (done)
          const Text(
            'All files have been received and verified.',
            style: TextStyle(color: muted, fontSize: 13),
          )
        else if (waiting && link.isExchange)
          InternetExchangePanel(link: link, ending: ending, onCopied: _toast)
        else if (waiting) ...[
          const Text(
            'This device is hosting your room. Share its invitation and temporary code.',
            style: TextStyle(color: muted, fontSize: 13),
          ),
          const SizedBox(height: 20),
          MotionReveal(
            delay: 60,
            distance: 10,
            child: _credential('ROOM NAME', link.room!),
          ),
          const SizedBox(height: 12),
          MotionReveal(
            delay: 120,
            distance: 10,
            child: _credential('TEMPORARY CODE', link.code!),
          ),
          const SizedBox(height: 14),
          const Text(
            'Valid for 10 minutes · One connection only',
            style: TextStyle(color: muted, fontSize: 11),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: () async {
              try {
                final current = await link.refreshInvitation(settings);
                if (current == null) {
                  _toast('Create a new room to copy a fresh invitation.');
                  return;
                }
                await Clipboard.setData(ClipboardData(text: current));
                _toast(
                  'Fresh invitation copied. Share the temporary code too.',
                );
              } catch (_) {
                _toast(
                  'Unable to refresh the Wi-Fi address. Check the host connection and try again.',
                );
              }
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy invitation'),
          ),
          const SizedBox(height: 14),
          Text(
            link.usesIpv6
                ? 'This room uses direct IPv6. The other device also needs IPv6 connectivity. Your router or mobile provider must allow incoming connections; outside access is not verified yet.'
                : link.internetEndpoint != null
                ? 'A direct internet route is prepared on this device. Keep Line and this network connected. Router and provider restrictions can still block access.'
                : Platform.isAndroid
                ? 'Keep this phone connected to Wi-Fi. The active sharing notification keeps the room available while you copy the invitation.'
                : 'Keep Line open here. Other networks may block incoming connections to this device.',
            style: TextStyle(color: muted, fontSize: 11, height: 1.5),
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text(
              'Host connection details',
              style: TextStyle(fontSize: 12),
            ),
            children: [
              SelectableText(
                'Route: ${link.usesIpv6
                    ? 'Direct IPv6'
                    : link.internetEndpoint != null
                    ? 'IPv4 with temporary router access'
                    : 'Local or manual address'}\nListening port: ${link.hostedPort}\n${link.hostedAddresses.join('\n')}',
                style: const TextStyle(fontSize: 11, color: muted),
              ),
            ],
          ),
        ] else if (link.phase != LinkPhase.connected && !stopped) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 14),
          Text(
            link.isSender && link.phase == LinkPhase.connecting
                ? 'Creating an encrypted room on this device.'
                : 'Setting up a secure connection. This may take a few seconds.',
            style: TextStyle(color: muted, fontSize: 13),
          ),
        ],
        if (link.safetyCode != null && !failed && !stopped) ...[
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: softSurface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'COMPARE ON BOTH SCREENS',
                  style: TextStyle(
                    color: accent,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  link.safetyCode!,
                  style: const TextStyle(
                    color: accent,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Matching codes confirm the same connection.',
                  style: TextStyle(color: accent, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
        if (transfer != null) ...[
          const SizedBox(height: 20),
          ...transfer.files.map((f) => _fileRow(f)),
          if (transfer.phase == TransferPhase.transferring || done) ...[
            const SizedBox(height: 16),
            TransferProgress(
              progress: transfer.progress,
              transferred: transfer.transferredBytes,
              total: transfer.totalBytes,
              speed: transfer.bytesPerSecond,
              complete: done,
            ),
          ],
          if (approval && !link.isSender) ...[
            const SizedBox(height: 16),
            const Text(
              'Verify the sender and the security code before accepting.',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            if (Platform.isWindows)
              TextButton.icon(
                onPressed: accepting
                    ? null
                    : () async {
                        final path = await FilePicker.platform.getDirectoryPath(
                          dialogTitle: 'Save files to',
                        );
                        if (path != null && mounted) {
                          setState(() => folder = path);
                        }
                      },
                icon: const Icon(Icons.folder_outlined, size: 18),
                label: Text(
                  folder == null
                      ? 'Choose destination folder'
                      : p.basename(folder!),
                ),
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: accepting ? null : _accept,
                icon: const Icon(Icons.south_west_rounded, size: 18),
                label: Text(
                  accepting
                      ? 'Preparing…'
                      : 'Accept and receive ${formatBytes(transfer.totalBytes)}',
                ),
              ),
            ),
          ],
          if (done && !link.isSender) ...[
            const SizedBox(height: 16),
            if (Platform.isAndroid)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: saving ? null : _saveAndroid,
                  icon: const Icon(Icons.save_alt_rounded),
                  label: Text(
                    saving ? 'Saving…' : 'Save to a folder on your phone',
                  ),
                ),
              )
            else
              OutlinedButton.icon(
                onPressed: () async {
                  await Process.start('explorer.exe', [transfer.destination!]);
                },
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('Open destination folder'),
              ),
            if (savedMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  savedMessage!,
                  style: const TextStyle(color: accent, fontSize: 12),
                ),
              ),
            if (Platform.isAndroid)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  'Received in Line. Save a copy to access the files in other apps.',
                  style: TextStyle(color: muted, fontSize: 11),
                ),
              ),
          ],
        ],
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: ending || saving ? null : _end,
            child: Text(
              ending
                  ? 'Closing…'
                  : done || failed || stopped
                  ? 'New transfer'
                  : 'Cancel and leave',
            ),
          ),
        ),
      ],
    );
  }

  Widget _credential(String label, String value) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: canvas,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: muted, fontSize: 9, letterSpacing: 1.3),
        ),
        const SizedBox(height: 7),
        SelectableText(
          value,
          style: const TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.4,
          ),
        ),
      ],
    ),
  );

  Widget _aside() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const AcBrandPanel(),
      const SizedBox(height: 26),
      const Padding(
        padding: EdgeInsets.only(left: 2),
        child: Text(
          'FROM HERE TO THERE IN 3 STEPS',
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.4,
            color: muted,
          ),
        ),
      ),
      const SizedBox(height: 20),
      _step(
        '01',
        'Choose your files',
        'Everything you want to send to the other side.',
      ),
      _step('02', 'Share the room', 'An invitation and a temporary code.'),
      _step('03', 'Connect and receive', 'Accept and follow the transfer.'),
    ],
  );

  Widget _step(String number, String title, String subtitle) => MotionReveal(
    delay: int.parse(number) * 55,
    distance: 12,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 18, left: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            number,
            style: const TextStyle(
              color: accent,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: muted,
                    fontSize: 11,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _footer() => Column(
    children: [
      const Divider(),
      const SizedBox(height: 14),
      Wrap(
        spacing: 26,
        runSpacing: 12,
        children: [
          _feature(Icons.person_outline_rounded, 'No account needed'),
          _feature(Icons.lock_outline_rounded, 'Encrypted connection'),
          _feature(Icons.cloud_off_outlined, 'No cloud storage'),
        ],
      ),
      const SizedBox(height: 18),
      const Text(
        'Keep both devices connected and Line open during the transfer.',
        style: TextStyle(color: muted, fontSize: 10),
        textAlign: TextAlign.center,
      ),
    ],
  );
  Widget _feature(IconData icon, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, color: muted, size: 15),
      const SizedBox(width: 7),
      Flexible(
        child: Text(label, style: const TextStyle(color: muted, fontSize: 11)),
      ),
    ],
  );
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.settings});
  final LineSettings settings;
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final publicAddress = TextEditingController(
    text: widget.settings.publicAddress,
  );
  late final port = TextEditingController(
    text: '${widget.settings.listenPort}',
  );
  late final stun = TextEditingController(text: widget.settings.stun);
  late final turn = TextEditingController(text: widget.settings.turn);
  late final user = TextEditingController(text: widget.settings.turnUser);
  late final password = TextEditingController(
    text: widget.settings.turnPassword,
  );
  String? error;
  @override
  void dispose() {
    for (final c in [publicAddress, port, stun, turn, user, password]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Connection settings'),
    content: SizedBox(
      width: 490,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The sending device hosts the room. Its invitation contains the address and a temporary TLS identity. No shared room server is required.',
              style: TextStyle(color: muted, fontSize: 13),
            ),
            const SizedBox(height: 22),
            TextField(
              controller: port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Listening port',
                hintText: '8790',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: publicAddress,
              enabled: !widget.settings.internetHosting,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Public host address (optional)',
                hintText: 'example.org:8790',
                helperMaxLines: 3,
                helperText: 'For direct access from another network. Requires a reachable address and routing/firewall support.',
              ),
            ),
            const SizedBox(height: 22),
            TextField(
              controller: stun,
              decoration: const InputDecoration(
                labelText: 'STUN server (optional)',
                helperText: 'For Nearby and direct-address rooms. Internet invitations use built-in free Cloudflare STUN.',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 18),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text(
                'TURN relay (optional)',
                style: TextStyle(fontSize: 14),
              ),
              subtitle: const Text(
                'For networks that block direct connections',
                style: TextStyle(fontSize: 11),
              ),
              children: [
                const SizedBox(height: 12),
                TextField(
                  controller: turn,
                  decoration: const InputDecoration(labelText: 'TURN address'),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: user,
                  decoration: const InputDecoration(labelText: 'TURN username'),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'TURN password'),
                ),
                const SizedBox(height: 12),
                const Text(
                  'The TURN password is kept for this session only. A relay forwards encrypted data and uses bandwidth.',
                  style: TextStyle(fontSize: 11, color: muted),
                ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(
                  error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          final updated = LineSettings(
            internetHosting: widget.settings.internetHosting,
            publicAddress: publicAddress.text.trim(),
            listenPort: int.tryParse(port.text.trim()) ?? 0,
            stun: stun.text.trim(),
            turn: turn.text.trim(),
            turnUser: user.text.trim(),
            turnPassword: password.text,
          );
          final invalid = updated.validate();
          if (invalid != null) {
            setState(() => error = invalid);
            return;
          }
          Navigator.pop(context, updated);
        },
        child: const Text('Save'),
      ),
    ],
  );
}
