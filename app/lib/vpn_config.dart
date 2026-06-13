import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
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

  // Split-tunnel routing (global): 'all' = everything via VPN (default); 'include' =
  // only the listed IPs/CIDRs/domains via VPN, rest direct; 'exclude' = everything via
  // VPN except the listed ones. The list is newline-separated CIDRs/domains.
  static const _kRouteMode = 'routeMode';
  static const _kRouteList = 'routeList';

  static Future<String> routeMode() async =>
      (await _storage.read(key: _kRouteMode)) ?? 'all';
  static Future<String> routeList() async =>
      (await _storage.read(key: _kRouteList)) ?? '';
  static Future<void> saveRoute(String mode, String list) async {
    await _storage.write(key: _kRouteMode, value: mode);
    await _storage.write(key: _kRouteList, value: list);
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
    // Resolve the server host up front (system DNS first, then classic resolvers) and
    // bake the IP in — so a blocked/poisoned 8.8.8.8 can't keep the tunnel from rising.
    final serverIp = await resolveServerIp(list[i].url);
    return buildSingboxConfig(list[i].url,
        caCertPath: caPath,
        routeMode: await routeMode(),
        routeList: await routeList(),
        serverIp: serverIp);
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

/// Classic public resolvers tried, in order, when the device's own DNS can't (or
/// won't) resolve the server host — e.g. Russia throttling/hijacking plain DNS. Yandex
/// (77.88.8.8) is included because it's the least likely to be blocked from inside RU.
const _fallbackResolvers = ['8.8.8.8', '1.1.1.1', '9.9.9.9', '77.88.8.8'];

/// Resolve a `vless://` server host to an IPv4 literal, preferring the device's own
/// (system) DNS and falling back to classic public resolvers over plain UDP/53.
/// Returns null only if every path fails (caller then lets sing-box try its own DNS).
/// Baking the IP into the outbound removes the in-tunnel DNS bootstrap entirely, so a
/// blocked 8.8.8.8 can't stop the connection from coming up.
Future<String?> resolveServerIp(String vlessUrl) async {
  String host;
  try {
    host = Uri.parse(vlessUrl.trim()).host;
  } catch (_) {
    return null;
  }
  if (host.isEmpty) return null;
  // Already a literal IPv4 — nothing to resolve.
  if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) return host;

  // 1) System resolver (whatever the phone uses for normal browsing — works even when
  //    8.8.8.8 is blocked, since the ISP's own resolver is reachable).
  try {
    final res = await InternetAddress.lookup(host, type: InternetAddressType.IPv4)
        .timeout(const Duration(seconds: 3));
    if (res.isNotEmpty) return res.first.address;
  } catch (_) {/* fall through to classic resolvers */}

  // 2) Classic public resolvers over plain UDP, in order.
  for (final server in _fallbackResolvers) {
    final ip = await _queryA(host, server);
    if (ip != null) return ip;
  }
  return null;
}

/// Minimal DNS A-record query over UDP/53 to [server]. Returns the first A answer or
/// null on timeout/error. Hand-rolled so it doesn't depend on the system resolver.
Future<String?> _queryA(String name, String server,
    {Duration timeout = const Duration(seconds: 2)}) async {
  RawDatagramSocket? sock;
  try {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final id = DateTime.now().microsecondsSinceEpoch & 0xFFFF;
    final b = BytesBuilder();
    b.add([(id >> 8) & 0xFF, id & 0xFF, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]);
    for (final label in name.split('.')) {
      final bytes = utf8.encode(label);
      b.addByte(bytes.length);
      b.add(bytes);
    }
    b.addByte(0); // root label
    b.add([0, 1, 0, 1]); // QTYPE=A, QCLASS=IN
    final query = b.toBytes();

    final completer = Completer<String?>();
    final s = sock;
    s.listen((ev) {
      if (ev == RawSocketEvent.read) {
        final dg = s.receive();
        if (dg != null && !completer.isCompleted) {
          completer.complete(_parseFirstA(dg.data));
        }
      }
    });
    s.send(query, InternetAddress(server), 53);
    return await completer.future
        .timeout(timeout, onTimeout: () => null);
  } catch (_) {
    return null;
  } finally {
    sock?.close();
  }
}

/// Parse the first A record out of a raw DNS response. Handles name compression by
/// stopping at a pointer (we never need to expand names, only skip them).
String? _parseFirstA(Uint8List m) {
  if (m.length < 12) return null;
  final qd = (m[4] << 8) | m[5];
  final an = (m[6] << 8) | m[7];
  int p = 12;
  for (int i = 0; i < qd; i++) {
    p = _skipName(m, p);
    p += 4; // QTYPE + QCLASS
  }
  for (int i = 0; i < an && p + 10 <= m.length; i++) {
    p = _skipName(m, p);
    if (p + 10 > m.length) return null;
    final type = (m[p] << 8) | m[p + 1];
    final rdlen = (m[p + 8] << 8) | m[p + 9];
    final rdata = p + 10;
    if (type == 1 && rdlen == 4 && rdata + 4 <= m.length) {
      return '${m[rdata]}.${m[rdata + 1]}.${m[rdata + 2]}.${m[rdata + 3]}';
    }
    p = rdata + rdlen;
  }
  return null;
}

