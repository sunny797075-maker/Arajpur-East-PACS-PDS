import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../auth/controller.dart';
import '../auth/models.dart';
import 'theme.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key, required this.auth});
  final AuthController auth;
  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  static const _states = ['Bihar', 'Other'];
  static const _districtsByState = <String, List<String>>{
    'Bihar': [
      'Araria',
      'Arwal',
      'Aurangabad',
      'Banka',
      'Begusarai',
      'Bhagalpur',
      'Bhojpur',
      'Buxar',
      'Darbhanga',
      'East Champaran',
      'Gaya',
      'Gopalganj',
      'Jamui',
      'Jehanabad',
      'Kaimur',
      'Katihar',
      'Khagaria',
      'Kishanganj',
      'Lakhisarai',
      'Madhepura',
      'Madhubani',
      'Munger',
      'Muzaffarpur',
      'Nalanda',
      'Nawada',
      'Patna',
      'Purnia',
      'Rohtas',
      'Saharsa',
      'Samastipur',
      'Saran',
      'Sheikhpura',
      'Sheohar',
      'Sitamarhi',
      'Siwan',
      'Supaul',
      'Vaishali',
      'West Champaran',
    ],
    'Other': ['Other'],
  };
  static const _blocksByDistrict = <String, List<String>>{
    'Madhepura': [
      'Alamnagar',
      'Bihariganj',
      'Chausa',
      'Gamharia',
      'Ghailarh',
      'Gwalpara',
      'Kumarkhand',
      'Madhepura',
      'Murliganj',
      'Puraini',
      'Shankarpur',
      'Singheshwar',
      'Uda Kishanganj',
    ],
  };
  final _form = GlobalKey<FormState>();
  final _fields = <String, TextEditingController>{
    for (final key in [
      'organizationName',
      'ownerName',
      'email',
      'mobile',
      'state',
      'district',
      'block',
      'panchayat',
      'village',
      'address',
      'pinCode',
      'pacsCode',
      'customType',
      'password',
      'confirmPassword',
    ])
      key: TextEditingController(),
  };
  String _type = 'INDEPENDENT';
  bool _busy = false, _hidden = true;
  String? _error, _assignedId;
  String value(String key) => _fields[key]!.text.trim();

  List<String> get _districtOptions =>
      _districtsByState[value('state')] ?? const <String>[];
  List<String> get _blockOptions =>
      _blocksByDistrict[value('district')] ?? const <String>[];

  @override
  void initState() {
    super.initState();
    _fields['state']!.text = 'Bihar';
    _fields['district']!.text = 'Madhepura';
    _fields['block']!.text = 'Chausa';
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  String normalizedPhone() {
    final phone = value('mobile').replaceAll(RegExp(r'[\s()-]'), '');
    return RegExp(r'^\d{10}$').hasMatch(phone) ? '+91$phone' : phone;
  }

  Future<void> submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final organization = <String, Object?>{
        for (final key in [
          'organizationName',
          'ownerName',
          'state',
          'district',
          'block',
          'panchayat',
          'village',
          'address',
          'pinCode',
        ])
          key: value(key),
        'organizationType': _type,
        if (_type == 'CUSTOM') 'customType': value('customType'),
        if (_type == 'PACS' && value('pacsCode').isNotEmpty)
          'pacsCode': value('pacsCode'),
      };
      final id = await widget.auth.repository.registerDistributor({
        'organization': organization,
        'email': value('email').toLowerCase(),
        'mobile': normalizedPhone(),
        'password': _fields['password']!.text,
        'confirmPassword': _fields['confirmPassword']!.text,
      });
      if (mounted) setState(() => _assignedId = id);
      // Store only the login email, never the password. A storage failure must
      // not obscure an account which has already been created successfully.
      try {
        await (await SharedPreferences.getInstance()).setString(
          'pds_id_distributor',
          value('email').toLowerCase(),
        );
      } catch (_) {}
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _error =
                  e is AuthFailure
                      ? e.message
                      : 'Registration could not be completed. Please retry with the same details.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget field(
    String key,
    String label, {
    int max = 100,
    bool optional = false,
    bool secret = false,
    TextInputType? keyboard,
    int lines = 1,
  }) => TextFormField(
    key: ValueKey(key),
    controller: _fields[key],
    enabled: !_busy,
    obscureText: secret && _hidden,
    maxLines: secret ? 1 : lines,
    autocorrect: !secret && key != 'email',
    enableSuggestions: !secret,
    keyboardType: keyboard,
    textInputAction: TextInputAction.next,
    autofillHints:
        secret
            ? const [AutofillHints.newPassword]
            : key == 'email'
            ? const [AutofillHints.email]
            : null,
    decoration: InputDecoration(
      labelText: label,
      suffixIcon:
          secret
              ? IconButton(
                tooltip: _hidden ? 'Show passwords' : 'Hide passwords',
                onPressed:
                    _busy ? null : () => setState(() => _hidden = !_hidden),
                icon: Icon(
                  _hidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              )
              : null,
    ),
    validator: (input) {
      final text = secret ? input ?? '' : input?.trim() ?? '';
      if (text.isEmpty) return optional ? null : 'Enter $label.';
      if (text.length > max) return 'Use at most $max characters.';
      if (key == 'email' &&
          !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(text)) {
        return 'Enter a valid email address.';
      }
      if (key == 'mobile' &&
          !RegExp(r'^\+[1-9]\d{6,14}$').hasMatch(normalizedPhone())) {
        return 'Enter 10 Indian digits or a +country-code number.';
      }
      if (key == 'pinCode' && !RegExp(r'^\d{6}$').hasMatch(text)) {
        return 'Enter a six-digit PIN code.';
      }
      if (secret && text.length < 12) return 'Use at least 12 characters.';
      if (key == 'confirmPassword' && text != _fields['password']!.text) {
        return 'Passwords do not match.';
      }
      return null;
    },
  );
  Widget dropdownField(
    String key,
    String label,
    List<String> options, {
    ValueChanged<String>? afterChanged,
  }) => DropdownButtonFormField<String>(
    key: ValueKey(key),
    value: options.contains(value(key)) ? value(key) : null,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final option in options)
        DropdownMenuItem(value: option, child: Text(option)),
    ],
    onChanged:
        _busy
            ? null
            : (selected) {
              if (selected == null) return;
              setState(() => _fields[key]!.text = selected);
              afterChanged?.call(selected);
            },
    validator: (input) {
      if ((input ?? '').trim().isEmpty) return 'Choose $label.';
      return null;
    },
  );

  Widget blockField() {
    final options = _blockOptions;
    if (options.isEmpty) {
      return field('block', 'Block / city', max: 80);
    }
    return dropdownField('block', 'Block / city', options);
  }

  Widget section(String title, List<Widget> children, double width) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 28),
      Text(
        title,
        style: const TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w700,
          color: ink,
        ),
      ),
      const SizedBox(height: 18),
      Wrap(
        spacing: 18,
        runSpacing: 20,
        children: [
          for (final child in children)
            SizedBox(
              width: width >= 650 ? (width - 18) / 2 : width,
              child: child,
            ),
        ],
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Distributor registration'),
      leading: IconButton(
        tooltip: 'Back to sign in',
        onPressed: _busy ? null : () => context.go('/distributor/login'),
        icon: const Icon(Icons.arrow_back),
      ),
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(
          MediaQuery.sizeOf(context).width < 600 ? 20 : 40,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (_assignedId != null) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Brand(),
                      const SizedBox(height: 36),
                      const Icon(
                        Icons.check_circle_outline,
                        size: 56,
                        color: green,
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        'Your account is ready',
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          color: ink,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Sign in using your registered email or mobile number and password. Your Distributor ID identifies your account; it is not a login credential. Distribution tools become available after payment or platform administrator approval.',
                        style: TextStyle(height: 1.6),
                      ),
                      const SizedBox(height: 20),
                      SelectableText(
                        _assignedId!,
                        style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          color: green,
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: _assignedId!),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Distributor ID copied'),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy Distributor ID'),
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: () => context.go('/distributor/login'),
                        child: const Text('Continue to sign in'),
                      ),
                      const SizedBox(height: 32),
                      const Text('Powered by MENHI GLOBAL TECH'),
                    ],
                  );
                }
                return Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Brand(),
                      const SizedBox(height: 30),
                      const Text(
                        'Create your distributor account',
                        style: TextStyle(
                          fontSize: 30,
                          height: 1.2,
                          fontWeight: FontWeight.w800,
                          color: ink,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Register your organization and choose a password. Your unique Distributor ID will be generated automatically.',
                        style: TextStyle(height: 1.6, color: Color(0xFF63776E)),
                      ),
                      section('Organization', [
                        field(
                          'organizationName',
                          'Organization name',
                          max: 150,
                        ),
                        DropdownButtonFormField<String>(
                          value: _type,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Organization type',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'INDEPENDENT',
                              child: Text('Independent distributor'),
                            ),
                            DropdownMenuItem(
                              value: 'PACS',
                              child: Text('PACS'),
                            ),
                            DropdownMenuItem(
                              value: 'OTHER',
                              child: Text('Other organization'),
                            ),
                            DropdownMenuItem(
                              value: 'CUSTOM',
                              child: Text('Custom type'),
                            ),
                          ],
                          onChanged:
                              _busy
                                  ? null
                                  : (value) => setState(() => _type = value!),
                        ),
                        if (_type == 'PACS')
                          field(
                            'pacsCode',
                            'PACS code (optional)',
                            max: 80,
                            optional: true,
                          ),
                        if (_type == 'CUSTOM')
                          field(
                            'customType',
                            'Organization type name',
                            max: 80,
                          ),
                        field('ownerName', 'Owner / contact name'),
                      ], constraints.maxWidth),
                      section('Contact details', [
                        field(
                          'email',
                          'Email address',
                          max: 254,
                          keyboard: TextInputType.emailAddress,
                        ),
                        field(
                          'mobile',
                          'Mobile number',
                          max: 24,
                          keyboard: TextInputType.phone,
                        ),
                      ], constraints.maxWidth),
                      section('Location', [
                        dropdownField(
                          'state',
                          'State',
                          _states,
                          afterChanged: (state) {
                            final districts =
                                _districtsByState[state] ?? const <String>[];
                            _fields['district']!.text =
                                districts.isNotEmpty ? districts.first : '';
                            final blocks =
                                _blocksByDistrict[value('district')] ??
                                const <String>[];
                            _fields['block']!.text =
                                blocks.isNotEmpty ? blocks.first : '';
                          },
                        ),
                        dropdownField(
                          'district',
                          'District',
                          _districtOptions,
                          afterChanged: (district) {
                            final blocks =
                                _blocksByDistrict[district] ?? const <String>[];
                            _fields['block']!.text =
                                blocks.isNotEmpty ? blocks.first : '';
                          },
                        ),
                        blockField(),
                        field('panchayat', 'Panchayat / ward', max: 80),
                        field('village', 'Village / locality'),
                        field(
                          'pinCode',
                          'PIN code',
                          max: 6,
                          keyboard: TextInputType.number,
                        ),
                        field('address', 'Street address', max: 500, lines: 2),
                      ], constraints.maxWidth),
                      section('Choose your password', [
                        field('password', 'Password', max: 128, secret: true),
                        field(
                          'confirmPassword',
                          'Confirm password',
                          max: 128,
                          secret: true,
                        ),
                      ], constraints.maxWidth),
                      const SizedBox(height: 12),
                      const Text(
                        'Use at least 12 characters. Sign in with your registered email or mobile number and this password.',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: Color(0xFF63776E),
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 20),
                        Notice(_error!, error: true),
                      ],
                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _busy ? null : submit,
                          child:
                              _busy
                                  ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                  : const Text(
                                    'Create account & get Distributor ID',
                                  ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: TextButton(
                          onPressed:
                              _busy
                                  ? null
                                  : () => context.go('/distributor/login'),
                          child: const Text('Already registered? Sign in'),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text('Powered by MENHI GLOBAL TECH'),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}
