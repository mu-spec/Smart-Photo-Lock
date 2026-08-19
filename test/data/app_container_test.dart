import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/models/security_settings.dart';
import 'package:smart_app_lock/profiles/lock_profile.dart';
import 'package:smart_app_lock/rules/lock_rule.dart';

/// Integration smoke test: the in-memory container wires every store and
/// repository together — the same wiring [AppContainer.create] performs
/// with real plugins on the device.
void main() {
  test('in-memory container serves all four persistence domains', () async {
    final AppContainer container = AppContainer.inMemory();

    // preferences
    expect(await container.preferences.isOnboardingCompleted(), isFalse);
    await container.preferences.setOnboardingCompleted(true);
    expect(await container.preferences.isOnboardingCompleted(), isTrue);

    // protected apps
    await container.protectedApps.add(
      ProtectedApp(
        packageName: 'com.whatsapp',
        label: 'WhatsApp',
        addedAt: DateTime(2026, 8, 19),
      ),
    );
    expect((await container.protectedApps.count()).valueOrNull, 1);
    expect(
      (await container.protectedApps.isProtected('com.whatsapp')).valueOrNull,
      isTrue,
    );

    // security settings
    await container.securitySettings.saveSettings(
      SecuritySettings.defaults.copyWith(stealthModeEnabled: true),
    );
    final SecuritySettings settings =
        (await container.securitySettings.getSettings()).valueOrNull!;
    expect(settings.stealthModeEnabled, isTrue);
    expect((await container.securitySettings.hasPin()).valueOrNull, isFalse);

    // profiles + rules
    await container.lockSettings.saveProfile(
      const LockProfile(id: 'night', name: 'Night', isActive: true),
    );
    expect(
      (await container.lockSettings.getActiveProfile()).valueOrNull?.id,
      'night',
    );
    await container.lockSettings.saveRules(
      const <LockRule>[
        LockRule(id: 'r1', type: LockRuleType.always, packageName: 'com.whatsapp'),
      ],
    );
    expect((await container.lockSettings.getRules()).valueOrNull, hasLength(1));
  });
}
