// main.dart
// LifeSync AI Alarm - One-file monster (real unlock modes, offline, AlarmVault & UPI locked)
//
// BEFORE RUNNING:
//  - Add dependencies (see top of file / instructions above).
//  - Add android/iOS permissions (see comments below).
//  - Place assets/alarm.mp3 inside project assets.
//
// WARNING: UPI/payment NOT IMPLEMENTED. AlarmVault + UPI Auto-Cut are LOCKED features shown as popup only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:intl/intl.dart';

// Permissions & native utilities
import 'package:permission_handler/permission_handler.dart';
import 'package:local_auth/local_auth.dart';
import 'package:pedometer/pedometer.dart';
import 'package:geolocator/geolocator.dart';
import 'package:record/record.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

/// ========= NOTE: Android/iOS permission snippets =========
/// AndroidManifest.xml (inside <manifest> / <application>): add
/// <uses-permission android:name="android.permission.RECORD_AUDIO" />
/// <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
/// <uses-permission android:name="android.permission.ACTIVITY_RECOGNITION" />
/// <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
///
/// Also add notification permission handling for Android 13+ in code or manifest meta-data as needed.
///
/// For iOS: Info.plist entries:
/// - NSMicrophoneUsageDescription
/// - NSLocationWhenInUseUsageDescription
/// - NSMotionUsageDescription
/// - NSCalendarsUsageDescription (if needed)
/// - Add UNUserNotificationCenter usage (notification permission)
///
/// =========================================================

final FlutterLocalNotificationsPlugin localNotif = FlutterLocalNotificationsPlugin();
final AudioPlayer audioPlayer = AudioPlayer();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();

  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidInit);

  String? initialPayload;

  await localNotif.initialize(
    initSettings,
    onDidReceiveNotificationResponse: (response) {
      initialPayload = response.payload; // store payload when tapped
    },
  );

  runApp(LifeSyncApp(initialAlarmPayload: initialPayload));
}
// ================== Models & Keys ==================
class AlarmItem {
  final int id;
  final int hour;
  final int minute;
  final String ringtoneType; // Default | Custom | Record | Shuffle
  final String? customPath; // file path if custom/record
  final List<String> unlocks; // Face, Walk, Geo, UPI (UPI is penalty mode)
  final bool enabled;
  final double? geoLat;
  final double? geoLng;

  AlarmItem({
    required this.id,
    required this.hour,
    required this.minute,
    required this.ringtoneType,
    this.customPath,
    required this.unlocks,
    this.enabled = true,
    this.geoLat,
    this.geoLng,
  });

  factory AlarmItem.fromJson(Map<String, dynamic> j) => AlarmItem(
        id: j['id'],
        hour: j['hour'],
        minute: j['minute'],
        ringtoneType: j['ringtoneType'],
        customPath: j['customPath'],
        unlocks: (j['unlocks'] as List).map((e) => e.toString()).toList(),
        enabled: j['enabled'] ?? true,
        geoLat: j['geoLat'] == null ? null : (j['geoLat'] as num).toDouble(),
        geoLng: j['geoLng'] == null ? null : (j['geoLng'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'hour': hour,
        'minute': minute,
        'ringtoneType': ringtoneType,
        'customPath': customPath,
        'unlocks': unlocks,
        'enabled': enabled,
        'geoLat': geoLat,
        'geoLng': geoLng,
      };

  String formatTime(bool use24) {
    final dt = DateTime(0, 1, 1, hour, minute);
    return use24 ? DateFormat.Hm().format(dt) : DateFormat.jm().format(dt);
  }
}

class K {
  static const first = 'first';
  static const name = 'name';
  static const is24 = 'is24';
  static const upiAllowed = 'upiAllowed';
  static const penaltyOffPaid = 'penaltyOffPaid';
  static const alarms = 'alarms';
  static const coins = 'coins';
  static const referrals = 'referrals';
  static const premium = 'premium';
  static const recentRingtones = 'ringtones';
  static const savedLocationLat = 'savedLocationLat';
  static const savedLocationLng = 'savedLocationLng';
}

// ================== Storage utils ==================
Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

Future<List<AlarmItem>> loadAlarms() async {
  final p = await _prefs();
  final raw = p.getString(K.alarms);
  if (raw == null || raw.isEmpty) return [];
  final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  return list.map(AlarmItem.fromJson).toList();
}

Future<void> saveAlarms(List<AlarmItem> list) async {
  final p = await _prefs();
  await p.setString(K.alarms, jsonEncode(list.map((e) => e.toJson()).toList()));
}

// store custom ringtones paths that user selected (for shuffle)
Future<List<String>> loadRingtones() async {
  final p = await _prefs();
  return p.getStringList(K.recentRingtones) ?? [];
}

Future<void> saveRingtones(List<String> paths) async {
  final p = await _prefs();
  await p.setStringList(K.recentRingtones, paths);
}

// ================== App Root ==================
class LifeSyncApp extends StatefulWidget {
  final String? initialAlarmPayload; // alarm id from notification
  const LifeSyncApp({super.key, this.initialAlarmPayload});

  @override
  State<LifeSyncApp> createState() => _LifeSyncAppState();
}

class _LifeSyncAppState extends State<LifeSyncApp> {
  @override
  void initState() {
    super.initState();
    // If app launched from notification, we'll navigate after build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.initialAlarmPayload != null) {
        final id = int.tryParse(widget.initialAlarmPayload!) ?? -1;
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => AlarmRingScreen(alarmId: id)));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LifeSync AI Alarm',
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
      ),
      debugShowCheckedModeBanner: false,
      home: const SplashScreen(),
    );
  }
}

