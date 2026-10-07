import UIKit
import Flutter

// Main (interactive) scene of the app. Apps linked against the iOS 27 SDK must
// adopt the UIScene life cycle or UIKit traps at launch
// (___UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption). Flutter
// 3.24.5 ships no FlutterSceneDelegate, so this one is hand-written.
//
// UIKit instantiates Main.storyboard for this scene (UISceneStoryboardFile in
// Info.plist) — RunnerFlutterViewController through initWithCoder, exactly as
// before — and assigns the window to `window` before willConnect. What changes
// is WHEN things exist: under scenes the storyboard controller is created
// AFTER application:didFinishLaunchingWithOptions:, and UIKit never fills
// FlutterAppDelegate.window. So this delegate (1) hands the window to the
// FlutterAppDelegate (its registrarForPlugin / rootFlutterViewController read
// window.rootViewController), (2) runs the plugin + channel setup that used to
// live in didFinishLaunching, (3) replays the launch options UIKit no longer
// passes (uni_links keeps the cold-start remotedisplay:// link from them) and
// (4) forwards scene URL events to the UIApplicationDelegate methods the
// plugins still implement (FlutterAppDelegate → FlutterPluginAppLifeCycleDelegate
// → UniLinksPlugin application:openURL:options:).
//
// No sceneDidBecomeActive/… forwarding: FlutterViewController and the plugin
// life-cycle delegate observe the UIApplication notifications, which UIKit
// keeps posting under scenes, so Dart's AppLifecycleState is unaffected.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  // Created by UIKit from UISceneStoryboardFile (Main.storyboard).
  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
             options connectionOptions: UIScene.ConnectionOptions) {
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
    appDelegate.window = window
    appDelegate.attachFlutter()

    // Cold start: the URL / source app arrive here instead of in launchOptions.
    var launch: [UIApplication.LaunchOptionsKey: Any] = [:]
    if let context = connectionOptions.urlContexts.first {
      launch[.url] = context.url
      if let source = context.options.sourceApplication {
        launch[.sourceApplication] = source
      }
    }
    appDelegate.replayLaunch(options: launch)
    for activity in connectionOptions.userActivities {
      forward(userActivity: activity)
    }
  }

  // Warm start by URL (remotedisplay://connection/new/<host>?password=…).
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      var options: [UIApplication.OpenURLOptionsKey: Any] = [
        .openInPlace: context.options.openInPlace
      ]
      if let source = context.options.sourceApplication {
        options[.sourceApplication] = source
      }
      _ = UIApplication.shared.delegate?.application?(
        UIApplication.shared, open: context.url, options: options)
    }
  }

  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    forward(userActivity: userActivity)
  }

  private func forward(userActivity: NSUserActivity) {
    _ = UIApplication.shared.delegate?.application?(
      UIApplication.shared, continue: userActivity, restorationHandler: { _ in })
  }
}
