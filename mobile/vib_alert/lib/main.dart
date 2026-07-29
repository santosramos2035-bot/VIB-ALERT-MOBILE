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
import 'package:url_launcher/url_launcher.dart';

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

  if (action == 'accept') {
    data['vib_alert_action'] = 'accept';
    await prefs.setString('pending_alert_payload', jsonEncode(data));
    return;
  }

  if (token == null || oid <= 0) return;
  try {
    final uri = Uri.parse('$apiBase?action=opportunity_decide');
    await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
        'X-VIB-Token': token,
      },
      body: jsonEncode({'id': oid, 'decision': 'refused'}),
    );
    await localNotifications.cancel(
      int.tryParse('${data['notification_id'] ?? oid}') ?? oid,
    );
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
      if (response.actionId == 'refuse') {
        final oid = int.tryParse('${data['opportunity_id'] ?? 0}') ?? 0;
        if (oid > 0) {
          try {
            await api.call('opportunity_decide', method: 'POST', body: {
              'id': oid,
              'decision': 'refused',
            });
          } catch (_) {}
        }
        await nativeAlertChannel.invokeMethod('stopIncomingAlert');
        await localNotifications.cancel(
          int.tryParse('${data['notification_id'] ?? oid}') ?? oid,
        );
        return;
      }

      if (response.actionId == 'accept') {
        data['vib_alert_action'] = 'accept';
      }

      navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => IncomingOpportunityPage(data: data)),
      );
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
    final prefs = await SharedPreferences.getInstance();
    api.token = prefs.getString('token');

    Map<String, dynamic>? pendingData;

    final pendingPayload = prefs.getString('pending_alert_payload');
    if (pendingPayload != null && pendingPayload.isNotEmpty) {
      try {
        pendingData = Map<String, dynamic>.from(jsonDecode(pendingPayload));
      } catch (_) {}
      await prefs.remove('pending_alert_payload');
    }

    try {
      final nativeData = await nativeAlertChannel.invokeMapMethod<String, dynamic>(
        'getInitialAlert',
      );
      if (nativeData != null && nativeData.isNotEmpty) {
        pendingData = Map<String, dynamic>.from(nativeData);
      }
    } catch (_) {}

    if (widget.initialMessage != null) {
      pendingData = Map<String, dynamic>.from(widget.initialMessage!.data);
    }

    if (mounted) setState(() => loading = false);

    if (pendingData != null && mounted) {
      final data = pendingData;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        navigatorKey.currentState?.push(
          MaterialPageRoute(builder: (_) => IncomingOpportunityPage(data: data!)),
        );
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

class _HomeState extends State<Home> with WidgetsBindingObserver {
  List items = [];
  Map<String, dynamic> dashboard = {};
  bool busy = true;
  bool testing = false;
  bool registrationBusy = false;
  String? error;

  Timer? registrationTimer;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _maintainDeviceRegistration();
    registrationTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _maintainDeviceRegistration(),
    );

    load();
  }

  Future<void> _maintainDeviceRegistration() async {
    if (registrationBusy || api.token == null) return;

    registrationBusy = true;

    try {
      await DeviceRegistrar.register();
    } catch (_) {
      // Une absence temporaire d'Internet ne doit pas bloquer l'application.
      // Un nouvel essai sera effectué automatiquement.
    } finally {
      registrationBusy = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      _maintainDeviceRegistration();
      load();
    }
  }

  @override
  void dispose() {
    registrationTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
  bool autoActionHandled = false;
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final action = '${widget.data['vib_alert_action'] ?? ''}'.toLowerCase();
      if (!autoActionHandled && action == 'accept') {
        autoActionHandled = true;
        acceptAndOpenPwa();
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    nativeAlertChannel.invokeMethod('stopIncomingAlert').catchError((_) {});
    super.dispose();
  }

  String get countdown =>
      '${(remaining ~/ 60).toString().padLeft(2, '0')}:${(remaining % 60).toString().padLeft(2, '0')}';

  int get opportunityId =>
      int.tryParse('${widget.data['opportunity_id'] ?? widget.data['id'] ?? 0}') ?? 0;

  String get alertLabel {
    final raw = '${widget.data['alert_label'] ?? widget.data['alert_type'] ?? ''}'
        .trim()
        .toLowerCase();
    if (raw.contains('achat') || raw == 'buy') return 'ALERTE D’ACHAT';
    if (raw.contains('vente') || raw == 'sell') return 'ALERTE DE VENTE';
    if (widget.data['test'] == true || raw.contains('test')) return 'ALERTE DE TEST';
    return 'OPPORTUNITÉ D’ARBITRAGE';
  }

  Future<void> refuse() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      if (opportunityId > 0) {
        await api.call(
          'opportunity_decide',
          method: 'POST',
          body: {'id': opportunityId, 'decision': 'refused'},
        );
      }
      await stopAlert();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> acceptAndOpenPwa() async {
    if (busy) return;
    setState(() => busy = true);

    try {
      if (opportunityId <= 0) {
        await stopAlert();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Alerte de test confirmée. Aucune opération réelle à ouvrir.'),
            ),
          );
          Navigator.pop(context);
        }
        return;
      }

      await api.call(
        'opportunity_decide',
        method: 'POST',
        body: {'id': opportunityId, 'decision': 'accepted'},
      );

      final handoff = await api.call(
        'pwa_handoff',
        method: 'POST',
        body: {'opportunity_id': opportunityId},
      );

      final rawUrl = '${handoff['url'] ?? ''}'.trim();
      if (rawUrl.isEmpty) {
        throw Exception('Le serveur n’a pas retourné le lien sécurisé de la PWA.');
      }

      final uri = Uri.tryParse(rawUrl);
      if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
        throw Exception('Le lien sécurisé de la PWA est invalide.');
      }

      await stopAlert();

      final opened = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );

      if (!opened) {
        throw Exception('Impossible d’ouvrir la PWA sur ce téléphone.');
      }

      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> stopAlert() async {
    timer?.cancel();
    await nativeAlertChannel.invokeMethod('stopIncomingAlert').catchError((_) {});
    final notificationId = int.tryParse(
          '${widget.data['notification_id'] ?? opportunityId}',
        ) ??
        opportunityId;
    if (notificationId > 0) {
      await localNotifications.cancel(notificationId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final isBuy = alertLabel.contains('ACHAT');
    final isSell = alertLabel.contains('VENTE');
    final accent = isBuy
        ? Colors.blueAccent
        : isSell
            ? Colors.greenAccent
            : Colors.orangeAccent;

    return PopScope(
      canPop: !busy,
      child: Scaffold(
        backgroundColor: const Color(0xFF071426),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                Icon(Icons.notifications_active, size: 88, color: accent),
                const SizedBox(height: 18),
                Text(
                  alertLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: accent,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  '${d['route'] ?? d['title'] ?? 'Route d’arbitrage'}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Bénéfice net : ${d['profit_usdt'] ?? d['profit'] ?? '—'} USDT',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 20,
                  ),
                ),
                Text(
                  'Score : ${d['score'] ?? '—'}/100',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 18),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: accent),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'TEMPS RESTANT',
                        style: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        countdown,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 36,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: busy ? null : refuse,
                  icon: const Icon(Icons.close),
                  label: const Text('REFUSER'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: busy ? null : acceptAndOpenPwa,
                  icon: busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.open_in_browser),
                  label: const Text('ACCEPTER ET OUVRIR LA PWA'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