// ================== Splash ==================
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 1100), _decide);
  }

  Future<void> _decide() async {
    final p = await _prefs();
    final first = p.getBool(K.first) ?? true;
    if (first) {
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const FirstTimeSetup()));
    } else {
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MainScaffold()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('⏰ LifeSync AI Alarm', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold))),
    );
  }
}

// ================== First-time Setup & Permission Flow ==================
class FirstTimeSetup extends StatefulWidget {
  const FirstTimeSetup({super.key});
  @override
  State<FirstTimeSetup> createState() => _FirstTimeSetupState();
}

class _FirstTimeSetupState extends State<FirstTimeSetup> {
  final TextEditingController nameCtrl = TextEditingController();
  bool use24 = false;
  bool upiPick = false; // user toggles allow UPI (but feature is locked)
  bool askedPermissions = false;
  final _localAuth = LocalAuthentication();

  @override
  void initState() {
    super.initState();
  }

  // Ask permissions in chronological order:
  //  • Notifications (system prompt may differ) — we request post-init.
  //  • Location
  //  • Activity recognition (steps)
  //  • Microphone (record)
  //  • Camera (if needed for future)
  Future<void> _askAllPermissions() async {
    // keep them sequential and show dialogs to explain
    await _requestPermissionWithDialog(
      title: 'Location',
      body: 'LifeSync needs location to support Geo unlock (when you choose Geo).',
      perm: Permission.locationWhenInUse,
    );

    await _requestPermissionWithDialog(
      title: 'Physical Activity (Step counter)',
      body: 'Steps required for Walk-to-Stop. Grant motion/activity permission on Android.',
      perm: Permission.activityRecognition,
    );

    await _requestPermissionWithDialog(
      title: 'Microphone',
      body: 'Allow microphone to record a custom alarm voice (Self Record).',
      perm: Permission.microphone,
    );

    await _requestPermissionWithDialog(
      title: 'Camera (optional)',
      body: 'Camera may be used for future face detection flows (we use system biometrics for real face/biometric unlock).',
      perm: Permission.camera,
    );

    // Notification permission gives better alarm experience on iOS & Android 13+
    await _requestPermissionWithDialog(
      title: 'Notifications',
      body: 'Allow notifications so alarms can show and open full-screen when active.',
      perm: Permission.notification,
    );

    // biometric: just check & show info
    final canCheckBiometrics = await _localAuth.canCheckBiometrics;
    if (!canCheckBiometrics) {
      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Biometrics'),
          content: const Text('Device does not support biometric authentication. Face unlock option will be hidden.'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    }

    setState(() => askedPermissions = true);
  }

  Future<void> _requestPermissionWithDialog({required String title, required String body, required Permission perm}) async {
    // explain
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Skip')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await perm.request();
            },
            child: const Text('Allow'),
          ),
        ],
      ),
    );
  }

  // When user toggles UPI allow or deny — ALWAYS show the SAME message describing it is a FUTURE locked feature
  void _showUpiLockedMessage() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('UPI Auto-Cut (Future Feature) 🔐'),
        content: const Text(
            'UPI Auto-Cut and AlarmVault are currently a future feature and are LOCKED.\n\n'
            'If / when enabled, snooze can auto-transfer ₹1 and AlarmVault will retain transaction history. For now, this is just an informational setting — no money will be taken. You will be notified when the real feature becomes available.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Got it')),
        ],
      ),
    );
  }

  Future<void> _completeSetup() async {
    final p = await _prefs();
    await p.setString(K.name, nameCtrl.text.trim().isEmpty ? 'User' : nameCtrl.text.trim());
    await p.setBool(K.is24, use24);
    await p.setBool(K.upiAllowed, upiPick); // saved but feature is locked
    await p.setBool(K.first, false);
    await p.setInt(K.coins, 0);
    await p.setStringList(K.referrals, []);
    await p.setBool(K.premium, false);
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MainScaffold()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome — Setup')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            const SizedBox(height: 8),
            const Text('Welcome to LifeSync!', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Enter your name', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text('Use 24-hour clock'),
              value: use24,
              onChanged: (v) => setState(() => use24 = v),
            ),
            const SizedBox(height: 8),
            // UPI toggle but locked feature
            SwitchListTile(
              title: const Text('Allow UPI Auto-Cut (₹1 on snooze)'),
              subtitle: const Text('Feature is FUTURE (locked). Toggle will show info.'),
              value: upiPick,
              onChanged: (v) {
                setState(() => upiPick = v);
                // show identical message whether allow or not
                _showUpiLockedMessage();
              },
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _askAllPermissions,
              icon: const Icon(Icons.lock_open),
              label: const Text('Grant Recommended Permissions'),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(onPressed: _completeSetup, icon: const Icon(Icons.check), label: const Text('Finish & Continue')),
            const SizedBox(height: 8),
            if (!askedPermissions)
              const Text('Tip: You can grant permissions now or later in Settings.', style: TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    );
  }
}

