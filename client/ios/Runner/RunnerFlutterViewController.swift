import UIKit
import Flutter
import GameController

// remotedisplay: pointer capture (iPadOS 14+). iPadOS's pointer is
// ABSOLUTE: when it reaches the screen edge it gets stuck and stops
// emitting events — making it impossible to cross to the external
// monitor's display or pan without limit. With `prefersPointerLocked` the
// system hides and locks the pointer, and the trackpad/mouse delivers raw
// DELTAS via GCMouse (GameController), which we forward to Dart: the
// remote cursor moves relatively, crosses monitors, and never gets stuck
// in corners. Same approach as the "gaming/pointer lock" modes of other
// remote desktop apps on iPad.
class RunnerFlutterViewController: FlutterViewController {
  private(set) static weak var current: RunnerFlutterViewController?

  private var captureWanted = false

  override var prefersPointerLocked: Bool { captureWanted }

  override func viewDidLoad() {
    super.viewDidLoad()
    RunnerFlutterViewController.current = self
  }

  func setPointerCapture(_ on: Bool) {
    guard captureWanted != on else { return }
    captureWanted = on
    setNeedsUpdateOfPrefersPointerLocked()
  }
}

/// Capture → Dart bridge over the `remotedisplay/pointer` channel: while
/// capture is active it sends `relMove` (deltas), `relButton`, `relWheel`
/// and `lockState` (when the system actually engages/releases the lock).
///
/// Two input sources with the pointer locked (WWDC20):
///   - MICE (Bluetooth/USB): GCMouse delivers raw deltas.
///   - TRACKPADS (Smart Connector: Magic Keyboard, Logitech Combo Touch…):
///     GCMouse does NOT see them — they arrive as INDIRECT TOUCHES, which we
///     capture with native gesture recognizers (pan = move / 2 fingers =
///     wheel, tap = click, 2-finger tap = right click), enabled only with the lock.
class PointerCaptureBridge: NSObject {
  // STRONG on purpose: the channel is created as a local variable in
  // AppDelegate and NO ONE else retains it — with weak, ARC would release
  // it after startup and every native→Dart invokeMethod would silently
  // become a no-op (Δ506 sent, rx0 received). Dart→native messages kept
  // working because binaryMessenger routes by name, not by object.
  private let channel: FlutterMethodChannel
  private weak var hostView: UIView?
  private var active = false
  private var observers: [NSObjectProtocol] = []
  private var recognizers: [UIGestureRecognizer] = []
  // Scroll: a DEDICATED recognizer (always active with capture, whether or
  // not GCMouse is present) — Apple's path for scroll with pointer lock.
  // GCMouse's scroll handler doesn't fire on many BT mice and gives odd
  // values on trackpads; UIKit's scroll events do arrive while locked.
  private var scrollRecognizer: UIPanGestureRecognizer?
  private var lastPan = CGPoint.zero
  private var lastScrollPan = CGPoint.zero
  private var lockedNow = false

