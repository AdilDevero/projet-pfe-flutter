import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import '../mysql.dart';
import '../services/notification_service.dart';
import 'login_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Theme constants
// ─────────────────────────────────────────────────────────────────────────────
class _T {
  static const primary = Color(0xFF0E7A50);
  static const dark    = Color(0xFF085C3A);
  static const light   = Color(0xFF1A9963);
  static const bg      = Color(0xFFF0F4F2);
  static const text    = Color(0xFF1A2E25);
  static const sub     = Color(0xFF6B8C7A);
}

// ─────────────────────────────────────────────────────────────────────────────
// Dashboard entry point
// ─────────────────────────────────────────────────────────────────────────────
class DashboardScreen extends StatefulWidget {
  final UserModel user;
  final StudentProfile? profile;
  final String? enrollmentStatus;
  final String? token; // Sanctum token for API calls

  const DashboardScreen({
    super.key,
    required this.user,
    this.profile,
    this.enrollmentStatus,
    this.token,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;
  int _unreadCount = 0;

  // SharedPreferences key for unread count
  static const _unreadKey = 'notif_unread_count';

  Timer? _globalPollTimer;
  StreamSubscription<String?>? _notifSubscription;

  // Global state notifiers to synchronize document requests and notifications
  final documentRequestsNotifier = ValueNotifier<List<DocumentRequestModel>?>(null);
  final notificationsNotifier = ValueNotifier<List<_NotifEntry>?>(null);

  static const _prefsKey = 'doc_request_statuses';

  late final List<_NavItem> _navItems = [
    _NavItem(Icons.dashboard_outlined, Icons.dashboard, 'Accueil'),
    _NavItem(Icons.person_outline, Icons.person, 'Mon Profil'),
    _NavItem(Icons.assignment_outlined, Icons.assignment, 'Inscription'),
    _NavItem(Icons.school_outlined, Icons.school, 'Scolarité'),
    _NavItem(Icons.description_outlined, Icons.description, 'Documents'),
    _NavItem(Icons.notifications_outlined, Icons.notifications, 'Notifications'),
    _NavItem(Icons.settings_outlined, Icons.settings, 'Paramètres'),
  ];

  @override
  void initState() {
    super.initState();
    _loadUnreadCount();
    _loadInitialHistory();
    _startGlobalPolling();
    _setupNotificationTapping();
  }

  @override
  void dispose() {
    _globalPollTimer?.cancel();
    _notifSubscription?.cancel();
    documentRequestsNotifier.dispose();
    notificationsNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadUnreadCount() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _unreadCount = prefs.getInt(_unreadKey) ?? 0);
  }

  Future<void> _loadInitialHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final historyRaw = prefs.getString('notif_history');
    if (historyRaw != null) {
      final list = (jsonDecode(historyRaw) as List)
          .map((e) => _NotifEntry.fromMap(e as Map<String, dynamic>))
          .toList();
      notificationsNotifier.value = list;
    } else {
      notificationsNotifier.value = [];
    }
  }

  void _startGlobalPolling() {
    _globalPollTimer?.cancel();
    if (widget.token == null) return;
    // 1. Run immediately on app launch/login
    _checkStatusChangesGlobal();
    // 2. Poll every 30 seconds
    _globalPollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkStatusChangesGlobal());
  }

  Future<void> _checkStatusChangesGlobal() async {
    if (widget.token == null || !mounted) return;
    try {
      final list = await MySQLHelper.getDocumentRequests(widget.token!);
      if (!mounted) return;

      // Update document requests notifier
      documentRequestsNotifier.value = list;

      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_prefsKey);
      final Map<String, String> previous =
          stored != null ? Map<String, String>.from(jsonDecode(stored) as Map) : {};

      // Load existing notification history
      final historyRaw = prefs.getString('notif_history');
      final List<Map<String, dynamic>> history = historyRaw != null
          ? (jsonDecode(historyRaw) as List).cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];

      bool historyChanged = false;
      int newUnreads = 0;

      for (final req in list) {
        final key       = req.id.toString();
        final oldStatus = previous[key];
        final newStatus = req.status;

        if (oldStatus != null && oldStatus != newStatus) {
          final isReady = newStatus == 'ready';

          // Fire local notification
          if (isReady) {
            await NotificationService.instance.showDocumentReady(
              notificationId: req.id,
              documentLabel: req.documentLabel,
            );
          } else {
            await NotificationService.instance.showStatusChanged(
              notificationId: req.id,
              documentLabel: req.documentLabel,
              statusLabel: req.statusLabel,
            );
          }

          // Bump unread badge count
          if (_selectedIndex != 5) {
            newUnreads++;
          }

          // Add notification entry
          history.insert(0, {
            'requestId':     req.id,
            'documentLabel': req.documentLabel,
            'statusLabel':   req.statusLabel,
            'isReady':       isReady,
            'timestamp':     DateTime.now().toIso8601String(),
          });
          historyChanged = true;
        }
      }

      if (historyChanged) {
        final trimmed = history.take(50).toList();
        await prefs.setString('notif_history', jsonEncode(trimmed));
        // Update notifications notifier
        notificationsNotifier.value =
            trimmed.map((e) => _NotifEntry.fromMap(e)).toList();
      }

      if (newUnreads > 0) {
        setState(() => _unreadCount += newUnreads);
        await prefs.setInt(_unreadKey, _unreadCount);
      }

      // Update local map
      final map = { for (final r in list) r.id.toString(): r.status };
      await prefs.setString(_prefsKey, jsonEncode(map));
    } catch (e) {
      debugPrint('Global polling error: $e');
    }
  }

  void _setupNotificationTapping() {
    // Listen for notification taps when the app is running
    _notifSubscription = NotificationService.selectNotificationStream.stream.listen((payload) {
      if (payload != null) {
        _handleNotificationTap(payload);
      }
    });

    // Check if the app was launched by tapping a notification
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (NotificationService.instance.initialPayload != null) {
        _handleNotificationTap(NotificationService.instance.initialPayload!);
        NotificationService.instance.initialPayload = null; // Clear it
      }
    });
  }

  void _handleNotificationTap(String payload) {
    final requestId = int.tryParse(payload);
    if (requestId == null) return;

    // Find the document label in requests list, or fall back to generic
    String docLabel = 'Document';
    if (documentRequestsNotifier.value != null) {
      try {
        final match = documentRequestsNotifier.value!.firstWhere(
          (r) => r.id == requestId,
        );
        docLabel = match.documentLabel;
      } catch (_) {}
    }

    // Navigate to Documents tab and trigger download
    _onNavSelect(4); // Select Documents tab

    // Trigger download
    DocumentDownloadHelper.downloadAndOpenDocument(
      context: context,
      token: widget.token,
      requestId: requestId,
      documentLabel: docLabel,
    );
  }

  void _onNavSelect(int i) {
    setState(() {
      _selectedIndex = i;
      // Clear badge when opening Notifications tab
      if (i == 5 && _unreadCount > 0) {
        _unreadCount = 0;
        SharedPreferences.getInstance()
            .then((p) => p.setInt(_unreadKey, 0));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final isWide = w >= 900;

    return Scaffold(
      backgroundColor: _T.bg,
      drawer: isWide ? null : _MobileDrawer(
        items: _navItems,
        selected: _selectedIndex,
        unreadCount: _unreadCount,
        user: widget.user,
        onSelect: (i) { _onNavSelect(i); Navigator.pop(context); },
        onLogout: _logout,
      ),
      body: Column(children: [
        _TopBar(
          user: widget.user,
          onLogout: _logout,
          unreadCount: _unreadCount,
          onBellTap: () => _onNavSelect(5),
          onMenuTap: isWide ? null : () => Scaffold.of(context).openDrawer(),
        ),
        Expanded(
          child: isWide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _Sidebar(
                    items: _navItems,
                    selected: _selectedIndex,
                    unreadCount: _unreadCount,
                    onSelect: _onNavSelect,
                  ),
                  Expanded(child: _body()),
                ])
              : _body(),
        ),
      ]),
      bottomNavigationBar: isWide ? null : _BottomNav(
        items: _navItems,
        selected: _selectedIndex,
        unreadCount: _unreadCount,
        onSelect: _onNavSelect,
      ),
    );
  }

  Widget _body() {
    return switch (_selectedIndex) {
      0 => _HomeTab(user: widget.user, profile: widget.profile,
            enrollmentStatus: widget.enrollmentStatus),
      1 => _ProfileTab(profile: widget.profile, user: widget.user),
      2 => _EnrollmentTab(status: widget.enrollmentStatus, profile: widget.profile),
      3 => _ScolariteTab(profile: widget.profile, token: widget.token),
      4 => _DocumentsTab(
            profile: widget.profile,
            token: widget.token,
            requestsNotifier: documentRequestsNotifier,
          ),
      5 => _NotificationsTab(
            token: widget.token,
            notificationsNotifier: notificationsNotifier,
          ),
      6 => _SettingsTab(
            user: widget.user,
            profile: widget.profile,
            token: widget.token,
          ),
      _ => const SizedBox(),
    };
  }

  Future<void> _logout() async {
    await MySQLHelper.close();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Top bar
// ─────────────────────────────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  final UserModel user;
  final VoidCallback onLogout;
  final VoidCallback? onMenuTap;
  final VoidCallback? onBellTap;
  final int unreadCount;
  const _TopBar({
    required this.user,
    required this.onLogout,
    this.onMenuTap,
    this.onBellTap,
    this.unreadCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [_T.dark, _T.primary],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        boxShadow: [
          BoxShadow(
            color: _T.dark.withValues(alpha: 0.4),
            blurRadius: 12, offset: const Offset(0, 3)),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        if (onMenuTap != null)
          IconButton(
            icon: const Icon(Icons.menu_rounded, color: Colors.white),
            onPressed: onMenuTap),
        // Logo
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white24),
          ),
          alignment: Alignment.center,
          child: const Text('E', style: TextStyle(
              color: Colors.white, fontWeight: FontWeight.w900, fontSize: 18)),
        ),
        const SizedBox(width: 10),
        const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ETALIB', style: TextStyle(
                color: Colors.white, fontSize: 16,
                fontWeight: FontWeight.w900, letterSpacing: 2.5)),
            Text('Espace Numérique Étudiant', style: TextStyle(
                color: Colors.white60, fontSize: 10)),
          ],
        ),
        const Spacer(),
        // Bell
        _BadgeIconButton(
          icon: Icons.notifications_outlined,
          count: unreadCount,
          onTap: onBellTap,
        ),
        const SizedBox(width: 6),
        // User chip
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(radius: 13, backgroundColor: _T.light,
              child: Text(
                user.name.isNotEmpty ? user.name[0].toUpperCase() : 'E',
                style: const TextStyle(color: Colors.white,
                    fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 8),
            Text(user.name.split(' ').first,
                style: const TextStyle(color: Colors.white, fontSize: 13,
                    fontWeight: FontWeight.w500)),
          ]),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.logout_rounded, color: Colors.white60, size: 20),
          tooltip: 'Déconnexion',
          onPressed: onLogout,
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Badge icon button (bell in top bar)
// ─────────────────────────────────────────────────────────────────────────────
class _BadgeIconButton extends StatelessWidget {
  final IconData icon;
  final int count;
  final VoidCallback? onTap;
  const _BadgeIconButton({required this.icon, required this.count, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Stack(clipBehavior: Clip.none, children: [
          Icon(icon, color: Colors.white70, size: 24),
          if (count > 0)
            Positioned(
              top: -4, right: -4,
              child: Container(
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  count > 99 ? '99+' : '$count',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 9,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sidebar (wide)
// ─────────────────────────────────────────────────────────────────────────────
class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _NavItem(this.icon, this.activeIcon, this.label);
}

class _Sidebar extends StatelessWidget {
  final List<_NavItem> items;
  final int selected;
  final int unreadCount;
  final ValueChanged<int> onSelect;
  const _Sidebar({
    required this.items,
    required this.selected,
    required this.unreadCount,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [_T.dark, Color(0xFF0D6B44)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        boxShadow: [BoxShadow(
            color: Color(0x33000000), blurRadius: 16)],
      ),
      child: Column(children: [
        // Logo area inside sidebar
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
          child: Row(children: [
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(9),
              ),
              alignment: Alignment.center,
              child: const Text('E', style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w900,
                  fontSize: 16)),
            ),
            const SizedBox(width: 8),
            const Expanded(child: Text('ETALIB',
                style: TextStyle(color: Colors.white, fontSize: 14,
                    fontWeight: FontWeight.w800, letterSpacing: 1.5))),
          ]),
        ),
        Divider(color: Colors.white.withValues(alpha: 0.12), height: 1),
        const SizedBox(height: 8),
        ...items.asMap().entries.map((e) => _SidebarTile(
          item: e.value,
          isSelected: selected == e.key,
          badge: e.value.label == 'Notifications' ? unreadCount : 0,
          onTap: () => onSelect(e.key),
        )),
        const Spacer(),
        Divider(color: Colors.white.withValues(alpha: 0.12), height: 1),
        const SizedBox(height: 8),
      ]),
    );
  }
}

class _SidebarTile extends StatelessWidget {
  final _NavItem item;
  final bool isSelected;
  final int badge;
  final VoidCallback onTap;
  const _SidebarTile({
    required this.item,
    required this.isSelected,
    required this.onTap,
    this.badge = 0,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.white.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: isSelected
              ? Border.all(color: Colors.white.withValues(alpha: 0.2))
              : null,
        ),
        child: Row(children: [
          Stack(clipBehavior: Clip.none, children: [
            Icon(isSelected ? item.activeIcon : item.icon,
                color: isSelected ? Colors.white : Colors.white54,
                size: 20),
            if (badge > 0)
              Positioned(
                top: -5, right: -6,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color: Colors.red.shade500,
                    shape: BoxShape.circle,
                    border: Border.all(color: _T.dark, width: 1.5),
                  ),
                  alignment: Alignment.center,
                  child: Text(badge > 99 ? '99+' : '$badge',
                      style: const TextStyle(color: Colors.white,
                          fontSize: 8, fontWeight: FontWeight.w700)),
                ),
              ),
          ]),
          const SizedBox(width: 12),
          Expanded(child: Text(item.label, style: TextStyle(
            color: isSelected ? Colors.white : Colors.white60,
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.normal,
          ))),
          if (badge > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.red.shade500,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(badge > 99 ? '99+' : '$badge',
                  style: const TextStyle(color: Colors.white,
                      fontSize: 10, fontWeight: FontWeight.w700)),
            ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mobile drawer
// ─────────────────────────────────────────────────────────────────────────────
class _MobileDrawer extends StatelessWidget {
  final List<_NavItem> items;
  final int selected;
  final int unreadCount;
  final UserModel user;
  final ValueChanged<int> onSelect;
  final VoidCallback onLogout;
  const _MobileDrawer({
    required this.items,
    required this.selected,
    required this.unreadCount,
    required this.user,
    required this.onSelect,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [_T.dark, Color(0xFF0D6B44)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Column(children: [
            // User header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              child: Row(children: [
                Container(
                  width: 52, height: 52,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [_T.light, _T.primary],
                      begin: Alignment.topLeft, end: Alignment.bottomRight),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [BoxShadow(
                      color: _T.dark.withValues(alpha: 0.4),
                      blurRadius: 8, offset: const Offset(0, 3))],
                  ),
                  alignment: Alignment.center,
                  child: Text(user.name[0].toUpperCase(),
                      style: const TextStyle(color: Colors.white,
                          fontSize: 20, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 14),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(user.name,
                        style: const TextStyle(color: Colors.white,
                            fontWeight: FontWeight.w700, fontSize: 15),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(user.email,
                        style: const TextStyle(color: Colors.white54,
                            fontSize: 11),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                )),
              ]),
            ),
            Divider(color: Colors.white.withValues(alpha: 0.12), height: 1),
            const SizedBox(height: 6),
            // Nav items
            ...items.asMap().entries.map((e) => _SidebarTile(
              item: e.value,
              isSelected: selected == e.key,
              badge: e.value.label == 'Notifications' ? unreadCount : 0,
              onTap: () => onSelect(e.key),
            )),
            const Spacer(),
            Divider(color: Colors.white.withValues(alpha: 0.12), height: 1),
            // Logout
            ListTile(
              leading: Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.logout_rounded,
                    color: Colors.redAccent, size: 17),
              ),
              title: const Text('Déconnexion',
                  style: TextStyle(color: Colors.white70,
                      fontSize: 13, fontWeight: FontWeight.w500)),
              onTap: onLogout,
            ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bottom nav (mobile)
// ─────────────────────────────────────────────────────────────────────────────
class _BottomNav extends StatelessWidget {
  final List<_NavItem> items;
  final int selected;
  final int unreadCount;
  final ValueChanged<int> onSelect;
  const _BottomNav({
    required this.items,
    required this.selected,
    required this.unreadCount,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _T.dark,
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 12, offset: const Offset(0, -2))],
      ),
      child: NavigationBar(
        selectedIndex: selected,
        onDestinationSelected: onSelect,
        backgroundColor: Colors.transparent,
        indicatorColor: Colors.white.withValues(alpha: 0.18),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: items.asMap().entries.map((e) {
          final isNotif = e.value.label == 'Notifications';
          final showBadge = isNotif && unreadCount > 0;
          final iconWidget = showBadge
              ? Stack(clipBehavior: Clip.none, children: [
                  Icon(e.value.icon, size: 22, color: Colors.white60),
                  Positioned(top: -4, right: -6,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 15, minHeight: 15),
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: Colors.red.shade500, shape: BoxShape.circle,
                        border: Border.all(color: _T.dark, width: 1.5)),
                      alignment: Alignment.center,
                      child: Text(unreadCount > 99 ? '99+' : '$unreadCount',
                          style: const TextStyle(color: Colors.white,
                              fontSize: 8, fontWeight: FontWeight.w800)),
                    )),
                ])
              : Icon(e.value.icon, size: 22, color: Colors.white60);
          final activeIconWidget = showBadge
              ? Stack(clipBehavior: Clip.none, children: [
                  Icon(e.value.activeIcon, size: 22, color: Colors.white),
                  Positioned(top: -4, right: -6,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 15, minHeight: 15),
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: Colors.red.shade500, shape: BoxShape.circle,
                        border: Border.all(color: _T.dark, width: 1.5)),
                      alignment: Alignment.center,
                      child: Text(unreadCount > 99 ? '99+' : '$unreadCount',
                          style: const TextStyle(color: Colors.white,
                              fontSize: 8, fontWeight: FontWeight.w800)),
                    )),
                ])
              : Icon(e.value.activeIcon, size: 22, color: Colors.white);
          return NavigationDestination(
            icon: iconWidget,
            selectedIcon: activeIconWidget,
            label: e.value.label,
          );
        }).toList(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB 0 — Home / Accueil
// ─────────────────────────────────────────────────────────────────────────────
class _HomeTab extends StatelessWidget {
  final UserModel user;
  final StudentProfile? profile;
  final String? enrollmentStatus;
  const _HomeTab({required this.user, this.profile, this.enrollmentStatus});

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final crossCount = w > 900 ? 3 : (w > 550 ? 2 : 1);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Hero banner ──────────────────────────────────────────────────────
        _HeroBanner(user: user, enrollmentStatus: enrollmentStatus),
        const SizedBox(height: 24),

        // ── Quick stats row ──────────────────────────────────────────────────
        _sectionLabel('Vue d\'ensemble'),
        const SizedBox(height: 12),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: crossCount,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          childAspectRatio: 2.2,
          children: [
            _StatCard(Icons.assignment_turned_in_outlined,
                'Statut inscription', _statusLabel(enrollmentStatus),
                _statusColor(enrollmentStatus)),
            _StatCard(Icons.school_outlined, 'Filière',
                profile?.chosenTrack ?? '—', _T.primary),
            _StatCard(Icons.grade_outlined, 'Note du l annee Precedent',
                profile != null ? '${profile!.bacGrade}/20' : '—', _T.light),
            _StatCard(Icons.calendar_today_outlined, 'Année de niveau precedent',
                profile?.bacYear.toString() ?? '—', _T.dark),
          ],
        ),
        const SizedBox(height: 24),

        // ── Quick access tiles ────────────────────────────────────────────────
        // _sectionLabel('Accès rapide'),
        // const SizedBox(height: 12),
        // GridView.count(
        //   shrinkWrap: true,
        //   physics: const NeverScrollableScrollPhysics(),
        //   crossAxisCount: crossCount,
        //   mainAxisSpacing: 14,
        //   crossAxisSpacing: 14,
        //   childAspectRatio: 1.6,
        //   children: const [
        //     _QuickTile(Icons.person_outline,       'Mon Profil',       _T.primary),
        //     _QuickTile(Icons.assignment_outlined,  'Mon Inscription',  Color(0xFF1565C0)),
        //     _QuickTile(Icons.school_outlined,      'Ma Scolarité',     Color(0xFF6A1B9A)),
        //     _QuickTile(Icons.description_outlined, 'Mes Documents',    Color(0xFFE65100)),
        //     _QuickTile(Icons.calendar_today,       'Emploi du temps',  Color(0xFF00838F)),
        //     _QuickTile(Icons.notifications_outlined,'Notifications',   Color(0xFF558B2F)),
        //   ],
        // ),
        const SizedBox(height: 24),

        // ── Info banner if no profile ─────────────────────────────────────────
        if (profile == null) _NoBanner(),
      ]),
    );
  }

  Widget _sectionLabel(String t) => Text(t, style: const TextStyle(
      fontSize: 14, fontWeight: FontWeight.w700, color: _T.text, letterSpacing: 0.3));

  String _statusLabel(String? s) => switch (s) {
    'approved' => 'Acceptée',
    'rejected' => 'Refusée',
    'pending'  => 'En attente',
    _          => 'Non soumise',
  };

  Color _statusColor(String? s) => switch (s) {
    'approved' => const Color(0xFF2E7D32),
    'rejected' => const Color(0xFFC62828),
    'pending'  => const Color(0xFFE65100),
    _          => _T.sub,
  };
}

