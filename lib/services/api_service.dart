import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  // ── Change this to your local Laragon URL when testing on a device/emulator
  // For Android emulator use: http://10.0.2.2/pfe/api
  // For Chrome/desktop (flutter run -d chrome): http://localhost/pfe/api
  static const String baseUrl = 'http://localhost/pfe/api';

  // ── Login ──────────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> login(
      String identifier, String password) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/mobile/login'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: json.encode({
              'identifier': identifier,
              'password': password,
            }),
          )
          .timeout(const Duration(seconds: 15));

      final body = json.decode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200 && body['success'] == true) {
        return {
          'success': true,
          'data': body['user'],
          'token': body['token'],
        };
      } else {
        return {
          'success': false,
          'message': body['message'] ?? 'Identifiants incorrects.',
        };
      }
    } on Exception catch (e) {
      return {
        'success': false,
        'message': 'Connexion impossible. Vérifiez votre réseau.\n($e)',
      };
    }
  }
}
