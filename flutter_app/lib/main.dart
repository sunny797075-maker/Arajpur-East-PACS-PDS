import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'github_sync.dart';
import 'local_store.dart';
import 'models.dart';
import 'tracker_controller.dart';

const tokenStore = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);
const tokenKey = 'pds.github.token';
const green = Color(0xff176344);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PdsApp());
}

class PdsApp extends StatelessWidget {
  const PdsApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Arajpur East PACS PDS',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: green),
      scaffoldBackgroundColor: const Color(0xfff5f7f3),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        filled: true,
        fillColor: Colors.white,
        contentPadding: EdgeInsets.all(16),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
    ),
    home: const Bootstrap(),
  );
}

class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key});
  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  late Future<TrackerController> loading;
  TrackerController? controller;
  http.Client? client;
  @override
  void initState() {
    super.initState();
    loading = load();
  }

  Future<TrackerController> load() async {
    final store = await DeviceStore.open();
    client = http.Client();
    final next = TrackerController(store, GitHubSync(client!));
    try {
      String? token;
      try {
        token = await tokenStore.read(key: tokenKey);
      } catch (_) {
        /* Offline use remains available if Android's keystore is locked. */
      }
      await next.initialize(token: token);
      controller = next;
      return next;
    } catch (_) {
      next.dispose();
      client?.close();
      rethrow;
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<TrackerController>(
    future: loading,
    builder: (context, snapshot) {
      if (snapshot.hasData) return TrackerScreen(controller: snapshot.data!);
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child:
                  snapshot.hasError
                      ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.storage, size: 48),
                          const SizedBox(height: 16),
                          const Text(
                            'Device data could not be opened. Existing records have not been erased.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '${snapshot.error}',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed:
                                () => setState(() {
                                  loading = load();
                                }),
                            child: const Text('Retry'),
                          ),
                        ],
                      )
                      : const CircularProgressIndicator(),
            ),
          ),
        ),
      );
    },
  );
}

enum SaleFilter { all, distributed, remaining }

