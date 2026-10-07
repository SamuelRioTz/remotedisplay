import UIKit
import Flutter

// remotedisplay: Flutter on iOS doesn't implement mouse cursors
// (MouseRegion.cursor does nothing on iPadOS), so the trackpad pointer is
// hidden natively with UIPointerInteraction. Dart (MobileSessionScreen)
// sends over the `remotedisplay/pointer` channel whether to hide it and in
// which rects (pill, menus) it must stay visible.
//
// UIScene life cycle (mandatory for apps linked against the iOS 27 SDK; Flutter
// 3.24.5 has no scene support of its own, see SceneDelegate.swift): the
// storyboard RunnerFlutterViewController is created when the main scene
// connects — AFTER didFinishLaunching — and UIKit never fills
// FlutterAppDelegate.window. SceneDelegate hands the window over and calls
// attachFlutter(); everything that needs the FlutterViewController lives
// there. The external monitor is ExternalDisplayController (scene-based too).
@main
@objc class AppDelegate: FlutterAppDelegate, UIPointerInteractionDelegate {
  private var pointerHidden = false
  private var visibleRects: [CGRect] = []
  private var pointerInteraction: UIPointerInteraction?
  // Pointer capture (pointer lock + GCMouse → deltas to Dart).
  private var pointerCaptureBridge: PointerCaptureBridge?
  // External monitor; owned here so it lives as long as its host controller.
  private var externalDisplay: ExternalDisplayController?
  /// The FlutterViewController the plugins and channels are installed on.
  /// UIKit builds a NEW one from Main.storyboard every time the scene
  /// connects — it may disconnect and reconnect the scene while the process
  /// lives — and each one owns its own implicit FlutterEngine, so the setup
  /// is keyed on the controller, not on a "done once" flag.
  private weak var attachedController: FlutterViewController?
  private var replayingLaunch = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if !replayingLaunch {
      dummyMethodToEnforceBundling()
    }
    // FlutterAppDelegate forwards this to the plugins registered through
    // addApplicationDelegate (uni_links reads launchOptions[.url] in it). At
    // the real launch none is registered yet (window is nil under scenes);
    // SceneDelegate replays it through replayLaunch(options:).
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Plugin registration and the native channels for the CURRENT storyboard
  /// controller. Called by SceneDelegate once UIKit has created the window
  /// from Main.storyboard (and, belt and braces, from
  /// RunnerFlutterViewController.viewDidLoad). No-op while the window is
  /// unknown or the controller is already set up; redone for a new controller
  /// (scene reconnect), exactly as Flutter's own scene embedder re-registers
  /// plugins per implicit engine.
  func attachFlutter() {
    guard let controller = window?.rootViewController as? FlutterViewController,
          controller !== attachedController else { return }
    attachedController = controller
    // State bound to a previous controller: release it first (the external
    // display controller unregisters its scene accessory and drops its
    // observers in deinit; the pointer interaction belonged to the old view).
    externalDisplay = nil
    pointerCaptureBridge = nil
    pointerInteraction = nil
    GeneratedPluginRegistrant.register(with: self)
    externalDisplay = ExternalDisplayController(host: controller)
    let channel = FlutterMethodChannel(
      name: "remotedisplay/pointer", binaryMessenger: controller.binaryMessenger)
    let bridge = PointerCaptureBridge(channel: channel)
    pointerCaptureBridge = bridge
    bridge.installRecognizers(on: controller.view)
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

  /// Under scenes UIKit passes nil launch options to didFinishLaunching; the
  /// URL / source app arrive in UIScene.ConnectionOptions instead. SceneDelegate
  /// converts them and replays the launch so every plugin sees exactly one
  /// didFinishLaunching per scene connection, now with the data (uni_links:
  /// initialLink for a cold start by remotedisplay://…). Routed through our
  /// override so the `super` call resolves exactly like the one Flutter's
  /// template makes.
  func replayLaunch(options: [UIApplication.LaunchOptionsKey: Any]) {
    replayingLaunch = true
    defer { replayingLaunch = false }
    _ = application(UIApplication.shared, didFinishLaunchingWithOptions: options)
  }

  public func dummyMethodToEnforceBundling() {
      dummy_method_to_enforce_bundling();
    session_get_rgba(nil, 0);
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
