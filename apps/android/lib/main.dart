import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:keybridge_protocol/keybridge_protocol.dart' as protocol;

void main() => runApp(const KeybridgeApp());

class KeybridgeApp extends StatelessWidget {
  const KeybridgeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Keybridge Connect',
    debugShowCheckedModeBanner: false,
    theme: keybridgeTheme(Brightness.light),
    darkTheme: keybridgeTheme(Brightness.dark),
    themeMode: ThemeMode.dark,
    home: const VaultScreen(),
  );
}

class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});
  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> with WidgetsBindingObserver {
  static const native = MethodChannel('dev.keybridge.connect/native');
  Map<String, dynamic> status = {};
  final statusUpdates = ValueNotifier<Map<String, dynamic>>({});
  int searchRequest = 0;
  List<dynamic> rows = [];
  String query = '', error = '', syncStatus = '';
  bool busy = false, foreground = true, hasMore = false;
  bool syncing = false, manualSync = false;
  int failures = 0;
  Timer? poll;
  String? comparison;
  int? listedGeneration;
  String listedQuery = '';
  Future<dynamic> call(String method, [Map<String, dynamic>? args]) async {
    final value = await native.invokeMethod(method, args);
    if (value is String && (value.startsWith('{') || value.startsWith('['))) {
      return jsonDecode(value);
    }
    return value;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    poll?.cancel();
    statusUpdates.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) {
      refresh();
    } else {
      poll?.cancel();
      if (mounted) {
        setState(() {
          rows = [];
          status = {};
        });
      }
    }
  }

  Future<void> refresh() async {
    try {
      final s = await call('status') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => status = s);
      statusUpdates.value = s;
      if (s['unlocked'] == true) {
        if (rows.isEmpty ||
            listedGeneration != s['generation'] ||
            listedQuery != query) {
          final requestedQuery = query;
          final request = ++searchRequest;
          final list = await call('list', {
            'query': requestedQuery,
            'offset': 0,
          });
          if (mounted &&
              request == searchRequest &&
              requestedQuery == query &&
              status['unlocked'] == true) {
            setState(() {
              rows = list as List;
              hasMore = rows.length == 100;
              listedGeneration = s['generation'];
              listedQuery = requestedQuery;
            });
          }
        }
      } else {
        if (mounted) setState(() => rows = []);
      }
      schedule();
    } catch (_) {}
  }

  void schedule() {
    poll?.cancel();
    if (foreground &&
        status['unlocked'] == true &&
        (status['paired'] == true || status['staged'] == true)) {
      poll = Timer(
        Duration(
          seconds: min(60, 5 * (1 << min(failures, 3))) + Random().nextInt(2),
        ),
        () => sync(quiet: true),
      );
    }
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = e.message ?? 'Operation failed.');
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Operation failed. Try unlocking and checking your desktop connection.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
      await refresh();
    }
  }

  Future<void> sync({bool quiet = false}) async {
    if (busy || syncing) {
      schedule();
      return;
    }
    setState(() {
      syncing = true;
      manualSync = !quiet;
      if (!quiet) error = '';
    });
    try {
      await call('sync');
      failures = 0;
      if (mounted) setState(() => syncStatus = 'Up to date');
    } catch (_) {
      failures++;
      if (mounted) {
        setState(() {
          syncStatus = 'Your saved passwords are available offline';
          if (!quiet) {
            error =
                'Couldn’t reach your Mac. Your saved passwords still work. Check that both devices are on the same Wi-Fi.';
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          syncing = false;
          manualSync = false;
        });
      }
      await refresh();
    }
  }

  Future<void> pair(String code) async {
    await run(() async {
      final p = await call('beginPair', {'code': code});
      if (mounted) setState(() => comparison = p['comparison']);
    });
    if (comparison != null) pairPoll();
  }

  Future<void> pairPoll() async {
    for (var i = 0; i < 150 && mounted && comparison != null; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        final p = await call('pollPair');
        if (p['status'] == 'approved') {
          if (mounted) setState(() => comparison = null);
          await sync();
          return;
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            error = 'Pairing expired or rejected. Scan a fresh invitation.';
            comparison = null;
          });
        }
        return;
      }
    }
  }

  Future<void> scan() async {
    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
    await refresh();
    if (code != null) {
      try {
        if (status['unlocked'] != true) {
          await call('unlock');
          await refresh();
        }
        await pair(code);
      } catch (_) {
        if (mounted) {
          setState(() => error = 'Unlock Keybridge to finish pairing.');
        }
      }
    }
  }

  Future<bool> confirm(
    String title,
    String text, {
    String action = 'Continue',
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> details(Map<String, dynamic> row) async {
    if (busy) return;
    var authorized = false;
    await run(() async {
      await call('authorizeSelection');
      authorized = true;
    });
    if (!mounted || !authorized) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => PasswordDetails(
          row: row,
          reveal: () =>
              native.invokeMethod<String>('reveal', {'id': row['id']}),
          copy: () async {
            if (await confirm(
              'Copy password?',
              'Other apps or your keyboard may read the clipboard. Keybridge clears its unchanged entry after 30 seconds.',
              action: 'Copy password',
            )) {
              await call('copy', {'id': row['id']});
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Password copied. Clears after 30 seconds.'),
                  ),
                );
              }
            }
          },
        ),
      ),
    );
  }

  Future<void> settings() async {
    var changingAuthentication = false;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (c) => ValueListenableBuilder<Map<String, dynamic>>(
          valueListenable: statusUpdates,
          builder: (c, currentStatus, _) => StatefulBuilder(
            builder: (c, updateSettings) {
              Widget section(String title) => Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
                child: Text(
                  title,
                  style: Theme.of(c).textTheme.titleSmall?.copyWith(
                    color: Theme.of(c).colorScheme.onSurfaceVariant,
                  ),
                ),
              );
              Widget setting(
                IconData icon,
                String title,
                String subtitle,
                VoidCallback action, {
                bool destructive = false,
              }) => ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 5,
                ),
                leading: Icon(
                  icon,
                  color: destructive ? Theme.of(c).colorScheme.error : null,
                ),
                title: Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    color: destructive ? Theme.of(c).colorScheme.error : null,
                  ),
                ),
                subtitle: Text(subtitle, style: const TextStyle(fontSize: 13)),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: action,
              );
              void open(String type) {
                run(() async {
                  await call('settings', {'type': type});
                });
              }

              return Scaffold(
                appBar: AppBar(title: const Text('Settings')),
                body: ListView(
                  children: [
                    section('Use your passwords'),
                    setting(
                      Icons.password_rounded,
                      'Enable autofill',
                      currentStatus['autofillEnabled'] == true
                          ? 'Keybridge is your autofill provider'
                          : 'Choose Keybridge in Android settings',
                      () => open('autofill'),
                    ),
                    if (currentStatus['credentialProviderSupported'] != false)
                      setting(
                        Icons.login_rounded,
                        'Sign-in requests',
                        'Use Keybridge with Android’s sign-in picker',
                        () => open('credential'),
                      ),
                    setting(
                      Icons.touch_app_outlined,
                      'Accessibility shortcut',
                      'For missing suggestions, including Firefox email-first sign-in',
                      () => open('accessibility'),
                    ),
                    section('Your computer'),
                    if (currentStatus['paired'] == true)
                      setting(
                        Icons.laptop_mac,
                        'Pair a different computer',
                        'Keep current passwords until the new sync finishes',
                        () async {
                          Navigator.pop(c);
                          if (await confirm(
                            'Replace your computer?',
                            'Your current passwords stay available until the new computer finishes syncing.',
                          )) {
                            await scan();
                          }
                        },
                      ),
                    if (currentStatus['staged'] == true)
                      setting(
                        Icons.close,
                        'Cancel pending connection',
                        'Keep your current computer',
                        () {
                          Navigator.pop(c);
                          run(() async {
                            await call('cancelReplacement');
                          });
                        },
                      ),
                    if (currentStatus['paired'] != true &&
                        currentStatus['staged'] != true)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 24),
                        child: Text('No computer paired yet.'),
                      ),
                    section('Privacy & security'),
                    SwitchListTile.adaptive(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 8,
                      ),
                      secondary: const Icon(Icons.fingerprint),
                      title: const Text('Ask every time'),
                      subtitle: const Text(
                        'Fingerprint or screen lock for each selection, reveal, copy, or security change.',
                      ),
                      value: currentStatus['authenticateEveryTime'] == true,
                      onChanged: changingAuthentication
                          ? null
                          : (value) async {
                              updateSettings(
                                () => changingAuthentication = true,
                              );
                              try {
                                await call('setAuthenticateEveryTime', {
                                  'enabled': value,
                                });
                                await refresh();
                              } on PlatformException catch (e) {
                                if (c.mounted) {
                                  ScaffoldMessenger.of(c).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        e.message ??
                                            'Authentication cancelled. Setting unchanged.',
                                      ),
                                    ),
                                  );
                                }
                              } finally {
                                if (c.mounted) {
                                  updateSettings(
                                    () => changingAuthentication = false,
                                  );
                                }
                              }
                            },
                    ),
                    setting(
                      Icons.lock_outline,
                      'Device screen lock',
                      'Protect access to your saved passwords',
                      () => open('security'),
                    ),
                    setting(
                      Icons.verified_user_outlined,
                      'Forget app approvals',
                      'Ask again before sharing with remembered apps',
                      () async {
                        if (await confirm(
                          'Forget app approvals?',
                          'Future app fills require confirmation again.',
                          action: 'Forget approvals',
                        )) {
                          await run(() async {
                            await call('clearAssociations');
                          });
                        }
                      },
                    ),
                    if (currentStatus['paired'] == true ||
                        currentStatus['staged'] == true)
                      setting(
                        Icons.link_off,
                        'Disconnect computer',
                        'Remove this phone’s saved copy of your passwords',
                        () async {
                          if (await confirm(
                            'Disconnect this computer?',
                            'This removes this app’s paired identity and offline passwords. It does not edit Apple Passwords.',
                            action: 'Disconnect',
                          )) {
                            await run(() async {
                              await call('unpair');
                            });
                            if (c.mounted) Navigator.pop(c);
                          }
                        },
                        destructive: true,
                      ),
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Keybridge Connect 0.1.3\nYour passwords stay on your devices.',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.6,
                          color: Theme.of(c).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await refresh();
  }

  String get lastSync {
    if (status['pendingReceipt'] == true) {
      return 'Finishing sync with your computer';
    }
    if (syncStatus.isNotEmpty) return syncStatus;
    final timestamp = status['lastConfirmed'] as int? ?? 0;
    if (timestamp == 0) return 'Ready for your first sync';
    final date = DateTime.fromMillisecondsSinceEpoch(
      timestamp * 1000,
    ).toLocal();
    final now = DateTime.now();
    final time = TimeOfDay.fromDateTime(date).format(context);
    return date.year == now.year &&
            date.month == now.month &&
            date.day == now.day
        ? 'Last synced today at $time'
        : 'Last synced ${date.day}/${date.month} at $time';
  }

  Widget introduction(
    String title,
    String subtitle,
    IconData icon,
    Widget action,
  ) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              icon,
              size: 32,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 32),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          action,
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final unlocked = status['unlocked'] == true;
    final connected = status['paired'] == true || status['staged'] == true;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Keybridge',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            onPressed: settings,
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
          ),
          if (unlocked)
            IconButton(
              onPressed: busy
                  ? null
                  : () => run(() async {
                      await call('lock');
                    }),
              icon: const Icon(Icons.lock_outline),
              tooltip: 'Lock passwords',
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (busy || manualSync) const LinearProgressIndicator(minHeight: 2),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: !unlocked
                  ? introduction(
                      'Your passwords are locked',
                      'Unlock to view the passwords saved from your Mac.',
                      Icons.key_rounded,
                      Column(
                        children: [
                          FilledButton.icon(
                            onPressed: busy
                                ? null
                                : () => run(() async {
                                    await call('unlock');
                                  }),
                            icon: const Icon(Icons.fingerprint),
                            label: const Text('Unlock Keybridge'),
                          ),
                          if (status['deviceSecure'] == false)
                            TextButton(
                              onPressed: () =>
                                  call('settings', {'type': 'security'}),
                              child: const Text('Set up a screen lock'),
                            ),
                        ],
                      ),
                    )
                  : comparison != null
                  ? introduction(
                      'Compare the codes',
                      'Make sure your computer shows this same code, then approve the connection there.',
                      Icons.verified_user_outlined,
                      Column(
                        children: [
                          Text(
                            comparison!,
                            style: Theme.of(context).textTheme.displayMedium
                                ?.copyWith(
                                  fontFeatures: [
                                    const FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                          const SizedBox(height: 24),
                          TextButton(
                            onPressed: () => run(() async {
                              await call('cancelPair');
                              if (mounted) setState(() => comparison = null);
                            }),
                            child: const Text('Cancel pairing'),
                          ),
                        ],
                      ),
                    )
                  : !connected
                  ? introduction(
                      'Start with your Mac',
                      'Open Keybridge on your Mac and choose Pair your phone. Connect both devices to the same Wi-Fi, then scan the code.',
                      Icons.devices_rounded,
                      FilledButton.icon(
                        onPressed: busy ? null : scan,
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Scan pairing code'),
                      ),
                    )
                  : passwordsView(),
            ),
            if (!unlocked || !connected)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 15,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    const Flexible(
                      child: Text(
                        'Encrypted and available offline',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget passwordsView() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: Text(
                'Passwords',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              onPressed: busy || syncing ? null : () => sync(),
              icon: const Icon(Icons.sync),
              tooltip: 'Sync now',
            ),
          ],
        ),
        Text(
          lastSync,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        if (status['autofillEnabled'] == false) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.password),
            title: const Text('Use your passwords in other apps'),
            subtitle: const Text(
              'Choose Keybridge as your phone’s autofill service.',
            ),
            trailing: TextButton(
              onPressed: () => call('settings', {'type': 'autofill'}),
              child: const Text('Enable'),
            ),
          ),
          const SizedBox(height: 16),
        ],
        TextField(
          onChanged: (value) {
            query = value;
            refresh();
          },
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'Search passwords',
            filled: true,
            fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          query.isEmpty ? Icons.sync : Icons.search_off,
                          size: 36,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          query.isEmpty
                              ? 'Ready for your passwords'
                              : 'No matching passwords',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          query.isEmpty
                              ? 'Choose Sync now on your Mac.\nKeep Keybridge open here while it finishes.'
                              : 'Try a different name or username.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: rows.length + (hasMore ? 1 : 0),
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    if (index == rows.length) {
                      return TextButton(
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                final requestedQuery = query;
                                final requestedOffset = rows.length;
                                final requestedRevision = searchRequest;
                                final next =
                                    await call('list', {
                                          'query': query,
                                          'offset': rows.length,
                                        })
                                        as List;
                                if (mounted) {
                                  if (!foreground ||
                                      status['unlocked'] != true ||
                                      searchRequest != requestedRevision ||
                                      query != requestedQuery ||
                                      rows.length != requestedOffset) {
                                    return;
                                  }
                                  setState(() {
                                    rows.addAll(next);
                                    hasMore = next.length == 100;
                                  });
                                }
                              }),
                        child: const Text('Load more'),
                      );
                    }
                    final row = rows[index] as Map<String, dynamic>;
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(vertical: 7),
                      leading: AccountBadge(row['title'] as String),
                      title: Text(
                        row['title'],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(
                        row['username'],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Icon(
                        row['state'] == 'active'
                            ? Icons.chevron_right
                            : Icons.info_outline,
                        size: 20,
                      ),
                      onTap: () => details(row),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with WidgetsBindingObserver {
  bool accepted = false;
  String scanError = '';
  final controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    cameraResolution: const Size(1920, 1080),
    autoZoom: true,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> camera(bool start) async {
    try {
      if (start) {
        await controller.start();
      } else {
        await controller.stop();
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!controller.value.hasCameraPermission) return;
    if (state == AppLifecycleState.resumed && !accepted) {
      unawaited(camera(true));
    } else if (state == AppLifecycleState.inactive) {
      unawaited(camera(false));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(controller.dispose());
    super.dispose();
  }

  void detected(BarcodeCapture capture) {
    if (accepted) return;
    for (final barcode in capture.barcodes) {
      final code = barcode.rawValue;
      if (code == null) continue;
      try {
        protocol.invitation(code);
        accepted = true;
        Navigator.pop(context, code);
        return;
      } catch (_) {}
    }
    if (scanError.isEmpty) {
      setState(
        () =>
            scanError = 'Scan a current Keybridge pairing code from your Mac.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan your Mac’s code')),
    body: Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Text(
            'On your Mac, choose Pair your phone. Keep both devices on the same Wi-Fi.',
            style: TextStyle(fontSize: 15, height: 1.5),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = min(
                constraints.maxWidth - 48,
                constraints.maxHeight - 48,
              ).clamp(80.0, 300.0);
              return MobileScanner(
                controller: controller,
                tapToFocus: true,
                placeholderBuilder: (_) =>
                    const Center(child: CircularProgressIndicator()),
                overlayBuilder: (_, _) => IgnorePointer(
                  child: Center(
                    child: Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white70, width: 2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                ),
                errorBuilder: (_, error) => Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.no_photography_outlined, size: 40),
                        const SizedBox(height: 16),
                        const Text(
                          'Camera unavailable',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Allow camera access for Keybridge in Android settings, then return and try again.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: () async {
                            await camera(false);
                            await camera(true);
                          },
                          child: const Text('Try camera again'),
                        ),
                        TextButton(
                          onPressed: () async {
                            try {
                              await _VaultScreenState.native.invokeMethod(
                                'settings',
                                {'type': 'camera'},
                              );
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Open Android settings → Apps → Keybridge → Permissions.',
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                          child: const Text('Open camera settings'),
                        ),
                      ],
                    ),
                  ),
                ),
                onDetect: detected,
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              scanError.isEmpty
                  ? 'Hold steady. The camera focuses and zooms automatically.'
                  : scanError,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    ),
  );
}

class PasswordDetails extends StatefulWidget {
  final Map<String, dynamic> row;
  final Future<String?> Function() reveal;
  final Future<void> Function() copy;
  const PasswordDetails({
    required this.row,
    required this.reveal,
    required this.copy,
    super.key,
  });
  @override
  State<PasswordDetails> createState() => _PasswordDetailsState();
}

class _PasswordDetailsState extends State<PasswordDetails>
    with WidgetsBindingObserver {
  String? secret;
  bool authenticating = false, foreground = true;
  String error = '';
  Timer? hide;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    hide?.cancel();
    secret = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      hide?.cancel();
      setState(() => secret = null);
    }
  }

  Future<void> reveal() async {
    if (authenticating) return;
    if (secret != null) {
      hide?.cancel();
      setState(() => secret = null);
      return;
    }
    setState(() => authenticating = true);
    try {
      final value = await widget.reveal();
      if (!mounted || !foreground) return;
      setState(() {
        secret = value;
        error = '';
      });
      hide = Timer(const Duration(seconds: 20), () {
        if (mounted) setState(() => secret = null);
      });
    } on PlatformException catch (e) {
      if (mounted) {
        setState(
          () => error = e.code == 'authentication_cancelled'
              ? 'Password stayed hidden. Authentication was cancelled.'
              : e.message ?? 'Unlock Keybridge again to view this password.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Unlock Keybridge again to view this password.');
      }
    } finally {
      if (mounted) setState(() => authenticating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget field(String label, Widget value, {Widget? action}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                value,
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Password details')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        children: [
          Row(
            children: [
              AccountBadge(widget.row['title'], size: 58),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  widget.row['title'],
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 30),
          field(
            'Username',
            SelectableText(
              widget.row['username'].toString().isEmpty
                  ? 'No username'
                  : widget.row['username'],
              style: const TextStyle(fontSize: 17),
            ),
          ),
          const Divider(height: 1),
          field(
            'Password',
            Text(
              secret ?? '••••••••••••',
              style: const TextStyle(fontSize: 19, letterSpacing: 1),
            ),
            action: IconButton(
              onPressed: authenticating ? null : reveal,
              icon: Icon(
                secret == null
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              tooltip: secret == null ? 'Show password' : 'Hide password',
            ),
          ),
          const Divider(height: 1),
          field(
            'Website',
            SelectableText(
              (widget.row['urls'] as List).join('\n'),
              style: const TextStyle(fontSize: 16, height: 1.5),
            ),
          ),
          if (widget.row['state'] != 'active')
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Text(
                'Review this password on your Mac before using it for autofill.',
                style: TextStyle(color: colors.error),
              ),
            ),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Text(error, style: TextStyle(color: colors.error)),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: authenticating
                ? null
                : () async {
                    setState(() => authenticating = true);
                    try {
                      await widget.copy();
                    } on PlatformException catch (e) {
                      if (mounted) {
                        setState(
                          () => error = e.code == 'authentication_cancelled'
                              ? 'Password was not copied. Authentication was cancelled.'
                              : 'Couldn’t copy. Unlock Keybridge and try again.',
                        );
                      }
                    } catch (_) {
                      if (mounted) {
                        setState(
                          () => error =
                              'Couldn’t copy. Unlock Keybridge and try again.',
                        );
                      }
                    } finally {
                      if (mounted) setState(() => authenticating = false);
                    }
                  },
            icon: const Icon(Icons.copy_outlined, size: 19),
            label: const Text('Copy password'),
          ),
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.laptop_mac, size: 18, color: colors.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'To make changes, edit this account in Apple Passwords on your Mac, then sync.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
