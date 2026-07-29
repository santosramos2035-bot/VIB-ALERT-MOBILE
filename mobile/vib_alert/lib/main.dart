import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const apiBase = 'https://send.vibplus.com/api/v1/index.php';
const urgentChannelId = 'vib_urgent_opportunities';
final navigatorKey = GlobalKey<NavigatorState>();
final localNotifications = FlutterLocalNotificationsPlugin();
const nativeAlertChannel = MethodChannel('vib_alert/full_screen');

@pragma('vm:entry-point')
Future<void>firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await NotificationController.showIncomingOpportunity(message.data,
      title: message.notification?.title, body: message.notification?.body);
}

@pragma('vm:entry-point')
Future<void>notificationActionBackground(NotificationResponse response) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  final payload = response.payload;
  if (payload == null || payload.isEmpty) return;
  final data = Map<String, dynamic>.from(jsonDecode(payload));
  final action = response.actionId;
  if (action != 'accept' && action != 'refuse') return;
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('token');
  final oid = int.tryParse('${data['opportunity_id'] ?? 0}') ?? 0;
  if (token == null || oid <= 0) return;
  try {
    final uri = Uri.parse('$apiBase?action=opportunity_decide');
    await http.post(uri,
      headers: {'Content-Type':'application/json','Accept':'application/json','Authorization':'Bearer $token'},
      body: jsonEncode({'id': oid, 'decision': action == 'accept' ? 'accepted' : 'refused'}));
    await localNotifications.cancel(int.tryParse('${data['notification_id'] ?? oid}') ?? oid);
  } catch (_) {}
}

class NotificationController {
  static Future<void>initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await localNotifications.initialize(settings,
        onDidReceiveNotificationResponse: (response) async {
      final payload = response.payload;
      if (payload == null || payload.isEmpty) return;
      final data = Map<String, dynamic>.from(jsonDecode(payload));
      if (response.actionId == 'accept' || response.actionId == 'refuse') {
        await _handleAlertDecision(data, response.actionId == 'accept' ? 'accepted' : 'refused');
        return;
      }
      navigatorKey.currentState?.push(MaterialPageRoute(
          builder: (_) => IncomingOpportunityPage(data: data)));
    }, onDidReceiveBackgroundNotificationResponse: notificationActionBackground);

    final androidPlugin = localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
    await androidPlugin?.requestFullScreenIntentPermission();
    await androidPlugin?.createNotificationChannel(const AndroidNotificationChannel(
      urgentChannelId,
      'Opportunités urgentes VIB',
      description: 'Alertes prioritaires affichées comme un appel entrant.',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    ));
  }

  static Future<void>showIncomingOpportunity(Map<String, dynamic> data,
      {String? title, String? body}) async {
    final id = int.tryParse('${data['notification_id'] ?? data['opportunity_id'] ?? 0}') ??
        DateTime.now().millisecondsSinceEpoch.remainder(100000);
    final payload = jsonEncode(data);
    final android = AndroidNotificationDetails(
      urgentChannelId,
      'Opportunités urgentes VIB',
      channelDescription: 'Alertes prioritaires affichées comme un appel entrant.',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      fullScreenIntent: true,
      ongoing: true,
      autoCancel: false,
      visibility: NotificationVisibility.public,
      ticker: 'Nouvelle opportunité VIB',
      timeoutAfter: 120000,
      actions: const [
        AndroidNotificationAction('accept', 'ACCEPTER', showsUserInterface: true),
        AndroidNotificationAction('refuse', 'REFUSER', showsUserInterface: true),
      ],
    );
    try {
      await nativeAlertChannel.invokeMethod('startIncomingAlert');
    } catch (_) {}
    await localNotifications.show(
      id,
      title ?? '${data['title'] ?? 'VIB Alert — Opportunité entrante'}',
      body ?? '${data['body'] ?? 'Touchez pour voir les détails'}',
      NotificationDetails(android: android),
      payload: payload,
    );
  }
}

Future<void>main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
  await NotificationController.initialize();
  final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
  runApp(VibApp(initialMessage: initialMessage));
}

class Api {
  String? token;
  Future<Map<String, dynamic>> call(String action,
      {String method = 'GET', Map<String, dynamic>? body}) async {
    final uri = Uri.parse('$apiBase?action=$action');
    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
      if (token != null) 'X-VIB-Token': token!,
    };
    final r = method == 'POST'
        ? await http.post(uri, headers: headers, body: jsonEncode(body ?? {}))
        : await http.get(uri, headers: headers);
    final decoded = jsonDecode(r.body);
    final data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    if (r.statusCode >= 400) throw Exception(data['error'] ?? 'Erreur serveur');
    return data;
  }
}

