import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'update_check.dart';
import 'vpn_config.dart';

/// Hidden owner-only screen to view / import / export / switch VPN profiles.
/// Reached from the board via a covert long-press; nothing links to it normally.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<VpnProfile> _profiles = [];
  int _active = 0;
  bool _loading = true;
  final Map<int, ProbeResult> _probe = {};
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await VpnStore.load();
    final a = await VpnStore.activeIndex();
    setState(() {
      _profiles = p;
      _active = p.isEmpty ? 0 : a.clamp(0, p.length - 1);
      _loading = false;
    });
  }

  Future<void> _persist() => VpnStore.save(_profiles, _active);

  Future<void> _checkAll() async {
    setState(() {
      _checking = true;
      _probe.clear();
    });
    // On desktop, run a TRUTHFUL check: push real traffic through each tunnel via the
    // core. On mobile (no spawnable core here), fall back to the shallow port probe.
    final core = (Platform.isAndroid || Platform.isIOS) ? null : desktopCorePath();
    final caPath = (core != null) ? await VpnStore.caBundlePath() : null;
    await Future.wait([
      for (var i = 0; i < _profiles.length; i++)
        (core != null
                ? probeViaCore(_profiles[i], core, caCertPath: caPath, port: 11900 + i)
                : probeProfile(_profiles[i]))
            .then((r) {
          if (mounted) setState(() => _probe[i] = r);
        }),
    ]);
    if (mounted) setState(() => _checking = false);
  }

  Future<void> _routeDialog() async {
    var mode = await VpnStore.routeMode();
    final ctrl = TextEditingController(text: await VpnStore.routeList());
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Маршрутизация'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final m in const [
                  ['all', 'Весь трафик через VPN'],
                  ['include', 'Только список → через VPN'],
                  ['exclude', 'Всё через VPN, кроме списка'],
                ])
                  RadioListTile<String>(
                    value: m[0],
                    groupValue: mode,
                    onChanged: (v) => setLocal(() => mode = v!),
                    title: Text(m[1]),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: ctrl,
                  maxLines: 7,
                  minLines: 3,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '# по строке: IP, маска или домен\n'
                        '10.0.0.0/24\n192.168.1.5\nyoutube.com\ngooglevideo.com',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Отмена')),
            FilledButton(
              onPressed: () async {
                await VpnStore.saveRoute(mode, ctrl.text);
                if (ctx.mounted) Navigator.pop(ctx);
                _toast('Маршрутизация сохранена (применится при следующем включении)');
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkUpdate() async {
    _toast('Проверяю обновления…');
    try {
      final info = await checkForUpdate();
      if (!mounted) return;
      if (info == null) {
        _toast('У вас последняя версия ($kAppVersion)');
        return;
      }
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Доступна версия ${info.version}'),
          content: Text(info.notes.isEmpty
              ? 'Скачать и установить обновление?'
              : info.notes),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Позже')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Скачать')),
          ],
        ),
      );
      if (go == true && info.url.isNotEmpty) {
        await launchUrl(Uri.parse(info.url),
            mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      _toast('Не удалось проверить обновления');
    }
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _addDialog() async {
    final ctrl = TextEditingController();
    final clip = (await Clipboard.getData('text/plain'))?.text ?? '';
    if (clip.trim().startsWith('vless://')) ctrl.text = clip.trim();
    if (!mounted) return;
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Импорт профиля'),
        content: TextField(
          controller: ctrl,
          maxLines: 5,
          minLines: 2,
          decoration: const InputDecoration(
              hintText: 'vless://...', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Добавить')),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    try {
      buildSingboxConfig(url); // validate by building
      final u = Uri.parse(url);
      final name = u.fragment.isNotEmpty ? Uri.decodeComponent(u.fragment) : u.host;
      setState(() => _profiles.add(VpnProfile(name, url)));
      await _persist();
      _toast('Добавлен: $name');
    } catch (_) {
      _toast('Не похоже на корректную vless://-ссылку');
    }
  }

  Future<void> _export(VpnProfile p) async {
    await Clipboard.setData(ClipboardData(text: p.url));
    _toast('Ссылка скопирована в буфер');
  }

  Future<void> _showConfig(VpnProfile p) async {
    String cfg;
    try {
      cfg = buildSingboxConfig(p.url);
    } catch (e) {
      cfg = 'Ошибка разбора: $e';
    }
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(p.name),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(cfg,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: cfg));
              if (ctx.mounted) Navigator.pop(ctx);
              _toast('JSON скопирован');
            },
            child: const Text('Копировать JSON'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
        ],
      ),
    );
  }

  Future<void> _delete(int i) async {
    setState(() {
      _profiles.removeAt(i);
      if (_active >= _profiles.length) _active = _profiles.isEmpty ? 0 : _profiles.length - 1;
    });
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Профили VPN · v$kAppVersion'),
        actions: [
          IconButton(
            tooltip: 'Маршрутизация',
            onPressed: _routeDialog,
            icon: const Icon(Icons.alt_route),
          ),
          IconButton(
            tooltip: 'Проверить обновления',
            onPressed: _checkUpdate,
            icon: const Icon(Icons.system_update),
          ),
          IconButton(
            tooltip: 'Проверить все',
            onPressed: _checking ? null : _checkAll,
            icon: _checking
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.network_check),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addDialog,
        tooltip: 'Импорт',
        child: const Icon(Icons.add),
      ),
      body: _profiles.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Нет профилей.\nНажмите «+» и вставьте vless://-ссылку.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54, fontSize: 15),
                ),
              ),
            )
          : ListView.builder(
        padding: const EdgeInsets.only(bottom: 88),
        itemCount: _profiles.length,
        itemBuilder: (ctx, i) {
          final p = _profiles[i];
          final isActive = i == _active;
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: ListTile(
              leading: Radio<int>(
                value: i,
                groupValue: _active,
                onChanged: (v) async {
                  setState(() => _active = v!);
                  await _persist();
                  _toast('Активен: ${p.name}');
                },
              ),
              title: Text(isActive ? '${p.name}  ● активен' : p.name),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: p.kind == 'Reality'
                              ? const Color(0xFF2E7D32)
                              : const Color(0xFF607D8B),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(p.kind,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600)),
                      ),
                      Flexible(child: Text(p.summary)),
                    ],
                  ),
                  if (_probe[i] != null)
                    Text(
                      _probe[i]!.ok
                          ? '✓ туннель работает · ${_probe[i]!.ms} мс'
                          : '✗ туннель не работает',
                      style: TextStyle(
                        color: _probe[i]!.ok
                            ? const Color(0xFF2E7D32)
                            : const Color(0xFFC62828),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
              onTap: () => _showConfig(p),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                      icon: const Icon(Icons.ios_share),
                      tooltip: 'Экспорт ссылки',
                      onPressed: () => _export(p)),
                  IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Удалить',
                      onPressed: () => _delete(i)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
