import 'package:flutter/material.dart';

ThemeData keybridgeTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final surface = Color(dark ? 0xff242426 : 0xfffafafc);
  final raised = Color(dark ? 0xff303033 : 0xffeef0f4);
  final ink = Color(dark ? 0xfff2f2f2 : 0xff202124);
  final muted = Color(dark ? 0xffb1b1b6 : 0xff62666e);
  final blue = Color(dark ? 0xff409cff : 0xff206bd1);
  final scheme = ColorScheme.fromSeed(seedColor: blue, brightness: brightness)
      .copyWith(
        surface: surface,
        onSurface: ink,
        primary: blue,
        surfaceContainerHighest: raised,
        onSurfaceVariant: muted,
        outlineVariant: Color(dark ? 0xff404044 : 0xffe1e4ea),
      );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: 'Roboto',
    scaffoldBackgroundColor: surface,
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      foregroundColor: ink,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'Roboto',
        color: ink,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xff206bd1),
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 52),
        textStyle: const TextStyle(
          fontFamily: 'Roboto',
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: raised,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: .6),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      showDragHandle: true,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
  );
}

class AccountBadge extends StatelessWidget {
  final String title;
  final double size;
  const AccountBadge(this.title, {this.size = 44, super.key});
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(size * .27),
    ),
    child: Text(
      title.isEmpty ? 'K' : title.characters.first.toUpperCase(),
      style: TextStyle(
        fontSize: size * .45,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}
