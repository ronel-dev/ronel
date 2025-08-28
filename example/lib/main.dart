import 'package:flutter/material.dart';
import 'package:ronel/ronel.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const ronelApp = Ronel(
        url: "https://ronel.dev/example/index.html",
        appTitle: 'Ronel Example',
        useAutoPlatformDetection: false,
        uiDesign: 'Material',
        appBarColor: Colors.redAccent,
      );
    return ronelApp;
  }
}