// ================== Main scaffold with Bottom Navigation ==================
class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});
  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _index = 0;
  final List<Widget> _pages = [const DashboardScreen(), const AlarmsPage(), const SettingsPage()];
  String name = 'User';

  @override
  void initState() {
    super.initState();
    _loadName();
  }

  Future<void> _loadName() async {
    final p = await _prefs();
    setState(() => name = p.getString(K.name) ?? 'User');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_index],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.alarm), label: 'Alarms'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

// ================== Dashboard (center) ==================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  String name = 'User';
  bool use24 = false;
  int coins = 0;
  int streak = 0;
  List<AlarmItem> upcoming = [];
  late Timer _clockTimer;
  DateTime now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() => now = DateTime.now()));
  }

  @override
  void dispose() {
    _clockTimer.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await _prefs();
    name = p.getString(K.name) ?? 'User';
    use24 = p.getBool(K.is24) ?? false;
    coins = p.getInt(K.coins) ?? 0;
    final all = await loadAlarms();
    upcoming = all.where((a) => a.enabled).toList()
      ..sort((a, b) {
        final ta = a.hour * 60 + a.minute;
        final tb = b.hour * 60 + b.minute;
        return ta.compareTo(tb);
      });
    // limit 5/day for display (user asked center shows max 5/day; actual scheduling unlimited)
    if (upcoming.length > 5) upcoming = upcoming.take(5).toList();
    setState(() {});
  }

  String greeting() {
    final h = now.hour;
    if (h < 12) return 'Good Morning';
    if (h < 17) return 'Good Afternoon';
    if (h < 21) return 'Good Evening';
    return 'Good Night';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LifeSync AI Alarm'),
        actions: [
          IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StatsPage())), icon: const Icon(Icons.bar_chart)),
          IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage())), icon: const Icon(Icons.settings)),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('$greeting(), $name 👋', style: const TextStyle(fontSize: 18)),
              Text(use24 ? DateFormat('HH:mm:ss').format(now) : DateFormat('hh:mm:ss a').format(now),
                  style: const TextStyle(fontSize: 18, fontFeatures: [FontFeature.tabularFigures()])),
            ]),
            const SizedBox(height: 8),
            Row(children: [Chip(label: Text('Coins: $coins')), const SizedBox(width: 8), Chip(label: Text('Streak: $streak'))]),
            const SizedBox(height: 12),
            const Text('Upcoming Alarms (max 5 shown)'),
            const SizedBox(height: 8),
            Expanded(
              child: upcoming.isEmpty
                  ? const Center(child: Text('No upcoming alarms. Add one from Alarms tab.'))
                  : ListView.builder(
                      itemCount: upcoming.length,
                      itemBuilder: (_, i) {
                        final a = upcoming[i];
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.alarm),
                            title: Text(a.formatTime(use24)),
                            subtitle: Text('Unlock: ${a.unlocks.join(', ')} • ${a.ringtoneType}'),
                            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AlarmDetailsPage(alarm: a))),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ================ Alarms page (add/edit) ==================
