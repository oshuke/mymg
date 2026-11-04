import 'package:shared_preferences/shared_preferences.dart';

import 'background.dart';
import 'legal_documents.dart';
import 'notification_service.dart';

/// Called after the foreground consent screen, including upgraded saved sessions.
Future<void> startConsentedServices() async {
  if (!await LegalConsent.isAccepted()) return;
  try {
    await NotificationService.instance.init();
  } catch (_) {}
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool('mymg.bg.enabled') ?? false) {
    await schedulePeriodicFetch();
  }
}
