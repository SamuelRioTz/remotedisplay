import 'package:flutter/material.dart';

/// Dark-first palette of the home screen and its sheets (with a light variant).
class HomeUi {
  final bool dark;
  HomeUi(this.dark);

  Color get accent => const Color(0xFF3B82F6);
  Color get violet => const Color(0xFF8B5CF6);
  Color get accentSoft =>
      dark ? const Color(0xFF93B8FA) : const Color(0xFF2563EB);
  Color get ok => dark ? const Color(0xFF34D399) : const Color(0xFF059669);
  Color get danger => const Color(0xFFE5484D);
  // Dark = OLED: PURE black background (pixel off) and barely elevated
  // surfaces, to take advantage of OLED screens (tablet/phone).
  Color get bg => dark ? Colors.black : const Color(0xFFF4F5F8);
  Color get card => dark ? const Color(0xFF101114) : Colors.white;
  Color get field => dark ? const Color(0xFF1B1D22) : const Color(0xFFF0F1F3);
  Color get chip => dark ? const Color(0xFF17191D) : const Color(0xFFF0F1F3);
  Color get fg => dark ? const Color(0xFFEDEDEF) : const Color(0xFF15171A);
  Color get fgSoft => dark ? const Color(0xFFC6C9CE) : const Color(0xFF474D57);
  Color get muted => dark ? const Color(0xFF8A8F98) : const Color(0xFF6B7280);
  Color get border =>
      dark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.06);

  BoxDecoration get cardDeco => BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      );

  InputDecoration input(String hint, IconData icon) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: muted, fontSize: 14),
        prefixIcon: Icon(icon, size: 18, color: muted),
        filled: true,
        fillColor: field,
        contentPadding:
            const EdgeInsets.symmetric(vertical: 15, horizontal: 8),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: accent, width: 1.5)),
      );

  /// Gradient primary button (the "Connect" look).
  Widget primaryButton(
      {required String label, VoidCallback? onPressed, bool busy = false}) {
    return SizedBox(
      width: double.infinity,
      height: 46,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            accent.withOpacity(onPressed == null ? 0.5 : 1),
            violet.withOpacity(onPressed == null ? 0.5 : 1),
          ]),
          borderRadius: BorderRadius.circular(10),
        ),
        child: ElevatedButton(
          onPressed: busy ? null : onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            disabledBackgroundColor: Colors.transparent,
            foregroundColor: Colors.white,
            disabledForegroundColor: Colors.white70,
            shadowColor: Colors.transparent,
            elevation: 0,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          child: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text(label,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}