class _HeroBanner extends StatelessWidget {
  final UserModel user;
  final String? enrollmentStatus;
  const _HeroBanner({required this.user, this.enrollmentStatus});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [_T.dark, _T.primary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(
          color: _T.primary.withValues(alpha: 0.3),
          blurRadius: 12, offset: const Offset(0, 4),
        )],
      ),
      child: Row(children: [
        CircleAvatar(
          radius: 36,
          backgroundColor: Colors.white.withValues(alpha: 0.15),
          child: Text(
            user.name.isNotEmpty ? user.name[0].toUpperCase() : 'E',
            style: const TextStyle(fontSize: 28, color: Colors.white,
                fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Bonjour, ${user.name.split(' ').first} 👋',
                style: const TextStyle(color: Colors.white,
                    fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(user.email,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 6, children: [
              _Chip(user.role == 'admin' ? 'Administrateur' : 'Étudiant',
                  Colors.white24),
              _Chip(_enrollLabel(enrollmentStatus),
                  _enrollColor(enrollmentStatus)),
            ]),
          ],
        )),
      ]),
    );
  }

  String _enrollLabel(String? s) => switch (s) {
    'approved' => '✓ Inscription acceptée',
    'rejected' => '✗ Inscription refusée',
    'pending'  => '⏳ En attente',
    _          => '○ Non inscrit',
  };

  Color _enrollColor(String? s) => switch (s) {
    'approved' => const Color(0xFF1B5E20),
    'rejected' => const Color(0xFFB71C1C),
    'pending'  => const Color(0xFFBF360C),
    _          => Colors.white24,
  };
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  const _Chip(this.label, this.color);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
  );
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _StatCard(this.icon, this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      boxShadow: [BoxShadow(
          color: Colors.black.withValues(alpha: 0.05),
          blurRadius: 6, offset: const Offset(0, 2))],
    ),
    child: Row(children: [
      Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: color, size: 20),
      ),
      const SizedBox(width: 12),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: const TextStyle(
              fontSize: 11, color: _T.sub, fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(
              fontSize: 14, color: _T.text, fontWeight: FontWeight.w700),
            overflow: TextOverflow.ellipsis),
        ],
      )),
    ]),
  );
}

class _NoBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.orange.shade50,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.orange.shade200),
    ),
    child: Row(children: [
      Icon(Icons.info_outline, color: Colors.orange.shade700),
      const SizedBox(width: 12),
      const Expanded(child: Text(
        'Votre profil étudiant est incomplet. Veuillez compléter votre dossier de préinscription.',
        style: TextStyle(fontSize: 13),
      )),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB 1 — Mon Profil
// ─────────────────────────────────────────────────────────────────────────────
class _ProfileTab extends StatelessWidget {
  final StudentProfile? profile;
  final UserModel user;
  const _ProfileTab({this.profile, required this.user});

  @override
  Widget build(BuildContext context) {
    if (profile == null) {
      return const Center(child: _EmptyState(
          Icons.person_off_outlined, 'Profil non renseigné'));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Avatar header
        _ProfileHeader(profile: profile!, email: user.email),
        const SizedBox(height: 20),

        _SectionCard('Informations personnelles', Icons.badge_outlined, [
          _Row('Prénom', profile!.firstName),
          _Row('Nom', profile!.lastName),
          if (profile!.firstNameAr != null)
            _Row('الاسم الشخصي', profile!.firstNameAr!),
          if (profile!.lastNameAr != null)
            _Row('اسم العائلة', profile!.lastNameAr!),
          if (profile!.cin != null) _Row('CIN', profile!.cin!),
          _Row('Code Massar', profile!.massarCode),
          _Row('Date de naissance', profile!.birthDate),
          _Row('Lieu de naissance', profile!.birthPlace),
          _Row('Téléphone', profile!.phone),
          _Row('Adresse', profile!.address),
          _Row('Ville', profile!.city),
        ]),
        const SizedBox(height: 16),

        // _SectionCard('Baccalauréat', Icons.school_outlined, [
        //   _Row('Établissement', profile!.previousSchool),
        //   _Row('Année', profile!.bacYear.toString()),
        //   _Row('Note', '${profile!.bacGrade}/20'),
        //   _Row('Filière choisie', profile!.chosenTrack),
        // ]),
        // const SizedBox(height: 16),

        _SectionCard('Responsable légal', Icons.family_restroom_outlined, [
          _Row('Nom', profile!.guardianName),
          _Row('Lien de parenté', profile!.guardianRelation),
          _Row('Téléphone', profile!.guardianPhone),
        ]),
      ]),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  final StudentProfile profile;
  final String email;
  const _ProfileHeader({required this.profile, required this.email});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [_T.dark, _T.primary],
        begin: Alignment.topLeft, end: Alignment.bottomRight,
      ),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(children: [
      CircleAvatar(
        radius: 34,
        backgroundColor: Colors.white.withValues(alpha: 0.2),
        child: Text(profile.firstName[0].toUpperCase(),
            style: const TextStyle(fontSize: 26, color: Colors.white,
                fontWeight: FontWeight.bold)),
      ),
      const SizedBox(width: 16),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(profile.fullName, style: const TextStyle(
              color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(email, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 6),
          if (profile.cin != null)
            Text('CIN: ${profile.cin}',
                style: const TextStyle(color: Colors.white60, fontSize: 12)),
          Text('Massar: ${profile.massarCode}',
              style: const TextStyle(color: Colors.white60, fontSize: 12)),
        ],
      )),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB 2 — Inscription
// ─────────────────────────────────────────────────────────────────────────────
class _EnrollmentTab extends StatelessWidget {
  final String? status;
  final StudentProfile? profile;
  const _EnrollmentTab({this.status, this.profile});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'approved' => const Color(0xFF2E7D32),
      'rejected' => const Color(0xFFC62828),
      'pending'  => const Color(0xFFE65100),
      _          => _T.sub,
    };
    final icon = switch (status) {
      'approved' => Icons.check_circle_outline,
      'rejected' => Icons.cancel_outlined,
      'pending'  => Icons.hourglass_top_outlined,
      _          => Icons.radio_button_unchecked,
    };
    final label = switch (status) {
      'approved' => 'Inscription Acceptée',
      'rejected' => 'Inscription Refusée',
      'pending'  => 'En cours de traitement',
      _          => 'Aucune demande soumise',
    };
    final desc = switch (status) {
      'approved' => 'Félicitations ! Votre demande d\'inscription a été acceptée. Vous pouvez maintenant accéder à tous les services.',
      'rejected' => 'Votre demande a été refusée. Veuillez contacter l\'administration pour plus d\'informations.',
      'pending'  => 'Votre dossier est en cours d\'examen par l\'administration. Vous serez notifié dès qu\'une décision est prise.',
      _          => 'Vous n\'avez pas encore soumis de demande d\'inscription. Veuillez compléter votre profil.',
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(children: [
        // Status card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 8)],
          ),
          child: Column(children: [
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 40),
            ),
            const SizedBox(height: 16),
            Text(label, style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 10),
            Text(desc, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: _T.sub, height: 1.6)),
          ]),
        ),
        const SizedBox(height: 20),

        // Filière info if profile exists
        if (profile != null)
          _SectionCard('Détails de la demande', Icons.assignment_outlined, [
            _Row('Filière demandée', profile!.chosenTrack),
            _Row('Établissement précédent', profile!.previousSchool),
            _Row('Note du l annee Precedent', '${profile!.bacGrade}/20'),
            _Row('Année du l annee Precedent', profile!.bacYear.toString()),
          ]),

        const SizedBox(height: 20),

        // Steps timeline
        _SectionCard('Étapes de votre dossier', Icons.timeline_outlined, [
          _TimelineStep('Création du compte', true),
          _TimelineStep('Remplissage du profil', profile != null),
          _TimelineStep('Soumission du dossier', status != null),
          _TimelineStep('Examen par l\'administration',
              status == 'approved' || status == 'rejected'),
          _TimelineStep('Décision finale', status == 'approved'),
        ]),
      ]),
    );
  }
}

