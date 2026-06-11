import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    await Future.wait([
      for (var i = 0; i < _profiles.length; i++)
        probeProfile(_profiles[i]).then((r) {
          if (mounted) setState(() => _probe[i] = r);
        }),
    ]);
    if (mounted) setState(() => _checking = false);
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
        title: const Text('Профили VPN'),
        actions: [
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
                  Text(p.summary),
                  if (_probe[i] != null)
                    Text(
                      _probe[i]!.ok
                          ? '✓ доступен · ${_probe[i]!.ms} мс'
                          : '✗ не отвечает',
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
