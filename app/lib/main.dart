import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'chess_board.dart';
import 'desktop_vpn.dart';
import 'settings_page.dart';
import 'vpn_config.dart';

// Held for the whole process lifetime so the OS keeps the single-instance lock; the
// lock is released automatically when the process exits (even on a crash), so a stale
// lock can never block a relaunch.
RandomAccessFile? _instanceLock;

void main() {
  _ensureSingleInstance();
  runApp(const ChessApp());
}

/// On desktop, refuse to start a second copy — two instances would each spawn the core
/// and fight over the tun0 device. An exclusive advisory lock on a file in the runtime
/// dir does it portably (Linux/Windows/macOS). Mobile already runs a single task.
void _ensureSingleInstance() {
  if (Platform.isAndroid || Platform.isIOS) return;
  try {
    final dir = Platform.environment['XDG_RUNTIME_DIR'] ?? Directory.systemTemp.path;
    _instanceLock = File('$dir${Platform.pathSeparator}chessvpn.lock')
        .openSync(mode: FileMode.write);
    _instanceLock!.lockSync(FileLock.exclusive); // throws if another instance holds it
  } on FileSystemException {
    exit(0); // already running — bow out quietly
  }
}

class ChessApp extends StatelessWidget {
  const ChessApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Chess',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true),
        home: const BoardPage(),
      );
}

/// The chess board is the face on every platform — it's the brand. Only the VPN
/// backend differs: Android uses the native VpnService (MethodChannel); desktop
/// uses the passwordless sing-box helper. Covert moves on the board:
///   knight g1->a3 / a3->g1  -> connect / disconnect (active profile)
///   rook  a1->c3            -> hidden profiles screen
/// A status dot by the move-text shows the real tunnel state.
class BoardPage extends StatefulWidget {
  const BoardPage({super.key});
  @override
  State<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends State<BoardPage> {
  static const _chan = MethodChannel('twomove/vpn');
  static bool get _mobile => Platform.isAndroid || Platform.isIOS;

  DesktopVpn? _desktop;
  String _status = 'disconnected';

  @override
  void initState() {
    super.initState();
    if (_mobile) {
      _chan.setMethodCallHandler((call) async {
        if (call.method == 'status') {
          final s = (call.arguments as String?) ?? 'disconnected';
          setState(() => _status = s.startsWith('error') ? 'error' : s);
        }
        return null;
      });
    } else {
      _desktop = DesktopVpn(onStatus: (s) {
        if (mounted) setState(() => _status = s);
      });
    }
  }

  Future<void> _connect() async {
    setState(() => _status = 'connecting');
    try {
      final cfg = await VpnStore.activeConfig();
      if (_mobile) {
        await _chan.invokeMethod('connect', {'config': cfg});
      } else {
        await _desktop!.connect(cfg);
      }
    } catch (_) {
      setState(() => _status = 'disconnected');
    }
  }

  Future<void> _disconnect() async {
    try {
      if (_mobile) {
        await _chan.invokeMethod('disconnect');
      } else {
        await _desktop!.disconnect();
      }
    } catch (_) {}
    if (_mobile) setState(() => _status = 'disconnected');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF1F2024),
        body: SafeArea(
          child: ChessBoard(
            vpnStatus: _status,
            onArm: _connect,
            onDisarm: _disconnect,
            onMenu: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ),
      );
}
