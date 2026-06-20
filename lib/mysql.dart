import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:http/http.dart' as http;
import 'package:mysql_client/mysql_client.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MySQLHelper — works on ALL platforms:
//   • Web / Android / iOS  → calls Laravel REST API (http)
//   • Windows / macOS / Linux desktop → direct MySQL TCP connection
// ─────────────────────────────────────────────────────────────────────────────
class MySQLHelper {
  static int? get currentUserId => _currentUserId;
  static int? _currentUserId;
  // ── Laravel API base URL ──────────────────────────────────────────────────
  // Laragon serves Laravel from /public — the correct URL is:
  static const String apiBase = 'http://localhost/pfe/public/api';

  // ── Direct MySQL config (desktop only) ────────────────────────────────────
  static const String _host = '127.0.0.1';
  static const int _port = 3306;
  static const String _dbUser = 'root';
  static const String _dbPass = '';
  static const String _dbName = 'pfe';

  static MySQLConnection? _conn;

  // ── Public login entry point ──────────────────────────────────────────────
  static Future<LoginResult> login(String email, String password) {
    if (kIsWeb) {
      return _loginViaApi(email, password);
    }
    // On desktop we can use direct MySQL; on mobile fall back to API too
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return _loginViaMysql(email, password);
    }
    return _loginViaApi(email, password);
  }

  // ── Close MySQL connection (desktop only) ─────────────────────────────────
  static Future<void> close() async {
    await _conn?.close();
    _conn = null;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // STRATEGY A — Laravel REST API  (web + mobile)
  // ═══════════════════════════════════════════════════════════════════════════
  static Future<LoginResult> _loginViaApi(
      String email, String password) async {
    try {
      final response = await http
          .post(
            Uri.parse('$apiBase/mobile/login'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: json.encode({
              'identifier': email,
              'password': password,
            }),
          )
          .timeout(const Duration(seconds: 15));

      final body = json.decode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200 && body['success'] == true) {
        final u = body['user'] as Map<String, dynamic>;
        final user = UserModel(
          id: u['id'] as int,
          name: u['name'] as String,
          email: u['email'] as String,
          role: u['role'] as String,
        );

        // Profile is embedded in the login response
        final profileData = u['student_profile'] as Map<String, dynamic>?;
        StudentProfile? profile;
        String? enrollmentStatus;

        if (profileData != null) {
          profile = StudentProfile.fromApiMap(profileData);
          final activeApp =
              profileData['active_application'] as Map<String, dynamic>?;
          enrollmentStatus = activeApp?['status'] as String?;
        }

        return LoginResult.success(
          user: user,
          profile: profile,
          enrollmentStatus: enrollmentStatus,
          token: body['token'] as String?,
        );
      } else {
        return LoginResult.failure(
            body['message'] as String? ?? 'Identifiants incorrects.');
      }
    } on SocketException {
      return LoginResult.failure(
          'Serveur inaccessible. Vérifiez que Laragon est démarré.');
    } on Exception catch (e) {
      return LoginResult.failure('Erreur réseau: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // STRATEGY B — Direct MySQL  (desktop only)
  // ═══════════════════════════════════════════════════════════════════════════
  static Future<MySQLConnection> get _connection async {
    if (_conn != null && _conn!.connected) return _conn!;
    _conn = await MySQLConnection.createConnection(
      host: _host,
      port: _port,
      userName: _dbUser,
      password: _dbPass,
      databaseName: _dbName,
      secure: false,
    );
    await _conn!.connect();
    return _conn!;
  }

  static Future<LoginResult> _loginViaMysql(
      String email, String plainPassword) async {
    try {
      final conn = await _connection;

      // 1. Fetch user
      final userResult = await conn.execute(
        'SELECT id, name, email, password, role '
        'FROM users WHERE email = :email LIMIT 1',
        {'email': email},
      );

      if (userResult.rows.isEmpty) {
        return LoginResult.failure('Identifiants incorrects.');
      }

      final userRow = userResult.rows.first.assoc();

      // 2. Verify bcrypt hash via PHP (Laravel default)
      final verified =
          await _verifyBcrypt(plainPassword, userRow['password']!);
      if (!verified) {
        return LoginResult.failure('Identifiants incorrects.');
      }

      final userId = userRow['id']!;

      // 3. Fetch student profile
      final profileResult = await conn.execute(
        'SELECT * FROM student_profiles WHERE user_id = :uid LIMIT 1',
        {'uid': userId},
      );

      Map<String, String?>? profileMap;
      if (profileResult.rows.isNotEmpty) {
        profileMap = profileResult.rows.first.assoc();
      }

      // 4. Fetch enrollment status
      String? enrollmentStatus;
      if (profileMap != null) {
        final enrollResult = await conn.execute(
          'SELECT status FROM enrollment_applications '
          'WHERE student_profile_id = :pid '
          'ORDER BY created_at DESC LIMIT 1',
          {'pid': profileMap['id']},
        );
        if (enrollResult.rows.isNotEmpty) {
          enrollmentStatus = enrollResult.rows.first.assoc()['status'];
        }
      }

      // Fetch a Sanctum token via the API under the hood so all API operations work on desktop
      String? token;
      try {
        final apiRes = await _loginViaApi(email, plainPassword);
          if (apiRes.success) {
            token = apiRes.token;
          }
          // Also store user ID from API login if available
          if (apiRes.user != null) {
            _currentUserId = apiRes.user!.id;
          }
      } catch (_) {}

      final loginResult = LoginResult.success(
          user: UserModel.fromDbMap(userRow),
          profile:
              profileMap != null ? StudentProfile.fromDbMap(profileMap) : null,
          enrollmentStatus: enrollmentStatus,
          token: token,
        );
      // Store the user ID for later DB queries
      _currentUserId = userRow['id'] != null ? int.parse(userRow['id']!) : null;
      return loginResult;
    } catch (e) {
      return LoginResult.failure(
          'Erreur de connexion à la base de données.\n$e');
    }
  }

  // Verify bcrypt using PHP (available on any machine that has Laragon)
  static Future<bool> _verifyBcrypt(String plain, String hash) async {
    // Escape quotes to avoid injection in the PHP one-liner
    final safePlain = plain.replaceAll('"', '\\"');
    final safeHash = hash.replaceAll('"', '\\"');
    try {
      final result = await Process.run('php', [
        '-r',
        'echo password_verify("$safePlain", "$safeHash") ? "1" : "0";',
      ]);
      return result.stdout.toString().trim() == '1';
    } catch (_) {
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Document requests — always via API (needs auth token)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Fetch all document requests for the logged-in user.
  static Future<List<DocumentRequestModel>> getDocumentRequests(
      String token) async {
    try {
      final r = await http.get(
        Uri.parse('$apiBase/mobile/documents'),
        headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));
      final body = json.decode(r.body) as Map<String, dynamic>;
      if (r.statusCode == 200 && body['success'] == true) {
        return (body['requests'] as List)
            .map((e) => DocumentRequestModel.fromMap(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}
    return [];
  }

  /// Submit a new document request.
  static Future<({bool success, String message, DocumentRequestModel? request})>
      submitDocumentRequest({
    required String token,
    required String documentType,
    required String deliveryMode,
    required int copies,
    String? purpose,
  }) async {
    try {
      final r = await http
          .post(
            Uri.parse('$apiBase/mobile/documents'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: json.encode({
              'document_type': documentType,
              'delivery_mode': deliveryMode,
              'copies': copies,
              if (purpose != null && purpose.isNotEmpty) 'purpose': purpose,
            }),
          )
          .timeout(const Duration(seconds: 10));
      final body = json.decode(r.body) as Map<String, dynamic>;
      if ((r.statusCode == 200 || r.statusCode == 201) &&
          body['success'] == true) {
        return (
          success: true,
          message: 'Demande envoyée avec succès.',
          request: DocumentRequestModel.fromMap(
              body['request'] as Map<String, dynamic>),
        );
      }
      return (
        success: false,
        message: body['message'] as String? ?? 'Erreur lors de la demande.',
        request: null,
      );
    } catch (e) {
      return (success: false, message: 'Erreur réseau: $e', request: null);
    }
  }

  /// Cancel a pending document request.
  static Future<bool> cancelDocumentRequest(
      String token, int requestId) async {
    try {
      final r = await http.delete(
        Uri.parse('$apiBase/mobile/documents/$requestId'),
        headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));
      final body = json.decode(r.body) as Map<String, dynamic>;
      return r.statusCode == 200 && body['success'] == true;
    } catch (_) {
      return false;
    }
  }

  // ── Grades ────────────────────────────────────────────────────────────────
  static Future<List<SemestreGrades>> getGrades(String token) async {
    try {
      final r = await http.get(
        Uri.parse('$apiBase/mobile/grades'),
        headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 15));
      final body = json.decode(r.body) as Map<String, dynamic>;
      if (r.statusCode == 200 && body['success'] == true) {
        return (body['semestres'] as List)
            .map((e) => SemestreGrades.fromMap(e as Map<String, dynamic>))
            .toList();
      }
      debugPrint('getGrades error: status=${r.statusCode} body=${r.body}');
    } catch (e) {
      debugPrint('getGrades exception: $e');
    }
    // If API fails or returns empty, fallback to direct DB if we have a user ID
    if (_currentUserId != null) {
      return await getGradesViaDb(_currentUserId!);
    }
    return [];
  }
  
  // ── Grades (Direct DB) ───────────────────────────────────────────────────────
  static Future<List<SemestreGrades>> getGradesViaDb(int userId) async {
    try {
      final conn = await _connection;
      final result = await conn.execute(
        'SELECT * FROM grades WHERE user_id = :uid ORDER BY semestre, annee, is_header DESC, numero_module',
        {'uid': userId},
      );
      if (result.rows.isEmpty) return [];

      // Group rows by semestre and annee
      final Map<String, List<Map<String, String?>>> grouped = {};
      for (var row in result.rows) {
        final m = row.assoc();
        final semestre = m['semestre'] ?? '';
        final annee = m['annee'] ?? '0';
        final key = '$semestre|$annee';
        grouped.putIfAbsent(key, () => []).add(m);
      }

      final List<SemestreGrades> grades = [];
      for (var entry in grouped.entries) {
        final parts = entry.key.split('|');
        final semestre = parts[0];
        final annee = int.tryParse(parts[1]) ?? 0;

        Map<String, String?>? header;
        final List<GradeRow> modules = [];

        for (var m in entry.value) {
          final isHeader = m['is_header'] == '1' || m['is_header'] == 'true';
          if (isHeader) {
            header = m;
          } else {
            // Convert string values to proper types for GradeRow.fromMap
            modules.add(GradeRow(
              id: int.tryParse(m['id'] ?? '0') ?? 0,
              numeroModule: int.tryParse(m['numero_module'] ?? '0') ?? 0,
              elementPedagogique: m['element_pedagogique'] ?? '',
              noteSs1: double.tryParse(m['note_ss1'] ?? ''),
              noteSs2: double.tryParse(m['note_ss2'] ?? ''),
              resultat: m['resultat'],
              noteFinale: double.tryParse(m['note_finale'] ?? ''),
              ptsJury: double.tryParse(m['pts_jury'] ?? ''),
              isHeader: false,
              reclamationStatus: m['reclamation_status'],
              noteTrouvee: double.tryParse(m['note_trouvee'] ?? ''),
              reponse: m['reponse'],
            ));
          }
        }

        final noteFinale = header != null
            ? double.tryParse(header['note_finale'] ?? '')
            : null;
        final resultat = header?['resultat'];

        grades.add(SemestreGrades(
          semestre: semestre,
          annee: annee,
          noteFinale: noteFinale,
          resultat: resultat,
          modules: modules,
        ));
      }

      return grades;
    } catch (_) {
      return [];
    }
  }

  // ── Convocations ──────────────────────────────────────────────────────────
  static Future<List<ConvocationModel>> getConvocations(String token) async {
    try {
      final r = await http.get(
        Uri.parse('$apiBase/mobile/convocations'),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 15));
      final body = json.decode(r.body) as Map<String, dynamic>;
      if (r.statusCode == 200 && body['success'] == true) {
        return (body['convocations'] as List)
            .map((e) => ConvocationModel.fromMap(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}
    return [];
  }

  // ── Absences ──────────────────────────────────────────────────────────────
  static Future<List<AbsenceModel>> getAbsences(String token) async {
    try {
      final r = await http.get(
        Uri.parse('$apiBase/mobile/absences'),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 15));
      final body = json.decode(r.body) as Map<String, dynamic>;
      if (r.statusCode == 200 && body['success'] == true) {
        return (body['absences'] as List)
            .map((e) => AbsenceModel.fromMap(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}
    return [];
  }

  /// Submit a justification for an absence (multipart: reason + optional file).
  /// Returns (success, message, updated absence or null).
  static Future<({bool success, String message, AbsenceModel? absence})>
      submitJustification({
    required String token,
    required int absenceId,
    required String reason,
    String? filePath,
    String? fileName,
    String? mimeType,
  }) async {
    try {
      final uri = Uri.parse('$apiBase/mobile/absences/$absenceId/justify');
      final req = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $token'
        ..headers['Accept'] = 'application/json'
        ..fields['reason'] = reason;

      if (filePath != null && fileName != null) {
        req.files.add(await http.MultipartFile.fromPath(
          'file',
          filePath,
          filename: fileName,
        ));
      }

      final streamed = await req.send().timeout(const Duration(seconds: 30));
      final body = json.decode(
          await streamed.stream.bytesToString()) as Map<String, dynamic>;

      if (streamed.statusCode == 200 && body['success'] == true) {
        final a = body['absence'] as Map<String, dynamic>?;
        return (
          success: true,
          message: body['message'] as String? ?? 'Justification envoyée.',
          absence: a != null ? AbsenceModel.fromMap(a) : null,
        );
      }
      return (
        success: false,
        message: body['message'] as String? ?? 'Erreur lors de l\'envoi.',
        absence: null,
      );
    } catch (e) {
      return (success: false, message: 'Erreur réseau: $e', absence: null);
    }
  }

  // ── Account / Settings ───────────────────────────────────────────────────

  /// Change the authenticated user's password.
  /// Returns (success, message).
  static Future<({bool success, String message})> changePassword({
    required String token,
    required String currentPassword,
    required String newPassword,
  }) async {
    try {
      final r = await http.post(
        Uri.parse('$apiBase/mobile/account/change-password'),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'current_password':          currentPassword,
          'new_password':              newPassword,
          'new_password_confirmation': newPassword,
        }),
      ).timeout(const Duration(seconds: 15));
      final body = json.decode(r.body) as Map<String, dynamic>;
      final msg  = body['message'] as String? ?? '';
      if (r.statusCode == 200 && body['success'] == true) {
        return (success: true,  message: msg);
      }
      // 422 validation error — Laravel returns 'errors' map
      if (r.statusCode == 422) {
        final errors = body['errors'] as Map<String, dynamic>?;
        final first  = errors?.values.firstOrNull;
        final detail = (first is List && first.isNotEmpty)
            ? first.first as String
            : msg;
        return (success: false, message: detail.isNotEmpty ? detail : 'Erreur de validation.');
      }
      return (success: false, message: msg.isNotEmpty ? msg : 'Erreur inattendue.');
    } catch (e) {
      return (success: false, message: 'Erreur réseau: $e');
    }
  }

  /// Upload or replace the user's avatar.
  /// Returns (success, message, avatarUrl).
  static Future<({bool success, String message, String? avatarUrl})>
      uploadAvatar({
    required String token,
    String? filePath,
    Uint8List? fileBytes,
    required String fileName,
  }) async {
    try {
      final uri = Uri.parse('$apiBase/mobile/account/avatar');
      final req = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $token'
        ..headers['Accept']        = 'application/json';

      if (fileBytes != null) {
        req.files.add(http.MultipartFile.fromBytes(
          'avatar', fileBytes, filename: fileName));
      } else if (filePath != null) {
        req.files.add(await http.MultipartFile.fromPath(
          'avatar', filePath, filename: fileName));
      } else {
        return (success: false, message: 'Aucun fichier choisi.', avatarUrl: null);
      }

      final streamed = await req.send().timeout(const Duration(seconds: 30));
      final body = json.decode(
          await streamed.stream.bytesToString()) as Map<String, dynamic>;
      if (streamed.statusCode == 200 && body['success'] == true) {
        return (
          success:   true,
          message:   body['message'] as String? ?? 'Avatar mis à jour.',
          avatarUrl: body['avatar_url'] as String?,
        );
      }
      return (
        success:   false,
        message:   body['message'] as String? ?? 'Erreur lors du téléchargement.',
        avatarUrl: null,
      );
    } catch (e) {
      return (success: false, message: 'Erreur réseau: $e', avatarUrl: null);
    }
  }

  /// Delete the user's avatar.
  static Future<bool> deleteAvatar(String token) async {
    try {
      final r = await http.delete(
        Uri.parse('$apiBase/mobile/account/avatar'),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));
      final body = json.decode(r.body) as Map<String, dynamic>;
      return r.statusCode == 200 && body['success'] == true;
    } catch (_) {
      return false;
    }
  }

  // ── Timetable ─────────────────────────────────────────────────────────────
  static Future<TimetableResult> getTimetable(String token) async {
    try {
      final r = await http.get(
        Uri.parse('$apiBase/mobile/timetable'),
        headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 15));
      final body = json.decode(r.body) as Map<String, dynamic>;
      if (r.statusCode == 200 && body['success'] == true) {
        return TimetableResult(
          className: body['class'] as String?,
          academicYear: body['year'] as String?,
          track: body['track'] as String?,
          entries: (body['entries'] as List)
              .map((e) => TimetableEntry.fromMap(e as Map<String, dynamic>))
              .toList(),
        );
      }
    } catch (_) {}
    return TimetableResult(entries: []);
  }

  // ── Account info (fetch avatar + user data) ───────────────────────────
  /// Fetch the authenticated user's account info (includes avatar_url).
  static Future<({String? avatarUrl})> getAccountInfo(String token) async {
    try {
      final r = await http.get(
        Uri.parse('$apiBase/mobile/account'),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));
      final body = json.decode(r.body) as Map<String, dynamic>;
      if (r.statusCode == 200 && body['success'] == true) {
        final user = body['user'] as Map<String, dynamic>?;
        return (avatarUrl: user?['avatar_url'] as String?);
      }
    } catch (_) {}
    return (avatarUrl: null);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Result & Models
// ─────────────────────────────────────────────────────────────────────────────

class LoginResult {
  final bool success;
  final String? message;
  final UserModel? user;
  final StudentProfile? profile;
  final String? enrollmentStatus;
  final String? token; // Sanctum token for subsequent API calls

  LoginResult._({
    required this.success,
    this.message,
    this.user,
    this.profile,
    this.enrollmentStatus,
    this.token,
  });

  factory LoginResult.success({
    required UserModel user,
    StudentProfile? profile,
    String? enrollmentStatus,
    String? token,
  }) =>
      LoginResult._(
          success: true,
          user: user,
          profile: profile,
          enrollmentStatus: enrollmentStatus,
          token: token);

  factory LoginResult.failure(String message) =>
      LoginResult._(success: false, message: message);
}

class UserModel {
  final int id;
  final String name;
  final String email;
  final String role;

  const UserModel({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
  });

  factory UserModel.fromDbMap(Map<String, String?> m) => UserModel(
        id: int.parse(m['id'] ?? '0'),
        name: m['name'] ?? '',
        email: m['email'] ?? '',
        role: m['role'] ?? 'student',
      );
}

class StudentProfile {
  final int id;
  final String firstName;
  final String lastName;
  final String? firstNameAr;
  final String? lastNameAr;
  final String? cin;
  final String massarCode;
  final String birthDate;
  final String birthPlace;
  final String phone;
  final String address;
  final String city;
  final String guardianName;
  final String guardianPhone;
  final String guardianRelation;
  final String previousSchool;
  final int bacYear;
  final String bacGrade;
  final String chosenTrack;

  const StudentProfile({
    required this.id,
    required this.firstName,
    required this.lastName,
    this.firstNameAr,
    this.lastNameAr,
    this.cin,
    required this.massarCode,
    required this.birthDate,
    required this.birthPlace,
    required this.phone,
    required this.address,
    required this.city,
    required this.guardianName,
    required this.guardianPhone,
    required this.guardianRelation,
    required this.previousSchool,
    required this.bacYear,
    required this.bacGrade,
    required this.chosenTrack,
  });

  String get fullName => '$firstName $lastName';

  // From direct MySQL query (all values are String?)
  factory StudentProfile.fromDbMap(Map<String, String?> m) => StudentProfile(
        id: int.parse(m['id'] ?? '0'),
        firstName: m['first_name'] ?? '',
        lastName: m['last_name'] ?? '',
        firstNameAr: m['first_name_ar'],
        lastNameAr: m['last_name_ar'],
        cin: m['cin'],
        massarCode: m['massar_code'] ?? '',
        birthDate: m['birth_date'] ?? '',
        birthPlace: m['birth_place'] ?? '',
        phone: m['phone'] ?? '',
        address: m['address'] ?? '',
        city: m['city'] ?? '',
        guardianName: m['guardian_name'] ?? '',
        guardianPhone: m['guardian_phone'] ?? '',
        guardianRelation: m['guardian_relation'] ?? '',
        previousSchool: m['previous_school'] ?? '',
        bacYear: int.parse(m['bac_year'] ?? '0'),
        bacGrade: m['bac_grade'] ?? '0',
        chosenTrack: m['chosen_track'] ?? '',
      );

  // From Laravel API response (values are dynamic)
  factory StudentProfile.fromApiMap(Map<String, dynamic> m) => StudentProfile(
        id: m['id'] as int? ?? 0,
        firstName: m['first_name'] as String? ?? '',
        lastName: m['last_name'] as String? ?? '',
        firstNameAr: m['first_name_ar'] as String?,
        lastNameAr: m['last_name_ar'] as String?,
        cin: m['cin'] as String?,
        massarCode: m['massar_code'] as String? ?? '',
        birthDate: m['birth_date'] as String? ?? '',
        birthPlace: m['birth_place'] as String? ?? '',
        phone: m['phone'] as String? ?? '',
        address: m['address'] as String? ?? '',
        city: m['city'] as String? ?? '',
        guardianName: m['guardian_name'] as String? ?? '',
        guardianPhone: m['guardian_phone'] as String? ?? '',
        guardianRelation: m['guardian_relation'] as String? ?? '',
        previousSchool: m['previous_school'] as String? ?? '',
        bacYear: m['bac_year'] as int? ?? 0,
        bacGrade: m['bac_grade']?.toString() ?? '0',
        chosenTrack: m['chosen_track'] as String? ?? '',
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// DocumentRequestModel
// ─────────────────────────────────────────────────────────────────────────────
class DocumentRequestModel {
  final int id;
  final String documentType;
  final String? purpose;
  final String deliveryMode;
  final int copies;
  final String status;
  final String? adminNotes;
  final String createdAt;

  const DocumentRequestModel({
    required this.id,
    required this.documentType,
    this.purpose,
    required this.deliveryMode,
    required this.copies,
    required this.status,
    this.adminNotes,
    required this.createdAt,
  });

  String get documentLabel => switch (documentType) {
    'attestation_inscription'   => 'Attestation d\'inscription',
    'releve_notes'              => 'Relevé de notes',
    'certificat_scolarite'      => 'Certificat de scolarité',
    'recepisse_candidature'     => 'Récépissé de candidature',
    _                           => documentType,
  };

  String get statusLabel => switch (status) {
    'pending'    => 'En attente',
    'processing' => 'En traitement',
    'ready'      => 'Prêt',
    'delivered'  => 'Remis',
    _            => status,
  };

  factory DocumentRequestModel.fromMap(Map<String, dynamic> m) =>
      DocumentRequestModel(
        id: m['id'] as int,
        documentType: m['document_type'] as String,
        purpose: m['purpose'] as String?,
        deliveryMode: m['delivery_mode'] as String,
        copies: m['copies'] as int,
        status: m['status'] as String,
        adminNotes: m['admin_notes'] as String?,
        createdAt: m['created_at'] as String? ?? '',
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Grade models
// ─────────────────────────────────────────────────────────────────────────────
class GradeRow {
  final int id;
  final int numeroModule;
  final String elementPedagogique;
  final double? noteSs1;
  final double? noteSs2;
  final String? resultat;
  final double? noteFinale;
  final double? ptsJury;
  final bool isHeader;
  final String? reclamationStatus; // null | 'enregistre'
  final double? noteTrouvee;
  final String? reponse;

  const GradeRow({
    required this.id,
    required this.numeroModule,
    required this.elementPedagogique,
    this.noteSs1,
    this.noteSs2,
    this.resultat,
    this.noteFinale,
    this.ptsJury,
    required this.isHeader,
    this.reclamationStatus,
    this.noteTrouvee,
    this.reponse,
  });

  factory GradeRow.fromMap(Map<String, dynamic> m) => GradeRow(
        id: _parseInt(m['id']),
        numeroModule: _parseInt(m['numero_module']),
        elementPedagogique: m['element_pedagogique'] as String? ?? '',
        noteSs1: _parseDouble(m['note_ss1']),
        noteSs2: _parseDouble(m['note_ss2']),
        resultat: m['resultat'] as String?,
        noteFinale: _parseDouble(m['note_finale']),
        ptsJury: _parseDouble(m['pts_jury']),
        isHeader: m['is_header'] == true || m['is_header'] == 1 ||
            m['is_header'] == '1',
        reclamationStatus: m['reclamation_status'] as String?,
        noteTrouvee: _parseDouble(m['note_trouvee']),
        reponse: m['reponse'] as String?,
      );

  // Safely parse a value that may be String, int, double, or null
  static double? _parseDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static int _parseInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

class SemestreGrades {
  final String semestre;
  final int annee;
  final double? noteFinale;
  final String? resultat;
  final List<GradeRow> modules;

  const SemestreGrades({
    required this.semestre,
    required this.annee,
    this.noteFinale,
    this.resultat,
    required this.modules,
  });

  factory SemestreGrades.fromMap(Map<String, dynamic> m) => SemestreGrades(
        semestre: m['semestre'] as String,
        annee: GradeRow._parseInt(m['annee']),
        noteFinale: GradeRow._parseDouble(m['note_finale']),
        resultat: m['resultat'] as String?,
        modules: (m['modules'] as List)
            .map((e) => GradeRow.fromMap(e as Map<String, dynamic>))
            .toList(),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Convocation models
// ─────────────────────────────────────────────────────────────────────────────

/// One module entry inside a convocation's modules JSON array.
/// e.g. {"name": "Mathématiques", "exam_date": "2026-07-15", "start_time": "09:00", "room": "Salle 5"}
class ConvocationModule {
  final String name;
  final String? examDate;
  final String? startTime; // stored as "start_time" in the DB JSON
  final String? room;

  const ConvocationModule({
    required this.name,
    this.examDate,
    this.startTime,
    this.room,
  });

  /// "09:00" or "09:00:00" → "09h00"
  String get heureLabel {
    if (startTime == null) return '';
    return startTime!.length >= 5
        ? startTime!.substring(0, 5).replaceAll(':', 'h')
        : startTime!;
  }

  /// "2026-07-15" → "15 Juil 2026"
  String get dateLabel {
    if (examDate == null) return '';
    try {
      final d = DateTime.parse(examDate!);
      const months = [
        '', 'Jan', 'Fév', 'Mar', 'Avr', 'Mai', 'Juin',
        'Juil', 'Aoû', 'Sep', 'Oct', 'Nov', 'Déc'
      ];
      return '${d.day.toString().padLeft(2, '0')} ${months[d.month]} ${d.year}';
    } catch (_) {
      return examDate!;
    }
  }

  factory ConvocationModule.fromMap(Map<String, dynamic> m) => ConvocationModule(
        name: m['name'] as String? ?? '',
        examDate: m['exam_date'] as String?,
        // DB stores the time as "start_time"; fall back to legacy "heure" key
        startTime: (m['start_time'] ?? m['heure']) as String?,
        room: m['room'] as String?,
      );
}

/// One row from the convocations table.
class ConvocationModel {
  final int id;
  final String groupName;
  final String? examSession;
  final String? examLocation;
  final List<ConvocationModule> modules;

  const ConvocationModel({
    required this.id,
    required this.groupName,
    this.examSession,
    this.examLocation,
    required this.modules,
  });

  factory ConvocationModel.fromMap(Map<String, dynamic> m) => ConvocationModel(
        id: m['id'] as int? ?? 0,
        groupName: m['group_name'] as String? ?? '',
        examSession: m['exam_session'] as String?,
        examLocation: m['exam_location'] as String?,
        modules: (m['modules'] as List? ?? [])
            .map((e) => ConvocationModule.fromMap(e as Map<String, dynamic>))
            .toList(),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Absence models
// ─────────────────────────────────────────────────────────────────────────────
class AbsenceModel {
  final int id;
  final String academicYear;
  final String className;
  final String date;       // "2026-06-17"
  final String timeSlot;   // "Matin", "Après-midi", etc.
  final String? subject;
  final String status;     // "unjustified" | "justified"
  final String? justificationReason;
  final String? justifiedAt;
  final String? attachmentUrl;
  final String? comments;

  const AbsenceModel({
    required this.id,
    required this.academicYear,
    required this.className,
    required this.date,
    required this.timeSlot,
    this.subject,
    required this.status,
    this.justificationReason,
    this.justifiedAt,
    this.attachmentUrl,
    this.comments,
  });

  bool get isJustified => status == 'justified';

  /// "2026-06-17" → "17 Juin 2026"
  String get dateLabel {
    try {
      final d = DateTime.parse(date);
      const months = [
        '', 'Jan', 'Fév', 'Mar', 'Avr', 'Mai', 'Juin',
        'Juil', 'Aoû', 'Sep', 'Oct', 'Nov', 'Déc'
      ];
      return '${d.day.toString().padLeft(2, '0')} ${months[d.month]} ${d.year}';
    } catch (_) {
      return date;
    }
  }

  factory AbsenceModel.fromMap(Map<String, dynamic> m) => AbsenceModel(
        id: m['id'] as int? ?? 0,
        academicYear: m['academic_year'] as String? ?? '',
        className: m['class_name'] as String? ?? '',
        date: m['date'] as String? ?? '',
        timeSlot: m['time_slot'] as String? ?? '',
        subject: m['subject'] as String?,
        status: m['status'] as String? ?? 'unjustified',
        justificationReason: m['justification_reason'] as String?,
        justifiedAt: m['justified_at'] as String?,
        attachmentUrl: m['attachment_url'] as String?,
        comments: m['comments'] as String?,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Timetable models
// ─────────────────────────────────────────────────────────────────────────────
class TimetableEntry {
  final int id;
  final String dayOfWeek;
  final String startTime; // "08:00:00"
  final String endTime;
  final String subject;
  final String? teacherName;
  final String? room;

  const TimetableEntry({
    required this.id,
    required this.dayOfWeek,
    required this.startTime,
    required this.endTime,
    required this.subject,
    this.teacherName,
    this.room,
  });

  /// "08:00:00" → "08h00"
  String get startLabel =>
      startTime.substring(0, 5).replaceAll(':', 'h');

  /// "10:00:00" → "10h00"
  String get endLabel =>
      endTime.substring(0, 5).replaceAll(':', 'h');

  String get slotLabel => '$startLabel - $endLabel';

  factory TimetableEntry.fromMap(Map<String, dynamic> m) => TimetableEntry(
        id: m['id'] as int? ?? 0,
        dayOfWeek: m['day_of_week'] as String,
        startTime: m['start_time'] as String,
        endTime: m['end_time'] as String,
        subject: m['subject'] as String,
        teacherName: m['teacher_name'] as String?,
        room: m['room'] as String?,
      );
}

class TimetableResult {
  final String? className;
  final String? academicYear;
  final String? track;
  final List<TimetableEntry> entries;

  const TimetableResult({
    this.className,
    this.academicYear,
    this.track,
    required this.entries,
  });
}
