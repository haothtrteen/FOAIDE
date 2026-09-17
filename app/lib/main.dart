import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/theme.dart';
import 'env/env_installer.dart';
import 'ui/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 运行时系统栏基线（对 Android < 15 设备生效；图标明暗在所有版本生效）。
  // Bug 410（2026-09-17 真机确认）：Flutter 引擎在 Android 15+ 设备（SDK_INT>=35，
  // 与 targetSdk 无关，见 android/app/src/main/res/values/colors.xml 注释）上会跳过
  // setStatusBarColor/setNavigationBarColor——运行时设色在这类设备上无效，系统栏
  // 颜色由主题 XML 声明兜底（styles.xml 的 android:statusBarColor/navigationBarColor）。
  // 主题切换时 AppBarTheme.systemOverlayStyle 负责各版本的图标明暗。
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Color(0xFF101418),
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Color(0xFF101418),
      systemNavigationBarDividerColor: Color(0xFF101418),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const FoaApp());
}

class FoaApp extends StatelessWidget {
  const FoaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => EnvState()..bootstrap()),
        ChangeNotifierProvider(create: (_) => ThemeController()),
      ],
      child: Consumer<ThemeController>(
        builder: (context, tc, _) => MaterialApp(
          title: 'Flutter On Android',
          debugShowCheckedModeBanner: false,
          theme: FoaTheme.light(),
          darkTheme: FoaTheme.dark(),
          themeMode: tc.mode,
          home: const HomePage(),
        ),
      ),
    );
  }
}