class TrackerScreen extends StatefulWidget {
  final TrackerController controller;
  const TrackerScreen({super.key, required this.controller});
  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen>
    with WidgetsBindingObserver {
  TrackerController get tracker => widget.controller;
  StreamSubscription<List<ConnectivityResult>>? connectivity;
  int tab = 0;
  SaleFilter filter = SaleFilter.all;
  final search = TextEditingController();
  bool working = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    connectivity = Connectivity().onConnectivityChanged.listen(
      (result) {
        if (result.any((item) => item != ConnectivityResult.none)) {
          unawaited(tracker.sync());
        }
      },
      onError: (Object _) {
        /* Timed retry also handles connectivity-plugin errors. */
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(tracker.sync(force: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    connectivity?.cancel();
    search.dispose();
    super.dispose();
  }

  void message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> perform(
    Future<void> Function() operation, {
    String? success,
  }) async {
    if (working) return;
    setState(() => working = true);
    try {
      await operation();
      if (success != null) message(success);
    } catch (error) {
      message(error.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<bool> confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: Text(title),
              content: SingleChildScrollView(child: Text(body)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(action),
                ),
              ],
            ),
      ) ??
      false;
  Future<void> sell(Household person) async {
    final month = tracker.selectedMonth;
    if (!await confirm(
      'Confirm distribution',
      '${person.headName} · RC ${person.rcNumber}\n\n${monthLabel(month)}\nWheat ${quantity(person.wheat)} kg + Rice ${quantity(person.rice)} kg\n\nConfirm only after handing over this month’s ration.',
      'Record sale',
    )) {
      return;
    }
    if (!mounted) return;
    await perform(
      () => tracker.recordSale(person, month),
      success: 'Sale saved for ${monthLabel(month)}.',
    );
  }

  Future<void> call(String phone) async {
    try {
      if (!await launchUrl(
        Uri(scheme: 'tel', path: phone),
        mode: LaunchMode.externalApplication,
      )) {
        message('No dialer is available on this device.');
      }
    } catch (_) {
      message('Could not open the dialer. Phone: $phone');
    }
  }

  Widget metric(String title, String value, IconData icon) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xffdce4dc)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: green),
        const SizedBox(height: 12),
        Text(title, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(
            fontSize: 28,
            color: green,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
  Widget dashboard() {
    final total = tracker.data.households.length, served = tracker.served;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'MONTHLY OVERVIEW',
          style: TextStyle(
            color: green,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: tracker.selectedMonth,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Distribution month'),
          items:
              tracker.data.months.reversed
                  .map(
                    (month) => DropdownMenuItem(
                      value: month,
                      child: Text(monthLabel(month), softWrap: true),
                    ),
                  )
                  .toList(),
          onChanged:
              working
                  ? null
                  : (month) {
                    if (month != null) {
                      unawaited(perform(() => tracker.selectMonth(month)));
                    }
                  },
        ),
        const SizedBox(height: 12),
        Text(
          'Sales and remaining-family calls apply to ${monthLabel(tracker.selectedMonth)}.',
          style: const TextStyle(color: Color(0xff52675b)),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final columns =
                width < 350 || MediaQuery.textScalerOf(context).scale(1) > 1.5
                    ? 1
                    : 2;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children:
                  [
                        metric('Total cards', '$total', Icons.credit_card),
                        metric(
                          'Distributed',
                          '$served',
                          Icons.check_circle_outline,
                        ),
                        metric(
                          'Remaining',
                          '${total - served}',
                          Icons.people_outline,
                        ),
                        metric(
                          'Grain issued (kg)',
                          quantity(tracker.distributedKg),
                          Icons.grass,
                        ),
                      ]
                      .map(
                        (child) => SizedBox(
                          width: (width - (columns - 1) * 12) / columns,
                          child: child,
                        ),
                      )
                      .toList(),
            );
          },
        ),
        const SizedBox(height: 16),
        LinearProgressIndicator(
          value: total == 0 ? 0 : served / total,
          minHeight: 7,
          borderRadius: BorderRadius.circular(8),
        ),
        const SizedBox(height: 8),
        Text('$served of $total families served'),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget card(Household person) {
    final sale = tracker.data.saleFor(person.id, tracker.selectedMonth);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  person.headName,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Chip(
                  label: Text(sale == null ? 'REMAINING' : 'DISTRIBUTED'),
                  backgroundColor:
                      sale == null
                          ? const Color(0xffffefcb)
                          : const Color(0xffdcefe1),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('RC ${person.rcNumber} · ${person.members} family members'),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(person.phone),
                if (sale == null && filter == SaleFilter.remaining && tab == 0)
                  OutlinedButton.icon(
                    onPressed: () => call(person.phone),
                    icon: const Icon(Icons.call),
                    label: const Text('📞 Call'),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Wheat ${quantity(person.wheat)} kg · Rice ${quantity(person.rice)} kg',
            ),
            if (sale != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${monthLabel(sale.month)}: issued ${quantity(sale.wheat + sale.rice)} kg\nRecorded ${DateTime.parse(sale.recordedAt).toLocal().toString().substring(0, 16)}',
                  style: const TextStyle(color: green),
                ),
              ),
            if (sale == null && tab == 0)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: working ? null : () => sell(person),
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: const Text(
                      '📦 Sale / वितरण करें',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget admin() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        const SizedBox(height: 12),
        const Text(
          'Backup & administration',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: tracker.exportBackup()),
                );
                message(
                  'Backup JSON copied, including the offline queue. Paste it into a private file.',
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy backup JSON'),
            ),
            OutlinedButton.icon(
              onPressed:
                  working
                      ? null
                      : () async {
                        final next = adjacentMonth(tracker.data.months.last, 1);
                        if (await confirm(
                              'Start new month?',
                              'Add ${monthLabel(next)}? All previous records remain available.',
                              'Add month',
                            ) &&
                            mounted) {
                          await perform(
                            tracker.startMonth,
                            success: 'New month added.',
                          );
                        }
                      },
              icon: const Icon(Icons.calendar_month),
              label: const Text('Start New Month'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const Text(
          'Arajpur East PACS, Chausa, Madhepura, Bihar 853204',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        TextButton(
          onPressed: () => call('8757114064'),
          child: const Text('Mobile No. 8757114064'),
        ),
        const Text(
          'Offline first · Your pending changes stay on this device.',
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: tracker,
    builder: (context, _) {
      final query = search.text.trim().toLowerCase();
      final people =
          tracker.data.households.where((person) {
              final matches =
                  '${person.rcNumber} ${person.headName} ${person.phone}'
                      .toLowerCase()
                      .contains(query);
              final distributed =
                  tracker.data.saleFor(person.id, tracker.selectedMonth) !=
                  null;
              return matches &&
                  (tab == 1 ||
                      filter == SaleFilter.all ||
                      (filter == SaleFilter.distributed
                          ? distributed
                          : !distributed));
            }).toList()
            ..sort((a, b) => a.headName.compareTo(b.headName));
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            'Arajpur East PACS PDS',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
          toolbarHeight:
              80 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 3.0),
          actions: [
            IconButton(
              tooltip: 'GitHub settings',
              onPressed:
                  () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (context) => SettingsSheet(controller: tracker),
                  ),
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected:
              (value) => setState(() {
                tab = value;
              }),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.grass),
              label: '🌾 Sale / Search',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_add_outlined),
              label: '📝 Master Entry',
            ),
          ],
        ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xffe5eee4),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  tracker.syncing
                                      ? Icons.sync
                                      : tracker.pendingCount > 0
                                      ? Icons.cloud_upload_outlined
                                      : Icons.cloud_done_outlined,
                                  color: green,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    tracker.syncStatus,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Sync now',
                                  onPressed:
                                      tracker.syncing
                                          ? null
                                          : () => tracker.sync(force: true),
                                  icon: const Icon(Icons.refresh),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          dashboard(),
                          if (tab == 1)
                            HouseholdForm(
                              onSave: (person) async {
                                await tracker.addHousehold(person);
                                message('Household saved locally.');
                              },
                            ),
                          Text(
                            tab == 0
                                ? 'Distribution register'
                                : 'Registered families',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: search,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              labelText: 'Search RC number or head name',
                              prefixIcon: const Icon(Icons.search),
                              suffixIcon:
                                  search.text.isEmpty
                                      ? null
                                      : IconButton(
                                        tooltip: 'Clear search',
                                        onPressed: () => setState(search.clear),
                                        icon: const Icon(Icons.close),
                                      ),
                            ),
                          ),
                          if (tab == 0)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children:
                                    SaleFilter.values
                                        .map(
                                          (value) => FilterChip(
                                            label: Text(switch (value) {
                                              SaleFilter.all => 'All',
                                              SaleFilter.distributed =>
                                                'Distributed Only',
                                              SaleFilter.remaining =>
                                                'Remaining Only',
                                            }),
                                            selected: filter == value,
                                            onSelected:
                                                (_) => setState(
                                                  () => filter = value,
                                                ),
                                            materialTapTargetSize:
                                                MaterialTapTargetSize.padded,
                                          ),
                                        )
                                        .toList(),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              '${people.length} families · ${monthLabel(tracker.selectedMonth)}',
                            ),
                          ),
                          if (people.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Text(
                                'No matching families. Add a household or change your search/filter.',
                                textAlign: TextAlign.center,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverList.builder(
                      itemCount: people.length,
                      itemBuilder: (context, index) => card(people[index]),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverToBoxAdapter(child: admin()),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class HouseholdForm extends StatefulWidget {
  final Future<void> Function(Household) onSave;
  const HouseholdForm({super.key, required this.onSave});
  @override
  State<HouseholdForm> createState() => _HouseholdFormState();
}

class _HouseholdFormState extends State<HouseholdForm> {
  final form = GlobalKey<FormState>();
  final fields = List.generate(6, (_) => TextEditingController());
  bool saving = false;
  @override
  void dispose() {
    for (final field in fields) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> submit() async {
    if (saving || !form.currentState!.validate()) return;
    setState(() => saving = true);
    try {
      final person = Household.fromJson({
        'id': newId(),
        'rcNumber': fields[0].text.trim(),
        'headName': fields[1].text.trim(),
        'phone': fields[2].text.trim(),
        'members': int.tryParse(fields[3].text),
        'wheat': double.tryParse(fields[4].text),
        'rice': double.tryParse(fields[5].text),
      });
      await widget.onSave(person);
      for (final field in fields) {
        field.clear();
      }
      form.currentState?.reset();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const labels = [
      'RC number',
      'Head of family',
      'Phone number',
      'Family members',
      'Wheat quota (kg)',
      'Rice quota (kg)',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Form(
        key: form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Add a beneficiary',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < fields.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: TextFormField(
                  controller: fields[i],
                  enabled: !saving,
                  decoration: InputDecoration(labelText: labels[i]),
                  maxLength:
                      i == 0
                          ? 40
                          : i == 1
                          ? 100
                          : i == 2
                          ? 20
                          : 8,
                  keyboardType:
                      i == 2
                          ? TextInputType.phone
                          : i >= 3
                          ? const TextInputType.numberWithOptions(decimal: true)
                          : TextInputType.text,
                  textInputAction:
                      i == 5 ? TextInputAction.done : TextInputAction.next,
                  validator:
                      (value) =>
                          value == null || value.trim().isEmpty
                              ? 'Required'
                              : null,
                  onFieldSubmitted: i == 5 ? (_) => submit() : null,
                ),
              ),
            FilledButton.icon(
              onPressed: saving ? null : submit,
              icon: const Icon(Icons.person_add),
              label: Text(saving ? 'Saving on device…' : 'Add beneficiary'),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsSheet extends StatefulWidget {
  final TrackerController controller;
  const SettingsSheet({super.key, required this.controller});
  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  final token = TextEditingController();
  bool saving = false;
  String? error;
  @override
  void dispose() {
    token.dispose();
    super.dispose();
  }

  Future<void> save({bool remove = false}) async {
    if (saving || widget.controller.syncing) return;
    final value = token.text.trim();
    if (!remove && (value.isEmpty || RegExp(r'\s').hasMatch(value))) {
      setState(() => error = 'Enter a valid GitHub token without spaces.');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      if (remove) {
        await tokenStore.delete(key: tokenKey);
      } else {
        await tokenStore.write(key: tokenKey, value: value);
      }
      widget.controller.setToken(remove ? null : value);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              error = 'Secure token storage failed. The token was not changed.',
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder:
        (context, _) => Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'GitHub sync settings',
                  style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const SelectableText(GitHubSync.repository),
                const SizedBox(height: 12),
                const Text(
                  'Database API',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SelectableText(GitHubSync.databaseApiUrl),
                const SizedBox(height: 12),
                const Text(
                  'Published website',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SelectableText(GitHubSync.websiteUrl),
                OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open PDS website'),
                  onPressed: () async {
                    try {
                      final opened = await launchUrl(
                        Uri.parse(GitHubSync.websiteUrl),
                        mode: LaunchMode.externalApplication,
                      );
                      if (!opened && mounted) {
                        setState(
                          () =>
                              error =
                                  'No browser is available to open the website.',
                        );
                      }
                    } catch (_) {
                      if (mounted) {
                        setState(() => error = 'Could not open the website.');
                      }
                    }
                  },
                ),
                const Text(
                  'GitHub Pages displays the website. Background sync reads and writes data.json through the authenticated GitHub REST API. Browser-local records do not automatically sync to this phone.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Use a private repository and a fine-grained token limited to this repository with Contents: Read and write. Sync uses data.json on its default branch. The token is encrypted with Android secure storage and is never included in backups.',
                ),
                const SizedBox(height: 16),
                Text(
                  widget.controller.hasToken
                      ? 'A token is saved. Enter a replacement to change it.'
                      : 'No token saved. Offline tracking works without one.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: token,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  autofillHints: const [],
                  decoration: InputDecoration(
                    labelText: 'Personal Access Token',
                    errorText: error,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: saving || widget.controller.syncing ? null : save,
                  child: Text(saving ? 'Saving…' : 'Save token & sync'),
                ),
                if (widget.controller.hasToken)
                  TextButton(
                    onPressed:
                        saving || widget.controller.syncing
                            ? null
                            : () => save(remove: true),
                    child: const Text('Remove token / Disconnect'),
                  ),
                if (widget.controller.syncing)
                  const Text(
                    'Wait for the current sync to finish before changing credentials.',
                  ),
                const SizedBox(height: 8),
                const Text(
                  'Queued changes retry when the connection returns, periodically while the app is running, and when you reopen it. Android may suspend the app in the background.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
  );
}
