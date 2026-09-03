// remotedisplay: home propio del cliente — UI moderna sobre el motor probado.
// Reusa connect() y las vistas de peers (descubrimiento LAN/Tailscale + recientes,
// con su menú de SimpleDisplay). No hay IDs, cuentas ni servidores: solo IP directa.
//
// Diseño: sistema de espaciado de 8px, jerarquía tipográfica clara, dark-aware,
// hover states y un indicador de escaneo animado (feedback de "vivo").
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/peers_view.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';

// Escala de espaciado (múltiplos de 8, base de la mayoría de design systems).
const double _xs = 4, _sm = 8, _md = 16, _lg = 24, _xl = 32;
const _accent = MyTheme.accent;

class RemotedeskHome extends StatefulWidget {
  const RemotedeskHome({Key? key}) : super(key: key);

  @override
  State<RemotedeskHome> createState() => _RemotedeskHomeState();
}

class _RemotedeskHomeState extends State<RemotedeskHome> {
  final _ipCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  final _ipFocus = FocusNode();
  bool _connecting = false;

  @override
  void dispose() {
    _ipCtrl.dispose();
    _pwCtrl.dispose();
    _ipFocus.dispose();
    super.dispose();
  }

  void _connect({bool fileTransfer = false}) {
    final id = _ipCtrl.text.trim();
    if (id.isEmpty) {
      _ipFocus.requestFocus();
      return;
    }
    setState(() => _connecting = true);
    connect(context, id,
        isFileTransfer: fileTransfer,
        password: _pwCtrl.text.isEmpty ? null : _pwCtrl.text);
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _connecting = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SideRail(),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(context),
                _connectHero(context),
                Expanded(child: _peersArea(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final titleColor = Theme.of(context).textTheme.titleLarge?.color;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_xl, _lg, _xl, _xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Remote Display',
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                      height: 1.1,
                      color: titleColor)),
              const SizedBox(height: _xs / 2),
              Text('Red local · sin servidores',
                  style: TextStyle(
                      fontSize: 13, color: Colors.grey.withOpacity(0.8))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _connectHero(BuildContext context) {
    final cardColor = Theme.of(context).colorScheme.surface;
    return Container(
      margin: const EdgeInsets.fromLTRB(_xl, _md, _xl, _sm),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.withOpacity(0.18)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 20,
              offset: const Offset(0, 8)),
        ],
      ),
      // Filo de acento arriba: peso visual sin ruido.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 3,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                  colors: [_accent, Color(0xFF5AA9FF)]),
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(_md + 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.bolt_rounded, size: 18, color: _accent),
                  const SizedBox(width: _sm - 2),
                  Text('Conectar a un equipo',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color:
                              Theme.of(context).textTheme.titleLarge?.color)),
                ]),
                const SizedBox(height: _md - 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      flex: 3,
                      child: _field(
                        controller: _ipCtrl,
                        focus: _ipFocus,
                        hint: 'IP  (ej. 192.168.1.117)',
                        icon: Icons.dns_rounded,
                        onSubmit: () => _connect(),
                      ),
                    ),
                    const SizedBox(width: _sm + 2),
                    Expanded(
                      flex: 2,
                      child: _field(
                        controller: _pwCtrl,
                        hint: 'Contraseña',
                        icon: Icons.lock_outline_rounded,
                        obscure: true,
                        onSubmit: () => _connect(),
                      ),
                    ),
                    const SizedBox(width: _md - 4),
                    _connectButton(),
                  ],
                ),
                const SizedBox(height: _sm),
                Row(
                  children: [
                    _quietButton(
                      icon: Icons.folder_open_rounded,
                      label: 'Transferir archivos',
                      onTap: _connecting
                          ? null
                          : () => _connect(fileTransfer: true),
                    ),
                    const Spacer(),
                    Text('Enter para conectar',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.withOpacity(0.6))),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    FocusNode? focus,
    bool obscure = false,
    VoidCallback? onSubmit,
  }) {
    return TextField(
      controller: controller,
      focusNode: focus,
      obscureText: obscure,
      onSubmitted: (_) => onSubmit?.call(),
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: Icon(icon, size: 18),
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey.withOpacity(0.6)),
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        border: _border(Colors.grey.withOpacity(0.3)),
        enabledBorder: _border(Colors.grey.withOpacity(0.22)),
        focusedBorder: _border(_accent, width: 1.6),
      ),
    );
  }

  OutlineInputBorder _border(Color c, {double width = 1}) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: c, width: width),
      );

  Widget _connectButton() {
    return SizedBox(
      height: 48,
      child: ElevatedButton(
        onPressed: _connecting ? null : () => _connect(),
        style: ElevatedButton.styleFrom(
          backgroundColor: _accent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: _accent.withOpacity(0.6),
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: _lg - 2),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: _connecting
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : Row(mainAxisSize: MainAxisSize.min, children: const [
                Icon(Icons.login_rounded, size: 18),
                SizedBox(width: _sm),
                Text('Conectar', style: TextStyle(fontWeight: FontWeight.w600)),
              ]),
      ),
    );
  }

  Widget _quietButton(
      {required IconData icon,
      required String label,
      required VoidCallback? onTap}) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 13)),
      style: TextButton.styleFrom(
        foregroundColor: Colors.grey,
        padding: const EdgeInsets.symmetric(horizontal: _sm, vertical: _xs),
      ),
    );
  }

  Widget _peersArea(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_xl, _sm, _xl, _lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: _panel(
              context,
              title: 'PCs en tu red',
              icon: Icons.radar_rounded,
              trailing: const _ScanPulse(),
              child: DiscoveredPeersView(
                menuPadding: const EdgeInsets.symmetric(horizontal: _xs),
              ),
            ),
          ),
          const SizedBox(height: _md - 2),
          Expanded(
            flex: 2,
            child: _panel(
              context,
              title: 'Recientes',
              icon: Icons.history_rounded,
              child: RecentPeersView(
                menuPadding: const EdgeInsets.symmetric(horizontal: _xs),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _panel(BuildContext context,
      {required String title,
      required IconData icon,
      Widget? trailing,
      required Widget child}) {
    final titleColor = Theme.of(context).textTheme.titleLarge?.color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(icon, size: 17, color: _accent),
          const SizedBox(width: _sm - 1),
          Text(title,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: titleColor)),
          if (trailing != null) ...[const SizedBox(width: _sm + 2), trailing],
        ]),
        const SizedBox(height: _sm),
        Expanded(child: child),
      ],
    );
  }
}