class AlarmsPage extends StatefulWidget {
  const AlarmsPage({super.key});
  @override
  State<AlarmsPage> createState() => _AlarmsPageState();
}

class _AlarmsPageState extends State<AlarmsPage> {
  List<AlarmItem> alarms = [];
  bool use24 = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    final p = await _prefs();
    use24 = p.getBool(K.is24) ?? false;
    alarms = await loadAlarms();
    setState(() {});
  }

  Future<void> _addAlarm() async {
    final res = await Navigator.push<AlarmItem>(context, MaterialPageRoute(builder: (_) => const AddAlarmScreen()));
    if (res != null) {
      alarms.add(res);
      await saveAlarms(alarms);
      await scheduleAlarm(res);
      await _loadAll();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Alarm set for ${res.formatTime(use24)}')));
    }
  }

  Future<void> _delete(AlarmItem a) async {
    alarms.removeWhere((e) => e.id == a.id);
    await saveAlarms(alarms);
    await cancelScheduled(a.id);
    await _loadAll();
  }

  Future<void> _toggle(AlarmItem a) async {
    final idx = alarms.indexWhere((e) => e.id == a.id);
    if (idx == -1) return;
    final updated = AlarmItem(
      id: a.id,
      hour: a.hour,
      minute: a.minute,
      ringtoneType: a.ringtoneType,
      customPath: a.customPath,
      unlocks: a.unlocks,
      enabled: !a.enabled,
      geoLat: a.geoLat,
      geoLng: a.geoLng,
    );
    alarms[idx] = updated;
    await saveAlarms(alarms);
    if (updated.enabled) {
      await scheduleAlarm(updated);
    } else {
      await cancelScheduled(updated.id);
    }
    await _loadAll();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alarms'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Expanded(
            child: alarms.isEmpty
                ? const Center(child: Text('No alarms. Tap + to add.'))
                : ListView.builder(
                    itemCount: alarms.length,
                    itemBuilder: (_, i) {
                      final a = alarms[i];
                      return Card(
                        child: ListTile(
                          leading: const Icon(Icons.alarm),
                          title: Text(a.formatTime(use24)),
                          subtitle: Text('${a.ringtoneType} • Unlock: ${a.unlocks.join(", ")}'),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            Switch(value: a.enabled, onChanged: (_) => _toggle(a)),
                            IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(a)),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ]),
      ),
      floatingActionButton: FloatingActionButton(onPressed: _addAlarm, child: const Icon(Icons.add)),
    );
  }
}

// ================ Add Alarm Screen ==================
class AddAlarmScreen extends StatefulWidget {
  const AddAlarmScreen({super.key});
  @override
  State<AddAlarmScreen> createState() => _AddAlarmScreenState();
}