class _TimelineStep extends StatelessWidget {
  final String label;
  final bool done;
  const _TimelineStep(this.label, this.done);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(children: [
      Icon(done ? Icons.check_circle : Icons.radio_button_unchecked,
          color: done ? _T.primary : _T.sub, size: 20),
      const SizedBox(width: 12),
      Text(label, style: TextStyle(
          fontSize: 13,
          color: done ? _T.text : _T.sub,
          fontWeight: done ? FontWeight.w600 : FontWeight.normal)),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB 3 — Scolarité  (emploi du temps depuis DB + parcours)
// ─────────────────────────────────────────────────────────────────────────────
class _ScolariteTab extends StatefulWidget {
  final StudentProfile? profile;
  final String? token;
  const _ScolariteTab({this.profile, this.token});

  @override
  State<_ScolariteTab> createState() => _ScolariteTabState();
}

class _ScolariteTabState extends State<_ScolariteTab>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  TimetableResult? _timetable;
  bool _loading = true;
  bool _downloadingPdf = false;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _loadTimetable();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadTimetable() async {
    if (widget.token == null) { setState(() => _loading = false); return; }
    setState(() => _loading = true);
    final result = await MySQLHelper.getTimetable(widget.token!);
    if (mounted) setState(() { _timetable = result; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Container(
        color: Colors.white,
        child: TabBar(
          controller: _tabCtrl,
          labelColor: _T.primary,
          unselectedLabelColor: _T.sub,
          indicatorColor: _T.primary,
          indicatorWeight: 3,
          labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          tabs: const [
            Tab(text: 'Emploi du temps'),
            Tab(text: 'Parcours académique'),
          ],
        ),
      ),
      Expanded(
        child: TabBarView(
          controller: _tabCtrl,
          children: [
            _TimetableView(
              timetable: _timetable,
              loading: _loading,
              downloading: _downloadingPdf,
              onRefresh: _loadTimetable,
              onDownload: _downloadTimetable,
            ),
            _ParcourView(profile: widget.profile, token: widget.token),
          ],
        ),
      ),
    ]);
  }

  Future<void> _downloadTimetable() async {
    if (_timetable == null || _timetable!.entries.isEmpty) return;
    setState(() => _downloadingPdf = true);

    final pdfBytes = await _TimetablePdfGenerator.generate(
      timetable: _timetable!,
    );

    setState(() => _downloadingPdf = false);
    if (!mounted) return;

    final filename = 'Emploi_du_temps_${DateTime.now().millisecondsSinceEpoch}.pdf';

    if (kIsWeb) {
      final b64 = base64Encode(pdfBytes);
      await launchUrl(Uri.parse('data:application/pdf;base64,$b64'));
    } else {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(pdfBytes, flush: true);
      final uri = Uri.file(file.path);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('PDF sauvegardé : ${file.path}'),
          backgroundColor: _T.primary,
        ));
      }
    }
  }
}

// ── Timetable view ────────────────────────────────────────────────────────────
class _TimetableView extends StatelessWidget {
  final TimetableResult? timetable;
  final bool loading;
  final bool downloading;
  final VoidCallback onRefresh;
  final VoidCallback onDownload;
  const _TimetableView({
    this.timetable,
    required this.loading,
    required this.downloading,
    required this.onRefresh,
    required this.onDownload,
  });

  static const _kDays = [
    'Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi'
  ];

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // ── Header: title + download button ────────────────────────────────
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                timetable?.className != null
                    ? '${timetable!.className} — ${timetable!.academicYear ?? ''}'
                    : 'Emploi du temps',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700, color: _T.text),
              ),
              Text(
                timetable?.track ?? 'Lycée Qualifiant — Maroc',
                style: const TextStyle(fontSize: 11, color: _T.sub),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.refresh, color: _T.sub),
            tooltip: 'Actualiser',
            onPressed: onRefresh,
          ),
          ElevatedButton.icon(
            onPressed: (downloading || loading ||
                    (timetable?.entries.isEmpty ?? true))
                ? null
                : onDownload,
            style: ElevatedButton.styleFrom(
              backgroundColor: _T.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              elevation: 0,
            ),
            icon: downloading
                ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.download_outlined, size: 18),
            label: Text(downloading ? 'PDF...' : 'Télécharger PDF',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),

      // ── Content ─────────────────────────────────────────────────────────
      Expanded(child: _buildContent()),
    ]);
  }

  Widget _buildContent() {
    if (loading) {
      return const Center(child: CircularProgressIndicator(color: _T.primary));
    }
    if (timetable == null || timetable!.entries.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.calendar_today_outlined,
              size: 48, color: _T.sub.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          const Text('Aucun emploi du temps disponible.',
              style: TextStyle(color: _T.sub, fontSize: 14)),
          const SizedBox(height: 6),
          const Text('Contactez l\'administration.',
              style: TextStyle(color: _T.sub, fontSize: 12)),
        ]),
      );
    }

    // Build time slots from DB data (unique, sorted)
    final allSlots = timetable!.entries
        .map((e) => '${e.startTime}|${e.endTime}')
        .toSet()
        .toList()
      ..sort();
    final slots = allSlots
        .map((s) => s.split('|'))
        .toList(); // [[start, end], ...]

    // Map: day → slot_key → entry
    final Map<String, Map<String, TimetableEntry>> grid = {};
    for (final e in timetable!.entries) {
      final key = '${e.startTime}|${e.endTime}';
      grid[e.dayOfWeek] ??= {};
      grid[e.dayOfWeek]![key] = e;
    }

    const dayColW = 88.0;
    const slotColW = 130.0;
    const rowH = 84.0;
    const headerH = 48.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade300),
            boxShadow: [BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 8, offset: const Offset(0, 2))],
          ),
          child: Column(children: [
            // Time slot header row
            Row(children: [
              // Corner
              Container(
                width: dayColW, height: headerH,
                decoration: BoxDecoration(
                  color: const Color(0xFF0E7A50).withValues(alpha: 0.1),
                  border: Border(
                    right: BorderSide(color: Colors.grey.shade300),
                    bottom: BorderSide(color: Colors.grey.shade300),
                  ),
                ),
              ),
              ...slots.map((s) {
                final start = s[0].substring(0, 5).replaceAll(':', 'h');
                final end = s[1].substring(0, 5).replaceAll(':', 'h');
                return Container(
                  width: slotColW, height: headerH,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0E7A50).withValues(alpha: 0.08),
                    border: Border(
                      left: BorderSide(color: Colors.grey.shade300),
                      bottom: BorderSide(color: Colors.grey.shade300),
                    ),
                  ),
                  child: Text('$start - $end',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w700,
                        color: Color(0xFF0E7A50))),
                );
              }),
            ]),
            // Day rows
            ..._kDays.map((day) => Row(children: [
              // Day label
              Container(
                width: dayColW, height: rowH,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF9C4).withValues(alpha: 0.8),
                  border: Border(
                    right: BorderSide(color: Colors.grey.shade300),
                    bottom: BorderSide(color: Colors.grey.shade300),
                  ),
                ),
                child: Text(day, style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700,
                    color: Color(0xFF1A1A1A))),
              ),
              // Slot cells
              ...slots.map((s) {
                final key = '${s[0]}|${s[1]}';
                final entry = grid[day]?[key];
                return Container(
                  width: slotColW, height: rowH,
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: entry != null
                        ? const Color(0xFFFFF9C4)
                        : Colors.white,
                    border: Border(
                      left: BorderSide(color: Colors.grey.shade300),
                      bottom: BorderSide(color: Colors.grey.shade300),
                    ),
                  ),
                  child: entry != null
                      ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text(entry.subject,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w700,
                                color: Color(0xFF1A1A1A))),
                          if (entry.teacherName != null) ...[
                            const SizedBox(height: 2),
                            Text(entry.teacherName!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 9, color: Color(0xFF555555))),
                          ],
                          if (entry.room != null)
                            Text(entry.room!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 9, color: Color(0xFF555555),
                                  fontStyle: FontStyle.italic)),
                        ])
                      : const SizedBox(),
                );
              }),
            ])),
          ]),
        ),
      ),
    );
  }
}

// ── Parcours view ─────────────────────────────────────────────────────────────
class _ParcourView extends StatefulWidget {
  final StudentProfile? profile;
  final String? token;
  const _ParcourView({this.profile, this.token});

  @override
  State<_ParcourView> createState() => _ParcourViewState();
}

class _ParcourViewState extends State<_ParcourView> {
  List<ConvocationModel> _convocations = [];
  bool _loadingConvoc = true;
  bool _downloadingConvocPdf = false;
  String? _convocError;

  @override
  void initState() {
    super.initState();
    _loadConvocations();
  }

  Future<void> _loadConvocations() async {
    if (widget.token == null) {
      setState(() { _loadingConvoc = false; _convocError = 'Non connecté.'; });
      return;
    }
    setState(() { _loadingConvoc = true; _convocError = null; });
    try {
      final list = await MySQLHelper.getConvocations(widget.token!);
      if (mounted) setState(() { _convocations = list; _loadingConvoc = false; });
    } catch (e) {
      if (mounted) setState(() { _loadingConvoc = false; _convocError = 'Erreur: $e'; });
    }
  }

  Future<void> _downloadConvocPdf() async {
    if (_convocations.isEmpty) return;
    setState(() => _downloadingConvocPdf = true);

    final pdfBytes = await _ConvocationPdfGenerator.generate(
      convocations: _convocations,
      profile: widget.profile,
    );

    setState(() => _downloadingConvocPdf = false);
    if (!mounted) return;

    final filename =
        'Convocation_examens_${DateTime.now().millisecondsSinceEpoch}.pdf';

    if (kIsWeb) {
      final b64 = base64Encode(pdfBytes);
      await launchUrl(Uri.parse('data:application/pdf;base64,$b64'));
    } else {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(pdfBytes, flush: true);
      final uri = Uri.file(file.path);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('PDF sauvegardé : ${file.path}'),
          backgroundColor: _T.primary,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.profile == null) {
      return const Center(child: _EmptyState(
          Icons.school_outlined, 'Aucune information de scolarité'));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        _SectionCard('Parcours académique', Icons.school_outlined, [
          _Row('Filière choisie', widget.profile!.chosenTrack),
          _Row('Établissement précédent', widget.profile!.previousSchool),
          _Row('Année du Niveau Precedent', widget.profile!.bacYear.toString()),
          _Row('Note du l annee Precedent', '${widget.profile!.bacGrade}/20'),
        ]),
        const SizedBox(height: 16),
        _GradesCard(token: widget.token),
        const SizedBox(height: 12),
        _ConvocationCard(
          loading: _loadingConvoc,
          error: _convocError,
          convocations: _convocations,
          onRefresh: _loadConvocations,
          downloading: _downloadingConvocPdf,
          onDownload: _downloadConvocPdf,
        ),
        const SizedBox(height: 12),
        _AbsenceCard(token: widget.token),
      ]),
    );
  }
}

// ── Grades card ───────────────────────────────────────────────────────────────
class _GradesCard extends StatefulWidget {
  final String? token;
  const _GradesCard({this.token});
  @override
  State<_GradesCard> createState() => _GradesCardState();
}

