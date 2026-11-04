import 'package:flutter/material.dart';

import 'quick_control_sheet.dart';
import 'ui/frosted_page.dart';

/// Uses the same PIN, remote control and result flow as the independent sheet.
class ClimatePage extends StatelessWidget {
  const ClimatePage({super.key, required this.token, required this.vin});

  final String token;
  final String vin;

  @override
  Widget build(BuildContext context) {
    return FrostedBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('空调控制'),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
        ),
        body: SafeArea(
          top: false,
          child: QuickControlSheet(
            embedded: true,
            climateOnly: true,
            token: token,
            vin: vin,
          ),
        ),
      ),
    );
  }
}