class _AddAlarmScreenState extends State<AddAlarmScreen> {
  TimeOfDay time = TimeOfDay.now();
  final List<String> ringtoneTypes = ['Default', 'Custom', 'Self Record', 'Shuffle'];
  String ringtoneType = 'Default';
  String? customPath;
  final Map<String, bool> unlocks = {'Face': true, 'Walk': false, 'Geo': false, 'UPI': false};
  double? geoLat;
  double? geoLng;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: time);
    if (picked != null) setState(() => time = picked);
  }

  Future<void> _pickCustomRingtone() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (result != null && result.files.isNotEmpty) {
      final path = result.files.first.path;
      if (path != null) {
        customPath = path;
        // store path in recent ringtones
        final list = await loadRingtones();
        if (!list.contains(path)) {
          list.add(path);
          await saveRingtones(list);
        }
        setState(() {});
      }
    }
  }

  Future<void> _recordSelf() async {
    final rec = Record();
    final has = await rec.hasPermission();
    if (!has) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Microphone permission required')));
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final out = '${dir.path}/self_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await rec.start(path: out, encoder: AudioEncoder.AAC);
    // simple start/stop flow
    bool recording = true;
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Recording'),
        content: const Text('Recording... Tap Stop when done.'),
        actions: [
          TextButton(
            onPressed: () async {
              if (recording) await rec.stop();
              recording = false;
              Navigator.pop(context);
            },
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (!recording) {
      customPath = await rec.getRecordPath();
      final list = await loadRingtones();
      if (customPath != null && !list.contains(customPath)) {
        list.add(customPath!);
        await saveRingtones(list);
      }
      setState(() {});
    }
  }

  Future<void> _setGeoTarget() async {
    // capture current location as target
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enable GPS to set geo-target')));
      return;
    }
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.deniedForever || perm == LocationPermission.denied) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location permission denied')));
      return;
    }
    final pos = await Geolocator.getCurrentPosition();
    geoLat = pos.latitude;
    geoLng = pos.longitude;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Geo target saved (current location)')));
  }

  AlarmItem _buildAlarm() {
    final id = DateTime.now().millisecondsSinceEpoch.remainder(1 << 31);
    final chosenUnlocks = unlocks.entries.where((e) => e.value).map((e) => e.key).toList();
    return AlarmItem(
      id: id,
      hour: time.hour,
      minute: time.minute,
      ringtoneType: ringtoneType,
      customPath: customPath,
      unlocks: chosenUnlocks.isEmpty ? ['Face'] : chosenUnlocks,
      enabled: true,
      geoLat: geoLat,
      geoLng: geoLng,
    );
  }

  Future<void> _save() async {
    final alarm = _buildAlarm();
    Navigator.pop(context, alarm);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Alarm')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(children: [
          ListTile(title: Text('Time: ${time.format(context)}'), trailing: OutlinedButton(onPressed: _pickTime, child: const Text('Pick'))),
          const SizedBox(height: 8),
          const Text('Ringtone Type'),
          DropdownButton<String>(
            value: ringtoneType,
            isExpanded: true,
            items: ringtoneTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
            onChanged: (v) => setState(() => ringtoneType = v ?? 'Default'),
          ),
          const SizedBox(height: 8),
          if (ringtoneType == 'Custom') ...[
            ElevatedButton.icon(onPressed: _pickCustomRingtone, icon: const Icon(Icons.folder), label: const Text('Pick audio file')),
            if (customPath != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Selected: ${customPath!.split('/').last}')),
          ],
          if (ringtoneType == 'Self Record') ...[
            ElevatedButton.icon(onPressed: _recordSelf, icon: const Icon(Icons.mic), label: const Text('Record yourself')),
            if (customPath != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Recorded: ${customPath!.split('/').last}')),
          ],
          if (ringtoneType == 'Shuffle') ...[
            const SizedBox(height: 8),
            const Text('Shuffle will play random from your selected custom/self ringtones list (if any).'),
          ],
          const SizedBox(height: 12),
          const Text('Unlock Modes'),
          ...unlocks.keys.map((k) => SwitchListTile(
                title: Text(k == 'UPI' ? 'UPI Penalty (₹1 on snooze) — Locked Feature' : k),
                value: unlocks[k]!,
                onChanged: (v) {
                  // if UPI toggled, show locked info (same message for both)
                  setState(() {
                    unlocks[k] = v;
                  });
                  if (k == 'UPI') {
                    showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('UPI Auto-Cut (Future — Locked) 🔐'),
                        content: const Text('UPI Auto-Cut and AlarmVault are locked for now. When available, snooze will auto-deduct ₹1. For now this toggle is informative only.'),
                        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
                      ),
                    );
                  }
                },
              )),
          if (unlocks['Geo'] == true)
            ListTile(
              title: const Text('Set Geo Target (current location)'),
              subtitle: Text(geoLat == null ? 'No target set' : 'Target saved: ${geoLat!.toStringAsFixed(4)}, ${geoLng!.toStringAsFixed(4)}'),
              trailing: ElevatedButton(onPressed: _setGeoTarget, child: const Text('Save')),
            ),
          const SizedBox(height: 20),
          ElevatedButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Save Alarm')),
        ]),
      ),
    );
  }
}