class _GradesCardState extends State<_GradesCard> {
  List<SemestreGrades> _semestres = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    if (widget.token == null) {
      setState(() { _loading = false; _error = 'Non connecté.'; });
      return;
    }
    setState(() { _loading = true; _error = null; });
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      // Desktop – use direct DB fetch with stored user ID
      final userId = MySQLHelper.currentUserId;
      if (userId != null) {
        final list = await MySQLHelper.getGradesViaDb(userId);
        if (mounted) setState(() { _semestres = list; _loading = false; });
        return;
      }
    }
    // Fallback – use API token based fetch
    final list = await MySQLHelper.getGrades(widget.token!);
    if (mounted) setState(() { _semestres = list; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(children: [
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: _T.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.grade_outlined, color: _T.primary, size: 18),
            ),
            const SizedBox(width: 10),
            const Expanded(child: Text('Résultats & Notes',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
            IconButton(
              icon: Icon(Icons.refresh, color: _T.sub, size: 20),
              tooltip: 'Actualiser',
              onPressed: _loading ? null : _load,
            ),
          ]),
        ),
        const Divider(height: 1),

        if (_loading)
          const Padding(
            padding: EdgeInsets.all(28),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Center(child: Column(children: [
              Icon(Icons.error_outline, color: Colors.red.shade300, size: 36),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.red.shade400, fontSize: 13)),
            ])),
          )
        else if (_semestres.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Center(child: Column(children: [
              Icon(Icons.grade_outlined,
                  color: _T.sub.withValues(alpha: 0.4), size: 40),
              const SizedBox(height: 10),
              Text('Aucune note disponible pour le moment.',
                  style: TextStyle(color: _T.sub, fontSize: 13)),
            ])),
          )
        else
          // One table per semestre
          ...List.generate(_semestres.length, (i) {
            final sem = _semestres[i];
            return Padding(
              padding: EdgeInsets.only(
                  bottom: i < _semestres.length - 1 ? 20 : 0),
              child: _GradesTable(sem: sem),
            );
          }),
        const SizedBox(height: 4),
      ]),
    );
  }
}

// ── Grades table for one semestre ─────────────────────────────────────────────
class _GradesTable extends StatelessWidget {
  final SemestreGrades sem;
  const _GradesTable({required this.sem});

  // Colours from the reference screenshot
  static const _headerBg    = Color(0xFF3D5A9B); // dark blue header row
  static const _subHeaderBg = Color(0xFF4D6AB5); // sub-header row
  static const _reclamBg    = Color(0xFF3D5A9B); // réclamation header cell
  static const _reponseBg   = Color(0xFF3D5A9B); // réponse header cell
  static const _rowOdd      = Color(0xFFFFFFFF);
  static const _rowEven     = Color(0xFFF7F9FC);
  static const _borderColor = Color(0xFFDDE3EE);

  String _fmt(double? v) => v == null ? '' : v.toString();

  @override
  Widget build(BuildContext context) {
    // Semester result color
    final resColor = switch (sem.resultat) {
      'VAL' || 'VAR' => _T.primary,
      'AJ'           => Colors.orange.shade700,
      _              => Colors.red.shade600,
    };

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Semestre title band
      Container(
        color: _headerBg,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(children: [
          Expanded(child: Text(sem.semestre,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700,
                  fontSize: 14))),
          if (sem.noteFinale != null || sem.resultat != null)
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (sem.noteFinale != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('Moy: ${_fmt(sem.noteFinale)}',
                      style: const TextStyle(color: Colors.white,
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              if (sem.resultat != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: resColor.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(sem.resultat!,
                      style: const TextStyle(color: Colors.white,
                          fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              ],
            ]),
        ]),
      ),

      // Horizontal scroll for the table
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(
              minWidth: MediaQuery.of(context).size.width - 32),
          child: Table(
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: TableBorder.all(color: _borderColor, width: 0.6),
            columnWidths: const {
              0: FixedColumnWidth(88),   // N° Module
              1: FlexColumnWidth(3),     // Élément de module
              2: FixedColumnWidth(72),   // Note SS1
              3: FixedColumnWidth(72),   // Note SS2
              4: FixedColumnWidth(82),   // Note finale
              5: FixedColumnWidth(90),   // Appréciation
              6: FixedColumnWidth(96),   // Réclamation
              7: FixedColumnWidth(82),   // Note trouvée
              8: FixedColumnWidth(80),   // Réponse
            },
            children: [
              // ── Column headers ──────────────────────────────────────
              TableRow(
                decoration: const BoxDecoration(color: _subHeaderBg),
                children: [
                  _th('N° Module'),
                  _th('Élément de module'),
                  _th('Note SS1'),
                  _th('Note SS2'),
                  _th('Note finale'),
                  _th('Appréciation'),
                  // Réclamation spans logically — we use a custom cell
                  _thCenter('Réclamation', bg: _reclamBg),
                  _thCenter('Note trouvée', bg: _reponseBg),
                  _thCenter('Réponse',      bg: _reponseBg),
                ],
              ),
              // ── Data rows ───────────────────────────────────────────
              ...sem.modules.asMap().entries.map((entry) {
                final i = entry.key;
                final row = entry.value;
                final bg = i.isEven ? _rowOdd : _rowEven;

                // Highlight VAR note finale in orange
                final nfColor = row.resultat == 'VAR'
                    ? Colors.orange.shade700
                    : _T.text;

                return TableRow(
                  decoration: BoxDecoration(color: bg),
                  children: [
                    _td(row.numeroModule > 0
                        ? 'HLGE${(row.numeroModule * 100).toString()}'
                        : '—'),
                    _tdLeft(row.elementPedagogique),
                    _td(_fmt(row.noteSs1)),
                    _td(_fmt(row.noteSs2)),
                    _tdColor(_fmt(row.noteFinale), nfColor),
                    _td(row.resultat ?? ''),
                    // Réclamation status
                    _tdWidget(row.reclamationStatus == 'enregistre'
                        ? _ReclamBadge()
                        : const SizedBox.shrink()),
                    // Note trouvée
                    _td(_fmt(row.noteTrouvee)),
                    // Réponse
                    _td(row.reponse ?? ''),
                  ],
                );
              }),
            ],
          ),
        ),
      ),
    ]);
  }

  // ── Table cell helpers ──────────────────────────────────────────────────────
  static Widget _th(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    child: Text(text,
        style: const TextStyle(
            color: Colors.white, fontSize: 11,
            fontWeight: FontWeight.w700)),
  );

  static Widget _thCenter(String text, {Color bg = _subHeaderBg}) =>
      ColoredBox(
        color: bg,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          child: Text(text, textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white, fontSize: 11,
                  fontWeight: FontWeight.w700)),
        ),
      );

  static Widget _td(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    child: Text(text, textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, color: _T.text)),
  );

  static Widget _tdLeft(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    child: Text(text,
        style: const TextStyle(fontSize: 12, color: _T.text)),
  );

  static Widget _tdColor(String text, Color color) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    child: Text(text, textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: color,
            fontWeight: FontWeight.w600)),
  );

  static Widget _tdWidget(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
    child: Center(child: child),
  );
}

// ── Réclamation "Enregistré" badge ────────────────────────────────────────────
class _ReclamBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: const Color(0xFF00BCD4),
      borderRadius: BorderRadius.circular(4),
    ),
    child: const Text('Enregistré',
        style: TextStyle(color: Colors.white, fontSize: 10,
            fontWeight: FontWeight.w700)),
  );
}

// ── Absence card ──────────────────────────────────────────────────────────────
class _AbsenceCard extends StatefulWidget {
  final String? token;
  const _AbsenceCard({this.token});

  @override
  State<_AbsenceCard> createState() => _AbsenceCardState();
}

class _AbsenceCardState extends State<_AbsenceCard> {
  List<AbsenceModel> _absences = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.token == null) {
      setState(() { _loading = false; _error = 'Non connecté.'; });
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final list = await MySQLHelper.getAbsences(widget.token!);
      if (mounted) setState(() { _absences = list; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Erreur: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Summary counts
    final total      = _absences.length;
    final justified  = _absences.where((a) => a.isJustified).length;
    final unjustified = total - justified;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Header ──────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(children: [
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.event_busy_outlined,
                  color: Colors.orange, size: 18),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text('Absences',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            ),
            IconButton(
              icon: Icon(Icons.refresh, color: _T.sub, size: 20),
              tooltip: 'Actualiser',
              onPressed: _loading ? null : _load,
            ),
          ]),
        ),
        const Divider(height: 1),

        // ── Summary chips (only when data loaded) ────────────────────────────
        if (!_loading && _error == null && total > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(children: [
              _AbsenceChip('$total Total', Colors.blueGrey),
              const SizedBox(width: 8),
              _AbsenceChip('$justified Justifiée${justified > 1 ? 's' : ''}',
                  const Color(0xFF2E7D32)),
              const SizedBox(width: 8),
              if (unjustified > 0)
                _AbsenceChip(
                    '$unjustified Non justifiée${unjustified > 1 ? 's' : ''}',
                    Colors.red.shade600),
            ]),
          ),

        // ── Body ─────────────────────────────────────────────────────────────
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(28),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Center(child: Column(children: [
              Icon(Icons.error_outline, color: Colors.red.shade300, size: 36),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.red.shade400, fontSize: 13)),
            ])),
          )
        else if (_absences.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
            child: Center(child: Column(children: [
              Icon(Icons.check_circle_outline,
                  color: _T.primary.withValues(alpha: 0.5), size: 40),
              const SizedBox(height: 10),
              Text('Aucune absence enregistrée.',
                  style: TextStyle(color: _T.sub, fontSize: 13)),
            ])),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _absences.length,
            separatorBuilder: (context, index) =>
                const Divider(height: 1, indent: 16),
            itemBuilder: (_, i) => _AbsenceTile(
              absence: _absences[i],
              token: widget.token,
              onJustified: (updated) {
                setState(() {
                  _absences[i] = updated;
                });
              },
            ),
          ),
      ]),
    );
  }
}

// ── Small summary chip ────────────────────────────────────────────────────────
class _AbsenceChip extends StatelessWidget {
  final String label;
  final Color color;
  const _AbsenceChip(this.label, this.color);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
            color: color)),
  );
}

// ── Single absence row ────────────────────────────────────────────────────────
class _AbsenceTile extends StatelessWidget {
  final AbsenceModel absence;
  final String? token;
  final ValueChanged<AbsenceModel> onJustified;
  const _AbsenceTile({
    required this.absence,
    required this.token,
    required this.onJustified,
  });

  @override
  Widget build(BuildContext context) {
    final color = absence.isJustified
        ? const Color(0xFF2E7D32)
        : Colors.red.shade600;
    final icon  = absence.isJustified
        ? Icons.check_circle_outline
        : Icons.cancel_outlined;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Date badge
        Container(
          width: 46, height: 46,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(absence.dateLabel.split(' ').first,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800,
                    color: color)),
            Text(absence.dateLabel.split(' ').elementAtOrNull(1) ?? '',
                style: TextStyle(fontSize: 10, color: _T.sub)),
          ]),
        ),
        const SizedBox(width: 12),
        // Content
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(
                  absence.subject ?? absence.timeSlot,
                  style: const TextStyle(fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
              ),
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 4),
              Text(absence.isJustified ? 'Justifiée' : 'Non justifiée',
                  style: TextStyle(fontSize: 11, color: color,
                      fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 3),
            Wrap(spacing: 8, runSpacing: 2, children: [
              Text(absence.timeSlot,
                  style: TextStyle(fontSize: 11, color: _T.sub)),
              if (absence.className.isNotEmpty)
                Text('• ${absence.className}',
                    style: TextStyle(fontSize: 11, color: _T.sub)),
            ]),
            // Justification preview
            if (absence.isJustified && absence.justificationReason != null) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF2E7D32).withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(children: [
                  Icon(Icons.notes_outlined, size: 13,
                      color: const Color(0xFF2E7D32)),
                  const SizedBox(width: 6),
                  Expanded(child: Text(absence.justificationReason!,
                      style: const TextStyle(fontSize: 11, color: _T.sub),
                      maxLines: 2, overflow: TextOverflow.ellipsis)),
                ]),
              ),
            ],
            // Justify button for unjustified absences
            if (!absence.isJustified) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 34,
                child: ElevatedButton.icon(
                  onPressed: () =>
                      _showJustifySheet(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _T.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.upload_file_outlined, size: 16),
                  label: const Text('Justifier',
                      style: TextStyle(fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ],
        )),
      ]),
    );
  }

  void _showJustifySheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _JustifySheet(
        absence: absence,
        token: token,
        onSuccess: onJustified,
      ),
    );
  }
}

// ── Justification bottom sheet ────────────────────────────────────────────────
class _JustifySheet extends StatefulWidget {
  final AbsenceModel absence;
  final String? token;
  final ValueChanged<AbsenceModel> onSuccess;
  const _JustifySheet({
    required this.absence,
    required this.token,
    required this.onSuccess,
  });

  @override
  State<_JustifySheet> createState() => _JustifySheetState();
}

