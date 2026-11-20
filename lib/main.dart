import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app/harmony_app.dart';
import 'app/theme/safe_error_screen.dart';
import 'app/third_party_licenses.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerThirdPartyLicenses();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  installReleaseErrorPresentation();
  runApp(const HarmonyApp());
}
