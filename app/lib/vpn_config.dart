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

  /// Connection kind for the UI badge: "Reality", "VLESS-TLS", or "VLESS".
  String get kind {
    try {
      final sec = Uri.parse(url).queryParameters['security'] ?? 'tls';
      if (sec == 'reality') return 'Reality';
      if (sec == 'none') return 'VLESS';
      return 'VLESS-TLS';
    } catch (_) {
      return 'VLESS';
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

  /// Public access to the bundled CA path (desktop only) — for the health-check probe.
  static Future<String?> caBundlePath() async =>
      (Platform.isAndroid || Platform.isIOS) ? null : await _ensureCaBundle();

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

/// Build just the vless/reality outbound (tag "proxy") from a `vless://` share URL.
/// Shared by the full tunnel config and the health-check probe. Throws on a bad URL.
Map<String, dynamic> _vlessOutbound(String vlessUrl, {String? caCertPath}) {
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
  final security = q['security'] ?? 'tls';
  final tlsOn = security != 'none';
  final realityOn = security == 'reality';

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
      // uTLS is mandatory for REALITY and good camouflage for plain TLS too.
      'utls': {'enabled': true, 'fingerprint': fp},
    };
    if (realityOn) {
      // REALITY borrows a real external site's handshake — trust is the x25519 key
      // (pbk) + short id (sid), not any CA; the SNI is hidden from DPI.
      tls['reality'] = {
        'enabled': true,
        'public_key': q['pbk'] ?? '',
        'short_id': q['sid'] ?? '',
      };
    } else if (caCertPath != null && caCertPath.isNotEmpty) {
      // Plain TLS: verify against our bundled root store, independent of the OS store.
      tls['certificate_path'] = caCertPath;
    }
    outbound['tls'] = tls;
  }
  // REALITY runs over raw TCP with xtls-rprx-vision flow — never a ws transport.
  if (type == 'ws' && !realityOn) {
    outbound['transport'] = {
      'type': 'ws',
      'path': path,
      'headers': {'Host': wsHost},
    };
  }
  return outbound;
}

/// Turn a `vless://` URL into a full sing-box client config (tun in + the outbound +
/// DNS that resolves the server directly to dodge the bootstrap loop).
String buildSingboxConfig(String vlessUrl, {String? caCertPath}) {
  final outbound = _vlessOutbound(vlessUrl, caCertPath: caCertPath);
  final host = outbound['server'] as String;

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

/// SHALLOW check (mobile fallback): just opens a TLS/TCP connection to the server's
/// port. NOTE: this only proves the port is reachable — it is fooled by REALITY
/// camouflage and by a Cloudflare edge whose origin tunnel is dead (both complete a
/// TLS handshake while carrying no working tunnel). Prefer [probeViaCore] on desktop.
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

/// A minimal sing-box config exposing the profile's outbound via a local HTTP proxy on
/// [httpPort] — used to push real traffic through the tunnel during a health check.
String buildProbeConfig(String vlessUrl, int httpPort, {String? caCertPath}) {
  final outbound = _vlessOutbound(vlessUrl, caCertPath: caCertPath);
  final host = outbound['server'] as String;
  final cfg = {
    'log': {'level': 'error'},
    'dns': {
      'servers': [
        {'tag': 'd', 'address': '8.8.8.8', 'detour': 'direct'},
        {'tag': 'p', 'address': '1.1.1.1', 'detour': 'proxy'},
      ],
      'rules': [
        {'domain': [host], 'server': 'd'},
      ],
      'final': 'p',
      'strategy': 'ipv4_only',
    },
    'inbounds': [
      {'type': 'http', 'tag': 'in', 'listen': '127.0.0.1', 'listen_port': httpPort},
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
    },
  };
  return const JsonEncoder.withIndent('  ').convert(cfg);
}

/// Locate the sing-box core for desktop health-checks, or null if not found.
String? desktopCorePath() {
  if (Platform.isLinux) {
    for (final c in ['/usr/local/lib/chessvpn/sing-box', '/usr/local/bin/sing-box']) {
      if (File(c).existsSync()) return c;
    }
  } else if (Platform.isWindows) {
    final p = '${File(Platform.resolvedExecutable).parent.path}\\sing-box.exe';
    if (File(p).existsSync()) return p;
  } else if (Platform.isMacOS) {
    final p = '${File(Platform.resolvedExecutable).parent.path}/sing-box';
    if (File(p).existsSync()) return p;
  }
  return null;
}

/// TRUTHFUL health check (desktop): spin up the core with the profile's outbound behind
/// a local HTTP proxy and actually fetch a 204 endpoint THROUGH the tunnel. Can't be
/// fooled by REALITY camouflage or a dead-origin Cloudflare edge. [corePath] = sing-box.
Future<ProbeResult> probeViaCore(VpnProfile p, String corePath,
    {String? caCertPath, int port = 11900}) async {
  final sw = Stopwatch()..start();
  Process? proc;
  final cfgFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}chessvpn-probe-$port.json');
  try {
    await cfgFile.writeAsString(buildProbeConfig(p.url, port, caCertPath: caCertPath));
    proc = await Process.start(corePath, ['run', '-c', cfgFile.path]);
    // give the http inbound a moment to come up
    await Future.delayed(const Duration(milliseconds: 1300));
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = (_) => 'PROXY 127.0.0.1:$port';
    try {
      final req = await client
          .getUrl(Uri.parse('http://www.gstatic.com/generate_204'))
          .timeout(const Duration(seconds: 9));
      final resp = await req.close().timeout(const Duration(seconds: 9));
      await resp.drain<void>();
      final ok = resp.statusCode == 204 || resp.statusCode == 200;
      return ProbeResult(
          ok, sw.elapsedMilliseconds, ok ? null : 'HTTP ${resp.statusCode}');
    } finally {
      client.close(force: true);
    }
  } catch (e) {
    return ProbeResult(false, sw.elapsedMilliseconds, e.toString());
  } finally {
    proc?.kill();
    try {
      if (cfgFile.existsSync()) cfgFile.deleteSync();
    } catch (_) {}
  }
}