/// Indicador de escaneo: punto pulsante + texto, comunica "vivo" sin bloquear.
/// (Investigación UX: nunca dejar la lista en silencio; un pulso mantiene la
/// percepción de progreso durante el descubrimiento continuo.)
class _ScanPulse extends StatefulWidget {
  const _ScanPulse({Key? key}) : super(key: key);
  @override
  State<_ScanPulse> createState() => _ScanPulseState();
}

class _ScanPulseState extends State<_ScanPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      FadeTransition(
        opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
        child: Container(
          width: 7,
          height: 7,
          decoration: const BoxDecoration(
              color: _accent, shape: BoxShape.circle),
        ),
      ),
      const SizedBox(width: _sm - 2),
      Text('Escaneando LAN y Tailscale',
          style: TextStyle(fontSize: 12, color: Colors.grey.withOpacity(0.75))),
    ]);
  }
}

class _SideRail extends StatelessWidget {
  const _SideRail({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 68,
      color: Theme.of(context).colorScheme.surface.withOpacity(0.5),
      child: Column(
        children: [
          const SizedBox(height: _lg),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [_accent, Color(0xFF5AA9FF)]),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                    color: _accent.withOpacity(0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 4)),
              ],
            ),
            child: const Icon(Icons.desktop_windows_rounded,
                color: Colors.white, size: 22),
          ),
          const Spacer(),
          _RailIcon(
            icon: Icons.settings_rounded,
            tooltip: 'Ajustes',
            onTap: () {
              if (DesktopSettingPage.tabKeys.isNotEmpty) {
                DesktopSettingPage.switch2page(DesktopSettingPage.tabKeys[0]);
              }
            },
          ),
          const SizedBox(height: _md),
        ],
      ),
    );
  }
}

/// Icono del rail con hover state (feedback en desktop).
class _RailIcon extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _RailIcon(
      {Key? key,
      required this.icon,
      required this.tooltip,
      required this.onTap})
      : super(key: key);
  @override
  State<_RailIcon> createState() => _RailIconState();
}

class _RailIconState extends State<_RailIcon> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(_sm + 2),
            decoration: BoxDecoration(
              color: _hover ? _accent.withOpacity(0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(widget.icon,
                size: 22,
                color: _hover ? _accent : Colors.grey.withOpacity(0.8)),
          ),
        ),
      ),
    );
  }
}
