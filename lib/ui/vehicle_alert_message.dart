import 'package:flutter/material.dart';

import '../src/rust/vehicle/model.dart';
import '../theme_controller.dart';

/// Presents server values without assigning undocumented meanings to codes.
String formatVehicleAlert({
  Object? alertData,
  Object? alertId,
  Object? alertType,
}) {
  final data = alertData?.toString().trim() ?? '';
  if (alertData is String &&
      data.isNotEmpty &&
      num.tryParse(data) == null &&
      int.tryParse(data) == null) {
    return data;
  }
  final id = alertId?.toString().trim() ?? '';
  final type = alertType?.toString().trim() ?? '';
  final codes = [
    if (id.isNotEmpty) '告警 ID：$id',
    if (type.isNotEmpty) '类型：$type',
    if (data.isNotEmpty) '数据：$data',
  ];
  return '${codes.isEmpty ? '车辆提醒（未提供代码）' : codes.join(' · ')}\n含义待确认';
}

/// A wrapping, theme-aware alert row for status and home surfaces.
class VehicleAlertMessage extends StatelessWidget {
  const VehicleAlertMessage({
    super.key,
    this.alertData,
    this.alertId,
    this.alertType,
  });

  VehicleAlertMessage.fromAlert(VehicleAlert alert, {super.key})
    : alertData = alert.alertData,
      alertId = alert.alertId,
      alertType = alert.alertType;

  final Object? alertData;
  final Object? alertId;
  final Object? alertType;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(Icons.info_outline, size: 20, color: context.warning),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              formatVehicleAlert(
                alertData: alertData,
                alertId: alertId,
                alertType: alertType,
              ),
              softWrap: true,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: context.strong,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
