import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../data/models/app_entry.dart';
import '../data/repositories/impl/installed_apps_repository_impl.dart';
import '../data/repositories/impl/lock_settings_repository_impl.dart';
import '../data/repositories/impl/protected_apps_repository_impl.dart';
import '../data/repositories/impl/security_settings_repository_impl.dart';
import '../data/repositories/installed_apps_repository.dart';
import '../data/repositories/lock_settings_repository.dart';
import '../data/repositories/protected_apps_repository.dart';
import '../data/repositories/security_settings_repository.dart';
import '../data/storage/impl/in_memory_key_value_store.dart';
import '../data/storage/impl/in_memory_local_database.dart';
import '../data/storage/impl/preferences_store_impl.dart';
import '../data/storage/impl/shared_prefs_key_value_store.dart';
import '../data/storage/impl/sqflite_local_database.dart';
import '../data/storage/key_value_store.dart';
import '../data/storage/local_database.dart';
import '../data/storage/preferences_store.dart';
import '../protection/access_controller.dart';
import '../protection/foreground_app_monitor.dart';
import '../protection/impl/default_access_controller.dart';
import '../protection/lock_trigger.dart';
import '../protection/protected_app_matcher.dart';
import '../security/encryption/settings_cipher.dart';
import '../security/encryption/settings_cipher_impl.dart';
import '../security/credentials/credential_manager.dart';
import '../security/credentials/credential_hash_policy.dart';
import '../security/credentials/impl/default_credential_manager.dart';
import '../security/credentials/impl/default_pin_credential_store.dart';
import '../security/storage/impl/flutter_secure_secret_store.dart';
import '../security/storage/impl/in_memory_secret_store.dart';
import '../security/storage/secret_store.dart';
import '../services/accessibility_lock_service.dart';
import '../services/biometric_service.dart';
import '../services/impl/local_auth_biometric_service.dart';
import '../services/impl/method_channel_accessibility_lock_service.dart';
import '../services/impl/method_channel_installed_apps_service.dart';
import '../services/impl/method_channel_overlay_lock_service.dart';
import '../services/impl/method_channel_screen_state_service.dart';
import '../services/impl/static_accessibility_lock_service.dart';
import '../services/impl/static_installed_apps_service.dart';
import '../services/impl/static_overlay_lock_service.dart';
import '../services/impl/static_screen_state_service.dart';
import '../services/capability_monitor.dart';
import '../services/installed_apps_service.dart';
import '../services/overlay_lock_service.dart';
import '../services/screen_state_service.dart';

/// Application dependency container — the single wiring point for all
/// persistence and security storage.
///
/// Screens and controllers never construct stores themselves; they receive
/// the repositories from here. Two ways to build one:
///
///  * [AppContainer.create]  — production: shared_preferences + SQLite +
///    Android Keystore-backed secret store + AES-GCM settings encryption.
///  * [AppContainer.inMemory] — tests/previews: volatile stores.
class AppContainer {
  AppContainer._({
    required KeyValueStore keyValueStore,
    required LocalDatabase database,
    required SecretStore secretStore,
    required InstalledAppsService installedAppsService,
    required AccessibilityLockService accessibilityService,
    required OverlayLockService overlayService,
    required ScreenStateService screenStateService,
    required this.capabilityMonitor,
    BiometricService? biometricsOverride,
    PreferencesStore? preferencesOverride,
  })  : _keyValueStore = keyValueStore,
        _database = database,
        secretStore = secretStore,
        installedAppsService = installedAppsService,
        accessibility = accessibilityService,
        overlay = overlayService,
        screenState = screenStateService {
    settingsCipher = AesGcmSettingsCipher(secretStore);
    preferences = preferencesOverride ?? PreferencesStoreImpl(_keyValueStore);
    protectedApps = ProtectedAppsRepositoryImpl(_database);
    securitySettings = SecuritySettingsRepositoryImpl(
      _database,
      cipher: settingsCipher,
    );
    lockSettings = LockSettingsRepositoryImpl(_database);
    // Installed-apps discovery (Phase 3A): repository over the platform
    // service. The service instance is shared — no screen ever creates
    // its own.
    installedApps = InstalledAppsRepositoryImpl(installedAppsService);
    // Phase 5A: merged foreground detection (usage-stats primary +
    // accessibility fallback). One shared instance; NOT auto-started —
    // the lock engine (later phase) owns the start/stop lifecycle.
    foregroundMonitor = ForegroundAppMonitor(
      installedApps: installedAppsService,
      accessibility: accessibilityService,
    );
    // Phase 5C: matching a detected foreground package against the
    // protected list. Wired to the SAME repository the Apps tab writes
    // — one shared instance for diagnostics now and the lock engine in
    // 5D+.
    protectedAppMatcher = ProtectedAppMatcher(repository: protectedApps);
    // Biometric foundation (Phase 2J): platform BiometricPrompt bridge.
    // Tests may override it with a fake for deterministic availability
    // states; production always uses the real local_auth service.
    biometrics = biometricsOverride ?? LocalAuthBiometricService();
    auth = DefaultCredentialManager(
      settings: securitySettings,
      // Production PIN storage: strict hash policy (PBKDF2 work factor,
      // key/salt/digest sizes) + fail-closed reads. The store takes the
      // settings repository positionally.
      pinStore: DefaultPinCredentialStore(
        securitySettings,
        policy: CredentialHashPolicy.strict,
      ),
      biometricService: biometrics,
    );
    // Phase 5D: the access decision pipeline (protected -> challenge ->
    // session) and the trigger that drives it from foreground changes.
    // Phase 5E: the controller also consults the credential manager so
    // an active authentication lockout yields `deny`. Constructed AFTER
    // `auth` — the controller reads credential state on every decision.
    // Phase 5K: the trigger also watches the device screen state —
    // a screen-off revokes every unlock session immediately.
    accessController = DefaultAccessController(
      matcher: protectedAppMatcher,
      auth: auth,
      now: accessClock,
    );
    lockTrigger = LockTrigger(
      monitor: foregroundMonitor,
      controller: accessController,
      screenState: screenStateService,
    );
  }

