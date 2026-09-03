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
    // Ventanas secundarias. Las de escritorio remoto usan NUESTRA UI de sesión
    // (ClientRemoteScreen, single-sesión + toolbar propia); el resto (file
    // transfer, port forward, etc.) sigue delegando en el engine.
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
    // TrackpadActivity (Android, modo escritorio): segundo engine Flutter en
    // la pantalla del teléfono que actúa de trackpad+teclado de la sesión
    // que corre en el monitor externo (misma app, mismo runtime rust).
    if (ui.PlatformDispatcher.instance.defaultRouteName == '/trackpad') {
      await _runTrackpad();
      return;
    }
    // Monitor externo del iPad: segundo engine Flutter que el Runner crea
    // sobre la UIScreen externa — muestra OTRO display remoto de la MISMA
    // conexión (segunda ui-session del runtime rust compartido).
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
  // Toda la UI en inglés (también los ítems del engine que reusamos).
  await bind.mainSetLocalOption(key: kCommConfKeyLang, value: 'en');
  // Handler multiventana del main (subconjunto del de desktop_home_page):
  // bookkeeping de ventanas activas + abrir sesiones por monitor.
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
      // ¿Qué displays del peer están visibles en las ventanas de sesión?
      // Se consulta EN VIVO contra las ventanas del plugin (que sí depura las
      // cerradas nativamente, a diferencia de _remoteDesktopWindows): así el
      // botón "abrir en ventana" reaparece solo cuando una ventana se cierra.
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
          // ventana muerta o sin sesión de ese peer: no cuenta
        }
      }
      return jsonEncode(open);
    } else if (call.method == kClientEventCloseWindow) {
      // Cerrar la ventana de otro display lo pide la toolbar vía main (solo
      // el main conoce/gobierna las ventanas). El cierre nativo dispara
      // onDestroy en esa ventana, que cierra su conexión con gracia.
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
  // Nota: NO llamamos startService() — el cliente no debe actuar de host/server.
  await bind.mainCheckConnectStatus();
  // Cada conexión abre su PROPIA ventana (nuestra sesión es single-conexión,
  // sin el tab bar de RustDesk).
  await bind.mainSetLocalOption(key: kOptionOpenNewConnInTabs, value: 'N');

  _runClientApp();

  final windowOptions = hbb.getHiddenTitleBarWindowOptions(isMainWindow: true);
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await restoreWindowPosition(WindowType.Main);
    // Lanzamiento directo (`remotedisplay --connect <ip> [--password <pw>]`, accesos
    // directos/scripts): lo resuelve la plomería de flutter_hbb y la home no se
    // muestra — mismo comportamiento que el main del engine.
    if (handleUriLink(cmdArgs: args)) {
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

/// Theme oscuro AMOLED para móvil: el darkTheme del engine con las
/// superficies base en negro PURO (scaffold, canvas, surface) para que en
/// pantallas OLED el fondo sean píxeles apagados.
ThemeData _mobileBlackTheme() => MyTheme.darkTheme.copyWith(
      scaffoldBackgroundColor: Colors.black,
      canvasColor: Colors.black,
      colorScheme: MyTheme.darkTheme.colorScheme.copyWith(
        surface: Colors.black,
        background: Colors.black,
      ),
    );

/// Estilo propio para TODOS los popups del engine (password, informativos,
/// permisos…), central vía theme: el CustomAlertDialog del engine es un
/// AlertDialog de Material, así que dialogTheme + estilos de botón/checkbox
/// lo visten completo con los códigos visuales de la app (grafito, radios
/// suaves, borde tenue, acento azul) sin reescribir cada diálogo.
ThemeData _restyleDialogs(ThemeData base) {
  final dark = base.brightness == Brightness.dark;
  const accent = Color(0xFF3B82F6);
  // Mismos códigos que la pill de sesión y la home: grafito #1A1D24, borde
  // 0x14FFFFFF, radio 14; campos rellenos redondeados como el login.
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
    // Campos como los del login: rellenos, redondeados, sin subrayado, label
    // como placeholder (sin flotar) y foco con anillo accent.
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
    // Modelos globales del gFFI: en móvil la RemotePage del engine (y sus
    // widgets de gestos/cursor) los resuelve con Provider.of desde el árbol de
    // la app, igual que hace el App del engine. En desktop la ventana de
    // sesión provee los suyos (ClientRemoteScreen); acá no molestan.
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
        // Móvil (tablet/teléfono OLED): SIEMPRE oscuro con fondos negro puro
        // (píxel apagado) — no seguir el theme del sistema como en desktop.
        // Todos los popups (password, informativos) llevan el estilo propio.
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
            // Como el engine: escala de texto fija (la sesión remota asume 1.0).
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

/// Arranque en Android/iOS: una sola Activity, sin window_manager ni
/// multi_window (no existen ahí). Réplica mínima de runMobileApp() del engine
/// sin update-check ni address book/grupos/usuario (no hay servidores). La
/// sesión la abre connect() del engine con su RemotePage MÓVIL (gestos
/// táctiles, teclado virtual, cambio de pantalla); la home es la nuestra.
Future<void> _runMobile() async {
  earlyAssert();
  WidgetsFlutterBinding.ensureInitialized();
  await hbb.initEnv(kAppTypeMain);
  await bind.mainSetLocalOption(key: kCommConfKeyLang, value: 'en');
  if (isAndroid) androidChannelInit();
  if (isAndroid) platformFFI.syncAndroidServiceAppDirConfigPath();
  draggablePositions.load();
  // Nota: NO startService() — el cliente no debe actuar de host/server.
  await bind.mainCheckConnectStatus();
  _runClientApp();
}

/// Bootstrap de la TrackpadActivity (Android): segundo engine Flutter del
/// mismo proceso — el rust ya está vivo, initEnv solo re-crea los bindings y
/// handlers de ESTE isolate. Sin startService ni descubrimiento: la pantalla
/// solo manda input a la sesión publicada en kOptTrackpadSession.
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

/// Bootstrap del isolate del monitor externo (iPad): igual que el trackpad,
/// el rust ya está vivo — initEnv re-crea los bindings de ESTE isolate. App
/// type propio ('extscreen'): así el stream global de eventos del isolate
/// principal ('main') no se pisa (en rust GLOBAL_EVENT_STREAM indexa por app
/// type y el último registro reemplaza al anterior).
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

/// Bootstrap de la ventana de sesión (multi_window tipo RemoteDesktop) con
/// nuestra UI. Réplica mínima de runMultiWindow() del engine, sin el tab page.
Future<void> _runSessionWindow(
    List<String> args, Map<String, dynamic> argument) async {
  earlyAssert();
  WidgetsFlutterBinding.ensureInitialized();

  hbb.kBootArgs = List.from(args);
  hbb.kWindowId = int.parse(args[1]);
  hbb.kWindowType = WindowType.RemoteDesktop;
  stateGlobal.setWindowId(hbb.kWindowId!);
  // Nuestra ventana de sesión usa marco NATIVO y no tiene el tab bar del
  // engine: sin esto, CanvasModel descuenta esos edges igual y todo el input
  // (clicks/moves) cae corrido ~30px verticales × el zoom del canvas
  // ("cursor en un lado, click en otro").
  stateGlobal.edgeToEdgeSessionView = true;
  argument['windowId'] = hbb.kWindowId;
  desktopType = DesktopType.remote;

  await hbb.initEnv(kAppTypeDesktopRemote);
  draggablePositions.load();
  // Nota: a diferencia del engine NO ocultamos la barra de título nativa ni
  // seteamos preventClose — mover/cerrar la ventana funciona nativo (V1).

  _runClientApp(home: ClientRemoteScreen(params: argument));

  if (argument['screen_rect'] == null) {
    await restoreWindowPosition(
      WindowType.RemoteDesktop,
      windowId: hbb.kWindowId!,
      peerId: argument['id'] as String?,
      display: argument['display'] as int?,
    );
  }

  // En el engine la ventana la muestra el tab bar (que acá no existe):
  // mostrarla explícitamente o queda invisible para siempre.
  final wc = WindowController.fromWindowId(hbb.kWindowId!);
  await wc.show();
  await wc.focus();
}
