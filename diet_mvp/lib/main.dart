import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'dart:async';
import 'firebase_options.dart';

late final AuthRepository authRepo;

void main() async {
  
  WidgetsFlutterBinding.ensureInitialized();
  // ★ Firebase 初期化
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  authRepo = AuthRepository(); // 認証状態管理
  final repo = await AppRepository.create();
  runApp(DietApp(repo: repo));
}

/// ====== データモデル ======
class WeightEntry {
  final DateTime dateTime; // 記録日時
  final String tod; // 'am' or 'pm'
  final double kg;

  WeightEntry({required this.dateTime, required this.tod, required this.kg});

  Map<String, dynamic> toJson() => {
        't': dateTime.toIso8601String(),
        'tod': tod,
        'kg': kg,
      };

  static WeightEntry fromJson(Map<String, dynamic> j) => WeightEntry(
        dateTime: DateTime.parse(j['t'] as String),
        tod: j['tod'] as String,
        kg: (j['kg'] as num).toDouble(),
      );
}

class MealEntry {
  final DateTime dateTime;
  final String note;
  final int? kcal;

  MealEntry({required this.dateTime, required this.note, this.kcal});

  Map<String, dynamic> toJson() => {
        't': dateTime.toIso8601String(),
        'n': note,
        'k': kcal,
      };

  static MealEntry fromJson(Map<String, dynamic> j) => MealEntry(
        dateTime: DateTime.parse(j['t'] as String),
        note: j['n'] as String,
        kcal: j['k'] == null ? null : (j['k'] as num).toInt(),
      );
}

/// ====== 永続化（SharedPreferencesにJSON配列で保存） ======
class AppRepository extends ChangeNotifier {
  static const _kWeights = 'weights_v1';
  static const _kMeals = 'meals_v1';
  static const _kRemindAm = 'remind_am';
  static const _kRemindPm = 'remind_pm';

  final SharedPreferences _prefs;
  List<WeightEntry> weights;
  List<MealEntry> meals;
  TimeOfDay? reminderAm;
  TimeOfDay? reminderPm;

  AppRepository._(this._prefs, this.weights, this.meals, this.reminderAm, this.reminderPm);

  static Future<AppRepository> create() async {
    final p = await SharedPreferences.getInstance();
    final w = (p.getStringList(_kWeights) ?? [])
        .map((s) => WeightEntry.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.dateTime.compareTo(b.dateTime));
    final m = (p.getStringList(_kMeals) ?? [])
        .map((s) => MealEntry.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.dateTime.compareTo(b.dateTime));
    TimeOfDay? parseTod(String? v) {
      if (v == null) return null;
      final sp = v.split(':');
      if (sp.length != 2) return null;
      return TimeOfDay(hour: int.tryParse(sp[0]) ?? 8, minute: int.tryParse(sp[1]) ?? 0);
    }

    return AppRepository._(
      p,
      w,
      m,
      parseTod(p.getString(_kRemindAm)),
      parseTod(p.getString(_kRemindPm)),
    );
  }

  Future<void> addWeight(WeightEntry e) async {
    weights = [...weights, e]..sort((a, b) => a.dateTime.compareTo(b.dateTime));
    await _prefs.setStringList(_kWeights, weights.map((e) => jsonEncode(e.toJson())).toList());
    notifyListeners();
  }

  Future<void> addMeal(MealEntry e) async {
    meals = [...meals, e]..sort((a, b) => a.dateTime.compareTo(b.dateTime));
    await _prefs.setStringList(_kMeals, meals.map((e) => jsonEncode(e.toJson())).toList());
    notifyListeners();
  }

  Future<void> clearAll() async {
    weights = [];
    meals = [];
    await _prefs.remove(_kWeights);
    await _prefs.remove(_kMeals);
    notifyListeners();
  }

  Future<void> setReminder({TimeOfDay? am, TimeOfDay? pm}) async {
    String? fmt(TimeOfDay? t) => t == null ? null : '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
    if (am != null) reminderAm = am;
    if (pm != null) reminderPm = pm;
    await _prefs.setString(_kRemindAm, fmt(reminderAm) ?? '');
    await _prefs.setString(_kRemindPm, fmt(reminderPm) ?? '');
    notifyListeners();
  }
}

// ★ 追加：認証ゲート
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    return AnimatedBuilder(
      animation: auth, // ← auth.notifyListeners() で再ビルド
      builder: (context, _) {
        return auth.isSignedIn ? const RootScaffold() : const _SignInScreen();
      },
    );
  }
}

/// ====== アプリ本体 ======
class DietApp extends StatelessWidget {
  final AppRepository repo;
  const DietApp({super.key, required this.repo});

