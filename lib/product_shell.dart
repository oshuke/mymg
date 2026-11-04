import 'dart:async';

import 'package:flutter/material.dart';

import 'consented_services.dart';

import 'home_page.dart';
import 'map_page.dart';
import 'ui/app_shell.dart';
import 'ui/home_return_navigator.dart';
import 'ui_navigation_contract.dart';
import 'vehicle_status_page.dart';
import 'vehicle_control_page.dart';

class ProductShell extends StatefulWidget {
  const ProductShell({super.key, required this.token, required this.vin});

  final String token;
  final String vin;

  @override
  State<ProductShell> createState() => _ProductShellState();
}

class _ProductShellState extends State<ProductShell> {
  int _index = 0;
  final _visited = <int>{0};
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    unawaited(startConsentedServices());
    _pages = [
      HomePage(token: widget.token, vin: widget.vin, onNavigate: _select),
      VehicleControlPage(token: widget.token, vin: widget.vin),
      VehicleStatusPage(token: widget.token, vin: widget.vin),
      MapPage(token: widget.token, vin: widget.vin),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return HomeReturnNavigator(
      isHome: _index == 0,
      onHome: () => _select(0),
      child: AppShell(
        currentIndex: _index,
        onIndexChanged: _select,
        body: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < _pages.length; i++)
              _visited.contains(i)
                  ? TickerMode(enabled: _index == i, child: _pages[i])
                  : const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }

  void _select(int index) {
    if (!mounted || index < 0 || index >= productDestinations.length) return;
    setState(() {
      _visited.add(index);
      _index = index;
      _pages[0] = HomePage(
        token: widget.token,
        vin: widget.vin,
        onNavigate: _select,
        active: index == 0,
      );
    });
  }
}
