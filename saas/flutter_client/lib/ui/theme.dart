import 'package:flutter/material.dart';

const ink = Color(0xFF152F2B);
const green = Color(0xFF17664F);
const paper = Color(0xFFF5F7F4);
ThemeData pdsTheme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: green),
  scaffoldBackgroundColor: paper,
  visualDensity: VisualDensity.standard,
  appBarTheme: const AppBarTheme(
    backgroundColor: paper,
    foregroundColor: ink,
    centerTitle: false,
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xFFCDD9D2)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xFFCDD9D2)),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(48, 54),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
  ),
  iconButtonTheme: IconButtonThemeData(
    style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
  ),
);

class Brand extends StatelessWidget {
  const Brand({super.key, this.light = false});
  final bool light;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: light ? Colors.white.withValues(alpha: .12) : green,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(
          Icons.grass_rounded,
          color: Color(0xFFDFC77F),
          size: 30,
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PDS Connect',
              style: TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.w800,
                color: light ? Colors.white : ink,
              ),
            ),
            Text(
              'DISTRIBUTOR MANAGEMENT',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.5,
                color: light ? Colors.white70 : green,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class Notice extends StatelessWidget {
  const Notice(this.text, {super.key, this.error = false});
  final String text;
  final bool error;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: error ? const Color(0xFFFFEDEA) : const Color(0xFFE9F1E8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: error ? const Color(0xFF9B2525) : ink,
          height: 1.5,
        ),
      ),
    ),
  );
}