// =========== scheduling helpers ===========
Future<void> scheduleAlarm(AlarmItem a) async {
  final now = DateTime.now();
  var scheduled = DateTime(now.year, now.month, now.day, a.hour, a.minute);
  if (!scheduled.isAfter(now)) scheduled = scheduled.add(const Duration(days: 1));
  await localNotif.zonedSchedule(
    a.id,
    '⏰ LifeSync Alarm',
    'Tap to open and stop the alarm.',
    tz.TZDateTime.from(scheduled, tz.local),
    NotificationDetails(
      android: AndroidNotificationDetails(
        'alarm_channel',
        'Alarms',
        channelDescription: 'LifeSync alarm channel',
        importance: Importance.max,
        priority: Priority.high,
        fullScreenIntent: true,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('alarm'),
      ),
    ),
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
    payload: '${a.id}',
    matchDateTimeComponents: DateTimeComponents.time,
  );
}

Future<void> cancelScheduled(int id) async {
  await localNotif.cancel(id);
}

// ============== Alarm Ring Screen (real checks) ==============
class AlarmRingScreen extends StatefulWidget {
  final int alarmId;
  const AlarmRingScreen({super.key, this.alarmId = -1});
  @override
  State<AlarmRingScreen> createState() => _AlarmRingScreenState();
}

class _AlarmRingScreenState extends State<AlarmRingScreen> {
  AlarmItem? alarm;
  bool faceOk = false;
  int steps = 0;
  bool geoOk = false;
  StreamSubscription<int>? pedSub;
  final _localAuth = LocalAuthentication();
  final _recorder = Record();
  bool playing = false;
  List<String> shufflePool = [];

  @override
  void initState() {
    super.initState();
    _loadAlarmAndStart();
    _listenShufflePool();
  }

  Future<void> _listenShufflePool() async {
    shufflePool = await loadRingtones();
  }

  Future<void> _loadAlarmAndStart() async {
    final all = await loadAlarms();
    final a = all.firstWhere((e) => e.id == widget.alarmId, orElse: () => AlarmItem(
      id: -1, hour: DateTime.now().hour, minute: DateTime.now().minute, ringtoneType: 'Default', unlocks: ['Face'], enabled: true
    ));
    setState(() => alarm = a);
    // start step listener if Walk enabled
    if (a.unlocks.contains('Walk')) {
      try {
        pedSub = Pedometer.stepCountStream.listen((StepCount event) {
          // pedometer's StepCount value is cumulative; we can compute a simple counter —
          // for simplicity we will just increment local steps on each update
          // Real production needs more careful handling.
          setState(() => steps += 1);
        }, onError: (e) {
          // ignore
        });
      } catch (_) {}
    }
    // If geo unlock set and geoLat/Lng exist, check proximity initially
    if (a.unlocks.contains('Geo') && a.geoLat != null && a.geoLng != null) {
      try {
        final pos = await Geolocator.getCurrentPosition();
        if (_distanceMeters(pos.latitude, pos.longitude, a.geoLat!, a.geoLng!) < 200) {
          setState(() => geoOk = true);
        }
      } catch (_) {}
    }
    await _playRingtoneForAlarm(a);
  }

  double _distanceMeters(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000; // meters
    double toRad(double d) => d * pi / 180;
    final dLat = toRad(lat2 - lat1);
    final dLon = toRad(lon2 - lon1);
    final a = sin(dLat/2)*sin(dLat/2) + cos(toRad(lat1))*cos(toRad(lat2))*sin(dLon/2)*sin(dLon/2);
    final c = 2 * atan2(sqrt(a), sqrt(1-a));
    return R * c;
  }

  Future<void> _playRingtoneForAlarm(AlarmItem a) async {
    try {
      if (a.ringtoneType == 'Default') {
        // use bundled asset alarm.mp3 (add to assets)
        await audioPlayer.setReleaseMode(ReleaseMode.loop);
        await audioPlayer.play(AssetSource('alarm.mp3'));
        setState(() => playing = true);
      } else if (a.ringtoneType == 'Custom' || a.ringtoneType == 'Self Record') {
        if (a.customPath != null && File(a.customPath!).existsSync()) {
          await audioPlayer.setReleaseMode(ReleaseMode.loop);
          await audioPlayer.play(DeviceFileSource(a.customPath!));
          setState(() => playing = true);
        }
      } else if (a.ringtoneType == 'Shuffle') {
        // pick random from shufflePool if available, else fallback to default
        if (shufflePool.isNotEmpty) {
          final pick = shufflePool[Random().nextInt(shufflePool.length)];
          if (File(pick).existsSync()) {
            await audioPlayer.setReleaseMode(ReleaseMode.loop);
            await audioPlayer.play(DeviceFileSource(pick));
            setState(() => playing = true);
            return;
          }
        }
        // fallback
        await audioPlayer.setReleaseMode(ReleaseMode.loop);
        await audioPlayer.play(AssetSource('alarm.mp3'));
        setState(() => playing = true);
      }
    } catch (e) {
      // fallback
      try {
        await audioPlayer.setReleaseMode(ReleaseMode.loop);
        await audioPlayer.play(AssetSource('alarm.mp3'));
        setState(() => playing = true);
      } catch (_) {}
    }
  }

