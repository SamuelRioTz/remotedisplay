import UIKit
import Flutter

// remotedisplay: Flutter en iOS no implementa cursores de mouse (MouseRegion.cursor no
// hace nada en iPadOS), así que el puntero del trackpad se oculta nativamente con
// UIPointerInteraction. Dart (MobileSessionScreen) manda por el canal
// `remotedisplay/pointer` si ocultar y en qué rects (pill, menús) debe seguir visible.
@main
@objc class AppDelegate: FlutterAppDelegate, UIPointerInteractionDelegate {
  private var pointerHidden = false
  private var visibleRects: [CGRect] = []
  private var pointerInteraction: UIPointerInteraction?
  // Captura del puntero (pointer lock + GCMouse → deltas a Dart).
  private var pointerCaptureBridge: PointerCaptureBridge?

  // Monitor externo (iPad, app sin escenas → API clásica de UIScreen): un
  // segundo FlutterEngine con ruta /extscreen dibuja en una UIWindow sobre la
  // pantalla externa (reemplaza el mirroring del sistema mientras exista).
  // Dart (isolate principal) gobierna attach/detach/setDisplay por
  // `remotedisplay/extdisplay`; al isolate externo se le habla por
  // `remotedisplay/extview`.
  private var extWindow: UIWindow?
  private var extEngine: FlutterEngine?
  private var extViewChannel: FlutterMethodChannel?
  private var extDisplayChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    dummyMethodToEnforceBundling();
    if let controller = window?.rootViewController as? FlutterViewController {
      setupExternalDisplayChannel(controller: controller)
      let channel = FlutterMethodChannel(
        name: "remotedisplay/pointer", binaryMessenger: controller.binaryMessenger)
      pointerCaptureBridge = PointerCaptureBridge(channel: channel)
      pointerCaptureBridge?.installRecognizers(on: controller.view)
      channel.setMethodCallHandler { [weak self, weak controller] call, result in
        guard let self = self, let controller = controller else { return }
        switch call.method {
        case "capture":
          let args = call.arguments as? [String: Any]
          let on = args?["on"] as? Bool ?? false
          self.pointerCaptureBridge?.setActive(on)
          result(nil)
        case "setHidden":
          let args = call.arguments as? [String: Any]
          self.pointerHidden = args?["hidden"] as? Bool ?? false
          if let rects = args?["visible"] as? [[Double]] {
            self.visibleRects = rects.compactMap {
              $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil
            }
          } else {
            self.visibleRects = []
          }
          if #available(iOS 13.4, *) {
            if self.pointerInteraction == nil {
              let interaction = UIPointerInteraction(delegate: self)
              controller.view.addInteraction(interaction)
              self.pointerInteraction = interaction
            }
            self.pointerInteraction?.invalidate()
          }
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  public func dummyMethodToEnforceBundling() {
      dummy_method_to_enforce_bundling();
    session_get_rgba(nil, 0);
  }

  // MARK: - Monitor externo

  private func setupExternalDisplayChannel(controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "remotedisplay/extdisplay", binaryMessenger: controller.binaryMessenger)
    extDisplayChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "isConnected":
        result(UIScreen.screens.count > 1)
      case "attach":
        self.attachExternalScreen()
        result(nil)
      case "detach":
        self.teardownExternalScreen(notifyDart: false)
        result(nil)
      case "setDisplay":
        let args = call.arguments as? [String: Any]
        let display = args?["display"] as? Int ?? -1
        self.extViewChannel?.invokeMethod("setDisplay", arguments: ["display": display])
        result(nil)
      case "cursorPos":
        // Posición del cursor remoto (coords globales) → overlay de la vista
        // externa. Alta frecuencia: reenvío directo, sin tocar nada más.
        self.extViewChannel?.invokeMethod("cursorPos", arguments: call.arguments)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NotificationCenter.default.addObserver(
      forName: UIScreen.didConnectNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.extDisplayChannel?.invokeMethod("connected", arguments: nil)
    }
    NotificationCenter.default.addObserver(
      forName: UIScreen.didDisconnectNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.teardownExternalScreen(notifyDart: true)
    }
    // El monitor puede renegociar el modo DESPUÉS de conectar (también en
    // hardware real): reencajar la ventana externa al nuevo bounds.
    NotificationCenter.default.addObserver(
      forName: UIScreen.modeDidChangeNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self = self, let win = self.extWindow else { return }
      guard let screen = note.object as? UIScreen, screen == win.screen else { return }
      win.frame = screen.bounds
      win.rootViewController?.view.frame = win.bounds
    }
  }

  private func attachExternalScreen() {
    guard extEngine == nil else { return }
    guard let screen = UIScreen.screens.first(where: { $0 != UIScreen.main }) else { return }
    // Subir al mejor modo disponible SOLO si mejora el actual — nunca
    // degradar: availableModes puede venir incompleto (p.ej. el TVOut simulado
    // lista solo 720x480 aunque el screen ya esté a 1080p).
    let area = { (m: UIScreenMode) in m.size.width * m.size.height }
    if let best = screen.availableModes.max(by: { area($0) < area($1) }) {
      let currentArea = screen.currentMode.map(area) ?? 0
      if area(best) > currentArea {
        screen.currentMode = best
      }
    }
    screen.overscanCompensation = .scale
    let engine = FlutterEngine(name: "extscreen")
    // Mismo main() de Dart; la ruta inicial elige el bootstrap _runExtScreen.
    engine.run(withEntrypoint: nil, initialRoute: "/extscreen")
    GeneratedPluginRegistrant.register(with: engine)
    let viewController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    let win = UIWindow(frame: screen.bounds)
    win.screen = screen
    win.rootViewController = viewController
    win.isHidden = false
    extEngine = engine
    extWindow = win
    extViewChannel = FlutterMethodChannel(
      name: "remotedisplay/extview", binaryMessenger: engine.binaryMessenger)
  }

  /// Cierra la vista externa: primero `dispose` al isolate (cierra su
  /// ui-session rust con gracia) y poco después se destruye el engine.
  private func teardownExternalScreen(notifyDart: Bool) {
    guard let engine = extEngine else {
      if notifyDart { extDisplayChannel?.invokeMethod("disconnected", arguments: nil) }
      return
    }
    extViewChannel?.invokeMethod("dispose", arguments: nil)
    extEngine = nil
    extViewChannel = nil
    let win = extWindow
    extWindow = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      win?.isHidden = true
      // Orden importa: soltar el FlutterViewController ANTES de destruir el
      // engine — el dealloc de la UIWindow dispara viewDidDisappear, que toca
      // el engine (iosPlatformView) y segfaultea si ya está destruido.
      win?.rootViewController = nil
      engine.viewController = nil
      engine.destroyContext()
    }
    if notifyDart { extDisplayChannel?.invokeMethod("disconnected", arguments: nil) }
  }

  // Sin región → puntero normal (sobre pill/menús); con región → estilo oculto.
  @available(iOS 13.4, *)
  func pointerInteraction(_ interaction: UIPointerInteraction,
                          regionFor request: UIPointerRegionRequest,
                          defaultRegion: UIPointerRegion) -> UIPointerRegion? {
    guard pointerHidden else { return nil }
    for r in visibleRects where r.contains(request.location) { return nil }
    return defaultRegion
  }

  @available(iOS 13.4, *)
  func pointerInteraction(_ interaction: UIPointerInteraction,
                          styleFor region: UIPointerRegion) -> UIPointerStyle? {
    return pointerHidden ? UIPointerStyle.hidden() : nil
  }
}