  @override
  Widget build(BuildContext context) {
    return RepositoryScope(
      repo: repo,
      child: AuthScope( // ★追加：認証のInheritedWidget
        auth: authRepo,
        child: MaterialApp(
          title: 'Diet MVP',
          theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
          // home: const RootScaffold(),
          home: const _AuthGate(),
        ),
      ),
    );
  }
}

/// InheritedWidgetで超軽量DI
class RepositoryScope extends InheritedWidget {
  final AppRepository repo;
  const RepositoryScope({super.key, required this.repo, required super.child});
  static AppRepository of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RepositoryScope>()!.repo;
  @override
  bool updateShouldNotify(covariant RepositoryScope oldWidget) => oldWidget.repo != repo;
}

/// ====== 認証（Firebase Auth + Google Sign-In） ======
class AuthRepository extends ChangeNotifier {
  AuthRepository() {
    _sub = FirebaseAuth.instance.authStateChanges().listen((_) => notifyListeners());
  }

  late final StreamSubscription<User?> _sub;

  User? get currentUser => FirebaseAuth.instance.currentUser;
  bool get isSignedIn => currentUser != null;

  Future<void> signInWithGoogle() async {
    try {
      // ★ 追加：前回のセッションを明示的にクリア
      final g = GoogleSignIn(scopes: ['email', 'profile']);
      try { await g.signOut(); } catch (_) {}
      final googleUser = await g.signIn();
      if (googleUser == null) {
        debugPrint('Google sign-in: cancelled');
        return;
      }
      final googleAuth = await googleUser.authentication;
      final cred = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      await FirebaseAuth.instance.signInWithCredential(cred);
    } catch (e, st) {
      debugPrint('Google sign-in error: $e\n$st');
      rethrow;
    }
  }


  Future<void> signOut() async {
    await FirebaseAuth.instance.signOut();
    try { await GoogleSignIn().signOut(); } catch (_) {}
  }

  @override
  void dispose() { _sub.cancel(); super.dispose(); }
}

class AuthScope extends InheritedWidget {
  final AuthRepository auth;
  const AuthScope({super.key, required this.auth, required super.child});
  static AuthRepository of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AuthScope>()!.auth;
  @override
  bool updateShouldNotify(covariant AuthScope oldWidget) => oldWidget.auth != auth;
}

/// ====== ルート（ボトムナビ） ======
class RootScaffold extends StatefulWidget {
  const RootScaffold({super.key});
  @override
  State<RootScaffold> createState() => _RootScaffoldState();
}

class _RootScaffoldState extends State<RootScaffold> {
  int _idx = 0;
  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);

    // ★ 追加：未ログイン時はログイン画面
    if (!auth.isSignedIn) {
      return const _SignInScreen();
    }

    final pages = [
      const HomeScreen(),
      const HistoryScreen(),
      const ChartScreen(),
      const SettingsScreen(),
    ];
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: Scaffold(
        key: ValueKey(_idx),
        appBar: AppBar(title: Text(['ホーム', '履歴', 'グラフ', '設定'][_idx])),
        body: pages[_idx],
        bottomNavigationBar: NavigationBar(
          selectedIndex: _idx,
          onDestinationSelected: (i) => setState(() => _idx = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'ホーム'),
            NavigationDestination(icon: Icon(Icons.list_alt_outlined), selectedIcon: Icon(Icons.list_alt), label: '履歴'),
            NavigationDestination(icon: Icon(Icons.show_chart_outlined), selectedIcon: Icon(Icons.show_chart), label: 'グラフ'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: '設定'),
          ],
        ),
        floatingActionButton: _idx == 0
            ? const _HomeFab()
            : null,
      ),
    );
  }
}