class _JustifySheetState extends State<_JustifySheet> {
  final _reasonCtrl = TextEditingController();
  PlatformFile? _pickedFile;
  bool _submitting = false;

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'gif'],
      withData: false,
      withReadStream: false,
    );
    if (result != null && result.files.isNotEmpty) {
      setState(() => _pickedFile = result.files.first);
    }
  }

  void _removeFile() => setState(() => _pickedFile = null);

  Future<void> _submit() async {
    final reason = _reasonCtrl.text.trim();
    if (reason.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Veuillez saisir un motif de justification.'),
        backgroundColor: Colors.red,
      ));
      return;
    }
    if (widget.token == null) return;

    setState(() => _submitting = true);

    final res = await MySQLHelper.submitJustification(
      token: widget.token!,
      absenceId: widget.absence.id,
      reason: reason,
      filePath: _pickedFile?.path,
      fileName: _pickedFile?.name,
    );

    if (!mounted) return;
    setState(() => _submitting = false);

    if (res.success) {
      // Build an updated absence to reflect in the list
      final updated = AbsenceModel(
        id: widget.absence.id,
        academicYear: widget.absence.academicYear,
        className: widget.absence.className,
        date: widget.absence.date,
        timeSlot: widget.absence.timeSlot,
        subject: widget.absence.subject,
        status: 'justified',
        justificationReason: reason,
        justifiedAt: DateTime.now().toIso8601String(),
        attachmentUrl: res.absence?.attachmentUrl,
        comments: widget.absence.comments,
      );
      widget.onSuccess(updated);
      if (mounted) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(res.message),
        backgroundColor: _T.primary,
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(res.message),
        backgroundColor: Colors.red,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(20, 24, 20, 24 + bottomInset),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
        // Handle
        Center(child: Container(
          width: 40, height: 4,
          decoration: BoxDecoration(
            color: Colors.grey.shade300,
            borderRadius: BorderRadius.circular(2),
          ),
        )),
        const SizedBox(height: 20),

        // Title
        Row(children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              color: _T.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.upload_file_outlined,
                color: _T.primary, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Justifier une absence',
                  style: TextStyle(fontSize: 15,
                      fontWeight: FontWeight.w700)),
              Text(
                '${widget.absence.dateLabel} • ${widget.absence.subject ?? widget.absence.timeSlot}',
                style: TextStyle(fontSize: 12, color: _T.sub),
              ),
            ],
          )),
        ]),
        const SizedBox(height: 20),

        // Reason field
        const Text('Motif *',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        TextFormField(
          controller: _reasonCtrl,
          maxLines: 3,
          maxLength: 500,
          decoration: InputDecoration(
            hintText: 'Expliquez la raison de votre absence...',
            hintStyle: TextStyle(color: _T.sub, fontSize: 13),
            filled: true,
            fillColor: _T.bg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: _T.primary, width: 1.5),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        const SizedBox(height: 16),

        // File attachment
        const Text('Pièce jointe (optionnel)',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('PDF, JPG, PNG, GIF — max 5 Mo',
            style: TextStyle(fontSize: 11, color: _T.sub)),
        const SizedBox(height: 8),

        if (_pickedFile == null)
          GestureDetector(
            onTap: _pickFile,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: _T.bg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: _T.primary.withValues(alpha: 0.4),
                    style: BorderStyle.solid),
              ),
              child: Column(children: [
                Icon(Icons.attach_file_outlined,
                    color: _T.primary, size: 28),
                const SizedBox(height: 6),
                Text('Appuyer pour choisir un fichier',
                    style: TextStyle(fontSize: 12,
                        color: _T.primary, fontWeight: FontWeight.w600)),
              ]),
            ),
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _T.primary.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: _T.primary.withValues(alpha: 0.3)),
            ),
            child: Row(children: [
              Icon(_fileIcon(_pickedFile!.name),
                  color: _T.primary, size: 22),
              const SizedBox(width: 10),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_pickedFile!.name,
                      style: const TextStyle(fontSize: 12,
                          fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text(_fileSize(_pickedFile!.size),
                      style: TextStyle(fontSize: 11, color: _T.sub)),
                ],
              )),
              IconButton(
                icon: Icon(Icons.close, color: Colors.red.shade400, size: 18),
                onPressed: _removeFile,
                tooltip: 'Supprimer',
              ),
            ]),
          ),

        const SizedBox(height: 24),

        // Submit button
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: _submitting ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: _T.primary,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: _submitting
                ? const SizedBox(width: 22, height: 22,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : const Text('Envoyer la justification',
                    style: TextStyle(fontSize: 14,
                        fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }

  IconData _fileIcon(String name) {
    final ext = name.split('.').last.toLowerCase();
    if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
    if (['jpg', 'jpeg', 'png', 'gif'].contains(ext)) {
      return Icons.image_outlined;
    }
    return Icons.attach_file_outlined;
  }

  String _fileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} Ko';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} Mo';
  }
}

// ── Convocation card ──────────────────────────────────────────────────────────
class _ConvocationCard extends StatelessWidget {
  final bool loading;
  final bool downloading;
  final String? error;
  final List<ConvocationModel> convocations;
  final VoidCallback onRefresh;
  final VoidCallback onDownload;

  const _ConvocationCard({
    required this.loading,
    required this.downloading,
    this.error,
    required this.convocations,
    required this.onRefresh,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
            child: Row(children: [
              Container(
                width: 34, height: 34,
                decoration: BoxDecoration(
                  color: _T.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.event_note_outlined, color: _T.primary, size: 18),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Convocation aux examens',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              ),
              // Download button — only when data is present
              if (!loading && error == null && convocations.isNotEmpty)
                _PdfDownloadButton(
                  downloading: downloading,
                  onTap: onDownload,
                ),
              IconButton(
                icon: Icon(Icons.refresh, color: _T.sub, size: 20),
                tooltip: 'Actualiser',
                onPressed: loading ? null : onRefresh,
              ),
            ]),
          ),
          const Divider(height: 1),

          // Body
          if (loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (error != null)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: Column(children: [
                  Icon(Icons.error_outline, color: Colors.red.shade300, size: 36),
                  const SizedBox(height: 8),
                  Text(error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.red.shade400, fontSize: 13)),
                ]),
              ),
            )
          else if (convocations.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
              child: Center(
                child: Column(children: [
                  Icon(Icons.event_available_outlined,
                      color: _T.sub.withValues(alpha: 0.5), size: 40),
                  const SizedBox(height: 10),
                  Text('Aucune convocation pour le moment.',
                      style: TextStyle(color: _T.sub, fontSize: 13)),
                ]),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: convocations.length,
              separatorBuilder: (context, index) => const Divider(height: 1, indent: 16),
              itemBuilder: (_, i) => _ConvocationTile(convocations[i]),
            ),
        ],
      ),
    );
  }
}

// ── Single convocation tile ───────────────────────────────────────────────────
class _ConvocationTile extends StatelessWidget {
  final ConvocationModel c;
  const _ConvocationTile(this.c);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Top row: group + session badge
        Row(children: [
          Icon(Icons.group_outlined, size: 16, color: _T.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(c.groupName,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          ),
          if (c.examSession != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: _T.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(c.examSession!,
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                      color: _T.primary)),
            ),
        ]),
        // Location
        if (c.examLocation != null && c.examLocation!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.room_outlined, size: 13, color: _T.sub),
            const SizedBox(width: 4),
            Text(c.examLocation!,
                style: TextStyle(fontSize: 12, color: _T.sub)),
          ]),
        ],
        // Modules table
        if (c.modules.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: _T.bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(children: [
              // Table header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                child: Row(children: [
                  Expanded(child: Text('Matière',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                          color: _T.sub))),
                  SizedBox(width: 90, child: Text('Date',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                          color: _T.sub))),
                  SizedBox(width: 55, child: Text('Heure',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                          color: _T.sub))),
                  SizedBox(width: 60, child: Text('Salle',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                          color: _T.sub))),
                ]),
              ),
              const Divider(height: 1),
              // Rows
              ...c.modules.asMap().entries.map((entry) {
                final isLast = entry.key == c.modules.length - 1;
                final mod = entry.value;
                return Column(children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(children: [
                      Expanded(
                        child: Text(mod.name,
                            style: const TextStyle(fontSize: 12,
                                fontWeight: FontWeight.w500)),
                      ),
                      SizedBox(
                        width: 90,
                        child: Text(mod.dateLabel,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 11, color: _T.text)),
                      ),
                      SizedBox(
                        width: 55,
                        child: Text(mod.heureLabel,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 11,
                                color: _T.primary,
                                fontWeight: FontWeight.w600)),
                      ),
                      SizedBox(
                        width: 60,
                        child: Text(mod.room ?? '—',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 11, color: _T.sub)),
                      ),
                    ]),
                  ),
                  if (!isLast) const Divider(height: 1, indent: 12),
                ]);
              }),
            ]),
          ),
        ],
      ]),
    );
  }
}

// ── Reusable PDF download icon button ────────────────────────────────────────
class _PdfDownloadButton extends StatelessWidget {
  final bool downloading;
  final VoidCallback onTap;
  const _PdfDownloadButton({required this.downloading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (downloading) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          width: 18, height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return IconButton(
      icon: Icon(Icons.picture_as_pdf_outlined, color: _T.primary, size: 20),
      tooltip: 'Télécharger en PDF',
      onPressed: onTap,
    );
  }
}

// ── Convocation PDF generator ─────────────────────────────────────────────────
class _ConvocationPdfGenerator {
  static final _green      = PdfColor.fromHex('#0E7A50');
  static final _darkGreen  = PdfColor.fromHex('#085C3A');
  static final _lightGreen = PdfColor.fromHex('#E8F5EF');
  static final _grey       = PdfColor.fromHex('#F4F6F8');
  static final _border     = PdfColor.fromHex('#D0D7DE');
  static final _textDark   = PdfColor.fromHex('#1A2E25');
  static final _textMuted  = PdfColor.fromHex('#6B8C7A');

  static Future<Uint8List> generate({
    required List<ConvocationModel> convocations,
    StudentProfile? profile,
  }) async {
    final pdf = pw.Document(
      title: 'Convocation aux examens',
      author: 'Lycée Qualifiant Mohamed El Kaghat ',
    );

    final studentName = profile != null
        ? '${profile.firstName} ${profile.lastName}'
        : 'Étudiant(e)';

    for (final convoc in convocations) {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (ctx) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // ── Page header ─────────────────────────────────────────────
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.symmetric(
                    horizontal: 20, vertical: 14),
                decoration: pw.BoxDecoration(
                  color: _darkGreen,
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          'ETALIB — Espace Numérique Étudiant',
                          style: pw.TextStyle(
                              color: PdfColors.white,
                              fontSize: 9,
                              fontWeight: pw.FontWeight.bold),
                        ),
                        pw.SizedBox(height: 4),
                        pw.Text(
                          'Convocation aux examens',
                          style: pw.TextStyle(
                              color: PdfColors.white,
                              fontSize: 18,
                              fontWeight: pw.FontWeight.bold),
                        ),
                        pw.SizedBox(height: 2),
                        pw.Text(
                          'Lycée Qualifiant Mohamed El Kaghat de Fès',
                          style: pw.TextStyle(
                              color: PdfColors.grey400, fontSize: 8),
                        ),
                      ],
                    ),
                    pw.Container(
                      padding: const pw.EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: pw.BoxDecoration(
                        color: _green,
                        borderRadius: pw.BorderRadius.circular(6),
                      ),
                      child: pw.Text(
                        convoc.examSession ?? '',
                        style: pw.TextStyle(
                            color: PdfColors.white,
                            fontSize: 10,
                            fontWeight: pw.FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 18),

              // ── Student info band ────────────────────────────────────────
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  color: _lightGreen,
                  borderRadius: pw.BorderRadius.circular(6),
                  border: pw.Border.all(color: _border, width: 0.5),
                ),
                child: pw.Row(
                  children: [
                    pw.Expanded(
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text('Nom et prénom',
                              style: pw.TextStyle(
                                  fontSize: 8, color: _textMuted)),
                          pw.SizedBox(height: 2),
                          pw.Text(studentName,
                              style: pw.TextStyle(
                                  fontSize: 12,
                                  fontWeight: pw.FontWeight.bold,
                                  color: _textDark)),
                        ],
                      ),
                    ),
                    pw.SizedBox(width: 20),
                    pw.Expanded(
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text('Groupe',
                              style: pw.TextStyle(
                                  fontSize: 8, color: _textMuted)),
                          pw.SizedBox(height: 2),
                          pw.Text(convoc.groupName,
                              style: pw.TextStyle(
                                  fontSize: 12,
                                  fontWeight: pw.FontWeight.bold,
                                  color: _textDark)),
                        ],
                      ),
                    ),
                    if (convoc.examLocation != null &&
                        convoc.examLocation!.isNotEmpty) ...[
                      pw.SizedBox(width: 20),
                      pw.Expanded(
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text('Salle / Lieu',
                                style: pw.TextStyle(
                                    fontSize: 8, color: _textMuted)),
                            pw.SizedBox(height: 2),
                            pw.Text(convoc.examLocation!,
                                style: pw.TextStyle(
                                    fontSize: 12,
                                    fontWeight: pw.FontWeight.bold,
                                    color: _textDark)),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              pw.SizedBox(height: 18),

              // ── Section title ────────────────────────────────────────────
              pw.Text('Programme des examens',
                  style: pw.TextStyle(
                      fontSize: 13,
                      fontWeight: pw.FontWeight.bold,
                      color: _textDark)),
              pw.SizedBox(height: 8),

              // ── Modules table ────────────────────────────────────────────
              pw.Table(
                border: pw.TableBorder.all(color: _border, width: 0.5),
                columnWidths: {
                  0: const pw.FlexColumnWidth(3),   // Matière
                  1: const pw.FixedColumnWidth(95),  // Date
                  2: const pw.FixedColumnWidth(60),  // Heure
                  3: const pw.FixedColumnWidth(70),  // Salle
                },
                children: [
                  // Header row
                  pw.TableRow(
                    decoration: pw.BoxDecoration(color: _green),
                    children: [
                      _cell('Matière', isHeader: true),
                      _cell('Date', isHeader: true, centered: true),
                      _cell('Heure', isHeader: true, centered: true),
                      _cell('Salle', isHeader: true, centered: true),
                    ],
                  ),
                  // Data rows
                  ...convoc.modules.asMap().entries.map((entry) {
                    final isEven = entry.key.isEven;
                    final mod = entry.value;
                    return pw.TableRow(
                      decoration: pw.BoxDecoration(
                          color: isEven ? _grey : PdfColors.white),
                      children: [
                        _cell(mod.name),
                        _cell(mod.dateLabel, centered: true),
                        _cell(mod.heureLabel,
                            centered: true, bold: true, color: _green),
                        _cell(mod.room ?? '—', centered: true),
                      ],
                    );
                  }),
                ],
              ),
              pw.Spacer(),

              // ── Footer ──────────────────────────────────────────────────
              pw.Divider(color: _border, thickness: 0.5),
              pw.SizedBox(height: 6),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Document généré le ${_today()}',
                    style: pw.TextStyle(fontSize: 7, color: _textMuted),
                  ),
                  pw.Text(
                    'Lycée Qualifiant Mohamed El Kaghat de Fès, Maroc',
                    style: pw.TextStyle(fontSize: 7, color: _textMuted),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return pdf.save();
  }

  static pw.Widget _cell(
    String text, {
    bool isHeader = false,
    bool centered = false,
    bool bold = false,
    PdfColor? color,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      alignment: centered ? pw.Alignment.center : pw.Alignment.centerLeft,
      child: pw.Text(
        text,
        textAlign: centered ? pw.TextAlign.center : pw.TextAlign.left,
        style: pw.TextStyle(
          fontSize: isHeader ? 9 : 10,
          fontWeight: (isHeader || bold) ? pw.FontWeight.bold : pw.FontWeight.normal,
          color: isHeader ? PdfColors.white : (color ?? _textDark),
        ),
      ),
    );
  }

  static String _today() {
    final d = DateTime.now();
    const months = [
      '', 'Jan', 'Fév', 'Mar', 'Avr', 'Mai', 'Juin',
      'Juil', 'Aoû', 'Sep', 'Oct', 'Nov', 'Déc'
    ];
    return '${d.day.toString().padLeft(2, '0')} ${months[d.month]} ${d.year}';
  }
}

// ── PDF generator — uses the `pdf` package for a proper visual output ─────────
class _TimetablePdfGenerator {
  static const _kDays = [
    'Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi'
  ];

