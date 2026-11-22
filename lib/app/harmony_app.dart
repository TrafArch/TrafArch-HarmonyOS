import 'dart:async';

import 'package:flutter/widgets.dart';

import '../features/qr/application/qr_acquisition.dart';
import '../features/qr/presentation/qr_page.dart';
import '../gallery/gallery_app.dart';
import '../gallery/gallery_consent_screen.dart';
import '../gallery/gallery_controller.dart';
import '../gallery/gallery_preferences.dart';
import '../platform/browser/feedback_browser.dart';
import '../platform/storage/settings_store.dart';
import 'app_dependencies.dart';
import 'harmony_gallery_controller.dart';
import 'legal_consent_gate.dart';

class HarmonyApp extends StatelessWidget {
  const HarmonyApp({super.key, this.settingsStore, this.createDependencies});

  final SettingsStore? settingsStore;
  final AppDependencies Function(SettingsStore)? createDependencies;

  @override
  Widget build(BuildContext context) {
    final store = settingsStore ?? FileSettingsStore();
    return LegalConsentGate(
      settingsStore: store,
      screenBuilder: GalleryConsentScreen.new,
      enableAnalytics: false,
      child: _HarmonyGallery(
        store: store,
        createDependencies: createDependencies,
      ),
    );
  }
}

class _HarmonyGallery extends StatefulWidget {
  const _HarmonyGallery({required this.store, this.createDependencies});

  final SettingsStore store;
  final AppDependencies Function(SettingsStore)? createDependencies;

  @override
  State<_HarmonyGallery> createState() => _HarmonyGalleryState();
}

class _HarmonyGalleryState extends State<_HarmonyGallery>
    with WidgetsBindingObserver {
  late final _app =
      widget.createDependencies?.call(widget.store) ??
      AppDependencies(settingsStore: widget.store);
  late final _controller = HarmonyGalleryController(_app);
  late final _preferences = GalleryPreferences(
    readEnabled: () async =>
        await widget.store.read(SettingsKeys.galleryPredictiveBackEnabled) !=
        'false',
    writeEnabled: (enabled) => widget.store.write(
      SettingsKeys.galleryPredictiveBackEnabled,
      '$enabled',
    ),
  )..load();
  bool _startupUpdateShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _controller.cancelRead();
      unawaited(_app.flushDiagnostics().catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _preferences.dispose();
    _app.dispose();
    super.dispose();
  }

  bool _claimStartupUpdatePrompt() {
    if (_startupUpdateShown) return false;
    _startupUpdateShown = true;
    return true;
  }

  @override
  Widget build(BuildContext context) => GalleryApp(
    controller: _controller,
    updates: _app.updates,
    claimStartupUpdatePrompt: _claimStartupUpdatePrompt,
    preferences: _preferences,
    openWebLink: const MethodChannelFeedbackBrowser().open,
    livePageBuilders: {
      GalleryPage.qr: (_) => QrPage(
        app: _app,
        acquisition: const QrAcquisition(useDartGallery: true),
      ),
    },
  );
}
