import 'dart:convert';
import 'dart:io';

/// App version. Bump [kAppBuild] on every release; the update check compares this
/// integer against the `build` field in the remote manifest.
const kAppBuild = 2;
const kAppVersion = '1.1.0';

/// Update manifest, hosted on a Russia-reachable mirror (no secrets in it). Shape:
/// {"build":N,"version":"x.y.z","notes":"…","android":"<apk url>","windows":"<zip url>"}
const kUpdateManifestUrl = 'https://tele.karlson.ru/chess/version.json';

class UpdateInfo {
  final int build;
  final String version;
  final String url;
  final String notes;
  UpdateInfo(this.build, this.version, this.url, this.notes);
}

/// Fetch the manifest and return [UpdateInfo] if a newer build is available for
/// this platform, or null if already up to date. Throws on network/parse error.
Future<UpdateInfo?> checkForUpdate() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(Uri.parse(kUpdateManifestUrl));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    final j = jsonDecode(body) as Map<String, dynamic>;
    final remoteBuild = (j['build'] as num).toInt();
    if (remoteBuild <= kAppBuild) return null;
    final key = Platform.isAndroid
        ? 'android'
        : Platform.isWindows
            ? 'windows'
            : Platform.isMacOS
                ? 'macos'
                : 'linux';
    final url = (j[key] ?? j['android'] ?? '') as String;
    return UpdateInfo(
      remoteBuild,
      (j['version'] ?? '') as String,
      url,
      (j['notes'] ?? '') as String,
    );
  } finally {
    client.close();
  }
}
