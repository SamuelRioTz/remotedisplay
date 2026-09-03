import 'dart:convert';
import 'dart:ui' as ui;

import 'package:bot_toast/bot_toast.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/refresh_wrapper.dart';
import 'package:flutter_hbb/main.dart' as hbb;
import 'package:flutter_hbb/mobile/pages/server_page.dart'
    show androidChannelInit;
import 'package:flutter_hbb/common/widgets/overlay.dart'
    show draggablePositions;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'home.dart';
import 'session/client_session.dart';
import 'session/external_screen.dart';
import 'session/trackpad_screen.dart';
import 'session/win_events.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'multi_window') {
    // Secondary windows. Remote desktop ones use OUR session UI
    // (ClientRemoteScreen, single-session + our own toolbar); the rest (file
    // transfer, port forward, etc.) still delegates to the engine.
    final argument = args[2].isEmpty
        ? <String, dynamic>{}
        : jsonDecode(args[2]) as Map<String, dynamic>;
    final int type = argument['type'] ?? -1;
    if (type.windowType == WindowType.RemoteDesktop) {
      await _runSessionWindow(args, argument);
      return;
    }
    await hbb.main(args);
    return;
  }
  if (args.isNotEmpty && (args.first == '--cm' || args.contains('--install'))) {
    await hbb.main(args);
    return;
  }

  if (!isDesktop) {
    // TrackpadActivity (Android, desktop mode): second Flutter engine on the
    // phone screen acting as trackpad+keyboard for the session running on
    // the external monitor (same app, same rust runtime).
    if (ui.PlatformDispatcher.instance.defaultRouteName == '/trackpad') {
      await _runTrackpad();
      return;
    }
    // iPad external monitor: second Flutter engine the Runner creates on the
    // external UIScreen — shows ANOTHER remote display from the SAME
    // connection (second ui-session of the shared rust runtime).
    if (ui.PlatformDispatcher.instance.defaultRouteName == '/extscreen') {
      await _runExtScreen();
      return;
    }
    await _runMobile();
    return;
  }

  earlyAssert();
  WidgetsFlutterBinding.ensureInitialized();

  desktopType = DesktopType.main;
  await windowManager.ensureInitialized();
  windowManager.setPreventClose(true);
  await hbb.initEnv(kAppTypeMain);
  // All UI in English (including the engine items we reuse).
  await bind.mainSetLocalOption(key: kCommConfKeyLang, value: 'en');
  // Main's multi-window handler (subset of desktop_home_page's):
  // active-window bookkeeping + opening per-monitor sessions.
  rustDeskWinManager.setMethodHandler((call, fromWindowId) async {
    debugPrint('[client main] ${call.method} from window $fromWindowId');
    if (call.method == kWindowEventShow) {
      await rustDeskWinManager.registerActiveWindow(call.arguments['id']);
    } else if (call.method == kWindowEventHide) {
      await rustDeskWinManager.unregisterActiveWindow(call.arguments['id']);
    } else if (call.method == kWindowEventOpenMonitorSession) {
      final args = jsonDecode(call.arguments);
      await rustDeskWinManager.openMonitorSession(
        args['window_id'] as int,
        args['peer_id'] as String,
        args['display'] as int,
        args['display_count'] as int,
        parseParamScreenRect(args),
        args['window_type'] as int,
      );
    } else if (call.method == kClientEventQueryOpenDisplays) {
      // Which displays of the peer are visible in session windows? Queried
      // LIVE against the plugin's windows (which does prune natively-closed
      // ones, unlike _remoteDesktopWindows): so the "open in window" button
      // only reappears once a window closes.
      final open = <Map<String, dynamic>>[];
      for (final winId in await rustDeskWinManager.getAllSubWindowIds()) {
        if (winId == fromWindowId) continue;
        try {
          final res = await DesktopMultiWindow.invokeMethod(
                  winId, kClientEventGetSessionDisplays, call.arguments)
              .timeout(const Duration(seconds: 1));
          if (res is String && res.isNotEmpty) {
            open.add(jsonDecode(res) as Map<String, dynamic>);
          }
        } catch (_) {
          // dead window or no session for that peer: doesn't count
        }
      }
      return jsonEncode(open);
    } else if (call.method == kClientEventCloseWindow) {
      // Closing another display's window is requested by the toolbar via
      // main (only main knows/governs the windows). The native close
      // triggers onDestroy on that window, which closes its connection gracefully.
      final winId = call.arguments as int;
      try {
        final wc = WindowController.fromWindowId(winId);
        await wc.setPreventClose(false);
        await wc.close();
      } catch (e) {
        debugPrint('[client main] close window $winId failed: $e');
      }
    }
    return null;
  });
  // Note: we do NOT call startService() — the client must not act as host/server.
  await bind.mainCheckConnectStatus();
  // Each connection opens its OWN window (our session is single-connection,
  // without RustDesk's tab bar).
  await bind.mainSetLocalOption(key: kOptionOpenNewConnInTabs, value: 'N');

  _runClientApp();

  // Links that arrive while the app is already running. Two paths, both
  // ending in flutter_hbb's handleUriLink:
  //  - remotedisplay://connection/new/<ip>?password=… opened from the system
  //    (Finder, browser, `open`): the uni_links plugin delivers it here;
  //  - `remotedisplay --connect <ip> --password <pw>` from a second process:
  //    the engine forwards it over the `_url` IPC socket as the global
  //    `on_url_scheme_received` event, which only reaches the FfiModel if the
  //    main window subscribes to global events (upstream does this in its
  //    server page, which this client does not have).
  // Without these two lines a link only worked as a launch argument.
  gFFI.ffiModel.updateEventListener(gFFI.sessionId, '');
  listenUniLinks();

  final windowOptions = hbb.getHiddenTitleBarWindowOptions(isMainWindow: true);
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await restoreWindowPosition(WindowType.Main);
    // Direct launch (`remotedisplay --connect <ip> [--password <pw>]`,
    // shortcuts/scripts) or launched by a remotedisplay:// link: resolved by
    // flutter_hbb's plumbing and the home is not shown — same behavior as the
    // engine's main.
    final handledByUniLinks = await initUniLinks();
    if (handledByUniLinks || handleUriLink(cmdArgs: args)) {
      await windowManager.setOpacity(1);
      await windowManager.hide();
      return;
    }
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setOpacity(1);
    await windowManager.setTitle('Remote Display');
    setResizable(true);
  });
}

