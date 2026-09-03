import UIKit
import Flutter
import GameController

// remotedisplay: captura del puntero (iPadOS 14+). El puntero de iPadOS es
// ABSOLUTO: al llegar al borde de la pantalla se clava y deja de emitir
// eventos — imposible cruzar al display del monitor externo o panear sin
// límite. Con `prefersPointerLocked` el sistema oculta y fija el puntero y
// el trackpad/mouse entrega DELTAS crudos vía GCMouse (GameController), que
// reenviamos a Dart: el cursor remoto se mueve relativo, cruza monitores y
// nunca se pega en esquinas. Mismo enfoque que los modos "gaming/pointer
// lock" de otras apps de escritorio remoto en iPad.
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

/// Puente de captura → Dart por el canal `remotedisplay/pointer`: mientras la
/// captura está activa manda `relMove` (deltas), `relButton`, `relWheel` y
/// `lockState` (cuando el sistema engancha/suelta el lock de verdad).
///
/// Dos fuentes de input con el puntero bloqueado (WWDC20):
///   - MICE (Bluetooth/USB): GCMouse entrega deltas crudos.
///   - TRACKPADS (Smart Connector: Magic Keyboard, Logitech Combo Touch…):
///     GCMouse NO los ve — llegan como TOUCHES INDIRECTOS, que capturamos
///     con gesture recognizers nativos (pan = mover / 2 dedos = rueda,
///     tap = click, tap 2 dedos = click derecho) habilitados solo con lock.
class PointerCaptureBridge: NSObject {
  // FUERTE a propósito: el canal se crea como variable local en el
  // AppDelegate y NADIE más lo retiene — con weak, ARC lo liberaba tras el
  // arranque y cada invokeMethod nativo→Dart se volvía un no-op silencioso
  // (Δ506 enviados, rx0 recibidos). Los mensajes Dart→nativo seguían
  // funcionando porque el binaryMessenger enruta por nombre, no por objeto.
  private let channel: FlutterMethodChannel
  private weak var hostView: UIView?
  private var active = false
  private var observers: [NSObjectProtocol] = []
  private var recognizers: [UIGestureRecognizer] = []
  // Scroll: recognizer DEDICADO (siempre activo con la captura, haya o no
  // GCMouse) — la vía Apple para scroll con pointer lock. El handler de
  // scroll de GCMouse no dispara en muchos mice BT y da valores raros en
  // trackpads; los scroll-events de UIKit sí llegan bloqueados.
  private var scrollRecognizer: UIPanGestureRecognizer?
  private var lastPan = CGPoint.zero
  private var lastScrollPan = CGPoint.zero
  private var lockedNow = false

  /// Reconocedores de touches indirectos sobre el view de Flutter. Solo se
  /// habilitan con el lock enganchado: desbloqueado, los .indirectPointer son
  /// los clicks normales del trackpad y no hay que robarlos.
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
    // Scroll dedicado: solo eventos de scroll (rueda del mouse = discreto,
    // dos dedos del trackpad = continuo), driven sin touches (numberOfTouches
    // == 0) — no pisa ni al pan de touches ni a GCMouse.
    let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScrollPan(_:)))
    scroll.allowedTouchTypes = types
    scroll.allowedScrollTypesMask = .all
    scroll.isEnabled = false
    view.addGestureRecognizer(scroll)
    scrollRecognizer = scroll
  }

  // Conversión px → pasos de rueda EN NATIVO (aquí se conocen los límites de
  // cada gesto): acumulador con quantum de 7 px y, clave para la rueda
  // discreta, si un gesto termina sin haber emitido ningún paso pero SÍ hubo
  // movimiento neto (un notch lento son pocos px), se fuerza ±1 — cada notch
  // scrollea SIEMPRE.
  private let scrollQuantum: CGFloat = 7
  private var scrollAccum = CGPoint.zero
  private var scrollStepsSent = false

  @objc private func onScrollPan(_ g: UIPanGestureRecognizer) {
    guard active, let v = hostView else { return }
    // Solo scroll puro (rueda / dos dedos de trackpad): sin touches activos.
    guard g.numberOfTouches == 0 else { return }
    let t = g.translation(in: v)
    // OJO estados: un flick rápido (y CADA notch de rueda discreta) vive casi
    // entero en .began y .ended — procesar el delta en LOS TRES estados.
    switch g.state {
    case .began:
      lastScrollPan = .zero
      scrollAccum = .zero
      scrollStepsSent = false
      consumeScroll(to: t)
    case .changed:
      consumeScroll(to: t)
    case .ended, .cancelled, .failed:
      consumeScroll(to: t) // último tramo antes de resetear
      if !scrollStepsSent && (t.x != 0 || t.y != 0) {
        // Gesto corto sin pasos (notch lento de rueda): ±1 garantizado.
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
    // Los reconocedores de touches indirectos son el plan B para trackpads
    // que GCMouse no ve (Smart Connector). Si GCMouse SÍ entrega (mouse
    // visible), DUPLICAN los eventos: cada click físico llegaba doble
    // (doble click → macOS veía 3-4 → seleccionaba el párrafo) y el tap de
    // dos dedos disparaba click derecho + scroll a la vez. Una sola fuente:
    // con GCMouse presente, reconocedores apagados.
    let enabled = active && !gcMouseAvailable
    for r in recognizers { r.isEnabled = enabled }
    // El scroll dedicado vive SIEMPRE que haya captura: GCMouse no cubre
    // scroll de forma fiable y su handler está desactivado.
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
        // pan de 1 dedo (o scroll continuo sin touches) = mover el cursor;
        // la traslación ya viene con y hacia abajo (no invertir).
        send("relMove", ["dx": Double(dx), "dy": Double(dy)])
      } else {
        // Mismo acumulador px→pasos que el scroll dedicado.
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
    // Estado REAL del lock (el sistema decide): visibilidad para Dart/toast.
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
    attachAll() // el mouse pudo conectarse antes de crear el bridge
    updateLock()
    syncRecognizers()
    if changed {
      // Fallback: la notificación de UIPointerLockState puede no llegar —
      // leer el estado real del lock un momento después de pedirlo.
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
    // Sin gate por GCMouse: los trackpads (Smart Connector) no aparecen ahí
    // pero SÍ entregan touches indirectos con el lock enganchado. La captura
    // es opt-in (toggle) y con el dedo siempre se puede desactivar.
    RunnerFlutterViewController.current?.setPointerCapture(active)
  }

  private func attach(_ mouse: GCMouse) {
    guard let input = mouse.mouseInput else { return }
    input.mouseMovedHandler = { [weak self] _, dx, dy in
      guard let self = self else { return }
      guard self.active else { return }
      // GCMouse: dy positivo hacia arriba; el escritorio remoto usa y↓.
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
    // OJO: sin handler de scroll de GCMouse — en muchos mice BT no dispara y
    // en trackpads da valores raros; el scroll va por onScrollPan (UIKit),
    // que sí llega con el lock. Un solo camino = sin duplicados.
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