final api = Api();


Future<void> _openPwaUrl(String url) async {
  await nativeAlertChannel.invokeMethod('openPwa', <String, dynamic>{'url': url});
}

Future<void> _handleAlertDecision(Map<String, dynamic> data, String decision) async {
  final oid = int.tryParse('${data['opportunity_id'] ?? 0}') ?? 0;
  if (oid <= 0) return;
  await api.call('opportunity_decide', method: 'POST', body: <String, dynamic>{
    'id': oid,
    'decision': decision,
  });
  await nativeAlertChannel.invokeMethod('stopIncomingAlert');
  await localNotifications.cancel(
    int.tryParse('${data['notification_id'] ?? oid}') ?? oid,
  );
  if (decision == 'accepted') {
    final handoff = await api.call('pwa_handoff', method: 'POST', body: <String, dynamic>{
      'opportunity_id': oid,
    });
    final url = '${handoff['url'] ?? ''}';
    if (url.isEmpty) throw Exception('Lien PWA introuvable.');
    await _openPwaUrl(url);
  }
}

class VibApp extends StatelessWidget {
  final RemoteMessage? initialMessage;
  const VibApp({super.key, this.initialMessage});
  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        title: 'VIB Alert',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: Gate(initialMessage: initialMessage),
      );
}

class Gate extends StatefulWidget {
  final RemoteMessage? initialMessage;
  const Gate({super.key, this.initialMessage});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
  bool loading = true;
  StreamSubscription<RemoteMessage>? foregroundSub;
  StreamSubscription<RemoteMessage>? openSub;
  @override
  void initState() {
    super.initState();
    _load();
    foregroundSub = FirebaseMessaging.onMessage.listen((message) {
      NotificationController.showIncomingOpportunity(message.data,
          title: message.notification?.title, body: message.notification?.body);
    });
    openSub = FirebaseMessaging.onMessageOpenedApp.listen((message) {
      navigatorKey.currentState?.push(MaterialPageRoute(
          builder: (_) => IncomingOpportunityPage(data: message.data)));
    });
  }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    api.token = p.getString('token');
    if (mounted) setState(() => loading = false);
    Map<String, dynamic>? pendingData;
    String pendingAction = 'open';
    try {
      final native = await nativeAlertChannel.invokeMapMethod<String, dynamic>('getInitialAlert');
      if (native != null && native.isNotEmpty) {
        pendingData = Map<String, dynamic>.from(native);
        pendingAction = '${native['vib_alert_action'] ?? 'open'}';
      }
    } catch (_) {}
    final initialData = pendingData ?? widget.initialMessage?.data;
    if (initialData != null && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (pendingAction == 'accept') {
          try { await _handleAlertDecision(initialData!, 'accepted'); } catch (_) {}
        } else if (pendingAction == 'refuse') {
          try { await _handleAlertDecision(initialData!, 'refused'); } catch (_) {}
        } else {
          navigatorKey.currentState?.push(MaterialPageRoute(
            builder: (_) => IncomingOpportunityPage(data: initialData!)));
        }
      });
    }
  }
  @override
  void dispose() {
    foregroundSub?.cancel();
    openSub?.cancel();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => loading
      ? const Scaffold(body: Center(child: CircularProgressIndicator()))
      : api.token == null
          ? const Login()
          : const Home();
}

class DeviceRegistrar {
  static Future<void> register() async {
    final prefs = await SharedPreferences.getInstance();
    var uuid = prefs.getString('device_uuid');
    uuid ??= const Uuid().v4();
    await prefs.setString('device_uuid', uuid);
    final info = DeviceInfoPlugin();
    String name = 'VIB Alert Android';
    String platform = Platform.operatingSystem;
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      name = '${a.manufacturer} ${a.model}'.trim();
      platform = 'android';
      await prefs.setString('os_name', 'Android ${a.version.release}');
    }
    final package = await PackageInfo.fromPlatform();
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    final fcmToken = await messaging.getToken();
    await api.call('device', method: 'POST', body: {
      'device_uuid': uuid,
      'platform': platform,
      'device_name': name,
      'app_version': package.version,
      'push_token': fcmToken ?? '',
      'notifications_enabled': true,
      'os_name': prefs.getString('os_name') ?? platform,
    });
    FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      try {
        await api.call('device', method: 'POST', body: {
          'device_uuid': uuid,
          'platform': platform,
          'device_name': name,
          'app_version': package.version,
          'push_token': token,
          'notifications_enabled': true,
          'os_name': prefs.getString('os_name') ?? platform,
        });
      } catch (_) {}
    });
  }
}

