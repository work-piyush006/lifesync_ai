// main.dart — LifeSync AI Alarm (One-File Monster Build)
// Features:
// - Splash → First-time setup (Name, 12/24h, UPI permission)
// - Dashboard with greeting, live clock, alarms list
// - Add Alarm: time picker, tone select (Default/Custom/Self/Shuffle), unlock modes (Face, Walk, Geo, UPI Penalty)
// - Local notifications + exact scheduling (flutter_local_notifications + timezone)
// - Alarm Ring screen with ringtone + unlock flows (simulated Face/Walk/Geo), Snooze triggers ₹1 auto-cut unless disabled
// - Penalty Wallet: auto-cut ₹1 ON by default; disable by paying ₹99 (QR popup + UPI ID), toggle stored
// - Coins & Streaks: on-time bonus, referral bonus; Premium Pass unlocks at 14,999 coins (manual monthly reset)
// - All persistence via SharedPreferences (no backend); alarms saved as JSON
//
// NOTE: Add to pubspec.yaml:
// dependencies:
//   flutter_local_notifications: ^17.0.0
//   audioplayers: ^6.0.0
//   shared_preferences: ^2.2.2
//   timezone: ^0.9.2
//   intl: ^0.19.0
// assets:
//   - assets/alarm.mp3
//   - assets/qr.png

import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:intl/intl.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();
final AudioPlayer globalPlayer = AudioPlayer(); // used on AlarmRingScreen

// ---------------- BOOT ----------------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();

  const AndroidInitializationSettings androidInit =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const InitializationSettings initSettings =
      InitializationSettings(android: androidInit);

  await flutterLocalNotificationsPlugin.initialize(
    initSettings,
    onDidReceiveNotificationResponse: (details) async {
      // Payload carries alarmId
      runApp(LifeSyncApp(initialRouteToRing: details.payload));
    },
  );

  runApp(const LifeSyncApp());
}

// ---------------- ROOT APP ----------------
class LifeSyncApp extends StatelessWidget {
  final String? initialRouteToRing; // alarmId if launched from notif
  const LifeSyncApp({super.key, this.initialRouteToRing});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LifeSync AI Alarm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
        snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      ),
      home: initialRouteToRing == null
          ? const SplashScreen()
          : AlarmRingScreen(alarmId: int.tryParse(initialRouteToRing!) ?? -1),
    );
  }
}

// ---------------- MODELS ----------------
class AlarmItem {
  final int id; // unique notification id
  final int hour; // 0-23
  final int minute; // 0-59
  final String tone; // "Default" | "Custom" | "Self" | "Shuffle"
  final List<String> unlocks; // e.g., ["Face","Walk","Geo","UPI"]
  final bool enabled;

  AlarmItem({
    required this.id,
    required this.hour,
    required this.minute,
    required this.tone,
    required this.unlocks,
    required this.enabled,
  });

  factory AlarmItem.fromJson(Map<String, dynamic> j) => AlarmItem(
        id: j['id'],
        hour: j['hour'],
        minute: j['minute'],
        tone: j['tone'],
        unlocks: (j['unlocks'] as List).map((e) => e.toString()).toList(),
        enabled: j['enabled'] ?? true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'hour': hour,
        'minute': minute,
        'tone': tone,
        'unlocks': unlocks,
        'enabled': enabled,
      };

  String formatTime(bool use24) {
    final dt = DateTime(0, 1, 1, hour, minute);
    return use24 ? DateFormat.Hm().format(dt) : DateFormat.jm().format(dt);
  }
}

// ---------------- KEYS ----------------
class K {
  static const first = 'first';
  static const name = 'name';
  static const is24 = 'is24hr';
  static const upiAllowed = 'upiAllowed'; // true means auto-cut allowed
  static const penaltyOffPaid = 'penaltyOffPaid'; // paid ₹99 QR
  static const alarms = 'alarms';
  static const coins = 'coins';
  static const streak = 'streak';
  static const lastWakeDate = 'lastWakeDate';
  static const referrals = 'referrals';
  static const premium = 'premiumUnlocked';
  static const premiumMonth = 'premiumMonth';
}

// ---------------- UTILS ----------------
Future<List<AlarmItem>> loadAlarms() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(K.alarms);
  if (raw == null || raw.isEmpty) return [];
  final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  return list.map(AlarmItem.fromJson).toList();
}

