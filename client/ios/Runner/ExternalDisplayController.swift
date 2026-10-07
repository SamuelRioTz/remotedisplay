import UIKit
import Flutter

// iPad external monitor under the UIScene life cycle (replaces the scene-less
// UIScreen / UIWindow(frame:).screen code that lived in AppDelegate up to
// 1.0.14: in a scene-based app every window belongs to a UIWindowScene, and the
// only supported way to replace system mirroring is a window attached to the
// scene with the windowExternalDisplayNonInteractive role).
//
// Dart contract (client/lib/session/external_screen.dart) is UNCHANGED:
//   main isolate → native, `remotedisplay/extdisplay`:
//     isConnected → Bool · screenSize → [w, h] px or nil · attach · detach ·
//     setDisplay {display} · cursorPos {x, y}
//   native → main isolate, same channel: connected / disconnected
//   native ↔ external isolate, `remotedisplay/extview`: setDisplay · cursorPos · dispose
//
// How the monitor is taken over:
//   iPadOS 27+   The system no longer offers the external-display scene on its
//                own (iOS 27 release notes, 177015874): the host
//                RunnerFlutterViewController registers a
//                UISceneAccessory(.externalNonInteractive) whose delegate is
//                ExternalDisplaySceneDelegate. The registration starts DISABLED
//                (mirroring continues); `attach` enables it → UIKit connects the
//                scene → we hang a UIWindow(windowScene:) with the second
//                FlutterEngine (route /extscreen) in it; `detach` tears the
//                engine down and disables the registration again → the scene
//                disconnects → mirroring returns. Monitor presence =
//                registration.isAvailable, read from
//                RunnerFlutterViewController.updateProperties() (UIKit tracks
//                that read — automatic in iOS 26+, no plist key — and re-runs
//                updateProperties when the value changes).
//   iPadOS 16–26 The Info.plist role configuration makes UIKit connect that
//                scene by itself while a monitor is present; we keep the scene
//                WITHOUT a window (mirroring continues) until Dart attaches.
//                Presence = the connected scene, or the deprecated but still
//                posted UIScreen notifications.
final class ExternalDisplayController: NSObject {
  private(set) static weak var shared: ExternalDisplayController?

  private weak var host: FlutterViewController?
  /// → main isolate.
  private let displayChannel: FlutterMethodChannel

  /// Scene with the windowExternalDisplayNonInteractive role, while connected.
  private weak var extScene: UIWindowScene?
  /// Dart asked for the external view (attach) and has not closed it.
  private var wantsWindow = false
  private var extWindow: UIWindow?
  private var extEngine: FlutterEngine?
  /// → external isolate.
  private var extViewChannel: FlutterMethodChannel?
  /// `screenSize` calls made while the scene is still connecting (attach is
  /// asynchronous on iPadOS 27): answered on connect, or nil after 3 s.
  private var pendingScreenSize: [FlutterResult] = []
  /// Last presence value sent to Dart (dedupes connected/disconnected).
  private var connectedNotified = false
  /// UISceneAccessoryRegistration on iPadOS 27+ (type-erased: the class is
  /// iOS 27-only and stored properties cannot carry availability).
  private var accessoryRegistration: AnyObject?
  private var observers: [NSObjectProtocol] = []