/// Dark AMOLED theme for mobile: the engine's darkTheme with base surfaces
/// in PURE black (scaffold, canvas, surface) so that on OLED screens the
/// background is off pixels.
ThemeData _mobileBlackTheme() => MyTheme.darkTheme.copyWith(
      scaffoldBackgroundColor: Colors.black,
      canvasColor: Colors.black,
      colorScheme: MyTheme.darkTheme.colorScheme.copyWith(
        surface: Colors.black,
        background: Colors.black,
      ),
    );

/// Our own style for ALL of the engine's popups (password, informational,
/// permissions…), applied centrally via theme: the engine's CustomAlertDialog
/// is a Material AlertDialog, so dialogTheme + button/checkbox styles fully
/// dress it with the app's visual codes (graphite, soft radii, faint border,
/// blue accent) without rewriting each dialog.
ThemeData _restyleDialogs(ThemeData base) {
  final dark = base.brightness == Brightness.dark;
  const accent = Color(0xFF3B82F6);
  // Same codes as the session pill and the home: graphite #1A1D24, border
  // 0x14FFFFFF, radius 14; filled rounded fields like the login.
  final bg = dark ? const Color(0xFF1A1D24) : Colors.white;
  final border = dark ? const Color(0x14FFFFFF) : const Color(0x14000000);
  final fg = dark ? const Color(0xFFEDEDEF) : const Color(0xFF15171A);
  final soft = dark ? const Color(0xFFB8BDC7) : const Color(0xFF474D57);
  final muted = dark ? const Color(0xFF8A8F98) : const Color(0xFF6B7280);
  final field = dark ? const Color(0xFF23262D) : const Color(0xFFF0F1F3);
  OutlineInputBorder fieldBorder([Color? c, double w = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide:
            c == null ? BorderSide.none : BorderSide(color: c, width: w),
      );
  return base.copyWith(
    dialogBackgroundColor: bg,
    dialogTheme: DialogTheme(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      elevation: 20,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: border),
      ),
      titleTextStyle: TextStyle(
          color: fg,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1),
      contentTextStyle: TextStyle(color: soft, fontSize: 14, height: 1.45),
    ),
    // Fields like the login's: filled, rounded, no underline, label acting
    // as a placeholder (not floating), and focus with an accent ring.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: field,
      hintStyle: TextStyle(color: muted, fontSize: 14),
      labelStyle: TextStyle(color: muted, fontSize: 14),
      helperStyle: TextStyle(color: muted, fontSize: 12),
      floatingLabelBehavior: FloatingLabelBehavior.never,
      prefixIconColor: muted,
      suffixIconColor: muted,
      contentPadding:
          const EdgeInsets.symmetric(vertical: 15, horizontal: 12),
      border: fieldBorder(),
      enabledBorder: fieldBorder(),
      focusedBorder: fieldBorder(accent, 1.5),
      errorBorder: fieldBorder(const Color(0xFFE5484D)),
      focusedErrorBorder: fieldBorder(const Color(0xFFE5484D), 1.5),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: accent,
      selectionColor: accent.withOpacity(0.35),
      selectionHandleColor: accent,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: accent),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor: accent,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: soft,
        side: BorderSide(
            color: dark ? const Color(0x33FFFFFF) : const Color(0x22000000)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: MaterialStateProperty.resolveWith((states) =>
          states.contains(MaterialState.selected)
              ? accent
              : Colors.transparent),
      side: BorderSide(color: soft, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
  );
}