Future<void> saveAlarms(List<AlarmItem> items) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(K.alarms, jsonEncode(items.map((e) => e.toJson()).toList()));
}

Future<void> scheduleAlarmNotification(AlarmItem a) async {
  final now = DateTime.now();
  var scheduled = DateTime(now.year, now.month, now.day, a.hour, a.minute);
  if (!scheduled.isAfter(now)) scheduled = scheduled.add(const Duration(days: 1));

  await flutterLocalNotificationsPlugin.zonedSchedule(
    a.id,
    '⏰ Alarm',
    'It\'s time! Tap to stop.',
    tz.TZDateTime.from(scheduled, tz.local),
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'alarm_notif',
        'Alarm Notifications',
        channelDescription: 'LifeSync Alarm Channel',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('alarm'),
        visibility: NotificationVisibility.public,
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: true,
      ),
    ),
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
    payload: '${a.id}',
    matchDateTimeComponents: DateTimeComponents.time,
  );
}

Future<void> cancelAlarmNotification(int id) async {
  await flutterLocalNotificationsPlugin.cancel(id);
}

// ---------------- SPLASH ----------------
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 1500), () async {
      final p = await SharedPreferences.getInstance();
      final first = p.getBool(K.first) ?? true;
      if (first) {
        if (!mounted) return;
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const FirstTimeSetup()));
      } else {
        if (!mounted) return;
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const DashboardScreen()));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('⏰ LifeSync AI Alarm', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold))),
    );
  }
}

// ---------------- FIRST-TIME SETUP ----------------
class FirstTimeSetup extends StatefulWidget {
  const FirstTimeSetup({super.key});
  @override
  State<FirstTimeSetup> createState() => _FirstTimeSetupState();
}

class _FirstTimeSetupState extends State<FirstTimeSetup> {
  final nameCtrl = TextEditingController();
  bool use24 = false;
  bool upiAutoCutAllowed = true;

  Future<void> _complete() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(K.name, nameCtrl.text.isEmpty ? 'User' : nameCtrl.text.trim());
    await p.setBool(K.is24, use24);
    await p.setBool(K.upiAllowed, upiAutoCutAllowed);
    await p.setBool(K.first, false);
    await p.setInt(K.coins, 0);
    await p.setInt(K.streak, 0);
    await p.setString(K.lastWakeDate, '');
    await p.setStringList(K.referrals, []);
    await p.setBool(K.premium, false);
    await p.setString(K.premiumMonth, DateFormat('yyyy-MM').format(DateTime.now()));
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const DashboardScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Setup Profile')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Enter your name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('Use 24-hour time'),
              value: use24,
              onChanged: (v) => setState(() => use24 = v),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('Allow UPI Penalty Auto-Cut ₹1'),
              subtitle: const Text('If you snooze, ₹1 is auto-deducted to work.piyush006@fam'),
              value: upiAutoCutAllowed,
              onChanged: (v) => setState(() => upiAutoCutAllowed = v),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _complete,
              icon: const Icon(Icons.check),
              label: const Text('Continue'),
            )
          ],
        ),
      ),
    );
  }
}

