import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// ─────────────────────────────────────────────────────────────────────────────
// NotificationService
//
// Wraps flutter_local_notifications for all platforms.
// • Android  — uses a "Document" channel with high importance
// • iOS/macOS — requests alert + sound + badge permissions on first launch
// • Web / Linux — gracefully no-ops (flutter_local_notifications has limited
//   web support; web notifications require a service worker outside this scope)
// ─────────────────────────────────────────────────────────────────────────────
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  // Stream to listen to notification taps when the app is running
  static final StreamController<String?> selectNotificationStream =
      StreamController<String?>.broadcast();

  // Cached payload when a notification launches the app from a terminated state
  String? initialPayload;

  // ── Notification channel config ───────────────────────────────────────────
  static const _channelId   = 'documents_channel';
  static const _channelName = 'Documents';
  static const _channelDesc = 'Notifications de statut des demandes de documents';

  // ── Init ──────────────────────────────────────────────────────────────────
  Future<void> init() async {
    if (_initialized || kIsWeb) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin  = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestSoundPermission: true,
      requestBadgePermission: true,
    );
    const linux = LinuxInitializationSettings(defaultActionName: 'Ouvrir');

    const settings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
      linux: linux,
    );

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        selectNotificationStream.add(response.payload);
      },
    );

    // Check if the app was launched by tapping a notification
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails != null && launchDetails.didNotificationLaunchApp) {
      initialPayload = launchDetails.notificationResponse?.payload;
    }

    // Create the Android notification channel (no-op on other platforms)
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDesc,
            importance: Importance.high,
            playSound: true,
          ),
        );

    _initialized = true;
  }

  // ── Show a "document ready to collect" notification ──────────────────────
  /// [notificationId] should be unique per document request so repeated
  /// notifications for the same request are deduplicated.
  Future<void> showDocumentReady({
    required int notificationId,
    required String documentLabel,
  }) async {
    if (kIsWeb || !_initialized) return;

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.max,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      ticker: 'Document prêt à retirer',
      playSound: true,
      enableVibration: true,
      styleInformation: BigTextStyleInformation(''),
    );
    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
      presentBadge: true,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );

    await _plugin.show(
      notificationId,
      '📄 Document prêt à retirer',
      'Votre "$documentLabel" est prêt. Vous pouvez vous présenter à la scolarité pour le récupérer.',
      details,
      payload: notificationId.toString(),
    );
  }

  // ── Show a generic status-change notification ─────────────────────────────
  Future<void> showStatusChanged({
    required int notificationId,
    required String documentLabel,
    required String statusLabel,
  }) async {
    if (kIsWeb || !_initialized) return;

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      icon: '@mipmap/ic_launcher',
    );
    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: false,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );

    await _plugin.show(
      notificationId,
      'Mise à jour de votre demande',
      '"$documentLabel" — $statusLabel',
      details,
      payload: notificationId.toString(),
    );
  }
}
