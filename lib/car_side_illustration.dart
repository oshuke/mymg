import 'package:flutter/material.dart';

/// 小米汽车风：侧视线稿插画（CustomPaint，无外链资源）
/// 用连续/分段路径勾勒轿车侧影 + 两轮 + 简单风切线。
class CarSideIllustration extends StatelessWidget {
  const CarSideIllustration({
    super.key,
    this.width = 220,
    this.height = 88,
    this.strokeColor,
    this.accentColor,
  });

  final double width;
  final double height;
  final Color? strokeColor;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final stroke = strokeColor ??
        (dark ? const Color(0xFFB8C0CC) : const Color(0xFF3A4250));
    final accent = accentColor ?? Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _CarSidePainter(stroke, accent),
      ),
    );
  }
}

class _CarSidePainter extends CustomPainter {
  _CarSidePainter(this.stroke, this.accent);
  final Color stroke;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = stroke;

    final soft = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..color = stroke.withOpacity(0.45);

    // 车身主体（侧视轮廓，车头朝左）
    final body = Path()
      ..moveTo(w * 0.06, h * 0.62)
      ..lineTo(w * 0.10, h * 0.48)
      ..quadraticBezierTo(w * 0.14, h * 0.40, w * 0.24, h * 0.38)
      ..lineTo(w * 0.36, h * 0.22)
      ..quadraticBezierTo(w * 0.42, h * 0.16, w * 0.55, h * 0.16)
      ..quadraticBezierTo(w * 0.68, h * 0.16, w * 0.74, h * 0.24)
      ..lineTo(w * 0.84, h * 0.40)
      ..quadraticBezierTo(w * 0.90, h * 0.44, w * 0.94, h * 0.52)
      ..lineTo(w * 0.94, h * 0.62)
      ..lineTo(w * 0.06, h * 0.62);
    canvas.drawPath(body, line);

    // 车窗分隔
    final glass = Path()
      ..moveTo(w * 0.38, h * 0.24)
      ..lineTo(w * 0.42, h * 0.36)
      ..lineTo(w * 0.62, h * 0.36)
      ..lineTo(w * 0.70, h * 0.26)
      ..quadraticBezierTo(w * 0.55, h * 0.20, w * 0.38, h * 0.24);
    canvas.drawPath(glass, soft);

    // 腰线
    canvas.drawLine(
      Offset(w * 0.12, h * 0.48),
      Offset(w * 0.88, h * 0.48),
      soft,
    );

    // 轮
    final wheelR = h * 0.14;
    void wheel(double cx) {
      canvas.drawCircle(Offset(cx, h * 0.62), wheelR, line);
      canvas.drawCircle(Offset(cx, h * 0.62), wheelR * 0.35, soft);
    }

    wheel(w * 0.28);
    wheel(w * 0.76);

    // 破风短线（车头前）
    final wind = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = accent.withOpacity(0.85);
    canvas.drawLine(Offset(w * 0.01, h * 0.42), Offset(w * 0.06, h * 0.42), wind);
    canvas.drawLine(Offset(w * 0.00, h * 0.50), Offset(w * 0.05, h * 0.50), wind);
    canvas.drawLine(Offset(w * 0.02, h * 0.58), Offset(w * 0.07, h * 0.58), wind);

    // 车尾气流（拉长）
    final tail = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round
      ..color = accent.withOpacity(0.55);
    canvas.drawLine(Offset(w * 0.94, h * 0.44), Offset(w * 0.99, h * 0.44), tail);
    canvas.drawLine(Offset(w * 0.94, h * 0.52), Offset(w * 0.995, h * 0.52), tail);
  }

  @override
  bool shouldRepaint(covariant _CarSidePainter oldDelegate) =>
      oldDelegate.stroke != stroke || oldDelegate.accent != accent;
}