// ---------------- DASHBOARD ----------------
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  String name = 'User';
  bool use24 = false;
  bool upiAllowed = true;
  bool penaltyOffPaid = false;
  int coins = 0;
  int streak = 0;
  bool premium = false;
  String premiumMonth = DateFormat('yyyy-MM').format(DateTime.now());
  List<AlarmItem> alarms = [];
  late final ValueNotifier<DateTime> _tick;

  @override
  void initState() {
    super.initState();
    _tick = ValueNotifier(DateTime.now());
    _startClock();
    _loadAll();
  }

  void _startClock() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      _tick.value = DateTime.now();
      return mounted;
    });
  }

  Future<void> _loadAll() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      name = p.getString(K.name) ?? 'User';
      use24 = p.getBool(K.is24) ?? false;
      upiAllowed = p.getBool(K.upiAllowed) ?? true;
      penaltyOffPaid = p.getBool(K.penaltyOffPaid) ?? false;
      coins = p.getInt(K.coins) ?? 0;
      streak = p.getInt(K.streak) ?? 0;
      premium = p.getBool(K.premium) ?? false;
      premiumMonth = p.getString(K.premiumMonth) ?? DateFormat('yyyy-MM').format(DateTime.now());
    });
    alarms = await loadAlarms();
    setState(() {});
  }

  String _greeting(DateTime now) {
    final h = now.hour;
    if (h < 12) return 'Good Morning';
    if (h < 17) return 'Good Afternoon';
    if (h < 21) return 'Good Evening';
    return 'Good Night';
    }

  Future<void> _addAlarm() async {
    final res = await Navigator.push<AlarmItem>(context, MaterialPageRoute(builder: (_) => const AddAlarmScreen()));
    if (res != null) {
      alarms.add(res);
      await saveAlarms(alarms);
      await scheduleAlarmNotification(res);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Alarm set at ${res.formatTime(use24)}')));
    }
  }

  Future<void> _toggleEnable(AlarmItem a) async {
    final idx = alarms.indexWhere((e) => e.id == a.id);
    if (idx == -1) return;
    final updated = AlarmItem(
      id: a.id,
      hour: a.hour,
      minute: a.minute,
      tone: a.tone,
      unlocks: a.unlocks,
      enabled: !a.enabled,
    );
    alarms[idx] = updated;
    await saveAlarms(alarms);
    if (updated.enabled) {
      await scheduleAlarmNotification(updated);
    } else {
      await cancelAlarmNotification(updated.id);
    }
    setState(() {});
  }

  Future<void> _deleteAlarm(AlarmItem a) async {
    alarms.removeWhere((e) => e.id == a.id);
    await cancelAlarmNotification(a.id);
    await saveAlarms(alarms);
    setState(() {});
  }

  Future<void> _openSettings() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(
      initial24: use24,
      upiAllowed: upiAllowed,
      penaltyOffPaid: penaltyOffPaid,
      onChanged: (new24, newUpiAllowed, newPenaltyOffPaid) async {
        final p = await SharedPreferences.getInstance();
        await p.setBool(K.is24, new24);
        await p.setBool(K.upiAllowed, newUpiAllowed);
        await p.setBool(K.penaltyOffPaid, newPenaltyOffPaid);
        use24 = new24;
        upiAllowed = newUpiAllowed;
        penaltyOffPaid = newPenaltyOffPaid;
        setState(() {});
      },
    )));
  }

  Future<void> _openStats() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => StatsScreen(
      coins: coins, streak: streak, premium: premium,
      onResetMonthly: () async {
        final p = await SharedPreferences.getInstance();
        await p.setBool(K.premium, false);
        await p.setInt(K.coins, 0);
        await p.setString(K.premiumMonth, DateFormat('yyyy-MM').format(DateTime.now()));
        setState(() { coins = 0; premium = false; premiumMonth = DateFormat('yyyy-MM').format(DateTime.now()); });
      },
    )));
  }

  Future<void> _simulateOnTime() async {
    final p = await SharedPreferences.getInstance();
    // streak handling by day
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final last = p.getString(K.lastWakeDate) ?? '';
    int newStreak = streak;
    if (last == '') {
      newStreak = 1;
    } else {
      final lastDt = DateTime.parse(last);
      final diff = DateTime.now().difference(DateTime(lastDt.year, lastDt.month, lastDt.day)).inDays;
      if (diff == 1) {
        newStreak = streak + 1;
      } else if (diff > 1) {
        newStreak = 1;
      }
    }
    int addCoins = 50; // base on-time
    if (newStreak % 7 == 0) addCoins += 200; // weekly streak bonus
    final newCoins = coins + addCoins;
    bool newPremium = premium || newCoins >= 14999;
    await p.setInt(K.coins, newCoins);
    await p.setInt(K.streak, newStreak);
    await p.setString(K.lastWakeDate, today);
    await p.setBool(K.premium, newPremium);
    setState(() { coins = newCoins; streak = newStreak; premium = newPremium; });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('On-time! +$addCoins coins')));
  }

  Future<void> _simulateReferral() async {
    final p = await SharedPreferences.getInstance();
    final newCoins = coins + 200;
    await p.setInt(K.coins, newCoins);
    setState(() => coins = newCoins);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Referral bonus +200 coins')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LifeSync AI Alarm'),
        actions: [
          IconButton(onPressed: _openStats, icon: const Icon(Icons.bar_chart)),
          IconButton(onPressed: _openSettings, icon: const Icon(Icons.settings)),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            ValueListenableBuilder<DateTime>(
              valueListenable: _tick,
              builder: (_, now, __) => Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${_greeting(now)}, $name 👋', style: const TextStyle(fontSize: 18)),
                  Text(use24 ? DateFormat('HH:mm:ss').format(now) : DateFormat('hh:mm:ss a').format(now),
                      style: const TextStyle(fontSize: 18, fontFeatures: [FontFeature.tabularFigures()])),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Chip(label: Text('Coins: $coins')),
                const SizedBox(width: 8),
                Chip(label: Text('Streak: $streak')),
                const SizedBox(width: 8),
                Chip(label: Text(premium ? '🌟 Premium' : 'Premium Locked')),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: alarms.isEmpty
                  ? const Center(child: Text('No alarms yet. Tap + to add.'))
                  : ListView.builder(
                      itemCount: alarms.length,
                      itemBuilder: (_, i) {
                        final a = alarms[i];
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.alarm),
                            title: Text(a.formatTime(use24)),
                            subtitle: Text('Tone: ${a.tone} • Unlock: ${a.unlocks.join(", ")}'),
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                              Switch(value: a.enabled, onChanged: (_) => _toggleEnable(a)),
                              IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _deleteAlarm(a)),
                            ]),
                          ),
                        );
                      },
                    ),
            ),
            const Divider(),
            Wrap(
              spacing: 10,
              children: [
                ElevatedButton.icon(onPressed: _simulateOnTime, icon: const Icon(Icons.check_circle_outline), label: const Text('Sim On-time')),
                ElevatedButton.icon(onPressed: () async {
                  // simulate snooze penalty
                  final p = await SharedPreferences.getInstance();
                  final bool allowed = p.getBool(K.upiAllowed) ?? true;
                  final bool offPaid = p.getBool(K.penaltyOffPaid) ?? false;
                  if (allowed && !offPaid) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('₹1 auto-cut to work.piyush006@fam (Snooze penalty)')));
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No penalty (wallet off or permission denied)')));
                  }
                }, icon: const Icon(Icons.snooze), label: const Text('Sim Snooze ₹1')),
                ElevatedButton.icon(onPressed: _simulateReferral, icon: const Icon(Icons.card_giftcard), label: const Text('Referral +200')),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(onPressed: _addAlarm, child: const Icon(Icons.add)),
    );
  }
}

