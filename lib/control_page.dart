import 'package:flutter/material.dart';

import 'quick_control_sheet.dart';
import 'ui/frosted_page.dart';

/// Legacy route retained for existing callers; execution is shared with the
/// independent tile/widget surface, including BLE unlock's drive authorization.
class ControlPage extends StatelessWidget {
  const ControlPage({super.key});

  @override
  Widget build(BuildContext context) {
    return FrostedBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('车辆控制'),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
        ),
        body: const SafeArea(
          top: false,
          child: QuickControlSheet(embedded: true),
        ),
      ),
    );
  }
}