  // Green matching the app theme
  static final _green      = PdfColor.fromHex('#0E7A50');
  static final _darkGreen  = PdfColor.fromHex('#085C3A');
  static final _lightGreen = PdfColor.fromHex('#E8F5EF');
  static final _yellow     = PdfColor.fromHex('#FFF9C4');
  static final _grey       = PdfColor.fromHex('#F4F6F8');
  static final _border     = PdfColor.fromHex('#D0D7DE');
  static final _textDark   = PdfColor.fromHex('#1A2E25');
  static final _textMuted  = PdfColor.fromHex('#6B8C7A');

  static Future<Uint8List> generate({required TimetableResult timetable}) async {
    final pdf = pw.Document(
      title: 'Emploi du temps',
      author: 'Lycée  Mohamed El Kaghat ',
    );

    // Build unique sorted time slots
    final slots = timetable.entries
        .map((e) => '${e.startTime}|${e.endTime}')
        .toSet()
        .toList()
      ..sort();

    // Build grid: day → slot_key → entry
    final Map<String, Map<String, TimetableEntry>> grid = {};
    for (final e in timetable.entries) {
      final key = '${e.startTime}|${e.endTime}';
      grid[e.dayOfWeek] ??= {};
      grid[e.dayOfWeek]![key] = e;
    }

    final slotLabels = slots.map((s) {
      final p = s.split('|');
      final st = p[0].substring(0, 5).replaceAll(':', 'h');
      final et = p[1].substring(0, 5).replaceAll(':', 'h');
      return '$st\n$et';
    }).toList();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        build: (ctx) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // ── Header ──────────────────────────────────────────────────
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                decoration: pw.BoxDecoration(
                  color: _darkGreen,
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'ETALIB — Espace Numérique Étudiant',
                      style: pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 10,
                          fontWeight: pw.FontWeight.bold),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      timetable.className != null
                          ? 'Emploi du temps — ${timetable.className}'
                          : 'Emploi du temps',
                      style: pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 16,
                          fontWeight: pw.FontWeight.bold),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Row(children: [
                      if (timetable.track != null)
                        pw.Text(
                          '${timetable.track}   •   ',
                          style: pw.TextStyle(
                              color: PdfColors.grey400, fontSize: 9),
                        ),
                      pw.Text(
                        'Année : ${timetable.academicYear ?? '—'}   •   '
                        'Lycee Mohamed Kaghat — Fes, Maroc',
                        style: pw.TextStyle(
                            color: PdfColors.grey400, fontSize: 9),
                      ),
                    ]),
                  ],
                ),
              ),
              pw.SizedBox(height: 14),

              // ── Table ───────────────────────────────────────────────────
              pw.Expanded(
                child: pw.Table(
                  border: pw.TableBorder.all(
                      color: _border, width: 0.5),
                  columnWidths: {
                    0: const pw.FixedColumnWidth(58), // day column
                    for (int i = 0; i < slots.length; i++)
                      i + 1: const pw.FlexColumnWidth(1),
                  },
                  children: [
                    // ── Column header row ─────────────────────────────
                    pw.TableRow(
                      decoration: pw.BoxDecoration(color: _green),
                      children: [
                        // Corner
                        pw.Container(
                          padding: const pw.EdgeInsets.all(6),
                          child: pw.Text('Jour',
                              style: pw.TextStyle(
                                  color: PdfColors.white,
                                  fontSize: 8,
                                  fontWeight: pw.FontWeight.bold)),
                        ),
                        ...slotLabels.map((label) => pw.Container(
                          padding: const pw.EdgeInsets.all(6),
                          alignment: pw.Alignment.center,
                          child: pw.Text(label,
                              textAlign: pw.TextAlign.center,
                              style: pw.TextStyle(
                                  color: PdfColors.white,
                                  fontSize: 8,
                                  fontWeight: pw.FontWeight.bold)),
                        )),
                      ],
                    ),
                    // ── Day rows ──────────────────────────────────────
                    ..._kDays.asMap().entries.map((dayEntry) {
                      final day = dayEntry.value;
                      final isEven = dayEntry.key.isEven;

                      return pw.TableRow(
                        decoration: pw.BoxDecoration(
                          color: isEven ? _grey : PdfColors.white,
                        ),
                        children: [
                          // Day label cell
                          pw.Container(
                            padding: const pw.EdgeInsets.symmetric(
                                horizontal: 6, vertical: 8),
                            color: _lightGreen,
                            child: pw.Text(day,
                                style: pw.TextStyle(
                                    fontSize: 9,
                                    fontWeight: pw.FontWeight.bold,
                                    color: _textDark)),
                          ),
                          // Slot cells
                          ...slots.map((slot) {
                            final entry = grid[day]?[slot];
                            return pw.Container(
                              padding: const pw.EdgeInsets.all(5),
                              color: entry != null ? _yellow : null,
                              child: entry != null
                                  ? pw.Column(
                                      crossAxisAlignment:
                                          pw.CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          pw.MainAxisAlignment.center,
                                      children: [
                                        pw.Text(entry.subject,
                                            style: pw.TextStyle(
                                                fontSize: 8,
                                                fontWeight:
                                                    pw.FontWeight.bold,
                                                color: _textDark)),
                                        if (entry.teacherName != null)
                                          pw.Text(entry.teacherName!,
                                              style: pw.TextStyle(
                                                  fontSize: 7,
                                                  color: _textMuted)),
                                        if (entry.room != null)
                                          pw.Text(entry.room!,
                                              style: pw.TextStyle(
                                                  fontSize: 7,
                                                  color: _textMuted,
                                                  fontStyle:
                                                      pw.FontStyle.italic)),
                                      ],
                                    )
                                  : pw.SizedBox(),
                            );
                          }),
                        ],
                      );
                    }),
                  ],
                ),
              ),

              // ── Footer ──────────────────────────────────────────────────
              pw.SizedBox(height: 10),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Lycée Qualifiant Mohamed El Kaghat de Fès',
                    style: pw.TextStyle(fontSize: 7, color: _textMuted),
                  ),
                  pw.Text(
                    'Généré le ${DateTime.now().day.toString().padLeft(2, '0')}/'
                    '${DateTime.now().month.toString().padLeft(2, '0')}/'
                    '${DateTime.now().year}',
                    style: pw.TextStyle(fontSize: 7, color: _textMuted),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );

    return pdf.save();
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// TAB 4 — Documents  (with request form)
// ─────────────────────────────────────────────────────────────────────────────

// Document catalogue — each entry drives both the tile and the form
class _DocDef {
  final String type;       // API key
  final String label;      // Display name
  final IconData icon;
  final Color color;
  final String description;
  const _DocDef(this.type, this.label, this.icon, this.color, this.description);
}

const List<_DocDef> _kDocs = [
  _DocDef('attestation_inscription', 'Attestation d\'inscription',
      Icons.card_membership_outlined, Color(0xFF0E7A50),
      'Atteste de votre inscription à Lycée Qualifiant Mohamed El Kaghat de Fès l\'année en cours.'),
  _DocDef('releve_notes', 'Relevé de notes',
      Icons.grade_outlined, Color(0xFF1565C0),
      'Liste de toutes vos notes par module et par semestre.'),
  _DocDef('certificat_scolarite', 'Certificat de scolarité',
      Icons.verified_outlined, Color(0xFF6A1B9A),
      'Certifie que vous êtes régulièrement inscrit(e) à l\'établissement.'),
  _DocDef('recepisse_candidature', 'Récépissé de candidature',
      Icons.receipt_long_outlined, Color(0xFFE65100),
      'Preuve de dépôt de votre dossier de candidature.'),
];

class _DocumentsTab extends StatefulWidget {
  final StudentProfile? profile;
  final String? token;
  final ValueNotifier<List<DocumentRequestModel>?> requestsNotifier;
  const _DocumentsTab({this.profile, this.token, required this.requestsNotifier});

  @override
  State<_DocumentsTab> createState() => _DocumentsTabState();
}

class _DocumentsTabState extends State<_DocumentsTab> {
  List<DocumentRequestModel> _requests = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.requestsNotifier.addListener(_onRequestsChanged);
    if (widget.requestsNotifier.value != null) {
      _requests = widget.requestsNotifier.value!;
      _loading = false;
    } else {
      _loadRequests();
    }
  }

  @override
  void dispose() {
    widget.requestsNotifier.removeListener(_onRequestsChanged);
    super.dispose();
  }

  void _onRequestsChanged() {
    if (mounted && widget.requestsNotifier.value != null) {
      setState(() {
        _requests = widget.requestsNotifier.value!;
        _loading = false;
      });
    }
  }

  // ── Load (initial / pull-to-refresh) ──────────────────────────────────────
  Future<void> _loadRequests() async {
    if (widget.token == null) { setState(() => _loading = false); return; }
    // Fetching will automatically update the global notifier value
    final list = await MySQLHelper.getDocumentRequests(widget.token!);
    if (!mounted) return;
    widget.requestsNotifier.value = list;
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: _T.primary,
      onRefresh: _loadRequests,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── Info banner ──────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: _T.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _T.primary.withValues(alpha: 0.2)),
            ),
            child: Row(children: [
              Icon(Icons.info_outline, color: _T.primary, size: 20),
              const SizedBox(width: 10),
              const Expanded(child: Text(
                'Cliquez sur un document pour soumettre une demande. '
                'Le délai de traitement est de 3 à 5 jours ouvrables.',
                style: TextStyle(fontSize: 12, color: _T.text, height: 1.5),
              )),
            ]),
          ),
          const SizedBox(height: 20),

          // ── Document tiles ───────────────────────────────────────────────
          const Text('Documents disponibles',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700,
                  color: _T.text)),
          const SizedBox(height: 12),
          ..._kDocs.map((doc) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _DocTile(
              doc: doc,
              onTap: () => _openRequestSheet(doc),
            ),
          )),

          // ── My requests ──────────────────────────────────────────────────
          const SizedBox(height: 8),
          Row(children: [
            const Text('Mes demandes',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700,
                    color: _T.text)),
            const Spacer(),
            if (_loading)
              const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2,
                      color: _T.primary)),
          ]),
          const SizedBox(height: 12),
          if (!_loading && _requests.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: const Column(children: [
                Icon(Icons.inbox_outlined, size: 40, color: _T.sub),
                SizedBox(height: 8),
                Text('Aucune demande pour le moment',
                    style: TextStyle(color: _T.sub, fontSize: 13)),
              ]),
            )
          else
            ..._requests.map((req) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _RequestStatusTile(
                request: req,
                onCancel: () => _cancel(req),
                token: widget.token,
              ),
            )),
        ]),
      ),
    );
  }

  void _openRequestSheet(_DocDef doc) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _RequestFormSheet(
        doc: doc,
        token: widget.token,
        onSubmitted: (newReq) {
          setState(() => _requests.insert(0, newReq));
        },
      ),
    );
  }

  Future<void> _cancel(DocumentRequestModel req) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Annuler la demande'),
        content: Text('Annuler la demande de "${req.documentLabel}" ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Non')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Oui, annuler',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true || widget.token == null) return;
    final ok = await MySQLHelper.cancelDocumentRequest(widget.token!, req.id);
    if (ok && mounted) {
      setState(() => _requests.removeWhere((r) => r.id == req.id));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Demande annulée.'), backgroundColor: _T.primary),
      );
    }
  }
}

// ── Document catalogue tile ───────────────────────────────────────────────────
class _DocTile extends StatelessWidget {
  final _DocDef doc;
  final VoidCallback onTap;
  const _DocTile({required this.doc, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.04), blurRadius: 6)],
      ),
      child: Row(children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: doc.color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(doc.icon, color: doc.color, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(doc.label, style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, color: _T.text)),
            const SizedBox(height: 2),
            Text(doc.description, style: const TextStyle(
                fontSize: 11, color: _T.sub),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        )),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _T.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text('Demander',
              style: TextStyle(fontSize: 11, color: _T.primary,
                  fontWeight: FontWeight.w600)),
        ),
      ]),
    ),
  );
}

// ── Request status tile ───────────────────────────────────────────────────────
class _RequestStatusTile extends StatelessWidget {
  final DocumentRequestModel request;
  final VoidCallback onCancel;
  final String? token;
  const _RequestStatusTile({
    required this.request,
    required this.onCancel,
    this.token,
  });

  @override
  Widget build(BuildContext context) {
    final isReady = request.status == 'ready';

    final statusColor = switch (request.status) {
      'pending'    => const Color(0xFFE65100),
      'processing' => const Color(0xFF1565C0),
      'ready'      => const Color(0xFF2E7D32),
      'delivered'  => _T.sub,
      _            => _T.sub,
    };
    final statusIcon = switch (request.status) {
      'pending'    => Icons.hourglass_top_outlined,
      'processing' => Icons.autorenew_outlined,
      'ready'      => Icons.check_circle_outline,
      'delivered'  => Icons.done_all_outlined,
      _            => Icons.help_outline,
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withValues(alpha: 0.3)),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.03), blurRadius: 4)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(statusIcon, color: statusColor, size: 22),
            const SizedBox(width: 12),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(request.documentLabel, style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: _T.text)),
                const SizedBox(height: 3),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  _MiniChip(request.statusLabel, statusColor),
                  _MiniChip('${request.copies} copie(s)', _T.sub),
                  _MiniChip(_deliveryLabel(request.deliveryMode), _T.sub),
                ]),
              ],
            )),
            if (request.status == 'pending')
              IconButton(
                icon: Icon(Icons.close, color: Colors.red.shade300, size: 18),
                tooltip: 'Annuler',
                onPressed: onCancel,
              ),
          ]),

          if (request.adminNotes != null) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _T.primary.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(children: [
                Icon(Icons.info_outline, size: 14, color: _T.primary),
                const SizedBox(width: 6),
                Expanded(child: Text(request.adminNotes!, style: const TextStyle(
                    fontSize: 11, color: _T.sub, fontStyle: FontStyle.italic))),
              ]),
            ),
          ],

          // ── Download button — only when ready ──────────────────────────
          if (isReady) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: ElevatedButton.icon(
                onPressed: () => DocumentDownloadHelper.downloadAndOpenDocument(
                  context: context,
                  token: token,
                  requestId: request.id,
                  documentLabel: request.documentLabel,
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Télécharger le PDF',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _deliveryLabel(String m) => switch (m) {
    'pickup' => 'Retrait',
    'email'  => 'Email',
    'post'   => 'Courrier',
    _        => m,
  };
}