// ---------------- ADD ALARM SCREEN ----------------
class AddAlarmScreen extends StatefulWidget {
  const AddAlarmScreen({super.key});
  @override
  State<AddAlarmScreen> createState() => _AddAlarmScreenState();
}

class _AddAlarmScreenState extends State<AddAlarmScreen> {
  TimeOfDay time = TimeOfDay.now();
  String tone = 'Default';
  final List<String> tones = const ['Default', 'Custom Music', 'Self Recorded', 'Shuffle Mode'];
  final Map<String, bool> unlocks = {'Face': true, 'Walk': false, 'Geo': false, 'UPI': false};

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: time);
    if (picked != null) setState(() => time = picked);
  }

  AlarmItem _buildAlarm() {
    final id = DateTime.now().millisecondsSinceEpoch.remainder(1 << 31);
    final unlockList = unlocks.entries.where((e) => e.value).map((e) => e.key).toList();
    return AlarmItem(
      id: id,
      hour: time.hour,
      minute: time.minute,
      tone: tone,
      unlocks: unlockList.isEmpty ? ['Face'] : unlockList,
      enabled: true,
    );
  }

  Future<void> _save() async {
    final a = _buildAlarm();
    Navigator.pop(context, a);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Alarm')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            ListTile(
              title: Text('Time: ${time.format(context)}'),
              trailing: OutlinedButton(onPressed: _pickTime, child: const Text('Pick')),
            ),
            const SizedBox(height: 8),
            const Text('Tone'),
            DropdownButton<String>(
              value: tone,
              isExpanded: true,
              items: tones.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
              onChanged: (v) => setState(() => tone = v ?? 'Default'),
            ),
            const SizedBox(height: 8),
            const Text('Unlock Modes'),
            ...unlocks.keys.map((k) => SwitchListTile(
                  title: Text(k == 'UPI' ? 'UPI Penalty (₹1 on Snooze)' : k),
                  value: unlocks[k]!,
                  onChanged: (v) => setState(() => unlocks[k] = v),
                )),
            const SizedBox(height: 20),
            ElevatedButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Save Alarm')),
          ],
        ),
      ),
    );
  }
}

// ---------------- SETTINGS ----------------
class SettingsScreen extends StatefulWidget {
  final bool initial24;
  final bool upiAllowed;
  final bool penaltyOffPaid;
  final void Function(bool use24, bool upiAllowed, bool penaltyOffPaid) onChanged;

