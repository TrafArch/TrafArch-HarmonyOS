import fs from 'fs';
import path from 'path';
import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { flutterHvigorPlugin } from 'flutter-hvigor-plugin';

const packageConfig = path.join(__dirname, '.dart_tool', 'package_config.json');
const packages = fs.existsSync(packageConfig) ? JSON.parse(fs.readFileSync(packageConfig, 'utf8')).packages : [];
if (!packages.some(entry => entry.name === 'sqlite3' && entry.rootUri.includes('/build/harmony/toolchain/sqlite3-3.9.1/'))) {
  throw new Error('Run dev/harmony/build_hap.ps1 -PrepareOnly after setup or flutter pub get.');
}

export default {
  system: appTasks,
  plugins: [flutterHvigorPlugin(__dirname)]
};