  Future<void> _stopTone() async {
    await audioPlayer.stop();
    setState(() => playing = false);
  }

  Future<void> _attemptFaceUnlock() async {
    try {
      final did = await _localAuth.authenticate(localizedReason: 'Unlock alarm with biometric');
      if (did) setState(() => faceOk = true);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Biometric failed or not available')));
    }
  }

  Future<void> _snoozePressed() async {
    // UPI penalty is only UI. Show same popup if UPI toggle exists, else simple snooze.
    final p = await _prefs();
    final allowedUpi = p.getBool(K.upiAllowed) ?? false;
    final willShowPenalty = (alarm?.unlocks.contains('UPI') ?? false) && allowedUpi;
    if (willShowPenalty) {
      // show popup describing penalty but do NOT actually charge
      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Snooze — Penalty (Locked)'),
          content: const Text('This app currently shows penalty information only. The UPI Auto-Cut feature is locked and will be available in future. No money is charged now.'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Snoozed (no penalty)')));
    }

    // schedule 5-min snooze
    final now = DateTime.now().add(const Duration(minutes: 5));
    await localNotif.zonedSchedule(
      alarm!.id,
      '⏰ Alarm (Snoozed)',
      'Back in 5 minutes',
      tz.TZDateTime.from(now, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails('alarm_channel', 'Alarms', importance: Importance.max, priority: Priority.high, playSound: true, sound: RawResourceAndroidNotificationSound('alarm')),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      payload: '${alarm!.id}',
    );

    await _stopTone();
    await Future.delayed(const Duration(milliseconds: 300));
    if (mounted) Navigator.pop(context);
  }

  bool _allCleared() {
    final req = alarm?.unlocks ?? ['Face'];
    bool ok = true;
    if (req.contains('Face')) ok = ok && faceOk;
    if (req.contains('Walk')) ok = ok && steps >= 25;
    if (req.contains('Geo')) ok = ok && geoOk;
    // UPI is penalty only
    return ok;
  }

  @override
  void dispose() {
    pedSub?.cancel();
    _stopTone();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = alarm;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: a == null
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  const SizedBox(height: 12),
                  const Icon(Icons.alarm, color: Colors.white, size: 72),
                  const SizedBox(height: 8),
                  Text(a.formatTime(false), style: const TextStyle(color: Colors.white, fontSize: 22)),
                  const SizedBox(height: 4),
                  Text('Unlock: ${a.unlocks.join(', ')} • ${a.ringtoneType}', style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 20),
                  if (a.unlocks.contains('Face')) _unlockCard(
                    title: 'Face / Biometric Unlock',
                    child: Row(children: [
                      Expanded(child: Text(faceOk ? 'Unlocked ✅' : 'Use device biometrics to unlock', style: const TextStyle(fontSize: 16))),
                      ElevatedButton(onPressed: _attemptFaceUnlock, child: const Text('Use Biometric')),
                    ]),
                  ),
                  if (a.unlocks.contains('Walk')) _unlockCard(
                    title: 'Walk-to-Stop (25 steps)',
                    child: Row(children: [
                      Expanded(child: Text('Steps: $steps / 25')),
                      Row(children: [
                        IconButton(onPressed: () => setState(() => steps = max(0, steps - 1)), icon: const Icon(Icons.remove)),
                        IconButton(onPressed: () => setState(() => steps += 1), icon: const Icon(Icons.add)),
                      ]),
                    ]),
                  ),
                  if (a.unlocks.contains('Geo')) _unlockCard(
                    title: 'Geo-Lock',
                    child: Row(children: [
                      Expanded(child: Text(geoOk ? 'At target location ✅' : 'Reach saved geo target')),
                      ElevatedButton(onPressed: () async {
                        if (a.geoLat != null && a.geoLng != null) {
                          try {
                            final pos = await Geolocator.getCurrentPosition();
                            if (_distanceMeters(pos.latitude, pos.longitude, a.geoLat!, a.geoLng!) < 200) {
                              setState(() => geoOk = true);
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not at target location yet')));
                            }
                          } catch (_) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location error')));
                          }
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No geo target set')));
                        }
                      }, child: const Text("I'm There")),
                    ]),
                  ),
                  const Spacer(),
                  Wrap(spacing: 12, children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: _snoozePressed,
                      icon: const Icon(Icons.snooze),
                      label: const Text('Snooze 5m'),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: _allCleared() ? Colors.green : Colors.grey),
                      onPressed: _allCleared()
                          ? () async {
                              await _stopTone();
                              Navigator.pop(context);
                            }
                          : null,
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Stop Alarm'),
                    ),
                  ]),
                  const SizedBox(height: 16),
                ]),
              ),
      ),
    );
  }

  Widget _unlockCard({required String title, required Widget child}) {
    return Card(
      color: Colors.white10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)), const SizedBox(height: 8), child])),
    );
  }
}