  /// Indirect-touch recognizers on Flutter's view. Only enabled once the
  /// lock is engaged: unlocked, the .indirectPointer ones are the trackpad's
  /// normal clicks and shouldn't be stolen.
  func installRecognizers(on view: UIView) {
    hostView = view
    let types: [NSNumber] = [
      NSNumber(value: UITouch.TouchType.indirect.rawValue),
      NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
    ]
    let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
    pan.allowedTouchTypes = types
    pan.maximumNumberOfTouches = 2
    let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
    tap.allowedTouchTypes = types
    let tap2 = UITapGestureRecognizer(target: self, action: #selector(onTap2(_:)))
    tap2.allowedTouchTypes = types
    tap2.numberOfTouchesRequired = 2
    recognizers = [pan, tap, tap2]
    for r in recognizers {
      r.isEnabled = false
      view.addGestureRecognizer(r)
    }
    // Dedicated scroll: only scroll events (mouse wheel = discrete, two
    // trackpad fingers = continuous), driven with no touches (numberOfTouches
    // == 0) — doesn't collide with either the touch pan or GCMouse.
    let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScrollPan(_:)))
    scroll.allowedTouchTypes = types
    scroll.allowedScrollTypesMask = .all
    scroll.isEnabled = false
    view.addGestureRecognizer(scroll)
    scrollRecognizer = scroll
  }

  // px → wheel-steps conversion done NATIVELY (this is where each gesture's
  // limits are known): accumulator with a 7px quantum, and — key for the
  // discrete wheel — if a gesture ends without having emitted any step but
  // there WAS net movement (a slow notch is only a few px), ±1 is forced —
  // every notch ALWAYS scrolls.
  private let scrollQuantum: CGFloat = 7
  private var scrollAccum = CGPoint.zero
  private var scrollStepsSent = false

  @objc private func onScrollPan(_ g: UIPanGestureRecognizer) {
    guard active, let v = hostView else { return }
    // Pure scroll only (wheel / two trackpad fingers): no active touches.
    guard g.numberOfTouches == 0 else { return }
    let t = g.translation(in: v)
    // NOTE on states: a fast flick (and EVERY discrete wheel notch) lives
    // almost entirely in .began and .ended — process the delta in ALL THREE states.
    switch g.state {
    case .began:
      lastScrollPan = .zero
      scrollAccum = .zero
      scrollStepsSent = false
      consumeScroll(to: t)
    case .changed:
      consumeScroll(to: t)
    case .ended, .cancelled, .failed:
      consumeScroll(to: t) // last stretch before resetting
      if !scrollStepsSent && (t.x != 0 || t.y != 0) {
        // Short gesture with no steps (slow wheel notch): guaranteed ±1.
        if abs(t.y) >= abs(t.x) {
          sendWheelSteps(0, t.y > 0 ? 1 : -1)
        } else {
          sendWheelSteps(t.x > 0 ? 1 : -1, 0)
        }
      }
      lastScrollPan = .zero
      scrollAccum = .zero
    default:
      break
    }
  }

  private func consumeScroll(to t: CGPoint) {
    let dx = t.x - lastScrollPan.x
    let dy = t.y - lastScrollPan.y
    lastScrollPan = t
    if dx == 0 && dy == 0 { return }
    accumulateScroll(dx, dy)
  }

  private func accumulateScroll(_ dx: CGFloat, _ dy: CGFloat) {
    scrollAccum.x += dx
    scrollAccum.y += dy
    let sx = Int(scrollAccum.x / scrollQuantum)
    let sy = Int(scrollAccum.y / scrollQuantum)
    if sx != 0 || sy != 0 {
      scrollAccum.x -= CGFloat(sx) * scrollQuantum
      scrollAccum.y -= CGFloat(sy) * scrollQuantum
      sendWheelSteps(sx, sy)
    }
  }

  private func sendWheelSteps(_ sx: Int, _ sy: Int) {
    scrollStepsSent = true
    send("relWheel", ["dx": sx, "dy": sy])
  }

  private var gcMouseAvailable: Bool {
    GCMouse.current != nil || !GCMouse.mice().isEmpty
  }

  private func syncRecognizers() {
    // Indirect-touch recognizers are plan B for trackpads GCMouse doesn't
    // see (Smart Connector). If GCMouse DOES deliver (mouse visible), they
    // DUPLICATE events: every physical click arrived twice (double click →
    // macOS saw 3-4 → selected the paragraph) and a two-finger tap fired
    // right click + scroll at once. Single source: with GCMouse present,
    // recognizers off.
    let enabled = active && !gcMouseAvailable
    for r in recognizers { r.isEnabled = enabled }
    // The dedicated scroll is always alive whenever there's capture:
    // GCMouse doesn't cover scroll reliably and its handler is disabled.
    scrollRecognizer?.isEnabled = active
  }

  @objc private func onPan(_ g: UIPanGestureRecognizer) {
    guard active, let v = hostView else { return }
    let t = g.translation(in: v)
    switch g.state {
    case .began:
      lastPan = t
    case .changed:
      let dx = t.x - lastPan.x
      let dy = t.y - lastPan.y
      lastPan = t
      if dx == 0 && dy == 0 { return }
      if g.numberOfTouches <= 1 {
        // 1-finger pan (or continuous scroll with no touches) = move the
        // cursor; the translation already has y pointing down (don't invert).
        send("relMove", ["dx": Double(dx), "dy": Double(dy)])
      } else {
        // Same px→steps accumulator as the dedicated scroll.
        accumulateScroll(dx, dy)
      }
    default:
      lastPan = .zero
    }
  }

  @objc private func onTap(_ g: UITapGestureRecognizer) {
    guard active, g.state == .ended else { return }
    send("relButton", ["button": "left", "down": true])
    send("relButton", ["button": "left", "down": false])
  }

  @objc private func onTap2(_ g: UITapGestureRecognizer) {
    guard active, g.state == .ended else { return }
    send("relButton", ["button": "right", "down": true])
    send("relButton", ["button": "right", "down": false])
  }

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    let nc = NotificationCenter.default
    observers.append(nc.addObserver(
      forName: .GCMouseDidConnect, object: nil, queue: .main
    ) { [weak self] note in
      guard let self = self else { return }
      if let mouse = note.object as? GCMouse { self.attach(mouse) }
      self.updateLock()
      self.syncRecognizers()
    })
    observers.append(nc.addObserver(
      forName: .GCMouseDidBecomeCurrent, object: nil, queue: .main
    ) { [weak self] note in
      guard let self = self else { return }
      if let mouse = note.object as? GCMouse { self.attach(mouse) }
      self.updateLock()
      self.syncRecognizers()
    })
    observers.append(nc.addObserver(
      forName: .GCMouseDidDisconnect, object: nil, queue: .main
    ) { [weak self] _ in
      self?.updateLock()
      self?.syncRecognizers()
    })
    // The lock's REAL state (the system decides it): visibility for Dart/toast.
    observers.append(nc.addObserver(
      forName: UIPointerLockState.didChangeNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self = self else { return }
      var locked = false
      if let scene = note.object as? UIWindowScene {
        locked = scene.pointerLockState?.isLocked ?? false
      } else if let state = note.object as? UIPointerLockState {
        locked = state.isLocked
      }
      self.lockedNow = locked
      self.syncRecognizers()
      self.send("lockState", ["locked": locked])
    })
    attachAll()
  }

  func setActive(_ on: Bool) {
    let changed = active != on
    active = on
    attachAll() // the mouse may have connected before the bridge was created
    updateLock()
    syncRecognizers()
    if changed {
      // Fallback: the UIPointerLockState notification may not arrive —
      // read the lock's real state a moment after requesting it.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        guard let self = self else { return }
        let locked = RunnerFlutterViewController.current?.viewIfLoaded?.window?
          .windowScene?.pointerLockState?.isLocked ?? false
        if locked != self.lockedNow {
          self.lockedNow = locked
          self.syncRecognizers()
          self.send("lockState", ["locked": locked])
        }
      }
    }
  }

  private func attachAll() {
    for mouse in GCMouse.mice() { attach(mouse) }
    if let cur = GCMouse.current { attach(cur) }
  }

  private func updateLock() {
    // No GCMouse gating: trackpads (Smart Connector) don't show up there
    // but DO deliver indirect touches with the lock engaged. Capture is
    // opt-in (toggle) and can always be turned off with a finger.
    RunnerFlutterViewController.current?.setPointerCapture(active)
  }

  private func attach(_ mouse: GCMouse) {
    guard let input = mouse.mouseInput else { return }
    input.mouseMovedHandler = { [weak self] _, dx, dy in
      guard let self = self else { return }
      guard self.active else { return }
      // GCMouse: positive dy points up; the remote desktop uses y↓.
      self.send("relMove", ["dx": Double(dx), "dy": Double(-dy)])
    }
    input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
      guard let self = self else { return }
      guard self.active else { return }
      self.send("relButton", ["button": "left", "down": pressed])
    }
    input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
      guard let self = self, self.active else { return }
      self.send("relButton", ["button": "right", "down": pressed])
    }
    input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
      guard let self = self, self.active else { return }
      self.send("relButton", ["button": "middle", "down": pressed])
    }
    // NOTE: no GCMouse scroll handler — it doesn't fire on many BT mice and
    // gives odd values on trackpads; scroll goes through onScrollPan
    // (UIKit), which does arrive with the lock. A single path = no duplicates.
    input.scroll.valueChangedHandler = nil
  }

  private func send(_ method: String, _ args: [String: Any]) {
    if Thread.isMainThread {
      channel.invokeMethod(method, arguments: args)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.channel.invokeMethod(method, arguments: args)
      }
    }
  }
}