class _MiniChip extends StatelessWidget {
  final String label;
  final Color color;
  const _MiniChip(this.label, this.color);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(label, style: TextStyle(
        fontSize: 10, color: color, fontWeight: FontWeight.w600)),
  );
}

// ── Request form bottom sheet ─────────────────────────────────────────────────
class _RequestFormSheet extends StatefulWidget {
  final _DocDef doc;
  final String? token;
  final ValueChanged<DocumentRequestModel> onSubmitted;
  const _RequestFormSheet(
      {required this.doc, this.token, required this.onSubmitted});

  @override
  State<_RequestFormSheet> createState() => _RequestFormSheetState();
}

class _RequestFormSheetState extends State<_RequestFormSheet> {
  final _formKey = GlobalKey<FormState>();
  final _purposeCtrl = TextEditingController();
  int _copies = 1;
  final String _deliveryMode = 'pickup';
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _purposeCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (widget.token == null) {
      setState(() => _error = 'Session expirée. Veuillez vous reconnecter.');
      return;
    }
    setState(() { _submitting = true; _error = null; });

    final result = await MySQLHelper.submitDocumentRequest(
      token: widget.token!,
      documentType: widget.doc.type,
      deliveryMode: _deliveryMode,
      copies: _copies,
      purpose: _purposeCtrl.text.trim().isEmpty ? null : _purposeCtrl.text.trim(),
    );

    setState(() => _submitting = false);
    if (!mounted) return;

    if (result.success && result.request != null) {
      widget.onSubmitted(result.request!);
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Demande de "${widget.doc.label}" envoyée !'),
        backgroundColor: _T.primary,
      ));
    } else {
      setState(() => _error = result.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(children: [
          // Handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
            ),
            child: Row(children: [
              Container(
                width: 42, height: 42,
                decoration: BoxDecoration(
                  color: widget.doc.color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(widget.doc.icon, color: widget.doc.color, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.doc.label, style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold, color: _T.text)),
                  Text(widget.doc.description, style: const TextStyle(
                      fontSize: 11, color: _T.sub), maxLines: 2),
                ],
              )),
              IconButton(
                icon: const Icon(Icons.close, color: _T.sub),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
          ),
          // Form
          Expanded(
            child: SingleChildScrollView(
              controller: scrollCtrl,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Number of copies
                    _fieldLabel('Nombre de copies'),
                    const SizedBox(height: 8),
                    Row(children: [
                      _CounterBtn(
                        icon: Icons.remove,
                        onTap: _copies > 1
                            ? () => setState(() => _copies--)
                            : null,
                      ),
                      const SizedBox(width: 16),
                      Text('$_copies', style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold,
                          color: _T.text)),
                      const SizedBox(width: 16),
                      _CounterBtn(
                        icon: Icons.add,
                        onTap: _copies < 10
                            ? () => setState(() => _copies++)
                            : null,
                      ),
                    ]),
                    const SizedBox(height: 24),

                    // Purpose / motif (optional)
                    _fieldLabel('Motif de la demande (optionnel)'),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _purposeCtrl,
                      maxLines: 3,
                      maxLength: 500,
                      decoration: InputDecoration(
                        hintText: 'Ex: Demande de visa, concours, emploi...',
                        hintStyle: const TextStyle(
                            color: Colors.black26, fontSize: 13),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                              color: _T.primary, width: 1.5),
                        ),
                        filled: true,
                        fillColor: Colors.grey.shade50,
                        contentPadding: const EdgeInsets.all(14),
                      ),
                    ),
                    const SizedBox(height: 8),

                    // Summary
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _T.primary.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: _T.primary.withValues(alpha: 0.2)),
                      ),
                      child: Column(children: [
                        _SummaryRow('Document', widget.doc.label),
                        _SummaryRow('Copies', '$_copies'),
                        _SummaryRow('Délai estimé', '3 à 5 jours ouvrables'),
                      ]),
                    ),

                    // Error
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Row(children: [
                          Icon(Icons.error_outline,
                              color: Colors.red.shade700, size: 18),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_error!,
                              style: TextStyle(
                                  color: Colors.red.shade700, fontSize: 13))),
                        ]),
                      ),
                    ],
                    const SizedBox(height: 24),

                    // Submit button
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: _submitting ? null : _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _T.primary,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                        icon: _submitting
                            ? const SizedBox(width: 18, height: 18,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : const Icon(Icons.send_outlined, size: 18),
                        label: Text(
                          _submitting ? 'Envoi en cours...' : 'Envoyer la demande',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _fieldLabel(String text) => Text(text,
      style: const TextStyle(
          fontSize: 13, fontWeight: FontWeight.w700, color: _T.text));
}

class _CounterBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _CounterBtn({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 36, height: 36,
      decoration: BoxDecoration(
        color: onTap != null
            ? _T.primary.withValues(alpha: 0.1)
            : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: onTap != null ? _T.primary.withValues(alpha: 0.3)
                : Colors.grey.shade200),
      ),
      child: Icon(icon,
          color: onTap != null ? _T.primary : Colors.grey.shade400,
          size: 18),
    ),
  );
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  const _SummaryRow(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(children: [
      SizedBox(width: 120,
          child: Text(label, style: const TextStyle(
              fontSize: 12, color: _T.sub, fontWeight: FontWeight.w600))),
      Expanded(child: Text(value, style: const TextStyle(
          fontSize: 12, color: _T.text, fontWeight: FontWeight.w500))),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB 5 — Notifications
// ─────────────────────────────────────────────────────────────────────────────

/// A single notification entry persisted in SharedPreferences.
class _NotifEntry {
  final int requestId;
  final String documentLabel;
  final String statusLabel;
  final bool isReady;
  final String timestamp; // ISO-8601

  const _NotifEntry({
    required this.requestId,
    required this.documentLabel,
    required this.statusLabel,
    required this.isReady,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() => {
    'requestId':     requestId,
    'documentLabel': documentLabel,
    'statusLabel':   statusLabel,
    'isReady':       isReady,
    'timestamp':     timestamp,
  };

  factory _NotifEntry.fromMap(Map<String, dynamic> m) => _NotifEntry(
    requestId:     m['requestId'] as int,
    documentLabel: m['documentLabel'] as String,
    statusLabel:   m['statusLabel'] as String,
    isReady:       m['isReady'] as bool? ?? false,
    timestamp:     m['timestamp'] as String,
  );

  String get timeAgo {
    try {
      final d = DateTime.parse(timestamp);
      final diff = DateTime.now().difference(d);
      if (diff.inSeconds < 60)  return 'À l\'instant';
      if (diff.inMinutes < 60)  return 'Il y a ${diff.inMinutes} min';
      if (diff.inHours < 24)    return 'Il y a ${diff.inHours}h';
      if (diff.inDays == 1)     return 'Hier';
      return 'Il y a ${diff.inDays} jours';
    } catch (_) {
      return '';
    }
  }
}

class _NotificationsTab extends StatefulWidget {
  final String? token;
  final ValueNotifier<List<_NotifEntry>?> notificationsNotifier;
  const _NotificationsTab({this.token, required this.notificationsNotifier});

  @override
  State<_NotificationsTab> createState() => _NotificationsTabState();
}

class _NotificationsTabState extends State<_NotificationsTab> {
  static const _historyKey = 'notif_history';

  List<_NotifEntry> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.notificationsNotifier.addListener(_onNotificationsChanged);
    if (widget.notificationsNotifier.value != null) {
      _entries = widget.notificationsNotifier.value!;
      _loading = false;
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    widget.notificationsNotifier.removeListener(_onNotificationsChanged);
    super.dispose();
  }

  void _onNotificationsChanged() {
    if (mounted && widget.notificationsNotifier.value != null) {
      setState(() {
        _entries = widget.notificationsNotifier.value!;
        _loading = false;
      });
    }
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (raw != null) {
      final list = (jsonDecode(raw) as List)
          .map((e) => _NotifEntry.fromMap(e as Map<String, dynamic>))
          .toList();
      list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      if (mounted) {
        widget.notificationsNotifier.value = list;
      }
    } else {
      if (mounted) {
        widget.notificationsNotifier.value = [];
      }
    }
  }

  Future<void> _clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
    widget.notificationsNotifier.value = [];
  }

  Future<void> _dismissEntry(int index, _NotifEntry entry) async {
    final removedEntry = _entries[index];
    setState(() {
      _entries.removeAt(index);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_historyKey, jsonEncode(_entries.map((e) => e.toMap()).toList()));
    widget.notificationsNotifier.value = List.from(_entries);

    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Notification supprimée'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'ANNULER',
          textColor: Colors.yellow,
          onPressed: () async {
            setState(() {
              _entries.insert(index, removedEntry);
            });
            await prefs.setString(_historyKey, jsonEncode(_entries.map((e) => e.toMap()).toList()));
            widget.notificationsNotifier.value = List.from(_entries);
          },
        ),
      ),
    );
  }

  Map<String, List<_NotifEntry>> _groupEntries(List<_NotifEntry> entries) {
    final Map<String, List<_NotifEntry>> groups = {};
    for (final entry in entries) {
      final dateStr = _getDateGroupLabel(entry.timestamp);
      groups[dateStr] ??= [];
      groups[dateStr]!.add(entry);
    }
    return groups;
  }

  String _getDateGroupLabel(String timestampStr) {
    try {
      final date = DateTime.parse(timestampStr);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final yesterday = today.subtract(const Duration(days: 1));
      final compareDate = DateTime(date.year, date.month, date.day);

      if (compareDate == today) {
        return "Aujourd'hui";
      } else if (compareDate == yesterday) {
        return "Hier";
      } else {
        const months = [
          '', 'Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin',
          'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre'
        ];
        return '${date.day} ${months[date.month]} ${date.year}';
      }
    } catch (_) {
      return 'Autres';
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groupEntries(_entries);
    final List<dynamic> items = [];
    groups.forEach((label, list) {
      items.add(label);
      items.addAll(list);
    });

    return Column(children: [
      // Header bar
      Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
        child: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: _T.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.notifications_outlined, color: _T.primary, size: 20),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text('Notifications',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                    color: _T.text)),
          ),
          if (_entries.isNotEmpty)
            TextButton.icon(
              onPressed: _clearAll,
              icon: const Icon(Icons.delete_sweep_outlined, size: 16, color: _T.sub),
              label: const Text('Tout effacer',
                  style: TextStyle(fontSize: 12, color: _T.sub)),
            ),
        ]),
      ),
      const Divider(height: 1),

      // Body
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _entries.isEmpty
                ? _buildEmpty()
                : RefreshIndicator(
                    color: _T.primary,
                    onRefresh: _load,
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        if (item is String) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 16, bottom: 8, left: 4),
                            child: Text(
                              item.toUpperCase(),
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: _T.sub,
                                letterSpacing: 1.0,
                              ),
                            ),
                          );
                        } else {
                          final entry = item as _NotifEntry;
                          final originalIndex = _entries.indexOf(entry);
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Dismissible(
                              key: Key('notif_${entry.requestId}_${entry.timestamp}'),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 20),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade600,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(Icons.delete_outline, color: Colors.white, size: 24),
                              ),
                              onDismissed: (_) => _dismissEntry(originalIndex, entry),
                              child: _NotifTile(entry: entry, token: widget.token),
                            ),
                          );
                        }
                      },
                    ),
                  ),
      ),
    ]);
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 72, height: 72,
          decoration: BoxDecoration(
            color: _T.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(Icons.notifications_none_outlined,
              color: _T.primary, size: 36),
        ),
        const SizedBox(height: 16),
        const Text('Aucune notification',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600,
                color: _T.text)),
        const SizedBox(height: 6),
        const Text('Vous serez notifié(e) dès qu\'un\ndocument est prêt à retirer.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: _T.sub, height: 1.5)),
      ]),
    );
  }
}

class _NotifTile extends StatelessWidget {
  final _NotifEntry entry;
  final String? token;
  const _NotifTile({required this.entry, this.token});