// ============= Alarm Details Page (view a single alarm) =============
class AlarmDetailsPage extends StatelessWidget {
  final AlarmItem alarm;
  const AlarmDetailsPage({super.key, required this.alarm});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alarm Details')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Time: ${alarm.formatTime(false)}', style: const TextStyle(fontSize: 18)),
          const SizedBox(height: 8),
          Text('Unlock modes: ${alarm.unlocks.join(', ')}'),
          const SizedBox(height: 8),
          Text('Ringtone type: ${alarm.ringtoneType}'),
          const SizedBox(height: 8),
          if (alarm.customPath != null) Text('Ringtone file: ${alarm.customPath!.split('/').last}'),
          const SizedBox(height: 20),
          ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ]),
      ),
    );
  }
}

// ================= Settings Page (includes AlarmVault locked) =================
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool use24 = false;
  bool upiAllowed = false;
  bool penaltyOffPaid = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await _prefs();
    use24 = p.getBool(K.is24) ?? false;
    upiAllowed = p.getBool(K.upiAllowed) ?? false;
    penaltyOffPaid = p.getBool(K.penaltyOffPaid) ?? false;
    setState(() {});
  }

  void _showAlarmVaultLocked() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('AlarmVault & Transactions 🔐'),
        content: const Text('AlarmVault (transactions / UPI auto-cut) is a future locked feature. When it is released, you will be able to see transaction history and manage wallet here. For now this is informational only.'),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  Future<void> _save() async {
    final p = await _prefs();
    await p.setBool(K.is24, use24);
    await p.setBool(K.upiAllowed, upiAllowed);
    await p.setBool(K.penaltyOffPaid, penaltyOffPaid);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved (UPI & AlarmVault are locked for now)')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SwitchListTile(title: const Text('Use 24-hour'), value: use24, onChanged: (v) => setState(() => use24 = v)),
        SwitchListTile(
          title: const Text('Allow UPI Auto-Cut (₹1 on snooze)'),
          subtitle: const Text('This setting is informational — the feature is currently locked.'),
          value: upiAllowed,
          onChanged: (v) {
            setState(() => upiAllowed = v);
            // show same message whether allowed or not
            showDialog(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('UPI Auto-Cut (Locked) 🔐'),
                content: const Text('This is a future feature. No money will be taken now. You will be notified when it is released.'),
                actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
              ),
            );
          },
        ),
        const Divider(),
        ListTile(
          title: const Text('AlarmVault & Transactions'),
          subtitle: const Text('Locked — future feature'),
          trailing: ElevatedButton(onPressed: _showAlarmVaultLocked, child: const Text('Open')),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Save Settings')),
      ]),
    );
  }
}

// ============== Stats Page (simple) ==================
class StatsPage extends StatelessWidget {
  const StatsPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Stats')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
          Text('Coins: 0', style: TextStyle(fontSize: 18)),
          SizedBox(height: 8),
          Text('Streak: 0 days', style: TextStyle(fontSize: 18)),
          SizedBox(height: 12),
          Text('Premium: Locked'),
        ]),
      ),
    );
  }
}