import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import '../auth/controller.dart';
import '../auth/models.dart';
import '../work/api.dart';
import '../work/importer.dart';
import 'theme.dart';

String monthKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}';
String dateKey(DateTime d) =>
    '${monthKey(d)}-${d.day.toString().padLeft(2, '0')}';
String readable(dynamic value) {
  if (value == null) return '—';
  final d = DateTime.tryParse(value.toString());
  return d == null
      ? value.toString()
      : '${dateKey(d.toLocal())} ${d.toLocal().hour.toString().padLeft(2, '0')}:${d.toLocal().minute.toString().padLeft(2, '0')}';
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.auth, this.apiFactory});
  final AuthController auth;
  final WorkApi Function(AuthController)? apiFactory;
  @override
  State<DashboardPage> createState() => _DashboardState();
}

class _DashboardState extends State<DashboardPage> {
  late final WorkApi api;
  String module = 'Dashboard',
      month = monthKey(DateTime.now()),
      filter = 'ALL',
      search = '',
      attendanceDate = dateKey(DateTime.now());
  String? error;
  bool loading = false, mutating = false;
  int page = 1, total = 0, generation = 0;
  Map<String, dynamic> metrics = {};
  List<dynamic> rows = [], staff = [], attendance = [], plans = [];
  Timer? debounce;
  final searchController = TextEditingController();
  bool get admin => widget.auth.session?.role == AccountRole.superAdmin;
  List<String> get modules =>
      admin
          ? ['Dashboard', 'Distributors', 'Subscription plans']
          : [
            'Dashboard',
            'Beneficiaries',
            'Excel / CSV import',
            'PDS distribution',
            'Remaining beneficiaries',
            'Staff',
            'Attendance',
            'Profile / settings',
          ];
  @override
  void initState() {
    super.initState();
    api = widget.apiFactory?.call(widget.auth) ?? WorkApi(widget.auth);
    unawaited(load());
  }

  @override
  void dispose() {
    generation++;
    debounce?.cancel();
    searchController.dispose();
    api.dispose();
    super.dispose();
  }

  void message(Object e) {
    if (mounted) {
      setState(
        () =>
            error =
                e is AuthFailure
                    ? e.message
                    : e is FormatException
                    ? e.message.toString()
                    : 'The operation could not be completed.',
      );
    }
  }

