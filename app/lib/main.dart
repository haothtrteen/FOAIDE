import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/theme.dart';
import 'env/env_installer.dart';
import 'ui/home_page.dart';

void main() {
  runApp(const FoaApp());
}

class FoaApp extends StatelessWidget {
  const FoaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => EnvState()..bootstrap(),
      child: MaterialApp(
        title: 'Flutter On Android',
        debugShowCheckedModeBanner: false,
        theme: FoaTheme.dark(),
        home: const HomePage(),
      ),
    );
  }
}