  const SettingsScreen({
    super.key,
    required this.initial24,
    required this.upiAllowed,
    required this.penaltyOffPaid,
    required this.onChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late bool use24;
  late bool upiAllowed;
  late bool penaltyOffPaid;

  @override
  void initState() {
    super.initState();
    use24 = widget.initial24;
    upiAllowed = widget.upiAllowed;
    penaltyOffPaid = widget.penaltyOffPaid;
  }

  void _openPenaltyOffDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Disable Penalty Wallet'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Pay ₹99 one-time to disable auto-cut.\nUPI: work.piyush006@fam'),
            const SizedBox(height: 12),
            Image.asset('assets/qr.png', height: 160, fit: BoxFit.contain),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ElevatedButton(
            onPressed: () {
              setState(() => penaltyOffPaid = true);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Marked as paid. Wallet OFF.')));
            },
            child: const Text('✅ I have paid'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    widget.onChanged(use24, upiAllowed, penaltyOffPaid);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('Use 24-hour format'),
            value: use24,
            onChanged: (v) => setState(() => use24 = v),
          ),
          SwitchListTile(
            title: const Text('Allow UPI Auto-Cut (₹1 on snooze)'),
            value: upiAllowed,
            onChanged: (v) => setState(() => upiAllowed = v),
          ),
          const Divider(),
          ListTile(
            title: const Text('Penalty Wallet'),
            subtitle: Text(penaltyOffPaid ? 'OFF (₹99 paid)' : 'ON (Auto-cut active)'),
            trailing: ElevatedButton(
              onPressed: penaltyOffPaid ? null : _openPenaltyOffDialog,
              child: Text(penaltyOffPaid ? 'Already OFF' : 'Turn OFF (₹99)'),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Referral'),
          ListTile(
            leading: const Icon(Icons.qr_code_2),
            title: const Text('Your Code'),
            subtitle: const Text('Share this with friends to earn +200 coins'),
            trailing: Text(_makeReferralCode()),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Code copied (pretend)!')));
            },
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Friend joined via your code! +200 coins (use Dashboard button to simulate).')));
            },
            icon: const Icon(Icons.person_add_alt),
            label: const Text('How Refer Works'),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('Save'),
          ),
        ],
      ),
    );
  }

  String _makeReferralCode() {
    final r = Random();
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return List.generate(6, (_) => chars[r.nextInt(chars.length)]).join();
  }
}

// ---------------- STATS / PREMIUM ----------------
class StatsScreen extends StatelessWidget {
  final int coins;
  final int streak;
  final bool premium;
  final VoidCallback onResetMonthly;
  const StatsScreen({super.key, required this.coins, required this.streak, required this.premium, required this.onResetMonthly});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your Stats')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('💰 Coins: $coins', style: const TextStyle(fontSize: 18)),
          const SizedBox(height: 8),
          Text('🔥 Streak: $streak days', style: const TextStyle(fontSize: 18)),
          const SizedBox(height: 8),
          Text(premium ? '🌟 Premium Pass: ACTIVE' : 'Premium Pass: Locked (14,999 coins)', style: const TextStyle(fontSize: 18)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: onResetMonthly,
            icon: const Icon(Icons.refresh),
            label: const Text('Reset Monthly (Dev)'),
          ),
          const SizedBox(height: 8),
          const Text('Premium gives: badges, VIP tones, themes, ad-free, priority features.'),
        ]),
      ),
    );
  }
}