void _runClientApp({Widget home = const ClientHome()}) {
  final botToastBuilder = BotToastInit();
  runApp(RefreshWrapper(
    // gFFI's global models: on mobile, the engine's RemotePage (and its
    // gesture/cursor widgets) resolve them via Provider.of from the app's
    // tree, same as the engine's App does. On desktop, the session window
    // provides its own (ClientRemoteScreen); they don't get in the way here.
    builder: (context) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: gFFI.ffiModel),
        ChangeNotifierProvider.value(value: gFFI.imageModel),
        ChangeNotifierProvider.value(value: gFFI.cursorModel),
        ChangeNotifierProvider.value(value: gFFI.canvasModel),
        ChangeNotifierProvider.value(value: gFFI.peerTabModel),
      ],
      child: GetMaterialApp(
        navigatorKey: globalKey,
        debugShowCheckedModeBanner: false,
        title: 'Remote Display',
        // Mobile (tablet/OLED phone): ALWAYS dark with pure black backgrounds
        // (pixel off) — don't follow the system theme like on desktop.
        // All popups (password, informational) carry our own style.
        theme: _restyleDialogs(
            isDesktop ? MyTheme.lightTheme : _mobileBlackTheme()),
        darkTheme: _restyleDialogs(
            isDesktop ? MyTheme.darkTheme : _mobileBlackTheme()),
        themeMode: isDesktop ? MyTheme.currentThemeMode() : ThemeMode.dark,
        home: home,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: supportedLocales,
        navigatorObservers: [BotToastNavigatorObserver()],
        builder: (context, child) {
          Widget w = child ?? const SizedBox.shrink();
          if (isAndroid) {
            // Like the engine: fixed text scale (the remote session assumes 1.0).
            w = MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.0)),
              child: w,
            );
          }
          return botToastBuilder(context, w);
        },
      ),
    ),
  ));
}

