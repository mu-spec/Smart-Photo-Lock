import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_colors.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/models/security_settings.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/profiles/lock_profile.dart';
import 'package:smart_app_lock/rules/lock_rule.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher_impl.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';
import 'package:smart_app_lock/ui/screens/home/home_screen.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';
import 'package:smart_app_lock/ui/screens/settings/settings_screen.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_screen.dart';
import 'package:smart_app_lock/ui/shell/main_shell.dart';

/// Phase 1G — regression suite.
///
/// Verifies the complete Phase 1 surface in one place:
/// launch, navigation, persistence, security chain, theme, and crash-free
/// rendering of every screen under both light and dark foundations.
void main() {
  // ---------------------------------------------------------------------
  // 1. Clean build & launch
  // ---------------------------------------------------------------------
  group('launch', () {
    testWidgets('app builds and launches into the home tab', (tester) async {
      await tester.pumpWidget(const SmartAppLockApp());

      expect(tester.takeException(), isNull);
      expect(find.byType(Scaffold), findsWidgets);
      expect(find.text(HomeScreen.phaseLabel), findsOneWidget);
      expect(find.text('Smart App Lock'), findsWidgets);
    });

    testWidgets('MaterialApp carries both theme foundations and system mode',
        (tester) async {
      await tester.pumpWidget(const SmartAppLockApp());
      final MaterialApp app =
          tester.widget<MaterialApp>(find.byType(MaterialApp));

      expect(app.theme, isNotNull);
      expect(app.darkTheme, isNotNull);
      expect(app.themeMode, ThemeMode.system);
      expect(app.theme!.brightness, Brightness.light);
      expect(app.darkTheme!.brightness, Brightness.dark);
    });
  });

  // ---------------------------------------------------------------------
  // 2. Navigation
  // ---------------------------------------------------------------------
  group('navigation', () {
    Future<void> go(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    testWidgets('all five tabs are reachable, forward and back', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const SmartAppLockApp());

      await go(tester, 'nav_apps');
      expect(find.text(AppsScreen.description), findsOneWidget);

      await go(tester, 'nav_smart');
      expect(find.text(SmartScreen.description), findsOneWidget);

      await go(tester, 'nav_security');
      expect(find.text(SecurityScreen.description), findsOneWidget);

      await go(tester, 'nav_settings');
      expect(find.text(SettingsScreen.description), findsOneWidget);

      // Back to home.
      await go(tester, 'nav_home');
      expect(find.text(HomeScreen.phaseLabel), findsOneWidget);

      // And out again — state must remain consistent across switches.
      await go(tester, 'nav_apps');
      await go(tester, 'nav_home');
      expect(find.text(HomeScreen.phaseLabel), findsOneWidget);
    });

    testWidgets('quick-access tiles jump to every section', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const SmartAppLockApp());

      const Map<String, String> tiles = <String, String>{
        'quick_access_apps': 'Apps',
        'quick_access_smart': 'Smart',
        'quick_access_security': 'Security',
        'quick_access_settings': 'Settings',
      };
      for (final MapEntry<String, String> entry in tiles.entries) {
        await go(tester, 'nav_home');
        await tester.tap(find.byKey(Key(entry.key)));
        await tester.pumpAndSettle();
        // The app bar title now shows the destination section.
        expect(find.text(entry.value), findsWidgets);
        expect(tester.takeException(), isNull);
      }
    });
  });

  // ---------------------------------------------------------------------
  // 3. Persistence
  // ---------------------------------------------------------------------
  group('persistence', () {
    testWidgets('all five domains round-trip through the container',
        (tester) async {
      final AppContainer container = AppContainer.inMemory();

      // preferences
      await container.preferences.setOnboardingCompleted(true);
      await container.preferences.setThemeMode('dark');
      expect(await container.preferences.isOnboardingCompleted(), isTrue);
      expect(await container.preferences.getThemeMode(), 'dark');

      // protected apps
      await container.protectedApps.add(ProtectedApp(
        packageName: 'com.whatsapp',
        label: 'WhatsApp',
        addedAt: DateTime(2026, 8, 19),
      ));
      expect((await container.protectedApps.count()).valueOrNull, 1);
      expect(
        (await container.protectedApps.isProtected('com.whatsapp'))
            .valueOrNull,
        isTrue,
      );

      // security settings (encrypted)
      await container.securitySettings.saveSettings(
        SecuritySettings.defaults.copyWith(stealthModeEnabled: true),
      );
      final SecuritySettings restored =
          (await container.securitySettings.getSettings()).valueOrNull!;
      expect(restored.stealthModeEnabled, isTrue);

      // profiles (single-active invariant)
      await container.lockSettings.saveProfile(
        const LockProfile(id: 'a', name: 'A', isActive: true),
      );
      await container.lockSettings.saveProfile(
        const LockProfile(id: 'b', name: 'B'),
      );
      await container.lockSettings.setActiveProfile('b');
      final List<LockProfile> profiles =
          (await container.lockSettings.getProfiles()).valueOrNull!;
      expect(profiles.where((LockProfile p) => p.isActive), hasLength(1));
      expect(
        (await container.lockSettings.getActiveProfile()).valueOrNull?.id,
        'b',
      );

      // rules
      await container.lockSettings.saveRules(
        const <LockRule>[
          LockRule(id: 'r1', type: LockRuleType.always),
        ],
      );
      expect(
        (await container.lockSettings.getRules()).valueOrNull,
        hasLength(1),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('security chain: PIN -> encrypted settings -> verify',
        (tester) async {
      final Pbkdf2PinHasher hasher = Pbkdf2PinHasher(iterations: 200);
      final AppContainer container = AppContainer.inMemory();

      final PinHash pinHash = await hasher.hash('1234');
      await container.securitySettings.saveSettings(
        SecuritySettings.defaults.copyWith(pinHash: pinHash),
      );

      final SecuritySettings settings =
          (await container.securitySettings.getSettings()).valueOrNull!;
      expect(settings.hasPin, isTrue);
      expect(await hasher.verify('1234', settings.pinHash!), isTrue);
      expect(await hasher.verify('0000', settings.pinHash!), isFalse);
      expect((await container.securitySettings.hasPin()).valueOrNull, isTrue);

      // Cipher sanity: tampering is rejected.
      final AesGcmSettingsCipher cipher =
          AesGcmSettingsCipher(InMemorySecretStore());
      final String encrypted = await cipher.encryptString('sensitive');
      final String tampered =
          '${encrypted.substring(0, encrypted.length - 1)}x';
      await expectLater(
        cipher.decryptString(tampered),
        throwsA(isA<Object>()),
      );

      expect(tester.takeException(), isNull);
    });
  });

  // ---------------------------------------------------------------------
  // 4. Theme
  // ---------------------------------------------------------------------
  group('theme', () {
    testWidgets('light and dark foundations apply distinct semantic tokens',
        (tester) async {
      Color? bgLight;
      Color? bgDark;
      Brightness? brightnessViaTokens;

      Widget probe(Brightness brightness) {
        final ThemeData theme =
            brightness == Brightness.light ? AppTheme.light : AppTheme.dark;
        return MaterialApp(
          theme: theme,
          darkTheme: theme,
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) {
                if (brightness == Brightness.light) {
                  bgLight = Theme.of(context).scaffoldBackgroundColor;
                } else {
                  bgDark = Theme.of(context).scaffoldBackgroundColor;
                  brightnessViaTokens = context.dsColors.brightness;
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        );
      }

      await tester.pumpWidget(probe(Brightness.light));
      await tester.pumpWidget(probe(Brightness.dark));

      expect(bgLight, isNot(bgDark));
      expect(bgDark, DsPalette.dark.background);
      expect(bgLight, DsPalette.light.background);
      expect(brightnessViaTokens, Brightness.dark);
      expect(tester.takeException(), isNull);
    });

    test('palette tokens and scales are internally consistent', () {
      expect(DsPalette.dark.background, isNot(DsPalette.light.background));
      expect(DsPalette.dark.primary, AppColors.accent);
      expect(DsSpacing.xxs, lessThan(DsSpacing.xs));
      expect(DsRadii.sm, lessThan(DsRadii.lg));
    });
  });

  // ---------------------------------------------------------------------
  // 5. No crashes — every screen under both themes, all actions tapped
  // ---------------------------------------------------------------------
  group('no crashes', () {
    for (final Brightness brightness in <Brightness>[
      Brightness.light,
      Brightness.dark,
    ]) {
      testWidgets('every tab renders cleanly ($brightness)', (tester) async {
        final ThemeData theme = brightness == Brightness.light
            ? AppTheme.light
            : AppTheme.dark;
        // theme == darkTheme + explicit mode forces the requested brightness;
        // IndexedStack builds ALL five tabs, so one pump covers every screen.
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            darkTheme: theme,
            themeMode: brightness == Brightness.light
                ? ThemeMode.light
                : ThemeMode.dark,
            home: const MainShell(),
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('security screen actions respond without crashing',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: SecurityScreen()),
        ),
      );

      // Tap the banner action -> snackbar, no exceptions.
      await tester.tap(find.text('Set up PIN'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('design-system components render under both themes',
        (tester) async {
      for (final Brightness brightness in <Brightness>[
        Brightness.light,
        Brightness.dark,
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: brightness == Brightness.light
                ? AppTheme.light
                : AppTheme.dark,
            home: Scaffold(
              body: ListView(
                children: <Widget>[
                  const DsCard(
                    title: 'Card',
                    child: DsStatusPill(label: 'pill', tone: DsTone.success),
                  ),
                  DsButton(label: 'Button', onPressed: () {}),
                  const DsTextField(label: 'Input'),
                  const SecurityStatusItem(
                    icon: Icons.lock_outline,
                    title: 'Unlock PIN',
                    level: SecurityLevel.notSet,
                  ),
                  const SecurityStatusBanner(
                    level: SecurityLevel.atRisk,
                    title: 'Banner',
                    message: 'message',
                  ),
                ],
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });
}
