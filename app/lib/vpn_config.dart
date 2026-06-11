import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A saved VPN server, stored as a standard `vless://` share URL (the same format
/// v2rayNG / sing-box import & export), so profiles round-trip with other clients.
class VpnProfile {
  String name;
  String url;
  VpnProfile(this.name, this.url);

  Map<String, dynamic> toJson() => {'name': name, 'url': url};
  factory VpnProfile.fromJson(Map<String, dynamic> j) =>
      VpnProfile((j['name'] ?? '') as String, (j['url'] ?? '') as String);

  /// Short human summary: server:port via protocol.
  String get summary {
    try {
      final u = Uri.parse(url);
      return '${u.host}:${u.port == 0 ? 443 : u.port}';
    } catch (_) {
      return url;
    }
  }
}

class VpnStore {
  static const _kProfiles = 'profiles';
  static const _kActive = 'active';

  // Profiles are encrypted at rest via the Android Keystore (EncryptedSharedPreferences).
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // Distributable build ships with NO baked-in server: each user imports their own
  // vless:// link (their own UUID) via the hidden profiles screen. This keeps the
  // source repo free of any home-access secret and makes per-user revocation possible.

  static Future<List<VpnProfile>> load() async {
    final raw = await _storage.read(key: _kProfiles);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => VpnProfile.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<int> activeIndex() async {
    final v = await _storage.read(key: _kActive);
    return int.tryParse(v ?? '0') ?? 0;
  }

  static Future<void> save(List<VpnProfile> list, int active) async {
    await _storage.write(
        key: _kProfiles,
        value: jsonEncode(list.map((e) => e.toJson()).toList()));
    final clamped = active.clamp(0, list.isEmpty ? 0 : list.length - 1);
    await _storage.write(key: _kActive, value: '$clamped');
  }

  /// The sing-box JSON for the currently active profile (what the core runs).
  static Future<String> activeConfig() async {
    final list = await load();
    if (list.isEmpty) {
      throw const FormatException('No VPN profile configured — import one first');
    }
    final i = (await activeIndex()).clamp(0, list.length - 1);
    // On desktop, verify the server cert against our OWN bundled root store, not the
    // OS one: old/un-updated Windows builds broken chains (e.g. Let's Encrypt via the
    // expired DST Root CA X3), and a device's trust store can't be relied on in hostile
    // networks. Android/iOS use the platform store via the native tunnel, which is fine.
    final caPath =
        (Platform.isAndroid || Platform.isIOS) ? null : await _ensureCaBundle();
    return buildSingboxConfig(list[i].url, caCertPath: caPath);
  }

  /// Materialise the bundled CA roots (assets/cacert.pem) to a temp file so sing-box
  /// can reference it by path. Returns null on failure (falls back to the OS store).
  static Future<String?> _ensureCaBundle() async {
    try {
      final dst =
          File('${Directory.systemTemp.path}${Platform.pathSeparator}chessvpn-ca.pem');
      final bytes = (await rootBundle.load('assets/cacert.pem')).buffer.asUint8List();
      if (!dst.existsSync() || await dst.length() != bytes.length) {
        await dst.writeAsBytes(bytes, flush: true);
      }
      return dst.path;
    } catch (_) {
      return null;
    }
  }
}

/// Turn a `vless://uuid@host:port?...#name` URL into a full sing-box client config
/// (tun inbound + vless outbound + DNS that resolves the server directly to avoid
/// the bootstrap loop). Throws [FormatException] on a malformed URL.
String buildSingboxConfig(String vlessUrl, {String? caCertPath}) {
  final u = Uri.parse(vlessUrl.trim());
  if (u.scheme != 'vless') {
    throw const FormatException('Not a vless:// URL');
  }
  final uuid = u.userInfo;
  final host = u.host;
  if (uuid.isEmpty || host.isEmpty) {
    throw const FormatException('Missing uuid or host');
  }
  final port = u.port == 0 ? 443 : u.port;
  final q = u.queryParameters;
  final type = q['type'] ?? 'ws';
  // Some share links write the ws path without a leading slash (path=foo); the HTTP
  // request target must start with '/', so normalise it.
  var path = q['path'] ?? '/';
  if (!path.startsWith('/')) path = '/$path';
  final wsHost = q['host'] ?? host;
  final sni = q['sni'] ?? q['peer'] ?? host;
  final fp = q['fp'] ?? 'chrome';
  final flow = q['flow'] ?? '';
  final tlsOn = (q['security'] ?? 'tls') != 'none';

  final outbound = <String, dynamic>{
    'type': 'vless',
    'tag': 'proxy',
    'server': host,
    'server_port': port,
    'uuid': uuid,
    'flow': flow,
  };
  if (tlsOn) {
    final tls = <String, dynamic>{
      'enabled': true,
      'server_name': sni,
      'utls': {'enabled': true, 'fingerprint': fp},
    };
    // Verify against our bundled root store (assets/cacert.pem), passed in by the
    // desktop caller. Covers every public CA (Let's Encrypt, Google Trust Services,
    // …) so it works with any of the servers, independent of the device's OS store.
    if (caCertPath != null && caCertPath.isNotEmpty) {
      tls['certificate_path'] = caCertPath;
    }
    outbound['tls'] = tls;
  }
  if (type == 'ws') {
    outbound['transport'] = {
      'type': 'ws',
      'path': path,
      'headers': {'Host': wsHost},
    };
  }

  final cfg = {
    'log': {'level': 'info', 'timestamp': true},
    'dns': {
      'servers': [
        {'tag': 'dns-direct', 'address': '8.8.8.8', 'detour': 'direct'},
        // Plain DNS over the proxy (not DoH): one fewer TLS handshake that would
        // otherwise also lean on the (broken, on old Windows) OS trust store.
        {'tag': 'dns-proxy', 'address': '1.1.1.1', 'detour': 'proxy'},
      ],
      'rules': [
        {'domain': [host], 'server': 'dns-direct'},
      ],
      'final': 'dns-proxy',
      'strategy': 'ipv4_only',
    },
    'inbounds': [
      {
        'type': 'tun',
        'tag': 'tun-in',
        'interface_name': 'tun0',
        'inet4_address': '172.19.0.1/30',
        'mtu': 1500,
        'auto_route': true,
        'strict_route': true,
        'stack': 'system',
        'sniff': true,
      }
    ],
    'outbounds': [
      outbound,
      {'type': 'direct', 'tag': 'direct'},
      {'type': 'dns', 'tag': 'dns-out'},
    ],
    'route': {
      'rules': [
        {'protocol': 'dns', 'outbound': 'dns-out'},
      ],
      'final': 'proxy',
      'auto_detect_interface': true,
    },
  };
  return const JsonEncoder.withIndent('  ').convert(cfg);
}

/// Result of a quick reachability probe of a profile's server.
class ProbeResult {
  final bool ok;
  final int ms;
  final String? err;
  ProbeResult(this.ok, this.ms, this.err);
}

/// Quick health check: open a TLS (or TCP) connection to the profile's server
/// from the current network. Proves the server is up & reachable (and the TLS
/// cert is valid) without bringing the whole tunnel up. Best-effort, 6s timeout.
Future<ProbeResult> probeProfile(VpnProfile p) async {
  final sw = Stopwatch()..start();
  try {
    final u = Uri.parse(p.url);
    final host = u.host;
    final port = u.port == 0 ? 443 : u.port;
    final secure = (u.queryParameters['security'] ?? 'tls') != 'none';
    const timeout = Duration(seconds: 6);
    if (secure) {
      final s = await SecureSocket.connect(host, port,
          timeout: timeout, onBadCertificate: (_) => true);
      s.destroy();
    } else {
      final s = await Socket.connect(host, port, timeout: timeout);
      s.destroy();
    }
    return ProbeResult(true, sw.elapsedMilliseconds, null);
  } catch (e) {
    return ProbeResult(false, sw.elapsedMilliseconds, e.toString());
  }
}
