import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Desktop (Linux/Windows) VPN controller — runs the sing-box core in TUN mode.
///
/// Linux: a one-time-installed privileged helper (`/usr/local/bin/chessvpn-helper`)
/// is whitelisted in sudoers NOPASSWD, so connect/disconnect need **no password**.
///
/// Windows: sing-box.exe + wintun.dll ship next to the app .exe. Connecting launches
/// an elevated watcher (single UAC prompt) that runs sing-box until a flag file is
/// removed; disconnecting just deletes that flag file, so turning the tunnel OFF needs
/// no second prompt. Output is mirrored to a log file we tail to detect "connected".
class DesktopVpn {
  static const helper = '/usr/local/bin/chessvpn-helper';
  Process? _proc;
  Timer? _logPoll;
  String _lastStatus = 'disconnected';
  final void Function(String status)? onStatus;
  DesktopVpn({this.onStatus});

  String get _cfg => '${Directory.systemTemp.path}${Platform.pathSeparator}.chessvpn-config.json';

  // Windows: folder that holds chess.exe (and the bundled sing-box.exe + wintun.dll).
  String get _winDir => File(Platform.resolvedExecutable).parent.path;
  String get _winFlag => '${Directory.systemTemp.path}\\chessvpn.run';
  String get _winLog => '${Directory.systemTemp.path}\\chessvpn-singbox.log';

  Future<void> connect(String configJson) async {
    _lastStatus = 'connecting';
    onStatus?.call('connecting');
    await File(_cfg).writeAsString(configJson);

    if (Platform.isWindows) {
      await _connectWindows();
    } else {
      // passwordless via the installed helper
      _proc = await Process.start('sudo', ['-n', helper, 'start', _cfg]);
      _proc!.stdout.transform(const SystemEncoding().decoder).listen(_parse);
      _proc!.stderr.transform(const SystemEncoding().decoder).listen(_parse);
      _proc!.exitCode.then((code) {
        onStatus?.call(_lastStatus == 'connected' || code == 0 ? 'disconnected' : 'error');
        _lastStatus = 'disconnected';
      });
    }
  }

  Future<void> _connectWindows() async {
    final bin = '$_winDir\\sing-box.exe';
    // Raise the flag the elevated watcher polls; clear any stale log.
    await File(_winFlag).writeAsString('1');
    try {
      final lf = File(_winLog);
      if (lf.existsSync()) lf.deleteSync();
    } catch (_) {}

    // Inner (elevated) script: start sing-box hidden, keep it alive while the flag
    // file exists, then stop it cleanly when the app removes the flag.
    final inner = '''
\$ErrorActionPreference='SilentlyContinue'
\$p = Start-Process -PassThru -WindowStyle Hidden -WorkingDirectory '$_winDir' -FilePath '$bin' -ArgumentList 'run','-c','$_cfg' -RedirectStandardError '$_winLog'
while (Test-Path '$_winFlag') { Start-Sleep -Milliseconds 500; if (\$p.HasExited) { break } }
if (-not \$p.HasExited) { Stop-Process -Id \$p.Id -Force }
''';
    final encoded = _psEncode(inner);

    // Outer launcher elevates the inner script via UAC (the one prompt the user sees).
    await Process.start('powershell', [
      '-NoProfile',
      '-WindowStyle',
      'Hidden',
      '-Command',
      "Start-Process powershell -Verb RunAs -WindowStyle Hidden "
          "-ArgumentList '-NoProfile','-WindowStyle','Hidden','-EncodedCommand','$encoded'",
    ]);

    _pollWindowsLog();
  }

  // Tail the sing-box log for the "started" banner to flip the UI to connected.
  void _pollWindowsLog() {
    _logPoll?.cancel();
    var ticks = 0;
    _logPoll = Timer.periodic(const Duration(milliseconds: 500), (t) {
      ticks++;
      final f = File(_winLog);
      if (f.existsSync()) {
        String txt = '';
        try {
          txt = f.readAsStringSync();
        } catch (_) {}
        if (txt.contains('sing-box started') || txt.contains('started')) {
          _lastStatus = 'connected';
          onStatus?.call('connected');
          t.cancel();
          return;
        }
        if (txt.contains('FATAL') || txt.contains('panic')) {
          onStatus?.call('error');
          t.cancel();
          return;
        }
      }
      // User cancelled the UAC prompt (flag gone) or we timed out (~30s).
      if (!File(_winFlag).existsSync() || ticks >= 60) {
        t.cancel();
        if (_lastStatus != 'connected') {
          _lastStatus = 'disconnected';
          onStatus?.call('error');
        }
      }
    });
  }

  // UTF-16LE + base64, the format PowerShell -EncodedCommand expects.
  String _psEncode(String s) {
    final bytes = <int>[];
    for (final u in s.codeUnits) {
      bytes.add(u & 0xFF);
      bytes.add((u >> 8) & 0xFF);
    }
    return base64.encode(bytes);
  }

  void _parse(String chunk) {
    if (chunk.contains('sing-box started')) {
      _lastStatus = 'connected';
      onStatus?.call('connected');
    } else if (chunk.contains('a password is required') ||
        chunk.contains('sudo:') ||
        chunk.contains('FATAL') ||
        chunk.contains('command not found')) {
      onStatus?.call('error');
    }
  }

  Future<void> disconnect() async {
    _logPoll?.cancel();
    if (Platform.isWindows) {
      // Removing the flag tells the elevated watcher to stop sing-box — no 2nd UAC.
      try {
        final f = File(_winFlag);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    } else {
      try {
        await Process.run('sudo', ['-n', helper, 'stop']);
      } catch (_) {}
      _proc?.kill();
    }
    _lastStatus = 'disconnected';
    onStatus?.call('disconnected');
  }
}