/// Advance past a DNS name (sequence of length-prefixed labels), stopping right after a
/// compression pointer (0xC0) or the zero root label.
int _skipName(Uint8List m, int p) {
  while (p < m.length) {
    final len = m[p];
    if (len == 0) return p + 1;
    if ((len & 0xC0) == 0xC0) return p + 2; // pointer terminates the name
    p += 1 + len;
  }
  return p;
}

/// Build just the vless/reality outbound (tag "proxy") from a `vless://` share URL.
/// Shared by the full tunnel config and the health-check probe. Throws on a bad URL.
/// When [serverIp] is given, it replaces the dial target (server) while SNI/Host keep
/// the original domain — so TLS/Reality camouflage is unchanged but no DNS is needed.
Map<String, dynamic> _vlessOutbound(String vlessUrl,
    {String? caCertPath, String? serverIp}) {
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
    // Dial the pre-resolved IP when we have one; SNI (server_name) and ws Host below
    // still carry the domain, so camouflage and routing are unaffected.
    'server': (serverIp != null && serverIp.isNotEmpty) ? serverIp : host,
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

/// Split a routing list (one entry per line, `#` comments) into IP/CIDR vs domain
/// matchers. A bare IPv4 gets `/32`.
({List<String> cidrs, List<String> domains}) _splitRouteList(String list) {
  final cidrs = <String>[];
  final domains = <String>[];
  for (final raw in list.split('\n')) {
    final e = raw.trim();
    if (e.isEmpty || e.startsWith('#')) continue;
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$').hasMatch(e)) {
      cidrs.add(e.contains('/') ? e : '$e/32');
    } else {
      domains.add(e);
    }
  }
  return (cidrs: cidrs, domains: domains);
}

/// Turn a `vless://` URL into a full sing-box client config (tun in + the outbound +
/// DNS + split-tunnel routing). [routeMode]: 'all' (everything via VPN, default),
/// 'include' (only [routeList] entries via VPN, rest direct), or 'exclude' (all via
/// VPN except [routeList]). [routeList] = newline-separated CIDRs/domains.
String buildSingboxConfig(String vlessUrl,
    {String? caCertPath,
    String routeMode = 'all',
    String routeList = '',
    String? serverIp}) {
  final outbound =
      _vlessOutbound(vlessUrl, caCertPath: caCertPath, serverIp: serverIp);
  // The host to feed the bootstrap DNS rule: the original domain (not the dialed IP).
  final host = Uri.parse(vlessUrl.trim()).host;

  final parsed = _splitRouteList(routeList);
  // DNS always stays in front; cidr & domain get SEPARATE rules (single-rule fields
  // are AND-ed in sing-box, so two rules = OR).
  final routeRules = <Map<String, dynamic>>[
    {'protocol': 'dns', 'outbound': 'dns-out'},
  ];
  String routeFinal;
  String dnsFinal;
  if (routeMode == 'include') {
    if (parsed.cidrs.isNotEmpty) {
      routeRules.add({'ip_cidr': parsed.cidrs, 'outbound': 'proxy'});
    }
    if (parsed.domains.isNotEmpty) {
      routeRules.add({'domain_suffix': parsed.domains, 'outbound': 'proxy'});
    }
    routeFinal = 'direct'; // everything not listed stays on the local connection
    dnsFinal = 'dns-direct'; // most traffic is direct → resolve locally
  } else if (routeMode == 'exclude') {
    if (parsed.cidrs.isNotEmpty) {
      routeRules.add({'ip_cidr': parsed.cidrs, 'outbound': 'direct'});
    }
    if (parsed.domains.isNotEmpty) {
      routeRules.add({'domain_suffix': parsed.domains, 'outbound': 'direct'});
    }
    routeFinal = 'proxy';
    dnsFinal = 'dns-proxy';
  } else {
    routeFinal = 'proxy'; // 'all'
    dnsFinal = 'dns-proxy';
  }

  final cfg = {
    'log': {'level': 'info', 'timestamp': true},
    'dns': {
      'servers': [
        // The server host is normally pre-resolved in Dart (system DNS → classic
        // resolvers, see resolveServerIp) and baked into the outbound as a literal IP,
        // so this rarely runs. When it does, prefer the device's own resolver over a
        // hardcoded 8.8.8.8 (which Russia may throttle/hijack).
        {'tag': 'dns-direct', 'address': 'local', 'detour': 'direct'},
        // Plain DNS over the proxy (not DoH): one fewer TLS handshake that would
        // otherwise also lean on the (broken, on old Windows) OS trust store.
        {'tag': 'dns-proxy', 'address': '1.1.1.1', 'detour': 'proxy'},
      ],
      'rules': [
        {'domain': [host], 'server': 'dns-direct'},
      ],
      'final': dnsFinal,
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
      'rules': routeRules,
      'final': routeFinal,
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
String buildProbeConfig(String vlessUrl, int httpPort,
    {String? caCertPath, String? serverIp}) {
  final outbound =
      _vlessOutbound(vlessUrl, caCertPath: caCertPath, serverIp: serverIp);
  final host = Uri.parse(vlessUrl.trim()).host;
  final cfg = {
    'log': {'level': 'error'},
    'dns': {
      'servers': [
        {'tag': 'd', 'address': 'local', 'detour': 'direct'},
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
    final serverIp = await resolveServerIp(p.url);
    await cfgFile.writeAsString(
        buildProbeConfig(p.url, port, caCertPath: caCertPath, serverIp: serverIp));
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