class _SignInScreen extends StatelessWidget {
  const _SignInScreen();

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('ログイン')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('ダイエット記録を同期するにはログインしてください。',
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(Icons.login),
                  label: const Text('Googleでログイン'),
                  onPressed: () async {
                    try {
                      await auth.signInWithGoogle();
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('ログインに失敗しました: $e')),
                      );
                    }
                  },
                ),
                const SizedBox(height: 12),
                const Text('※ 初回ログイン＝ユーザー登録になります'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ====== ホーム ======
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = RepositoryScope.of(context);
    // 今日のデータ抽出
    final now = DateTime.now();
    bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
    final todayWeights = repo.weights.where((w) => sameDay(w.dateTime, now)).toList();
    final am = todayWeights.where((e) => e.tod == 'am').fold<double?>(null, (p, e) => e.kg);
    final pm = todayWeights.where((e) => e.tod == 'pm').fold<double?>(null, (p, e) => e.kg);
    final todayMeals = repo.meals.where((m) => sameDay(m.dateTime, now)).toList();
    final kcal = todayMeals.fold<int>(0, (s, m) => s + (m.kcal ?? 0));

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          _Section(title: '今日の記録', child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _RowItem(label: '朝の体重', value: am == null ? '-' : '${am.toStringAsFixed(1)} kg'),
              _RowItem(label: '夜の体重', value: pm == null ? '-' : '${pm.toStringAsFixed(1)} kg'),
              _RowItem(label: '摂取カロリー合計', value: '$kcal kcal'),
            ],
          )),
          const SizedBox(height: 12),
          _Section(title: 'クイック入力', child: Wrap(
            spacing: 8, runSpacing: 8,
            children: [
              FilledButton.icon(onPressed: () => _openWeight(context, 'am'), icon: const Icon(Icons.wb_sunny_outlined), label: const Text('体重（朝）')),
              FilledButton.icon(onPressed: () => _openWeight(context, 'pm'), icon: const Icon(Icons.nights_stay_outlined), label: const Text('体重（夜）')),
              OutlinedButton.icon(onPressed: () => _openMeal(context), icon: const Icon(Icons.restaurant_outlined), label: const Text('食事メモ')),
            ],
          )),
          const SizedBox(height: 12),
          const _StreakCard(),
        ],
      ),
    );
  }

  static Future<void> _openWeight(BuildContext context, String tod) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => WeightEntryScreen(defaultTod: tod)));
  }

  static Future<void> _openMeal(BuildContext context) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MealEntryScreen()));
  }
}

class _HomeFab extends StatelessWidget {
  const _HomeFab();

  @override
  Widget build(BuildContext context) {
    return ExpandableFab(children: [
      FloatingActionButton.extended(
        heroTag: 'w_am',
        onPressed: () => HomeScreen._openWeight(context, 'am'),
        icon: const Icon(Icons.wb_sunny_outlined),
        label: const Text('体重（朝）'),
      ),
      FloatingActionButton.extended(
        heroTag: 'w_pm',
        onPressed: () => HomeScreen._openWeight(context, 'pm'),
        icon: const Icon(Icons.nights_stay_outlined),
        label: const Text('体重（夜）'),
      ),
      FloatingActionButton.extended(
        heroTag: 'meal',
        onPressed: () => HomeScreen._openMeal(context),
        icon: const Icon(Icons.restaurant_outlined),
        label: const Text('食事'),
      ),
    ]);
  }
}

/// ====== 入力画面：体重 ======
class WeightEntryScreen extends StatefulWidget {
  final String? defaultTod; // 'am' or 'pm'
  const WeightEntryScreen({super.key, this.defaultTod});
  @override
  State<WeightEntryScreen> createState() => _WeightEntryScreenState();
}

class _WeightEntryScreenState extends State<WeightEntryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _kgCtrl = TextEditingController();
  String _tod = 'am';

  @override
  void initState() {
    super.initState();
    _tod = widget.defaultTod ?? 'am';
  }

  @override
  void dispose() {
    _kgCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = RepositoryScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('体重を入力')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(children: [
            TextFormField(
              controller: _kgCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: '体重 (kg)', hintText: '例: 67.8'),
              validator: (v) {
                final x = double.tryParse((v ?? '').replaceAll(',', '.'));
                if (x == null) return '数値を入力してください';
                if (x < 30 || x > 300) return '30〜300の範囲で入力';
                return null;
              },
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'am', label: Text('朝')),
                ButtonSegment(value: 'pm', label: Text('夜')),
              ],
              selected: {_tod},
              onSelectionChanged: (s) => setState(() => _tod = s.first),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: () async {
                if (!_formKey.currentState!.validate()) return;
                final kg = double.parse(_kgCtrl.text.replaceAll(',', '.'));
                await repo.addWeight(WeightEntry(dateTime: DateTime.now(), tod: _tod, kg: kg));
                if (!context.mounted) return;
                Navigator.pop(context);
              },
              icon: const Icon(Icons.save_outlined),
              label: const Text('保存'),
            ),
          ]),
        ),
      ),
    );
  }
}

/// ====== 入力画面：食事 ======
class MealEntryScreen extends StatefulWidget {
  const MealEntryScreen({super.key});
  @override
  State<MealEntryScreen> createState() => _MealEntryScreenState();
}