class Login extends StatefulWidget {
  const Login({super.key});
  @override
  State<Login> createState() => _LoginState();
}
class _LoginState extends State<Login> {
  final email = TextEditingController(), pass = TextEditingController();
  bool busy = false;
  String? error;
  Future<void> go() async {
    setState(() { busy = true; error = null; });
    try {
      final r = await api.call('login', method: 'POST', body: {
        'email': email.text.trim(), 'password': pass.text
      });
      api.token = '${r['token']}';
      final p = await SharedPreferences.getInstance();
      await p.setString('token', api.token!);
      // L'enregistrement Firebase ne doit pas bloquer une connexion valide.
      // La page d'accueil réessaiera automatiquement si nécessaire.
      try { await DeviceRegistrar.register(); } catch (_) {}
      if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const Home()));
    } catch (e) {
      setState(() => error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
  @override
  Widget build(BuildContext context) => Scaffold(body: SafeArea(child: Center(child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 420),
    child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.notifications_active, size: 70),
      const SizedBox(height: 12),
      const Text('VIB Alert', style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
      const Text('Alertes urgentes d’arbitrage'),
      const SizedBox(height: 28),
      TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Adresse email', border: OutlineInputBorder())),
      const SizedBox(height: 12),
      TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Mot de passe', border: OutlineInputBorder())),
      if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: Colors.red))),
      const SizedBox(height: 18),
      FilledButton.icon(onPressed: busy ? null : go, icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.login), label: const Text('Se connecter')),
    ])),
  ))));
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List items = [];
  Map<String, dynamic> dashboard = {};
  bool busy = true;
  bool testing = false;
  String? error;

  @override
  void initState() {
    super.initState();
    DeviceRegistrar.register().catchError((_) {});
    load();
  }

  Future<void> load() async {
    if (mounted) setState(() => busy = true);
    try {
      final results = await Future.wait([
        api.call('dashboard'),
        api.call('notifications'),
      ]);
      if (!mounted) return;
      setState(() {
        dashboard = Map<String, dynamic>.from(results[0]['dashboard'] ?? {});
        items = results[1]['notifications'] ?? [];
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> testAlert() async {
    setState(() => testing = true);
    try {
      final result = await api.call('test_alert', method: 'POST');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${result['message']}')));
      await load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    } finally {
      if (mounted) setState(() => testing = false);
    }
  }

  Future<void> logout() async {
    try { await api.call('logout', method: 'POST'); } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    api.token = null;
    if (mounted) Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const Login()), (_) => false);
  }

  Widget statCard(IconData icon, String label, String value, String detail) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Icon(icon), const Spacer(), Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900))]),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 3),
          Text(detail, style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('VIB Alert'),
      actions: [
        IconButton(onPressed: busy ? null : load, icon: const Icon(Icons.refresh), tooltip: 'Actualiser'),
        PopupMenuButton<String>(onSelected: (v) { if (v == 'logout') logout(); }, itemBuilder: (_) => const [PopupMenuItem(value: 'logout', child: Text('Se déconnecter'))]),
      ],
    ),
    body: busy
      ? const Center(child: CircularProgressIndicator())
      : error != null
        ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(error!, textAlign: TextAlign.center), const SizedBox(height: 12), FilledButton(onPressed: load, child: const Text('Réessayer'))])))
        : RefreshIndicator(
          onRefresh: load,
          child: ListView(padding: const EdgeInsets.all(12), children: [
            LayoutBuilder(builder: (context, constraints) {
              final width = constraints.maxWidth;
              final cardWidth = width >= 760 ? (width - 24) / 3 : width >= 480 ? (width - 12) / 2 : width;
              return Wrap(spacing: 12, runSpacing: 12, children: [
                SizedBox(width: cardWidth, child: statCard(Icons.cloud_done, 'Serveur', dashboard['server_online'] == true ? 'EN LIGNE' : 'HORS LIGNE', 'API ${dashboard['api_version'] ?? '—'}')),
                SizedBox(width: cardWidth, child: statCard(Icons.trending_up, 'Opportunités aujourd’hui', '${dashboard['opportunities_today'] ?? 0}', 'Détectées par le moteur radar')),
                SizedBox(width: cardWidth, child: statCard(Icons.notifications_active, 'Alertes aujourd’hui', '${dashboard['alerts_today'] ?? 0}', 'Téléphones en ligne : ${dashboard['online_devices'] ?? 0}')),
              ]);
            }),
            const SizedBox(height: 12),
            Card(child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [
              const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Test de l’alerte urgente', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)), SizedBox(height: 4), Text('Le téléphone doit sonner, vibrer et afficher l’écran type appel.')])),
              const SizedBox(width: 12),
              FilledButton.icon(onPressed: testing ? null : testAlert, icon: testing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.campaign), label: const Text('TESTER')),
            ]))),
            const SizedBox(height: 16),
            Row(children: [const Text('Historique récent', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)), const Spacer(), Text('Synchronisé : ${dashboard['synced_at'] ?? '—'}', style: Theme.of(context).textTheme.bodySmall)]),
            const SizedBox(height: 8),
            if (items.isEmpty)
              const Card(child: Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Aucune alerte pour le moment.'))))
            else
              ...items.map((raw) {
                final n = Map<String, dynamic>.from(raw as Map);
                return Card(child: ListTile(
                  leading: Icon(n['priority'] == 'urgent' ? Icons.warning_amber : Icons.notifications),
                  title: Text('${n['title']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('${n['body']}\n${n['created_at']}'),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => IncomingOpportunityPage(data: n['payload'] is Map ? Map<String,dynamic>.from(n['payload']) : n))),
                ));
              }),
          ]),
        ),
  );
}

