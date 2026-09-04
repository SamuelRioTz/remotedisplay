import UIKit
import Flutter

// remotedisplay: Flutter on iOS doesn't implement mouse cursors
// (MouseRegion.cursor does nothing on iPadOS), so the trackpad pointer is
// hidden natively with UIPointerInteraction. Dart (MobileSessionScreen)
// sends over the `remotedisplay/pointer` channel whether to hide it and in
// which rects (pill, menus) it must stay visible.
@main
@objc class AppDelegate: FlutterAppDelegate, UIPointerInteractionDelegate {
  private var pointerHidden = false
  private var visibleRects: [CGRect] = []
  private var pointerInteraction: UIPointerInteraction?
  // Pointer capture (pointer lock + GCMouse → deltas to Dart).
  private var pointerCaptureBridge: PointerCaptureBridge?

  // External monitor (iPad, scene-less app → classic UIScreen API): a
  // second FlutterEngine with route /extscreen draws into a UIWindow on the
  // external screen (replaces system mirroring while it exists). Dart (main
  // isolate) governs attach/detach/setDisplay over `remotedisplay/extdisplay`;
  // the external isolate is talked to over `remotedisplay/extview`.
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

  // MARK: - External monitor

  private func setupExternalDisplayChannel(controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "remotedisplay/extdisplay", binaryMessenger: controller.binaryMessenger)
    extDisplayChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "isConnected":
        result(UIScreen.screens.count > 1)
      case "screenSize":
        // Pixel size of the external monitor's current mode (the one the
        // external window is on, or the first non-main screen).
        let screen = self.extWindow?.screen ?? UIScreen.screens.first(where: { $0 != UIScreen.main })
        if let screen = screen {
          let size = screen.currentMode?.size
            ?? CGSize(width: screen.bounds.width * screen.scale, height: screen.bounds.height * screen.scale)
          result([Double(size.width), Double(size.height)])
        } else {
          result(nil)
        }
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
        // Remote cursor position (global coords) → external view's overlay.
        // High frequency: direct forwarding, without touching anything else.
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
    // The monitor can renegotiate its mode AFTER connecting (also on real
    // hardware): refit the external window to the new bounds.
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
    // Switch to the best available mode ONLY if it improves on the current
    // one — never downgrade: availableModes can come back incomplete (e.g.
    // simulated TVOut lists only 720x480 even though the screen is already at 1080p).
    let area = { (m: UIScreenMode) in m.size.width * m.size.height }
    if let best = screen.availableModes.max(by: { area($0) < area($1) }) {
      let currentArea = screen.currentMode.map(area) ?? 0
      if area(best) > currentArea {
        screen.currentMode = best
      }
    }
    screen.overscanCompensation = .scale
    let engine = FlutterEngine(name: "extscreen")
    // Same Dart main(); the initial route picks the _runExtScreen bootstrap.
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

  /// Closes the external view: first `dispose` to the isolate (gracefully
  /// closes its rust ui-session) and shortly after the engine is destroyed.
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
      // Order matters: release the FlutterViewController BEFORE destroying
      // the engine — the UIWindow's dealloc triggers viewDidDisappear, which
      // touches the engine (iosPlatformView) and segfaults if it's already destroyed.
      win?.rootViewController = nil
      engine.viewController = nil
      engine.destroyContext()
    }
    if notifyDart { extDisplayChannel?.invokeMethod("disconnected", arguments: nil) }
  }

  // No region → normal pointer (over pill/menus); with a region → hidden style.
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
