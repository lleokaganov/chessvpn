import 'dart:convert';
import 'dart:io';
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
    return buildSingboxConfig(list[i].url);
  }
}

/// Turn a `vless://uuid@host:port?...#name` URL into a full sing-box client config
/// (tun inbound + vless outbound + DNS that resolves the server directly to avoid
/// the bootstrap loop). Throws [FormatException] on a malformed URL.
String buildSingboxConfig(String vlessUrl) {
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
  final path = q['path'] ?? '/';
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
    outbound['tls'] = {
      'enabled': true,
      'server_name': sni,
      'utls': {'enabled': true, 'fingerprint': fp},
      // Pin the Let's Encrypt root (ISRG Root X1) so the server certificate is
      // verified against THIS root only, independent of the OS trust store. Old /
      // un-updated Windows machines lack ISRG Root X1 and otherwise build the chain
      // through the long-expired DST Root CA X3 — making every handshake fail with
      // "certificate has expired". Pinning the real root keeps it secure and portable.
      'certificate': _isrgRootX1.trim().split('\n'),
    };
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

/// ISRG Root X1 — the Let's Encrypt root our home server's certificate chains to.
/// Pinned in [buildSingboxConfig] so TLS verification never touches the OS trust
/// store (see the comment there). Valid until 2035-06-04.
const _isrgRootX1 = '''
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
-----END CERTIFICATE-----''';