  /// Production container: real on-device persistence with
  /// Android Keystore-backed protection for sensitive values.
  static Future<AppContainer> create() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final SqfliteLocalDatabase database = SqfliteLocalDatabase();
    await database.init();
    // Phase 4F repair: the revocation monitor must probe the SAME
    // service instances the UI reads. Build the three bridges first,
    // construct the monitor once over them, and hand both in — the
    // final field is initialized exactly once by the constructor.
    final InstalledAppsService installedAppsService =
        MethodChannelInstalledAppsService();
    final AccessibilityLockService accessibilityService =
        MethodChannelAccessibilityLockService();
    final OverlayLockService overlayService =
        MethodChannelOverlayLockService();
    // The monitor records grant history through the SAME preferences
    // store the UI reads — built first so both share one instance.
    final PreferencesStore preferences =
        PreferencesStoreImpl(SharedPreferencesKeyValueStore(prefs));
    return AppContainer._(
      keyValueStore: SharedPreferencesKeyValueStore(prefs),
      database: database,
      secretStore: FlutterSecureSecretStore(),
      installedAppsService: installedAppsService,
      accessibilityService: accessibilityService,
      overlayService: overlayService,
      screenStateService: MethodChannelScreenStateService(),
      capabilityMonitor: CapabilityMonitor(
        hasUsageAccess: installedAppsService.hasUsageAccess,
        isAccessibilityEnabled: accessibilityService.isServiceEnabled,
        canDrawOverlays: overlayService.canDrawOverlays,
        markEverGranted: (CapabilityKind kind) =>
            preferences.markCapabilityEverGranted(kind.name),
      ),
      preferencesOverride: preferences,
    );
  }

  /// Volatile container for tests and previews (no platform plugins).
  /// [biometrics] overrides the real platform service (test fakes);
  /// [apps] seeds the static installed-apps service; [appIcons] provides
  /// PNG bytes for specific packages; [usageAccessGranted] controls the
  /// capability state the static service reports.
  static AppContainer inMemory({
    BiometricService? biometrics,
    List<AppEntry> apps = const <AppEntry>[],
    Map<String, Uint8List> appIcons = const <String, Uint8List>{},
    bool usageAccessGranted = true,
    bool accessibilityEnabled = false,
    bool overlayGranted = false,
    DateTime Function()? accessClock,
    // Phase 5T (process-recreation test seams): share the SAME database
    // and secret store across two containers to simulate a process
    // death/recreation over the persisted state — exactly what SQLite +
    // the Android Keystore survive in production.
    LocalDatabase? database,
    SecretStore? secretStore,
  }) {
    final InstalledAppsService installedAppsService =
        StaticInstalledAppsService(
      apps,
      iconBytesFor: appIcons,
      usageAccessGranted: usageAccessGranted,
    );
    final AccessibilityLockService accessibilityService =
        StaticAccessibilityLockService(
      enabled: accessibilityEnabled,
    );
    final OverlayLockService overlayService = StaticOverlayLockService(
      overlayGranted: overlayGranted,
    );
    final KeyValueStore keyValueStore = InMemoryKeyValueStore();
    final PreferencesStore preferences = PreferencesStoreImpl(keyValueStore);
    return AppContainer._(
      keyValueStore: keyValueStore,
      database: database ?? InMemoryLocalDatabase(),
      secretStore: secretStore ?? InMemorySecretStore(),
      installedAppsService: installedAppsService,
      accessibilityService: accessibilityService,
      overlayService: overlayService,
      screenStateService: StaticScreenStateService(),
      capabilityMonitor: CapabilityMonitor(
        hasUsageAccess: installedAppsService.hasUsageAccess,
        isAccessibilityEnabled: accessibilityService.isServiceEnabled,
        canDrawOverlays: overlayService.canDrawOverlays,
        markEverGranted: (CapabilityKind kind) =>
            preferences.markCapabilityEverGranted(kind.name),
      ),
      biometricsOverride: biometrics,
      preferencesOverride: preferences,
    );
  }

  final KeyValueStore _keyValueStore;
  final LocalDatabase _database;

  /// Sensitive values (master key, future tokens) — Keystore-backed in
  /// production. Nothing sensitive is ever written elsewhere.
  final SecretStore secretStore;

  /// AES-256-GCM cipher protecting the security settings document.
  late final SettingsCipher settingsCipher;

  /// Typed app preferences (onboarding, theme, language, notifications).
  late final PreferencesStore preferences;

  /// Protected applications list.
  late final ProtectedAppsRepository protectedApps;

  /// Security configuration (encrypted at rest; holds the PIN credential hash).
  late final SecuritySettingsRepository securitySettings;

  /// Lock profiles and rules.
  late final LockSettingsRepository lockSettings;

  /// Credential lifecycle (Phase 2A): enroll / status / authenticate /
  /// clear for PIN, pattern and biometric.
  late final CredentialManager auth;

  /// Platform biometric bridge (Phase 2J): capability checks + prompt.
  late final BiometricService biometrics;

  /// Installed-apps catalog (Phase 3A): discovery repository over the
  /// platform package-manager bridge, filtered to apps appropriate for
  /// App Lock selection.
  late final InstalledAppsRepository installedApps;

  /// The shared platform service behind [installedApps] (Phase 4B: the
  /// UI reads usage-access capability state from here — one instance,
  /// never recreated per screen).
  final InstalledAppsService installedAppsService;

  /// Phase 5A: foreground-app detection (usage-stats polls +
  /// accessibility fallback), shared app-wide. Started/stopped by the
  /// lock engine phase — 5A delivers detection only.
  late final ForegroundAppMonitor foregroundMonitor;

  /// Phase 5C: protected-app matching over the shared repository.
  late final ProtectedAppMatcher protectedAppMatcher;

  /// Phase 5D: the access decision policy (protected? session? challenge).
  late final AccessController accessController;

  /// Phase 5D: the lock trigger — monitors foreground changes and emits
  /// lock requirements through [accessController]. The app root starts
  /// and stops it alongside the app lifecycle.
  late final LockTrigger lockTrigger;

  /// The shared accessibility capability bridge (Phase 4C) — detection
  /// fallback state + settings routing. One instance for UI and, later,
  /// the lock engine.
  final AccessibilityLockService accessibility;

  /// The shared overlay capability bridge (Phase 4D) — draw-over-apps
  /// state + settings routing; the lock window itself lands with the
  /// lock-screen phase.
  final OverlayLockService overlay;

  /// Phase 5K: the device screen-state bridge (screen off/on
  /// broadcasts) — the lock trigger revokes all unlock sessions when
  /// the screen turns off.
  final ScreenStateService screenState;

  /// Revocation watcher (Phase 4F): probes the same services and emits
  /// granted→revoked changes. Started by the app root.
  final CapabilityMonitor capabilityMonitor;
}