  Future<void> load() async {
    final run = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      dynamic data;
      if (admin) {
        data =
            module == 'Subscription plans'
                ? await api.request('GET', 'platform/plans')
                : await api.request(
                  'GET',
                  'platform/distributors?page=$page&search=${Uri.encodeQueryComponent(search)}',
                );
      } else {
        final overview = await api.request('GET', 'work/overview?month=$month');
        if (!mounted || run != generation) return;
        metrics = Map<String, dynamic>.from(overview);
        if ([
          'Beneficiaries',
          'PDS distribution',
          'Remaining beneficiaries',
        ].contains(module)) {
          data = await api.request(
            'GET',
            'work/beneficiaries?month=$month&filter=${module == 'Remaining beneficiaries' ? 'REMAINING' : filter}&page=$page&search=${Uri.encodeQueryComponent(search)}',
          );
        } else if (module == 'Staff' || module == 'Attendance') {
          final result = await Future.wait([
            api.request('GET', 'work/staff'),
            api.request('GET', 'work/attendance?month=$month'),
          ]);
          if (!mounted || run != generation) return;
          staff = result[0] as List;
          attendance = result[1] as List;
        } else if (module == 'Profile / settings') {
          data = await api.request('GET', 'distributor/me');
        }
      }
      if (!mounted || run != generation) return;
      setState(() {
        if (data is Map && data.containsKey('rows')) {
          rows = data['rows'] as List;
          total = data['total'] as int;
        } else if (module == 'Subscription plans') {
          plans = data as List;
        } else if (module == 'Profile / settings') {
          rows = [data];
        }
      });
    } catch (e) {
      if (mounted && run == generation) message(e);
    } finally {
      if (mounted && run == generation) setState(() => loading = false);
    }
  }

  void navigate(String next) {
    debounce?.cancel();
    setState(() {
      module = next;
      rows = [];
      search = '';
      searchController.clear();
      filter = 'ALL';
      page = 1;
    });
    unawaited(load());
  }

  Future<void> action(Future<void> Function() work) async {
    if (mutating) return;
    setState(() {
      mutating = true;
      error = null;
    });
    try {
      await work();
      if (mounted) await load();
    } catch (e) {
      message(e);
    } finally {
      if (mounted) setState(() => mutating = false);
    }
  }

  Future<bool> confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder:
            (c) => AlertDialog(
              title: Text(title),
              content: Text(text),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Confirm'),
                ),
              ],
            ),
      ) ??
      false;
  Future<void> distribute(Map<String, dynamic> b) async {
    if (!await confirm(
      'Confirm distribution',
      'Record ration distribution for ${b['name']} (${b['card_number']}) for $month?',
    )) {
      return;
    }
    await action(() async {
      await api.request('POST', 'work/distribute', {
        'beneficiaryId': b['id'],
        'month': month,
        'commandId': const Uuid().v4(),
      });
    });
  }

  Future<void> call(String phone) async {
    try {
      if (!await launchUrl(Uri(scheme: 'tel', path: phone))) {
        throw const AuthFailure('No phone dialer is available on this device.');
      }
    } catch (e) {
      message(e);
    }
  }

  Future<void> beneficiary([Map<String, dynamic>? b]) async {
    final values = await editForm(
      context,
      title: b == null ? 'Add beneficiary' : 'Edit beneficiary',
      fields: {
        'cardNumber': 'Ration Card Number',
        'name': 'Head of Family Name',
        'mobile': 'Mobile Number',
        'units': 'Total Units',
        'category': 'Category',
        'address': 'Address',
        'village': 'Village',
      },
      initial: {
        'cardNumber': b?['card_number'] ?? '',
        'name': b?['name'] ?? '',
        'mobile': b?['mobile'] ?? '',
        'units': b?['family_members']?.toString() ?? '1',
        'category': b?['category'] ?? 'PHH',
        'address': b?['address'] ?? '',
        'village': b?['village'] ?? '',
      },
      optional: {'address', 'village'},
    );
    if (values == null) return;
    await action(() async {
      await api.request(
        b == null ? 'POST' : 'PATCH',
        b == null ? 'work/beneficiaries' : 'work/beneficiaries/${b['id']}',
        {...values, 'units': int.parse(values['units']!)},
      );
    });
  }

  Future<void> editStaff([Map<String, dynamic>? s]) async {
    final values = await editForm(
      context,
      title: s == null ? 'Add staff' : 'Edit staff',
      fields: {
        'name': 'Staff Name',
        'mobile': 'Mobile Number',
        'workDetails': 'Role / Work Details',
        'active': 'Status',
      },
      initial: {
        'name': s?['name'] ?? '',
        'mobile': s?['mobile'] ?? '',
        'workDetails': s?['work_details'] ?? '',
        'active': s?['active'] == false ? 'Inactive' : 'Active',
      },
    );
    if (values == null) return;
    await action(() async {
      await api.request(
        s == null ? 'POST' : 'PATCH',
        s == null ? 'work/staff' : 'work/staff/${s['id']}',
        {...values, 'active': values['active'] == 'Active'},
      );
    });
  }

  Future<void> importFile() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'xlsx'],
        withData: true,
      );
      if (picked == null || !mounted) return;
      final file = picked.files.single;
      if (file.bytes == null) {
        throw const FormatException('The selected file could not be read.');
      }
      final entries = parseBeneficiaries(file.name, file.bytes!);
      await action(() async {
        final preview = await api.request('POST', 'work/import', {
          'rows': entries,
          'fileName': file.name,
          'preview': true,
        });
        if (preview['valid'] != true) {
          throw AuthFailure((preview['errors'] as List).take(10).join('\n'));
        }
        if (!mounted) return;
        if (!await confirm(
          'Import ${entries.length} beneficiaries?',
          '${entries.take(5).map((r) => '${r['cardNumber']} · ${r['name']} · ${r['category']} · ${r['units']} units').join('\n')}\n\nCheck that card numbers retain any leading zeros. All rows will be saved to your distributor account.',
        )) {
          return;
        }
        final result = await api.request('POST', 'work/import', {
          'rows': entries,
          'fileName': file.name,
          'preview': false,
        });
        if (result['valid'] != true) {
          throw AuthFailure((result['errors'] as List).join('\n'));
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${result['imported']} beneficiaries imported.'),
            ),
          );
        }
      });
    } catch (e) {
      message(e);
    }
  }

  Future<void> platformAction(Map<String, dynamic> d, String operation) async {
    if (operation == 'History') {
      await action(() async {
        final data = await api.request(
          'GET',
          'platform/distributors/${d['id']}/history',
        );
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder:
              (c) => AlertDialog(
                title: Text('${d['distributor_id']} · History'),
                content: SizedBox(
                  width: 550,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Payments',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        if ((data['payments'] as List).isEmpty)
                          const Text('No payments recorded.'),
                        for (final p in data['payments'])
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              '₹${(num.parse(p['amount_paise'].toString()) / 100).toStringAsFixed(2)} · ${p['status']}',
                            ),
                            subtitle: Text(
                              '${p['gateway']} · ${p['order_id']}\n${readable(p['paid_at'])}',
                            ),
                          ),
                        const Text(
                          'Access approvals',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        for (final g in data['approvals'])
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              '${g['source']} · until ${readable(g['expires_at'])}',
                            ),
                            subtitle: Text(g['reason'].toString()),
                          ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text('Close'),
                  ),
                ],
              ),
        );
      });
      return;
    }
    if (operation == 'Approve without payment') {
      final v = await editForm(
        context,
        title: operation,
        fields: {'days': 'Extend access by days', 'reason': 'Approval reason'},
        initial: {'days': '30'},
      );
      if (v == null) return;
      await action(() async {
        await api.request('POST', 'platform/distributors/${d['id']}/approve', {
          ...v,
          'days': int.parse(v['days']!),
        });
      });
    } else if (operation == 'Record payment') {
      try {
        final available = await api.request('GET', 'platform/plans') as List;
        if (!mounted) return;
        if (available.isEmpty) {
          throw const AuthFailure('Create a subscription plan first.');
        }
        final selected = await showDialog<Map<String, dynamic>>(
          context: context,
          builder:
              (c) => SimpleDialog(
                title: const Text('Select paid plan'),
                children: [
                  for (final p in available)
                    SimpleDialogOption(
                      onPressed:
                          () => Navigator.pop(c, Map<String, dynamic>.from(p)),
                      child: Text(
                        '${p['name']} · ₹${num.parse(p['price_paise'].toString()) / 100} · ${p['billing_days']} days',
                      ),
                    ),
                ],
              ),
        );
        if (selected == null || !mounted) return;
        final v = await editForm(
          context,
          title: 'Confirm money actually received',
          fields: {
            'reference': 'Unique payment receipt reference',
            'reason': 'Payment details / receipt note',
          },
        );
        if (v == null) return;
        await action(() async {
          await api.request(
            'POST',
            'platform/distributors/${d['id']}/payment',
            {...v, 'planId': selected['id']},
          );
        });
      } catch (e) {
        message(e);
      }
    } else {
      final v = await editForm(
        context,
        title: 'Suspend distributor',
        fields: {'reason': 'Reason for suspension'},
      );
      if (v == null) return;
      await action(() async {
        await api.request('PATCH', 'admin/distributors/${d['id']}/status', {
          'status': 'SUSPENDED',
          ...v,
        });
      });
    }
  }

  Widget navigation() => SafeArea(
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Brand(),
        const SizedBox(height: 24),
        for (final item in modules)
          ListTile(
            selected: module == item,
            selectedTileColor: const Color(0xFFE5EEE5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            title: Text(item),
            onTap: () {
              if (Scaffold.maybeOf(context)?.isDrawerOpen == true) {
                Navigator.pop(context);
              }
              navigate(item);
            },
          ),
        const Divider(),
        ListTile(
          title: const Text('Sign out'),
          leading: const Icon(Icons.logout),
          onTap: widget.auth.logout,
        ),
      ],
    ),
  );
  Widget searchBox() => TextField(
    controller: searchController,
    decoration: InputDecoration(
      labelText: admin ? 'Search distributor' : 'Search card, name or mobile',
      prefixIcon: const Icon(Icons.search),
    ),
    onChanged: (v) {
      search = v;
      page = 1;
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 250), load);
    },
  );
  Widget pager() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Expanded(child: Text('$total records · Page $page')),
      IconButton(
        tooltip: 'Previous page',
        onPressed:
            page > 1 && !loading
                ? () {
                  page--;
                  load();
                }
                : null,
        icon: const Icon(Icons.chevron_left),
      ),
      IconButton(
        tooltip: 'Next page',
        onPressed:
            page * 50 < total && !loading
                ? () {
                  page++;
                  load();
                }
                : null,
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );
  Widget metric(String label, dynamic value) => SizedBox(
    width: 190,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(height: 10),
            Text(
              '${value ?? 0}',
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                color: green,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  List<Widget> content() {
    if (admin) {
      if (module == 'Subscription plans') {
        return [
          FilledButton.icon(
            onPressed:
                mutating
                    ? null
                    : () async {
                      final v = await editForm(
                        context,
                        title: 'New subscription plan',
                        fields: {
                          'name': 'Plan name',
                          'amount': 'Amount in rupees',
                          'days': 'Duration in days',
                        },
                        initial: {'days': '30'},
                      );
                      if (v != null) {
                        await action(() async {
                          await api.request('POST', 'platform/plans', {
                            'name': v['name'],
                            'amountPaise':
                                (double.parse(v['amount']!) * 100).round(),
                            'days': int.parse(v['days']!),
                          });
                        });
                      }
                    },
            icon: const Icon(Icons.add),
            label: const Text('Create plan'),
          ),
          for (final p in plans)
            Card(
              child: ListTile(
                title: Text(p['name'].toString()),
                subtitle: Text(
                  '₹${num.parse(p['price_paise'].toString()) / 100} · ${p['billing_days']} days',
                ),
                trailing: Switch(
                  value: p['active'] == true,
                  onChanged:
                      mutating
                          ? null
                          : (active) => action(() async {
                            await api.request(
                              'PATCH',
                              'platform/plans/${p['id']}',
                              {'active': active},
                            );
                          }),
                ),
              ),
            ),
          if (plans.isEmpty)
            const Text('No plans yet. Create your first subscription plan.'),
        ];
      }
      return [
        const Text(
          'Manage platform access and payments. Beneficiary and staff data remain private to each distributor.',
        ),
        const SizedBox(height: 16),
        searchBox(),
        pager(),
        for (final raw in rows)
          Builder(
            builder: (context) {
              final d = Map<String, dynamic>.from(raw);
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d['organization_name'].toString(),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text('${d['distributor_id']} · ${d['owner_name']}'),
                      Text('${d['mobile']} · ${d['email']}'),
                      Text('${d['district']}, ${d['state']}'),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        children: [
                          Chip(label: Text(d['payment_status'].toString())),
                          Chip(label: Text(d['access_status'].toString())),
                          if (d['source'] == 'MANUAL')
                            const Chip(label: Text('Manually Approved')),
                        ],
                      ),
                      Text('Subscription expiry: ${readable(d['expires_at'])}'),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final op in [
                            'Approve without payment',
                            'Record payment',
                            'History',
                            'Suspend',
                          ])
                            TextButton(
                              onPressed:
                                  mutating ? null : () => platformAction(d, op),
                              child: Text(op),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        if (rows.isEmpty && !loading) const Text('No distributors found.'),
      ];
    }
    if (module == 'Dashboard') {
      return [
        Text(
          'Welcome, ${widget.auth.session?.name ?? ''}',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            metric('Total Beneficiaries', metrics['total']),
            metric('Distributed', metrics['distributed']),
            metric('Remaining', metrics['remaining']),
            metric("Today's Distribution", metrics['today']),
            metric('Active Staff', metrics['staff']),
            metric("Today's Attendance", metrics['present']),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          'Access: ${metrics['access'] == null
              ? 'Awaiting approval'
              : DateTime.parse(metrics['access']['expires_at'].toString()).isBefore(DateTime.now())
              ? 'Expired'
              : metrics['access']['source'] == 'MANUAL'
              ? 'Manually Approved'
              : 'Paid'} · Expiry: ${readable(metrics['access']?['expires_at'])}',
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton(
              onPressed: () => navigate('PDS distribution'),
              child: const Text('Distribute ration'),
            ),
            OutlinedButton(
              onPressed: () => navigate('Remaining beneficiaries'),
              child: const Text('View remaining families'),
            ),
            OutlinedButton(
              onPressed: () => navigate('Attendance'),
              child: const Text('Mark attendance'),
            ),
          ],
        ),
      ];
    }
    if (module == 'Excel / CSV import') {
      return [
        const Text(
          'Import beneficiaries',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        const Text(
          'Choose a CSV or Excel (.xlsx) file. The first worksheet is used. Up to 500 rows and 5 MB per file. Required column headers:',
        ),
        const SizedBox(height: 12),
        const SelectableText(
          'Ration Card Number, Head of Family Name, Mobile Number, Total Units, Category, Address, Village',
        ),
        const SizedBox(height: 12),
        const Text(
          'Category must be PHH or AAY. Address and Village are optional. Format card and mobile columns as text to preserve leading zeros. Duplicate cards are rejected; existing records are never overwritten by an import.',
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: mutating ? null : importFile,
          icon: const Icon(Icons.upload_file),
          label: const Text('Choose file and validate'),
        ),
      ];
    }
    if (module == 'Staff') {
      return [
        FilledButton.icon(
          onPressed: mutating ? null : () => editStaff(),
          icon: const Icon(Icons.person_add),
          label: const Text('Add staff'),
        ),
        const Text(
          'Up to 3 active staff. Deactivating a member preserves attendance history.',
        ),
        for (final s in staff)
          Card(
            child: ListTile(
              isThreeLine: true,
              title: Text(s['name'].toString()),
              subtitle: Text(
                '${s['mobile']} · ${s['work_details']}\n${s['active'] ? 'Active' : 'Inactive'}',
              ),
              trailing: IconButton(
                tooltip: 'Edit staff',
                onPressed:
                    mutating
                        ? null
                        : () => editStaff(Map<String, dynamic>.from(s)),
                icon: const Icon(Icons.edit),
              ),
            ),
          ),
        if (staff.isEmpty) const Text('No staff members yet.'),
      ];
    }
    if (module == 'Attendance') {
      return [
        OutlinedButton.icon(
          onPressed: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: DateTime.parse(attendanceDate),
              firstDate: DateTime(2020),
              lastDate: DateTime.now(),
            );
            if (d != null) {
              setState(() {
                attendanceDate = dateKey(d);
                month = monthKey(d);
              });
              load();
            }
          },
          icon: const Icon(Icons.calendar_month),
          label: Text('Attendance date: $attendanceDate'),
        ),
        for (final s in staff.where((s) => s['active'] == true))
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s['name'].toString(),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    attendance
                            .where(
                              (a) =>
                                  a['staff_id'] == s['id'] &&
                                  a['attendance_date'].toString().startsWith(
                                    attendanceDate,
                                  ),
                            )
                            .map((a) => a['status'])
                            .firstOrNull
                            ?.toString() ??
                        'Not marked',
                  ),
                  Wrap(
                    spacing: 10,
                    children: [
                      for (final status in ['PRESENT', 'ABSENT'])
                        OutlinedButton(
                          onPressed:
                              mutating
                                  ? null
                                  : () => action(() async {
                                    await api
                                        .request('POST', 'work/attendance', {
                                          'staffId': s['id'],
                                          'date': attendanceDate,
                                          'status': status,
                                        });
                                  }),
                          child: Text(status),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 20),
        Text(
          'Monthly attendance · $month',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        for (final s in staff)
          ExpansionTile(
            title: Text(s['name'].toString()),
            subtitle: Text(
              '${attendance.where((a) => a['staff_id'] == s['id'] && a['status'] == 'PRESENT').length} present · ${attendance.where((a) => a['staff_id'] == s['id'] && a['status'] == 'ABSENT').length} absent',
            ),
            children: [
              for (final a in attendance.where((a) => a['staff_id'] == s['id']))
                ListTile(
                  title: Text(a['attendance_date'].toString().substring(0, 10)),
                  trailing: Text(a['status'].toString()),
                ),
            ],
          ),
        if (staff.isEmpty) const Text('Add staff to mark attendance.'),
      ];
    }
    if (module == 'Profile / settings') {
      return [
        if (rows.isNotEmpty) ...[
          Text(
            rows.first['organization_name'].toString(),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          Text(
            '${rows.first['distributor_id']}\n${rows.first['address']}\n${rows.first['district']}, ${rows.first['state']} ${rows.first['pin_code']}\n${rows.first['mobile']}',
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed:
                mutating
                    ? null
                    : () async {
                      final p = rows.first;
                      final fields = {
                        'organizationName': 'Organization name',
                        'contactPerson': 'Contact person',
                        'state': 'State',
                        'district': 'District',
                        'block': 'Block',
                        'panchayat': 'Panchayat',
                        'village': 'Village',
                        'address': 'Address',
                        'pinCode': 'PIN code',
                      };
                      final v = await editForm(
                        context,
                        title: 'Edit profile',
                        fields: fields,
                        initial: {
                          'organizationName': p['organization_name'],
                          'contactPerson': p['contact_person'] ?? '',
                          'state': p['state'],
                          'district': p['district'],
                          'block': p['block'],
                          'panchayat': p['panchayat'],
                          'village': p['village'],
                          'address': p['address'],
                          'pinCode': p['pin_code'],
                        },
                        optional: {'contactPerson'},
                      );
                      if (v != null) {
                        await action(() async {
                          await api.request('PATCH', 'distributor/me', {
                            ...v,
                            'contactPerson':
                                v['contactPerson']!.isEmpty
                                    ? null
                                    : v['contactPerson'],
                          });
                        });
                      }
                    },
            child: const Text('Edit profile'),
          ),
        ],
      ];
    }
    return [
      if (module == 'Beneficiaries')
        FilledButton.icon(
          onPressed: mutating ? null : () => beneficiary(),
          icon: const Icon(Icons.person_add_alt),
          label: const Text('Add beneficiary'),
        ),
      const SizedBox(height: 12),
      searchBox(),
      if (module != 'Remaining beneficiaries')
        Wrap(
          spacing: 8,
          children: [
            for (final f in ['ALL', 'DISTRIBUTED', 'REMAINING'])
              ChoiceChip(
                label: Text(f),
                selected: filter == f,
                onSelected: (_) {
                  setState(() {
                    filter = f;
                    page = 1;
                  });
                  load();
                },
              ),
          ],
        ),
      pager(),
      for (final raw in rows)
        Builder(
          builder: (context) {
            final b = Map<String, dynamic>.from(raw);
            final served = b['distributed_at'] != null;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      b['name'].toString(),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    SelectableText('RC: ${b['card_number']}'),
                    Text(
                      '${b['category'] ?? '—'} · ${b['family_members'] ?? '—'} units',
                    ),
                    Text(
                      '${b['mobile'] ?? ''}\n${b['address'] ?? ''} ${b['village'] ?? ''}',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      served
                          ? 'DISTRIBUTED · ${readable(b['distributed_at'])}'
                          : 'REMAINING · $month',
                      style: TextStyle(
                        color: served ? green : Colors.brown,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (!served)
                          FilledButton.icon(
                            onPressed: mutating ? null : () => distribute(b),
                            icon: const Icon(Icons.inventory_2_outlined),
                            label: const Text('Distribute / वितरण करें'),
                          ),
                        if (!served && b['mobile'] != null)
                          OutlinedButton.icon(
                            onPressed: () => call(b['mobile'].toString()),
                            icon: const Icon(Icons.call),
                            label: const Text('Call'),
                          ),
                        if (module == 'Beneficiaries') ...[
                          TextButton(
                            onPressed: mutating ? null : () => beneficiary(b),
                            child: const Text('Edit'),
                          ),
                          TextButton(
                            onPressed:
                                mutating
                                    ? null
                                    : () async {
                                      if (await confirm(
                                        'Delete beneficiary?',
                                        'Remove ${b['name']} from active lists? Distribution history will be preserved.',
                                      )) {
                                        await action(() async {
                                          await api.request(
                                            'DELETE',
                                            'work/beneficiaries/${b['id']}',
                                          );
                                        });
                                      }
                                    },
                            child: const Text('Delete'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      if (rows.isEmpty && !loading)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('No matching beneficiaries.'),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (widget.auth.session == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final months =
        {
            month,
            ...List.generate(
              24,
              (i) => monthKey(
                DateTime(DateTime.now().year, DateTime.now().month - i),
              ),
            ),
          }.toList()
          ..sort((a, b) => b.compareTo(a));
    return LayoutBuilder(
      builder: (context, limits) {
        final desktop = limits.maxWidth >= 1050;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              admin ? 'Super Admin workspace' : 'Distributor workspace',
              style: const TextStyle(fontSize: 18),
            ),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: loading ? null : load,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: 'Sign out',
                onPressed: widget.auth.logout,
                icon: const Icon(Icons.logout),
              ),
            ],
          ),
          drawer:
              desktop
                  ? null
                  : Drawer(
                    child: Builder(
                      builder:
                          (drawerContext) => SafeArea(
                            child: ListView(
                              padding: const EdgeInsets.all(20),
                              children: [
                                const Brand(),
                                for (final item in modules)
                                  ListTile(
                                    title: Text(item),
                                    selected: module == item,
                                    onTap: () {
                                      Navigator.pop(drawerContext);
                                      navigate(item);
                                    },
                                  ),
                              ],
                            ),
                          ),
                    ),
                  ),
          body: SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (desktop)
                  SizedBox(
                    width: 260,
                    child: ColoredBox(color: Colors.white, child: navigation()),
                  ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: load,
                    child: ListView(
                      padding: EdgeInsets.all(limits.maxWidth < 500 ? 16 : 32),
                      children: [
                        Text(
                          module,
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 20),
                        if (!admin)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: DropdownButtonFormField<String>(
                              value: month,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Distribution / attendance month',
                              ),
                              items:
                                  months
                                      .map(
                                        (m) => DropdownMenuItem(
                                          value: m,
                                          child: Text(m),
                                        ),
                                      )
                                      .toList(),
                              onChanged:
                                  loading
                                      ? null
                                      : (v) {
                                        setState(() {
                                          month = v!;
                                          page = 1;
                                        });
                                        load();
                                      },
                            ),
                          ),
                        if (loading || mutating)
                          const LinearProgressIndicator(),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Notice(error!, error: true),
                          ),
                        ...content(),
                        const SizedBox(height: 32),
                        if (!admin)
                          Text(widget.auth.session?.profile?.contactText ?? ''),
                        const SizedBox(height: 8),
                        const Text(
                          'Powered by MENHI GLOBAL TECH',
                          style: TextStyle(fontSize: 12, color: green),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

Future<Map<String, String>?> editForm(
  BuildContext context, {
  required String title,
  required Map<String, String> fields,
  Map<String, dynamic> initial = const {},
  Set<String> optional = const {},
}) async {
  final controllers = {
    for (final key in fields.keys)
      key: TextEditingController(text: initial[key]?.toString() ?? ''),
  };
  final key = GlobalKey<FormState>();
  final result = await showDialog<Map<String, String>>(
    context: context,
    barrierDismissible: false,
    builder:
        (c) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: Form(
                key: key,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final entry in fields.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child:
                            ['category', 'active'].contains(entry.key)
                                ? DropdownButtonFormField<String>(
                                  value:
                                      controllers[entry.key]!.text.isEmpty
                                          ? null
                                          : controllers[entry.key]!.text,
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    labelText: entry.value,
                                  ),
                                  items:
                                      (entry.key == 'category'
                                              ? ['PHH', 'AAY']
                                              : ['Active', 'Inactive'])
                                          .map(
                                            (v) => DropdownMenuItem(
                                              value: v,
                                              child: Text(v),
                                            ),
                                          )
                                          .toList(),
                                  onChanged:
                                      (v) => controllers[entry.key]!.text = v!,
                                  validator:
                                      (v) =>
                                          v == null ? 'Choose a value.' : null,
                                )
                                : TextFormField(
                                  controller: controllers[entry.key],
                                  decoration: InputDecoration(
                                    labelText: entry.value,
                                  ),
                                  keyboardType:
                                      [
                                            'units',
                                            'days',
                                            'amount',
                                            'mobile',
                                            'pinCode',
                                          ].contains(entry.key)
                                          ? TextInputType.number
                                          : TextInputType.text,
                                  maxLength:
                                      entry.key == 'address' ||
                                              entry.key == 'reason'
                                          ? 500
                                          : 150,
                                  validator: (v) {
                                    final value = v?.trim() ?? '';
                                    if (value.isEmpty) {
                                      return optional.contains(entry.key)
                                          ? null
                                          : 'Required.';
                                    }
                                    if (['units', 'days'].contains(entry.key)) {
                                      final n = int.tryParse(value);
                                      if (n == null ||
                                          n < 1 ||
                                          n >
                                              (entry.key == 'units'
                                                  ? 100
                                                  : 3660)) {
                                        return 'Enter a valid positive whole number.';
                                      }
                                    }
                                    if (entry.key == 'amount' &&
                                        (double.tryParse(value) == null ||
                                            double.parse(value) < 0)) {
                                      return 'Enter a valid amount.';
                                    }
                                    if (entry.key == 'mobile' &&
                                        !RegExp(
                                          r'^\+?[1-9]\d{9,14}$',
                                        ).hasMatch(value)) {
                                      return 'Use 10–15 digits, optionally beginning with +.';
                                    }
                                    if (entry.key == 'pinCode' &&
                                        !RegExp(r'^\d{6}$').hasMatch(value)) {
                                      return 'Enter a 6-digit PIN.';
                                    }
                                    if (entry.key == 'reason' &&
                                        value.length < 5) {
                                      return 'Enter at least 5 characters.';
                                    }
                                    return null;
                                  },
                                ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (key.currentState!.validate()) {
                  Navigator.pop(c, {
                    for (final e in controllers.entries)
                      e.key: e.value.text.trim(),
                  });
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
  );
  // Controllers remain alive until the dialog's closing animation has completed.
  await Future<void>.delayed(const Duration(milliseconds: 250));
  for (final c in controllers.values) {
    c.dispose();
  }
  return result;
}