  @override
  Widget build(BuildContext context) {
    final color = entry.isReady ? const Color(0xFF2E7D32) : _T.sub;
    final icon  = entry.isReady
        ? Icons.check_circle_outline
        : Icons.info_outline;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Icon badge
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              // Text
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.isReady
                          ? '📄 Document prêt à retirer'
                          : 'Mise à jour de demande',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _T.text,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      entry.isReady
                          ? 'Votre "${entry.documentLabel}" est prêt. Présentez-vous à la scolarité pour le récupérer.'
                          : '"${entry.documentLabel}" — ${entry.statusLabel}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: _T.sub,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Timestamp
              Text(
                entry.timeAgo,
                style: TextStyle(
                  fontSize: 11,
                  color: _T.sub.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
          if (entry.isReady) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 38,
              child: ElevatedButton.icon(
                onPressed: () => DocumentDownloadHelper.downloadAndOpenDocument(
                  context: context,
                  token: token,
                  requestId: entry.requestId,
                  documentLabel: entry.documentLabel,
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text(
                  'Télécharger le PDF',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB 6 — Paramètres
// ─────────────────────────────────────────────────────────────────────────────
class _SettingsTab extends StatefulWidget {
  final UserModel user;
  final StudentProfile? profile;
  final String? token;
  const _SettingsTab({
    required this.user,
    this.profile,
    this.token,
  });

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  // Avatar state
  String? _avatarUrl;

  // Password form
  final _pwFormKey    = GlobalKey<FormState>();
  final _currentCtrl  = TextEditingController();
  final _newCtrl      = TextEditingController();
  final _confirmCtrl  = TextEditingController();
  bool _obscureCurrent = true;
  bool _obscureNew     = true;
  bool _obscureConfirm = true;
  bool _savingPw       = false;
  String? _pwError;
  String? _pwSuccess;

  @override
  void initState() {
    super.initState();
    _loadCurrentAvatar();
    _newCtrl.addListener(() => setState(() {})); // rebuild strength bar on typing
  }

  Future<void> _loadCurrentAvatar() async {
    if (widget.token == null) {
      debugPrint('SettingsTab: widget.token is null, cannot load current avatar.');
      return;
    }
    final info = await MySQLHelper.getAccountInfo(widget.token!);
    if (mounted && info.avatarUrl != null) {
      setState(() => _avatarUrl = '${info.avatarUrl}?t=${DateTime.now().millisecondsSinceEpoch}');
    }
  }

  @override
  void dispose() {
    _currentCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }



  // ── Password ─────────────────────────────────────────────────────────────
  Future<void> _changePassword() async {
    if (!_pwFormKey.currentState!.validate()) return;
    if (widget.token == null) {
      setState(() { _pwError = 'Erreur : Session non authentifiée (Token absent).'; });
      return;
    }
    setState(() { _savingPw = true; _pwError = null; _pwSuccess = null; });

    final res = await MySQLHelper.changePassword(
      token:           widget.token!,
      currentPassword: _currentCtrl.text,
      newPassword:     _newCtrl.text,
    );
    if (!mounted) return;
    setState(() {
      _savingPw = false;
      if (res.success) {
        _pwSuccess = res.message;
        _currentCtrl.clear();
        _newCtrl.clear();
        _confirmCtrl.clear();
      } else {
        _pwError = res.message;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── Profile picture card ───────────────────────────────────────────
        _SettingsCard(
          icon: Icons.photo_camera_outlined,
          title: 'Photo de profil',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              // Avatar circle
              Container(
                width: 88, height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [_T.light, _T.primary],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [BoxShadow(
                    color: _T.primary.withValues(alpha: 0.3),
                    blurRadius: 12, offset: const Offset(0, 4))],
                ),
                child: _avatarUrl != null
                    ? ClipOval(child: Image.network(
                        _avatarUrl!,
                        width: 88, height: 88,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _avatarFallback(),
                      ))
                    : _avatarFallback(),
              ),
              const SizedBox(width: 20),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.user.name,
                      style: const TextStyle(fontSize: 16,
                          fontWeight: FontWeight.w700, color: _T.text)),
                  const SizedBox(height: 4),
                  Text(widget.user.email,
                      style: const TextStyle(fontSize: 12, color: _T.sub)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _T.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      widget.user.role == 'admin'
                          ? 'Administrateur'
                          : 'Étudiant(e)',
                      style: const TextStyle(fontSize: 11,
                          color: _T.primary, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              )),
            ]),
          ]),
        ),
        const SizedBox(height: 16),

        // ── Account info card ──────────────────────────────────────────────
        _SettingsCard(
          icon: Icons.person_outline_rounded,
          title: 'Informations du compte',
          child: Column(children: [
            _InfoRow(Icons.badge_outlined,        'Nom complet',  widget.user.name),
            _InfoRow(Icons.email_outlined,        'Adresse e-mail', widget.user.email),
            _InfoRow(Icons.manage_accounts_outlined, 'Rôle',
                widget.user.role == 'admin' ? 'Administrateur' : 'Étudiant(e)'),
            if (widget.profile != null) ...[
              _InfoRow(Icons.tag_outlined,        'Code Massar',
                  widget.profile!.massarCode),
              if (widget.profile!.cin != null)
                _InfoRow(Icons.credit_card_outlined, 'CIN',
                    widget.profile!.cin!),
              _InfoRow(Icons.phone_outlined,      'Téléphone',
                  widget.profile!.phone),
              _InfoRow(Icons.location_city_outlined, 'Ville',
                  widget.profile!.city),
              _InfoRow(Icons.school_outlined,     'Filière',
                  widget.profile!.chosenTrack),
            ],
          ]),
        ),
        const SizedBox(height: 16),

        // ── Change password card ───────────────────────────────────────────
        _SettingsCard(
          icon: Icons.lock_outline_rounded,
          title: 'Modifier le mot de passe',
          child: Form(
            key: _pwFormKey,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              // Success banner
              if (_pwSuccess != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: _T.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: _T.primary.withValues(alpha: 0.3)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.check_circle_outline,
                        color: _T.primary, size: 18),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_pwSuccess!,
                        style: const TextStyle(
                            color: _T.primary, fontSize: 13))),
                  ]),
                ),
                const SizedBox(height: 16),
              ],
              // Error banner
              if (_pwError != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF0F0),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Row(children: [
                    Icon(Icons.error_outline,
                        color: Colors.red.shade600, size: 18),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_pwError!,
                        style: TextStyle(
                            color: Colors.red.shade700, fontSize: 13))),
                  ]),
                ),
                const SizedBox(height: 16),
              ],
              // Current password
              _PwField(
                controller: _currentCtrl,
                label: 'Mot de passe actuel',
                obscure: _obscureCurrent,
                onToggle: () => setState(
                    () => _obscureCurrent = !_obscureCurrent),
                validator: (v) => (v == null || v.isEmpty)
                    ? 'Champ obligatoire'
                    : null,
              ),
              const SizedBox(height: 14),
              // New password
              _PwField(
                controller: _newCtrl,
                label: 'Nouveau mot de passe',
                obscure: _obscureNew,
                onToggle: () =>
                    setState(() => _obscureNew = !_obscureNew),
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Champ obligatoire';
                  if (v.length < 8) return 'Minimum 8 caractères';
                  return null;
                },
              ),
              const SizedBox(height: 14),
              // Confirm password
              _PwField(
                controller: _confirmCtrl,
                label: 'Confirmer le nouveau mot de passe',
                obscure: _obscureConfirm,
                onToggle: () => setState(
                    () => _obscureConfirm = !_obscureConfirm),
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Champ obligatoire';
                  if (v != _newCtrl.text) {
                    return 'Les mots de passe ne correspondent pas';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              // Strength indicator
              _PwStrengthBar(password: _newCtrl.text),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _savingPw ? null : _changePassword,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _T.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _savingPw
                      ? const SizedBox(width: 22, height: 22,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.lock_reset_outlined, size: 18),
                            SizedBox(width: 8),
                            Text('Enregistrer le nouveau mot de passe',
                                style: TextStyle(fontSize: 13,
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 16),

        // ── Danger zone ────────────────────────────────────────────────────
        _SettingsCard(
          icon: Icons.logout_rounded,
          iconColor: Colors.red.shade600,
          title: 'Session',
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                // Bubble up to dashboard logout
                final state = context
                    .findAncestorStateOfType<_DashboardScreenState>();
                state?._logout();
              },
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.red.shade300),
                foregroundColor: Colors.red.shade600,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text('Se déconnecter',
                  style: TextStyle(fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ]),
    );
  }

  Widget _avatarFallback() {
    final initials = widget.user.name.isNotEmpty
        ? widget.user.name[0].toUpperCase()
        : 'E';
    return Center(
      child: Text(initials,
          style: const TextStyle(fontSize: 34, color: Colors.white,
              fontWeight: FontWeight.bold)),
    );
  }
}

// ── Settings card wrapper ─────────────────────────────────────────────────────
class _SettingsCard extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final Widget child;
  const _SettingsCard({
    required this.icon,
    this.iconColor,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final color = iconColor ?? _T.primary;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          child: Row(children: [
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 10),
            Text(title,
                style: const TextStyle(fontSize: 15,
                    fontWeight: FontWeight.w700, color: _T.text)),
          ]),
        ),
        Divider(height: 1, color: Colors.grey.shade100),
        Padding(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ]),
    );
  }
}

// ── Info row inside account info card ─────────────────────────────────────────
class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(children: [
      Icon(icon, size: 17, color: _T.sub),
      const SizedBox(width: 12),
      SizedBox(width: 130,
          child: Text(label,
              style: const TextStyle(fontSize: 12,
                  color: _T.sub, fontWeight: FontWeight.w500))),
      Expanded(child: Text(value,
          style: const TextStyle(fontSize: 13,
              color: _T.text, fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis)),
    ]),
  );
}

// ── Password text field ───────────────────────────────────────────────────────
class _PwField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool obscure;
  final VoidCallback onToggle;
  final String? Function(String?) validator;
  const _PwField({
    required this.controller,
    required this.label,
    required this.obscure,
    required this.onToggle,
    required this.validator,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label,
          style: const TextStyle(fontSize: 12,
              fontWeight: FontWeight.w600, color: _T.text)),
      const SizedBox(height: 6),
      TextFormField(
        controller: controller,
        obscureText: obscure,
        validator: validator,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.lock_outline, size: 18, color: _T.sub),
          suffixIcon: IconButton(
            icon: Icon(
              obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              color: _T.sub, size: 18),
            onPressed: onToggle,
          ),
          filled: true,
          fillColor: const Color(0xFFF8FAF9),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFDDE3E0))),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFDDE3E0))),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _T.primary, width: 1.5)),
          errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.red)),
          focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.red, width: 1.5)),
          contentPadding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 14),
        ),
      ),
    ],
  );
}

// ── Password strength indicator ───────────────────────────────────────────────
class _PwStrengthBar extends StatelessWidget {
  final String password;
  const _PwStrengthBar({required this.password});

  int get _strength {
    if (password.isEmpty) return 0;
    int s = 0;
    if (password.length >= 8)                              s++;
    if (RegExp(r'[A-Z]').hasMatch(password))               s++;
    if (RegExp(r'[0-9]').hasMatch(password))               s++;
    if (RegExp(r'[!@#\$%^&*(),.?":{}|<>]').hasMatch(password)) s++;
    return s;
  }

  @override
  Widget build(BuildContext context) {
    if (password.isEmpty) return const SizedBox.shrink();
    final s = _strength;
    final color = switch (s) {
      1 => Colors.red.shade500,
      2 => Colors.orange.shade500,
      3 => Colors.yellow.shade700,
      4 => _T.primary,
      _ => Colors.grey.shade300,
    };
    final label = switch (s) {
      1 => 'Très faible',
      2 => 'Faible',
      3 => 'Moyen',
      4 => 'Fort',
      _ => '',
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: List.generate(4, (i) => Expanded(
        child: Container(
          height: 4,
          margin: EdgeInsets.only(right: i < 3 ? 4 : 0),
          decoration: BoxDecoration(
            color: i < s ? color : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ))),
      const SizedBox(height: 6),
      Text(label,
          style: TextStyle(fontSize: 11, color: color,
              fontWeight: FontWeight.w600)),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared widgets
// ─────────────────────────────────────────────────────────────────────────────
class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;
  const _SectionCard(this.title, this.icon, this.children);

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      boxShadow: [BoxShadow(
          color: Colors.black.withValues(alpha: 0.05),
          blurRadius: 8, offset: const Offset(0, 2))],
    ),
    child: Column(children: [
      // Header
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: _T.primary.withValues(alpha: 0.07),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
          border: Border(bottom: BorderSide(
              color: _T.primary.withValues(alpha: 0.15))),
        ),
        child: Row(children: [
          Icon(icon, color: _T.primary, size: 18),
          const SizedBox(width: 8),
          Text(title, style: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w700, color: _T.text)),
        ]),
      ),
      // Rows
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: children),
      ),
    ]),
  );
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  const _Row(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(children: [
      SizedBox(
        width: 160,
        child: Text(label, style: const TextStyle(
            fontSize: 12, color: _T.sub, fontWeight: FontWeight.w600)),
      ),
      Expanded(child: Text(value, style: const TextStyle(
          fontSize: 13, color: _T.text, fontWeight: FontWeight.w500))),
    ]),
  );
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  const _EmptyState(this.icon, this.message);

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(icon, size: 64, color: _T.sub.withValues(alpha: 0.4)),
      const SizedBox(height: 16),
      Text(message, style: const TextStyle(color: _T.sub, fontSize: 15)),
    ],
  );
}

class DocumentDownloadHelper {
  static Future<void> downloadAndOpenDocument({
    required BuildContext context,
    required String? token,
    required int requestId,
    required String documentLabel,
  }) async {
    if (token == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Session expirée, veuillez vous reconnecter.'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    // Show loading indicator
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
        const SizedBox(width: 12),
        Expanded(child: Text('Génération du PDF pour "$documentLabel" en cours...')),
      ]),
      duration: const Duration(seconds: 30),
      backgroundColor: const Color(0xFF2E7D32),
    ));

    try {
      final response = await http.get(
        Uri.parse('${MySQLHelper.apiBase}/mobile/documents/$requestId/download'),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/pdf',
        },
      ).timeout(const Duration(seconds: 30));

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (response.statusCode != 200) {
        final msg = response.statusCode == 403
            ? 'Document pas encore prêt.'
            : 'Erreur serveur (${response.statusCode}).';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg), backgroundColor: Colors.red));
        return;
      }

      final bytes = response.bodyBytes;
      final docLabel = documentLabel.replaceAll(' ', '_').replaceAll("'", '');
      final filename = '${docLabel}_${DateTime.now().millisecondsSinceEpoch}.pdf';

      if (kIsWeb) {
        final base64 = base64Encode(bytes);
        final dataUrl = Uri.parse('data:application/pdf;base64,$base64');
        launchUrl(dataUrl);
      } else {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/$filename');
        await file.writeAsBytes(bytes, flush: true);
        final uri = Uri.file(file.path);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri);
        } else if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('PDF sauvegardé : ${file.path}'),
            backgroundColor: const Color(0xFF2E7D32),
            duration: const Duration(seconds: 6),
          ));
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erreur: $e'), backgroundColor: Colors.red));
      }
    }
  }
}
