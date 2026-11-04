import 'package:flutter/material.dart';

enum ProductDestinationId {
  home,
  control,
  vehicleStatus,
  location,
  settings,
  climate,
}

class ProductDestination {
  const ProductDestination({
    required this.id,
    required this.label,
    required this.icon,
  });

  final ProductDestinationId id;
  final String label;
  final IconData icon;
}

const productDestinations = <ProductDestination>[
  ProductDestination(
    id: ProductDestinationId.home,
    label: '首页',
    icon: Icons.home_rounded,
  ),
  ProductDestination(
    id: ProductDestinationId.control,
    label: '车控',
    icon: Icons.directions_car_filled_rounded,
  ),
  ProductDestination(
    id: ProductDestinationId.vehicleStatus,
    label: '车况',
    icon: Icons.monitor_heart_rounded,
  ),
  ProductDestination(
    id: ProductDestinationId.location,
    label: '位置',
    icon: Icons.location_on_rounded,
  ),
];
