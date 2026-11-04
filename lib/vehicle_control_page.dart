import 'package:flutter/material.dart';

import 'quick_control_sheet.dart';
import 'ui/frosted_page.dart';

class VehicleControlPage extends StatelessWidget {
  const VehicleControlPage({super.key, required this.token, required this.vin});

  final String token;
  final String vin;

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
        body: SafeArea(
          top: false,
          child: QuickControlSheet(embedded: true, token: token, vin: vin),
        ),
      ),
    );
  }
}