// ---------------- ALARM RING SCREEN ----------------
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
  bool playing = false;

  @override
  void initState() {
    super.initState();
    _loadAlarm();
  }

  Future<void> _loadAlarm() async {
    // Load alarm by id & start ringtone
    final list = await loadAlarms();
    setState(() {
      alarm = list.firstWhere((e) => e.id == widget.alarmId, orElse: () => AlarmItem(id: -1, hour: 0, minute: 0, tone: 'Default', unlocks: ['Face'], enabled: true));
    });
    await _playTone();
  }

  Future<void> _playTone() async {
    if (playing) return;
    playing = true;
    // For demo, always play assets/alarm.mp3 regardless of "tone"
    await globalPlayer.setReleaseMode(ReleaseMode.loop);
    await globalPlayer.play(AssetSource('alarm.mp3'));
  }

  Future<void> _stopTone() async {
    playing = false;
    await globalPlayer.stop();
  }

  Future<void> _snoozePenalty() async {
    final p = await SharedPreferences.getInstance();
    final allowed = p.getBool(K.upiAllowed) ?? true;
    final paidOff = p.getBool(K.penaltyOffPaid) ?? false;
    if (alarm?.unlocks.contains('UPI') == true && allowed && !paidOff) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('₹1 auto-cut to work.piyush006@fam (Snooze)')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Snoozed (no penalty)')));
    }
  }

  bool _allUnlocksCleared() {
    final req = alarm?.unlocks ?? ['Face'];
    bool ok = true;
    if (req.contains('Face')) ok = ok && faceOk;
    if (req.contains('Walk')) ok = ok && steps >= 25;
    if (req.contains('Geo')) ok = ok && geoOk;
    // UPI is penalty mode (not condition)
    return ok;
  }

  @override
  void dispose() {
    _stopTone();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = alarm;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: a == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 16),
                    const Icon(Icons.alarm, color: Colors.white, size: 72),
                    const SizedBox(height: 8),
                    Text(a.formatTime(false),
                        style: const TextStyle(color: Colors.white, fontSize: 22)),
                    const SizedBox(height: 4),
                    Text('Tone: ${a.tone} • Unlock: ${a.unlocks.join(", ")}',
                        style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 24),

                    // Unlock Blocks
                    if (a.unlocks.contains('Face'))
                      _UnlockCard(
                        title: 'Face/Eye Unlock',
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                faceOk ? 'Detected ✅' : 'Open eyes + smile 😄',
                                style: const TextStyle(fontSize: 16),
                              ),
                            ),
                            ElevatedButton(
                              onPressed: () => setState(() => faceOk = true),
                              child: const Text('I\'m Smiling'),
                            )
                          ],
                        ),
                      ),
                    if (a.unlocks.contains('Walk'))
                      _UnlockCard(
                        title: 'Walk-to-Stop (25 steps)',
                        child: Row(
                          children: [
                            Expanded(child: Text('Steps: $steps / 25')),
                            Row(children: [
                              IconButton(onPressed: () => setState(() => steps = max(0, steps - 1)), icon: const Icon(Icons.remove)),
                              IconButton(onPressed: () => setState(() => steps += 1), icon: const Icon(Icons.add)),
                            ]),
                          ],
                        ),
                      ),
                    if (a.unlocks.contains('Geo'))
                      _UnlockCard(
                        title: 'Geo-Lock',
                        child: Row(
                          children: [
                            Expanded(child: Text(geoOk ? 'At target location ✅' : 'Reach your saved location')),
                            ElevatedButton(onPressed: () => setState(() => geoOk = true), child: const Text('I\'m There')),
                          ],
                        ),
                      ),

                    const Spacer(),
                    Wrap(
                      spacing: 12,
                      children: [
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                          onPressed: () async {
                            await _snoozePenalty();
                            // Re-schedule 5-min snooze for same alarm id
                            final now = DateTime.now().add(const Duration(minutes: 5));
                            await flutterLocalNotificationsPlugin.zonedSchedule(
                              a.id,
                              '⏰ Alarm (Snoozed)',
                              'Back in 5 minutes',
                              tz.TZDateTime.from(now, tz.local),
                              const NotificationDetails(
                                android: AndroidNotificationDetails(
                                  'alarm_notif',
                                  'Alarm Notifications',
                                  importance: Importance.max,
                                  priority: Priority.high,
                                  playSound: true,
                                  sound: RawResourceAndroidNotificationSound('alarm'),
                                  fullScreenIntent: true,
                                ),
                              ),
                              androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
                              uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
                              payload: '${a.id}',
                            );
                            await _stopTone();
                            if (!mounted) return;
                            Navigator.pop(context);
                          },
                          icon: const Icon(Icons.snooze),
                          label: const Text('Snooze 5m'),
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(backgroundColor: _allUnlocksCleared() ? Colors.green : Colors.grey),
                          onPressed: _allUnlocksCleared()
                              ? () async {
                                  await _stopTone();
                                  if (!mounted) return;
                                  Navigator.pop(context);
                                }
                              : null,
                          icon: const Icon(Icons.check_circle_outline),
                          label: const Text('Stop Alarm'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
        ),
      ),
    );
  }
}

class _UnlockCard extends StatelessWidget {
  final String title;
  final Widget child;
  const _UnlockCard({required this.title, required this.child});
  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.white10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          child,
        ]),
      ),
    );
  }
}