class IncomingOpportunityPage extends StatefulWidget {
  final Map<String, dynamic> data;
  const IncomingOpportunityPage({super.key, required this.data});
  factory IncomingOpportunityPage.fromJson(String json) => IncomingOpportunityPage(data: Map<String,dynamic>.from(jsonDecode(json)));
  @override
  State<IncomingOpportunityPage> createState() => _IncomingOpportunityPageState();
}
class _IncomingOpportunityPageState extends State<IncomingOpportunityPage> {
  bool busy = false;
  int remaining = 120;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    remaining = int.tryParse('${widget.data['expires_in'] ?? 120}') ?? 120;
    nativeAlertChannel.invokeMethod('startIncomingAlert').catchError((_) {});
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (remaining <= 1) {
        timer?.cancel();
        nativeAlertChannel.invokeMethod('stopIncomingAlert').catchError((_) {});
        Navigator.maybePop(context);
      } else {
        setState(() => remaining--);
      }
    });
  }
  @override
  void dispose() {
    timer?.cancel();
    nativeAlertChannel.invokeMethod('stopIncomingAlert').catchError((_) {});
    super.dispose();
  }
  String get countdown => '${(remaining ~/ 60).toString().padLeft(2,'0')}:${(remaining % 60).toString().padLeft(2,'0')}';
  Future<void> decide(String decision) async {
    final oid = int.tryParse('${widget.data['opportunity_id'] ?? 0}') ?? 0;
    if (oid <= 0) { if (mounted) Navigator.pop(context); return; }
    setState(() => busy = true);
    try {
      await _handleAlertDecision(widget.data, decision);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    return Scaffold(
      backgroundColor: const Color(0xFF071426),
      body: SafeArea(child: Padding(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Spacer(),
        const Icon(Icons.notifications_active, size: 88, color: Colors.orange),
        const SizedBox(height: 18),
        Text('${d['alert_label'] ?? (d['alert_type'] == 'buy' ? 'ALERTE D’ACHAT' : d['alert_type'] == 'sell' ? 'ALERTE DE VENTE' : 'ALERTE D’ARBITRAGE')}', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900)),
        const SizedBox(height: 24),
        Text('${d['route'] ?? d['title'] ?? 'Route d’arbitrage'}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Text('Bénéfice net : ${d['profit_usdt'] ?? d['profit'] ?? '—'} USDT', textAlign: TextAlign.center, style: const TextStyle(color: Colors.greenAccent, fontSize: 20)),
        Text('Score : ${d['score'] ?? '—'}/100', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 18)),
        const SizedBox(height: 20),
        Container(padding: const EdgeInsets.symmetric(vertical: 12), decoration: BoxDecoration(color: Colors.orange.withValues(alpha: .12), borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.orangeAccent)), child: Column(children: [
          const Text('TEMPS RESTANT', style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold)),
          Text(countdown, style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w900)),
        ])),
        const Spacer(),
        Row(children: [
          Expanded(child: OutlinedButton.icon(onPressed: busy ? null : () => decide('refused'), icon: const Icon(Icons.close), label: const Text('REFUSER'), style: OutlinedButton.styleFrom(foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 18)))),
          const SizedBox(width: 12),
          Expanded(child: FilledButton.icon(onPressed: busy ? null : () => decide('accepted'), icon: const Icon(Icons.check), label: const Text('ACCEPTER ET OUVRIR'), style: FilledButton.styleFrom(backgroundColor: Colors.green, padding: const EdgeInsets.symmetric(vertical: 18)))),
        ]),
        const SizedBox(height: 20),
      ]))),
    );
  }
}