  init(host: FlutterViewController) {
    self.host = host
    displayChannel = FlutterMethodChannel(
      name: "remotedisplay/extdisplay", binaryMessenger: host.binaryMessenger)
    super.init()
    ExternalDisplayController.shared = self
    displayChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "isConnected":
        let present = self.monitorPresent
        self.connectedNotified = present
        result(present)
      case "screenSize":
        // Pixel size of the monitor's current mode (the screen our window is
        // on, or the connected scene's); while attach is in flight, answered
        // when the scene connects.
        if let screen = self.externalScreen {
          result(self.pixelSize(of: screen))
        } else if self.wantsWindow {
          self.pendingScreenSize.append(result)
          DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.flushPendingScreenSize()
          }
        } else {
          result(nil)
        }
      case "attach":
        self.attach()
        result(nil)
      case "detach":
        self.detach()
        result(nil)
      case "setDisplay":
        let args = call.arguments as? [String: Any]
        let display = args?["display"] as? Int ?? -1
        self.extViewChannel?.invokeMethod("setDisplay", arguments: ["display": display])
        result(nil)
      case "cursorPos":
        // Remote cursor (global coords) → external view's overlay. High
        // frequency: forwarded verbatim, nothing else touched.
        self.extViewChannel?.invokeMethod("cursorPos", arguments: call.arguments)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    adoptConnectedScene()
    registerAccessoryIfAvailable()
    let center = NotificationCenter.default
    // Deprecated since iOS 16 but still posted: the only presence signal before
    // iPadOS 27 when no scene is offered, and a second one there.
    observers.append(center.addObserver(
      forName: UIScreen.didConnectNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.refreshConnected() })
    observers.append(center.addObserver(
      forName: UIScreen.didDisconnectNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.refreshConnected() })
    // The monitor can renegotiate its mode AFTER connecting (also on real
    // hardware): refit the external window to the new bounds.
    observers.append(center.addObserver(
      forName: UIScreen.modeDidChangeNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self = self, let win = self.extWindow,
            let screen = note.object as? UIScreen,
            screen == win.windowScene?.screen else { return }
      win.frame = screen.bounds
      win.rootViewController?.view.frame = win.bounds
    })
  }

  /// Released by AppDelegate when the scene reconnects with a new storyboard
  /// controller: hand the monitor back and drop the old host's accessory.
  deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    if let engine = extEngine {
      extViewChannel?.invokeMethod("dispose", arguments: nil)
      ExternalDisplayController.destroyLater(window: extWindow, engine: engine)
    }
    if #available(iOS 27.0, *),
       let registration = accessoryRegistration as? UISceneAccessoryRegistration {
      host?.unregisterSceneAccessory(registration)
    }
  }

  // MARK: - Scene events (from ExternalDisplaySceneDelegate)

  func sceneConnected(_ scene: UIWindowScene) {
    extScene = scene
    if wantsWindow { showWindow(in: scene) }
    refreshConnected()
  }

  func sceneDisconnected(_ scene: UIWindowScene) {
    guard extScene == nil || extScene === scene else { return }
    extScene = nil
    // We did not ask for it (detach clears wantsWindow first): the monitor went
    // away, or the system withdrew the scene, while the external view was open
    // — the old UIScreen.didDisconnect path.
    let systemInitiated = wantsWindow
    wantsWindow = false
    closeWindow()
    flushPendingScreenSize()
    if systemInitiated {
      setAccessoryEnabled(false)
      if connectedNotified {
        connectedNotified = false
        displayChannel.invokeMethod("disconnected", arguments: nil)
      }
    }
    // Re-announces the monitor if it is in fact still there.
    refreshConnected()
  }

  /// iPadOS 27: called from RunnerFlutterViewController.updateProperties().
  /// Reading `isAvailable` inside it makes UIKit re-run updateProperties when
  /// the value changes.
  func accessoryAvailabilityChanged() {
    refreshConnected()
  }

  // MARK: - Presence

  private var monitorPresent: Bool {
    if #available(iOS 27.0, *),
       let registration = accessoryRegistration as? UISceneAccessoryRegistration {
      return registration.isAvailable
    }
    if extScene != nil { return true }
    return UIScreen.screens.count > 1 // deprecated (iOS 16) but still populated
  }

  private func refreshConnected() {
    let present = monitorPresent
    guard present != connectedNotified else { return }
    connectedNotified = present
    displayChannel.invokeMethod(present ? "connected" : "disconnected", arguments: nil)
  }

  /// The monitor's UIScreen: the one our window is on, else the connected
  /// scene's, else (pre-27 fallback) the first screen that is not the iPad's.
  private var externalScreen: UIScreen? {
    if let screen = extWindow?.windowScene?.screen ?? extScene?.screen { return screen }
    let mainScreen = host?.viewIfLoaded?.window?.windowScene?.screen ?? UIScreen.main
    return UIScreen.screens.first(where: { $0 != mainScreen })
  }

  private func pixelSize(of screen: UIScreen) -> [Double] {
    let size = screen.currentMode?.size
      ?? CGSize(width: screen.bounds.width * screen.scale,
                height: screen.bounds.height * screen.scale)
    return [Double(size.width), Double(size.height)]
  }

  private func flushPendingScreenSize() {
    guard !pendingScreenSize.isEmpty else { return }
    let waiting = pendingScreenSize
    pendingScreenSize = []
    let size = externalScreen.map(pixelSize(of:))
    for reply in waiting { reply(size) }
  }

  // MARK: - Attach / detach

  private func attach() {
    guard !wantsWindow else { return }
    wantsWindow = true
    if let scene = extScene {
      showWindow(in: scene) // iPadOS 16–26: scene already offered by the system
    } else {
      setAccessoryEnabled(true) // iPadOS 27: ask for the scene → sceneConnected
    }
  }

  private func detach() {
    wantsWindow = false
    closeWindow()
    flushPendingScreenSize()
  }

  private func showWindow(in scene: UIWindowScene) {
    guard extEngine == nil, extWindow == nil else { return }
    let screen = scene.screen
    // Best mode only if it improves on the current one — never downgrade:
    // availableModes can come back incomplete (simulated TVOut lists only
    // 720x480 while the screen is already at 1080p). Apple: set the mode
    // BEFORE associating the screen with a window.
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
    let win = UIWindow(windowScene: scene)
    win.frame = screen.bounds
    win.rootViewController = viewController
    // Visible but NOT key: a key external window would be picked up by the
    // plugins that present on UIApplication.windows.first(isKeyWindow)
    // (file_picker, image_picker) and by UIApplication.keyWindow users
    // (url_launcher, video_player, Flutter's text input / popSystemNavigator).
    // If the monitor keeps mirroring after attach on the iPad, switch this to
    // win.makeKeyAndVisible() followed by host.view.window?.makeKey().
    win.isHidden = false
    (scene.delegate as? ExternalDisplaySceneDelegate)?.window = win
    extEngine = engine
    extWindow = win
    extViewChannel = FlutterMethodChannel(
      name: "remotedisplay/extview", binaryMessenger: engine.binaryMessenger)
    flushPendingScreenSize()
  }

  /// Closes the external view: first `dispose` to the isolate (gracefully
  /// closes its rust ui-session), 0.4 s later the engine is destroyed. Order
  /// matters: release the FlutterViewController BEFORE destroyContext — the
  /// window's viewDidDisappear touches the engine (iosPlatformView) and
  /// segfaults if it is already gone. Detaching the window from its scene
  /// restores system mirroring (TN3187); on iPadOS 27 the accessory is then
  /// disabled so the scene goes away too.
  private func closeWindow() {
    guard let engine = extEngine else {
      if !wantsWindow { setAccessoryEnabled(false) }
      return
    }
    extViewChannel?.invokeMethod("dispose", arguments: nil)
    extEngine = nil
    extViewChannel = nil
    let win = extWindow
    extWindow = nil
    ExternalDisplayController.destroyLater(window: win, engine: engine)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      // Not if Dart re-attached meanwhile (a new window lives in the scene).
      if let self = self, !self.wantsWindow { self.setAccessoryEnabled(false) }
    }
  }

  /// Captures only the window and the engine (also used from deinit).
  private static func destroyLater(window win: UIWindow?, engine: FlutterEngine) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      win?.isHidden = true
      win?.rootViewController = nil
      engine.viewController = nil
      engine.destroyContext()
      win?.windowScene = nil
    }
  }

  // MARK: - Scenes and accessory

  /// iPadOS 16–26: the system may have connected the external-display scene
  /// before this controller existed (monitor plugged before launch, or a
  /// reconnect of the main scene). Adopt it so `attach` can use it.
  private func adoptConnectedScene() {
    guard #available(iOS 16.0, *) else { return }
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
    where scene.session.role == .windowExternalDisplayNonInteractive {
      extScene = scene
      return
    }
  }

  private func registerAccessoryIfAvailable() {
    guard #available(iOS 27.0, *), let host = host else { return }
    let configuration = UISceneConfiguration(
      name: ExternalDisplaySceneDelegate.configurationName,
      sessionRole: .windowExternalDisplayNonInteractive)
    configuration.delegateClass = ExternalDisplaySceneDelegate.self
    let accessory = UISceneAccessory.externalNonInteractive(sceneConfiguration: configuration)
    let registration = host.registerSceneAccessory(accessory)
    registration.isEnabled = false // nothing is presented until Dart attaches
    accessoryRegistration = registration
    host.setNeedsUpdateProperties() // first isAvailable read, see RunnerFlutterViewController
  }

  private func setAccessoryEnabled(_ enabled: Bool) {
    guard #available(iOS 27.0, *),
          let registration = accessoryRegistration as? UISceneAccessoryRegistration,
          registration.isEnabled != enabled else { return }
    registration.isEnabled = enabled
  }
}

/// Delegate of the external-display scene (role windowExternalDisplayNonInteractive):
/// named in Info.plist for iPadOS 16–26 and passed as `delegateClass` of the
/// scene accessory on iPadOS 27+. UIKit instantiates it; the controller owns
/// the window and the engine.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
  static let configurationName = "External display"

  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
             options connectionOptions: UIScene.ConnectionOptions) {
    guard let windowScene = scene as? UIWindowScene else { return }
    ExternalDisplayController.shared?.sceneConnected(windowScene)
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    guard let windowScene = scene as? UIWindowScene else { return }
    window = nil
    ExternalDisplayController.shared?.sceneDisconnected(windowScene)
  }
}
