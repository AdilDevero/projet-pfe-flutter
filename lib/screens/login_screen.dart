import 'package:flutter/material.dart';
import '../mysql.dart';
import 'dashboard_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _rememberMe = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  static const Color _primaryColor = Color(0xFF0E7A50);  // same as dashboard _T.primary
  static const Color _bgColor     = Color(0xFFF0F4F2);  // same as dashboard _T.bg

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await MySQLHelper.login(
      _emailController.text.trim(),
      _passwordController.text,
    );

    setState(() => _isLoading = false);
    if (!mounted) return;

    if (result.success) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => DashboardScreen(
            user: result.user!,
            profile: result.profile,
            enrollmentStatus: result.enrollmentStatus,
            token: result.token,
          ),
        ),
      );
    } else {
      setState(() => _errorMessage = result.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width > 800;

    return Scaffold(
      backgroundColor: _bgColor,
      body: Column(
        children: [
          _TopBar(primaryColor: _primaryColor),
          Expanded(
            child: isWide
                ? Row(children: [
                    Expanded(
                        flex: 5,
                        child: _InfoPanel(primaryColor: _primaryColor)),
                    Expanded(
                      flex: 4,
                      child: Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(32),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 400),
                            child: _buildCard(),
                          ),
                        ),
                      ),
                    ),
                  ])
                : SingleChildScrollView(
                    child: Column(children: [
                      _InfoPanel(primaryColor: _primaryColor, compact: true),
                      Padding(
                          padding: const EdgeInsets.all(20),
                          child: _buildCard()),
                    ]),
                  ),
          ),
          _Footer(primaryColor: _primaryColor),
        ],
      ),
    );
  }

  Widget _buildCard() {
    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Espace Connexion',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: _primaryColor,
                ),
              ),
              const SizedBox(height: 8),
              Divider(color: _primaryColor.withValues(alpha: 0.3)),
              const SizedBox(height: 24),

              _label('ADRESSE EMAIL / CNE'),
              const SizedBox(height: 6),
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                decoration: _inputDeco(
                    hint: 'email@exemple.ma', icon: Icons.person_outline),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Champ obligatoire' : null,
              ),
              const SizedBox(height: 18),

              _label('MOT DE PASSE'),
              const SizedBox(height: 6),
              TextFormField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _login(),
                decoration: _inputDeco(
                  hint: '••••••••',
                  icon: Icons.lock_outline,
                ).copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      color: Colors.grey,
                      size: 20,
                    ),
                    onPressed: () => setState(
                        () => _obscurePassword = !_obscurePassword),
                  ),
                ),
                validator: (v) =>
                    v == null || v.isEmpty ? 'Champ obligatoire' : null,
              ),
              const SizedBox(height: 12),

              Row(children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    value: _rememberMe,
                    activeColor: _primaryColor,
                    onChanged: (v) =>
                        setState(() => _rememberMe = v ?? false),
                  ),
                ),
                const SizedBox(width: 8),
                const Text('Se souvenir de moi ?',
                    style:
                        TextStyle(fontSize: 13, color: Colors.black54)),
              ]),
              const SizedBox(height: 20),

              if (_errorMessage != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    border: Border.all(color: Colors.red.shade200),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(children: [
                    Icon(Icons.error_outline,
                        color: Colors.red.shade700, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_errorMessage!,
                          style: TextStyle(
                              color: Colors.red.shade700, fontSize: 13)),
                    ),
                  ]),
                ),

              SizedBox(
                height: 46,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.5),
                        )
                      : const Text('Se Connecter',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Text(text,
      style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.black54,
          letterSpacing: 0.8));

  InputDecoration _inputDeco(
          {required String hint, required IconData icon}) =>
      InputDecoration(
        hintText: hint,
        hintStyle:
            const TextStyle(color: Colors.black26, fontSize: 14),
        prefixIcon: Icon(icon, color: Colors.grey, size: 20),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: _primaryColor, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: Colors.red),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide:
              const BorderSide(color: Colors.red, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        filled: true,
        fillColor: Colors.grey.shade50,
      );

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared login page layout widgets
// ─────────────────────────────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  final Color primaryColor;
  const _TopBar({required this.primaryColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
      color: primaryColor,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _LogoCircle('F'),
          const Expanded(
            child: Column(children: [
              Text('ETALIB',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 3)),
              Text('Espace Numérique Étudiant',
                  style:
                      TextStyle(color: Colors.white70, fontSize: 11)),
            ]),
          ),
          _LogoCircle('E'),
        ],
      ),
    );
  }
}

class _LogoCircle extends StatelessWidget {
  final String letter;
  const _LogoCircle(this.letter);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.15),
          border: Border.all(color: Colors.white38, width: 2)),
      alignment: Alignment.center,
      child: Text(letter,
          style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 18)),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  final Color primaryColor;
  final bool compact;
  const _InfoPanel({required this.primaryColor, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: compact ? null : double.infinity,
      padding: EdgeInsets.symmetric(
          horizontal: 40, vertical: compact ? 32 : 60),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [primaryColor, const Color(0xFF085C3A)],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Bienvenue sur',
              style:
                  TextStyle(color: Colors.white70, fontSize: 16)),
          const SizedBox(height: 8),
          const Text('Etalib',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 42,
                  fontWeight: FontWeight.w900)),
          const SizedBox(height: 16),
          Container(width: 60, height: 3, color: Colors.white38),
          const SizedBox(height: 20),
          const Text(
            'Lycée Qualifiant Mohamed El Kaghat ',
            style: TextStyle(
                color: Colors.white70, fontSize: 13, height: 1.6),
          ),
          const SizedBox(height: 32),
          _bullet(Icons.school_outlined, 'Gestion de scolarité'),
          const SizedBox(height: 10),
          _bullet(Icons.assignment_outlined, 'Résultats & Notes'),
          const SizedBox(height: 10),
          _bullet(Icons.calendar_today_outlined, 'Emploi du temps'),
          const SizedBox(height: 10),
          _bullet(Icons.card_membership_outlined,
              'Attestations & Documents'),
        ],
      ),
    );
  }

  Widget _bullet(IconData icon, String label) => Row(children: [
        Icon(icon, color: Colors.white60, size: 18),
        const SizedBox(width: 10),
        Text(label,
            style: const TextStyle(
                color: Colors.white70, fontSize: 13)),
      ]);
}

class _Footer extends StatelessWidget {
  final Color primaryColor;
  const _Footer({required this.primaryColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.symmetric(vertical: 10, horizontal: 24),
      color: primaryColor,
      child: const Column(children: [
        Text(
          'Lycée Qualifiant Mohamed El Kaghat ',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600),
        ),
        SizedBox(height: 2),
        Text("Lycée Mohamed El Kaghat — Fes, Maroc",
            textAlign: TextAlign.center,
            style:
                TextStyle(color: Colors.white70, fontSize: 11)),
      ]),
    );
  }
}