class _MealEntryScreenState extends State<MealEntryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _noteCtrl = TextEditingController();
  final _kcalCtrl = TextEditingController();

  @override
  void dispose() {
    _noteCtrl.dispose();
    _kcalCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = RepositoryScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('食事を記録')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(children: [
            TextFormField(
              controller: _noteCtrl,
              decoration: const InputDecoration(labelText: 'メモ（例：牛丼、サラダなど）'),
              validator: (v) => (v == null || v.isEmpty) ? 'メモを入力してください' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _kcalCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'カロリー（kcal・任意）'),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: () async {
                if (!_formKey.currentState!.validate()) return;
                final kcal = _kcalCtrl.text.trim().isEmpty ? null : int.tryParse(_kcalCtrl.text.trim());
                await repo.addMeal(MealEntry(dateTime: DateTime.now(), note: _noteCtrl.text.trim(), kcal: kcal));
                if (!context.mounted) return;
                Navigator.pop(context);
              },
              icon: const Icon(Icons.save_outlined),
              label: const Text('保存'),
            ),
          ]),
        ),
      ),
    );
  }
}

/// ====== 履歴 ======
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = RepositoryScope.of(context);
    return AnimatedBuilder(
      animation: repo,
      builder: (context, _) {
        final groups = <String, Map<String, dynamic>>{};
        String ymd(DateTime d) => '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

        for (final w in repo.weights) {
          final k = ymd(w.dateTime);
          groups.putIfAbsent(k, () => {'am': null, 'pm': null, 'meals': <MealEntry>[]});
          groups[k]![w.tod] = w;
        }
        for (final m in repo.meals) {
          final k = ymd(m.dateTime);
          groups.putIfAbsent(k, () => {'am': null, 'pm': null, 'meals': <MealEntry>[]});
          (groups[k]!['meals'] as List<MealEntry>).add(m);
        }

        final days = groups.keys.toList()..sort((a,b)=> b.compareTo(a)); // 新しい順
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: days.length,
          itemBuilder: (context, i) {
            final day = days[i];
            final g = groups[day]!;
            final am = g['am'] as WeightEntry?;
            final pm = g['pm'] as WeightEntry?;
            final meals = (g['meals'] as List<MealEntry>);
            final kcal = meals.fold<int>(0, (s, m) => s + (m.kcal ?? 0));
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(day, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text('朝体重: ${am == null ? '-' : am.kg.toStringAsFixed(1)} kg / 夜体重: ${pm == null ? '-' : pm.kg.toStringAsFixed(1)} kg'),
                  Text('摂取カロリー: $kcal kcal'),
                  if (meals.isNotEmpty) const SizedBox(height: 6),
                  if (meals.isNotEmpty)
                    ...meals.map((m) => Text('・${m.note}${m.kcal == null ? '' : ' (${m.kcal}kcal)'}')).toList(),
                ]),
              ),
            );
          },
        );
      },
    );
  }
}

/// ====== グラフ（依存なしのシンプルスパークライン） ======
class ChartScreen extends StatelessWidget {
  const ChartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = RepositoryScope.of(context);
    return AnimatedBuilder(
      animation: repo,
      builder: (context, _) {
        if (repo.weights.isEmpty) {
          return const Center(child: Text('まだ体重データがありません'));
        }
        // 日毎の平均（朝/夜の平均）
        final byDay = <DateTime, List<double>>{};
        DateTime dayKey(DateTime d) => DateTime(d.year, d.month, d.day);
        for (final w in repo.weights) {
          final k = dayKey(w.dateTime);
          byDay.putIfAbsent(k, () => []);
          byDay[k]!.add(w.kg);
        }
        final points = byDay.keys.toList()
          ..sort();
        final series = points.map((d) => byDay[d]!.reduce((a,b)=>a+b)/byDay[d]!.length).toList();
        final avg7 = series.isEmpty ? 0 : series.takeLast(7).average();
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _Section(title: '体重推移（平均・日次）', child: SizedBox(
                height: 160,
                child: CustomPaint(painter: SparklinePainter(series), child: Container()),
              )),
              const SizedBox(height: 12),
              _RowItem(label: '直近7日平均', value: '${avg7 == 0 ? '-' : avg7.toStringAsFixed(1)} kg'),
            ],
          ),
        );
      },
    );
  }
}

class SparklinePainter extends CustomPainter {
  final List<double> values;
  SparklinePainter(this.values);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..color = Colors.teal;
    if (values.length < 2) return;
    final minV = values.reduce(math.min);
    final maxV = values.reduce(math.max);
    final range = (maxV - minV) == 0 ? 1 : (maxV - minV);
    final dx = size.width / (values.length - 1);

