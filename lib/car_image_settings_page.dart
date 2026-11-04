import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'car_image_store.dart';
import 'ui/glass_surface.dart';
import 'ui/vehicle_hero.dart';
import 'ui/frosted_page.dart';
import 'widget_sync.dart';

class CarImageSettingsPage extends StatefulWidget {
  const CarImageSettingsPage({super.key});

  @override
  State<CarImageSettingsPage> createState() => _CarImageSettingsPageState();
}

class _CarImageSettingsPageState extends State<CarImageSettingsPage> {
  bool _busy = false;

  Future<void> _change({bool reset = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      String? path;
      if (reset) {
        await CarImageStore.resetToDefault();
      } else {
        final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 2048,
          maxHeight: 2048,
          imageQuality: 95,
        );
        if (picked == null) return;
        path = await CarImageStore.saveFromFile(picked.path);
      }
      await WidgetSync.setWidgetCarImage(path);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(reset ? '已恢复默认车辆图片' : '车辆图片已更新')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('图片保存失败，请重新选择一张有效图片')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('车辆图片')),
    body: FrostedBackground(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const VehicleHeroCard(title: '我的 MG5', subtitle: '自定义外观预览'),
          const SizedBox(height: 20),
          GlassSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('车辆主视觉', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text('首页与桌面小组件同步更新。建议使用横向照片，也支持透明背景 PNG。'),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _change(),
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.photo_library_outlined),
                  label: Text(_busy ? '正在处理…' : '从相册选择'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _change(reset: true),
                  icon: const Icon(Icons.restore_rounded),
                  label: const Text('恢复默认图片'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