/// Startup on Android/iOS: a single Activity, no window_manager or
/// multi_window (they don't exist there). Minimal replica of the engine's
/// runMobileApp() without update-check or address book/groups/user (there
/// are no servers). The session is opened by the engine's connect() with its
/// MOBILE RemotePage (touch gestures, virtual keyboard, screen switching);
/// the home is ours.
Future<void> _runMobile() async {
  earlyAssert();
  WidgetsFlutterBinding.ensureInitialized();
  await hbb.initEnv(kAppTypeMain);
  await bind.mainSetLocalOption(key: kCommConfKeyLang, value: 'en');
  if (isAndroid) androidChannelInit();
  if (isAndroid) platformFFI.syncAndroidServiceAppDirConfigPath();
  draggablePositions.load();
  // Note: NO startService() — the client must not act as host/server.
  await bind.mainCheckConnectStatus();
  _runClientApp();
}

/// Bootstrap for the TrackpadActivity (Android): second Flutter engine of
/// the same process — rust is already alive, initEnv only re-creates the
/// bindings and handlers for THIS isolate. No startService or discovery: the
/// screen only sends input to the session published in kOptTrackpadSession.
Future<void> _runTrackpad() async {
  earlyAssert();
  WidgetsFlutterBinding.ensureInitialized();
  await hbb.initEnv(kAppTypeMain);
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Remote Display Trackpad',
    theme: ThemeData.dark(),
    home: const TrackpadScreen(),
  ));
}

/// Bootstrap for the external monitor's isolate (iPad): same as the
/// trackpad, rust is already alive — initEnv re-creates the bindings for
/// THIS isolate. Its own app type ('extscreen'): so the main isolate's
/// ('main') global event stream doesn't get overwritten (in rust
/// GLOBAL_EVENT_STREAM indexes by app type and the last registration
/// replaces the previous one).
Future<void> _runExtScreen() async {
  earlyAssert();
  WidgetsFlutterBinding.ensureInitialized();
  await hbb.initEnv('extscreen');
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Remote Display External Screen',
    theme: ThemeData.dark(),
    home: const ExternalScreenView(),
  ));
}

/// Bootstrap for the session window (multi_window of RemoteDesktop type)
/// with our UI. Minimal replica of the engine's runMultiWindow(), without
/// the tab page.
Future<void> _runSessionWindow(
    List<String> args, Map<String, dynamic> argument) async {
  earlyAssert();
  WidgetsFlutterBinding.ensureInitialized();

  hbb.kBootArgs = List.from(args);
  hbb.kWindowId = int.parse(args[1]);
  hbb.kWindowType = WindowType.RemoteDesktop;
  stateGlobal.setWindowId(hbb.kWindowId!);
  // Our session window uses a NATIVE frame and has no engine tab bar:
  // without this, CanvasModel still subtracts those edges and all input
  // (clicks/moves) lands offset ~30 vertical px × the canvas zoom
  // ("cursor on one side, click on another").
  stateGlobal.edgeToEdgeSessionView = true;
  argument['windowId'] = hbb.kWindowId;
  desktopType = DesktopType.remote;

  await hbb.initEnv(kAppTypeDesktopRemote);
  draggablePositions.load();
  // Note: unlike the engine we do NOT hide the native title bar nor set
  // preventClose — moving/closing the window works natively (V1).

  _runClientApp(home: ClientRemoteScreen(params: argument));

  if (argument['screen_rect'] == null) {
    await restoreWindowPosition(
      WindowType.RemoteDesktop,
      windowId: hbb.kWindowId!,
      peerId: argument['id'] as String?,
      display: argument['display'] as int?,
    );
  }

  // In the engine, the tab bar shows the window (which doesn't exist here):
  // show it explicitly or it stays invisible forever.
  final wc = WindowController.fromWindowId(hbb.kWindowId!);
  await wc.show();
  await wc.focus();
}
