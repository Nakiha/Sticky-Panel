import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(380, 620),
    minimumSize: Size(300, 360),
    center: true,
    title: 'Sticky Panel',
    titleBarStyle: TitleBarStyle.hidden,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setPreventClose(true);
    await windowManager.show();
    await windowManager.focus();
  });

  final store = AppStore();
  await store.load();
  runApp(StickyPanelApp(store: store, enableSystemTray: Platform.isWindows));
}
