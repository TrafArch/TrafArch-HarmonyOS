import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'app/harmony_app.dart';
import 'app/theme/safe_error_screen.dart';
import 'app/third_party_licenses.dart';
import 'features/qr/data/harmony_qr_scanner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MobileScannerPlatform.instance = HarmonyQrScanner();
  registerThirdPartyLicenses();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  installReleaseErrorPresentation();
  runApp(const HarmonyApp());
}