    final path = Path();
    for (int i = 0; i < values.length; i++) {
      final x = dx * i;
      final y = size.height - ((values[i] - minV) / range) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    // 背景の目安線
    final grid = Paint()
      ..color = Colors.teal.withOpacity(0.15)
      ..strokeWidth = 1;
    for (int i = 1; i < 4; i++) {
      final gy = size.height * i / 4;
      canvas.drawLine(Offset(0, gy), Offset(size.width, gy), grid);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant SparklinePainter oldDelegate) => oldDelegate.values != values;
}

/// ====== 設定 ======
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = RepositoryScope.of(context);

    final auth = AuthScope.of(context);
    final user = auth.currentUser;

    return AnimatedBuilder(
      animation: repo,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
            _Section(
              title: 'ユーザー',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _RowItem(label: '表示名', value: user?.displayName ?? '-'),
                  _RowItem(label: 'メール', value: user?.email ?? '-'),
                  const SizedBox(height: 8),
                  if (auth.isSignedIn)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.logout),
                      label: const Text('サインアウト'),
                      onPressed: () async {
                        await auth.signOut();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('サインアウトしました')),
                        );
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),

              ListTile(
                title: const Text('朝のリマインド時刻'),
                subtitle: Text(repo.reminderAm == null ? '未設定' : '${repo.reminderAm!.format(context)}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final t = await showTimePicker(context: context, initialTime: repo.reminderAm ?? const TimeOfDay(hour: 8, minute: 0));
                  if (t != null) await repo.setReminder(am: t);
                },
              ),
              ListTile(
                title: const Text('夜のリマインド時刻'),
                subtitle: Text(repo.reminderPm == null ? '未設定' : '${repo.reminderPm!.format(context)}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final t = await showTimePicker(context: context, initialTime: repo.reminderPm ?? const TimeOfDay(hour: 20, minute: 0));
                  if (t != null) await repo.setReminder(pm: t);
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('全データを削除'),
                onTap: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('確認'),
                      content: const Text('すべてのデータを削除しますか？'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
                        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('削除')),
                      ],
                    ),
                  );
                  if (ok == true) {
                    await repo.clearAll();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('削除しました')));
                  }
                },
              ),
              const Spacer(),
              const Text('v0.1.0  (ローカル保存のみ)'),
            ],
          ),
        );
      },
    );
  }
}

/// ====== UI 小物 ======
class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          child,
        ]),
      ),
    );
  }
}

class _RowItem extends StatelessWidget {
  final String label;
  final String value;
  const _RowItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
          Text(value, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _StreakCard extends StatelessWidget {
  const _StreakCard();

  @override
  Widget build(BuildContext context) {
    final repo = RepositoryScope.of(context);
    return AnimatedBuilder(
      animation: repo,
      builder: (context, _) {
        final streak = _calcStreak(repo.weights);
        return _Section(
          title: '連続記録',
          child: Text('$streak 日', style: Theme.of(context).textTheme.headlineMedium),
        );
      },
    );
  }

  int _calcStreak(List<WeightEntry> list) {
    if (list.isEmpty) return 0;
    DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
    final set = list.map((e) => day(e.dateTime)).toSet();
    int s = 0;
    var cur = day(DateTime.now());
    while (set.contains(cur)) {
      s++;
      cur = cur.subtract(const Duration(days: 1));
    }
    return s;
  }
}

/// ====== 拡張 ======
extension _Avg<T extends num> on Iterable<T> {
  double average() => isEmpty ? 0 : (fold<double>(0, (p, e) => p + e.toDouble()) / length);
  Iterable<T> takeLast(int n) => skip(length - (n.clamp(0, length)));
}

/// ====== 拡張FAB（ホーム画面用） ======
class ExpandableFab extends StatefulWidget {
  final List<Widget> children;
  const ExpandableFab({super.key, required this.children});

  @override
  State<ExpandableFab> createState() => _ExpandableFabState();
}

class _ExpandableFabState extends State<ExpandableFab> with SingleTickerProviderStateMixin {
  bool _open = false;
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: _open ? (56.0 * (widget.children.length + 1) + 8.0 * (widget.children.length)) : 56,
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          ...List.generate(widget.children.length, (i) {
            final child = widget.children[i];
            return Positioned(
              bottom: (56.0 + 8.0) * (i + 1),
              right: 0,
              child: FadeTransition(opacity: _c, child: ScaleTransition(scale: _c, child: child)),
            );
          }),
          FloatingActionButton(
            onPressed: () { setState(() { _open = !_open; if (_open) _c.forward(); else _c.reverse(); }); },
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: Icon(_open ? Icons.close : Icons.add, key: ValueKey(_open)),
            ),
          ),
        ],
      ),
    );
  }
}

