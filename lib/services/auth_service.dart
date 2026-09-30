import 'package:supabase_flutter/supabase_flutter.dart';

/// Wrapper around Supabase Auth.
class AuthService {
  AuthService._();

  static final SupabaseClient _client = Supabase.instance.client;

  static Stream<AuthState> get authStateChanges =>
      _client.auth.onAuthStateChange;

  static Session? get currentSession => _client.auth.currentSession;
  static User? get currentUser => _client.auth.currentUser;
  static bool get isLoggedIn => currentUser != null;

  /// Sign in with email and password. Throws [AuthException] on failure.
  static Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    return _client.auth.signInWithPassword(email: email, password: password);
  }

  /// Sign out the current user.
  static Future<void> signOut() async {
    await _client.auth.signOut();
  }

  /// Fetch the `staff` profile row for the currently signed-in user.
  static Future<Map<String, dynamic>?> getCurrentProfile() async {
    final user = currentUser;
    if (user == null) return null;

    return _client
        .from('staff')
        .select('*, departments(name)')
        .eq('id', user.id)
        .maybeSingle();
  }

  /// Convenience: returns the role string ('staff' | 'admin') or 'staff'.
  static Future<String> getCurrentRole() async {
    final profile = await getCurrentProfile();
    return (profile?['role'] as String?) ?? 'staff';
  }
}