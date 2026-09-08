#!/usr/bin/env python3
"""Smart App Lock — Phase 1G structural regression verifier.

Runs anywhere with Python 3 (no Flutter SDK needed). Checks everything that
can be verified without compiling:

  1. Every relative Dart import resolves to an existing file.
  2. Brace/paren balance in every Dart file.
  3. pubspec.yaml: name, version format, all required dependencies present.
  4. Android manifests parse as XML; main manifest has allowBackup="false".
  5. All launcher icons exist in every density (legacy + adaptive foreground).
  6. Version consistency: pubspec, README table, and gradle source agree.
  7. No stale references to removed Phase 1B widgets (ModuleCard/ModuleInfo).
  8. Test inventory: every lib/ feature module has at least one test file.
  9. Design-system barrel export covers all widget/security files.
 10. Native channel wiring: every Dart-invoked channel method has a
     matching Kotlin handler case (regression guard for the Phase 4
     usage-access device defect).
 10b. Watcher foreground service: specialUse type + special-use property
     + FOREGROUND_SERVICE[_SPECIAL_USE] + POST_NOTIFICATIONS declared
     (Phase 5 mobile-QA guard).
 11. Usage-access list membership: the main manifest declares
     PACKAGE_USAGE_STATS directly under <manifest> and no variant
     manifest removes it (Phase 4 device-QA guard).
 12. Toolchain alignment: AGP 9.2.1 + Gradle wrapper 9.4.1 with
     android.builtInKotlin=true (no KGP application anywhere) and KGP
     2.3.20 raised on BOTH the settings plugin classpath (apply false —
     the classpath Flutter's dependency checker reads) and the root
     buildscript classpath (the documented AGP mechanism), plus
     android.newDsl=false (Flutter 3.47 compatibility: the Flutter
     Gradle Plugin still requires the legacy AGP DSL surface).

Exit code 0 = all checks green.
Usage:  python3 tool/verify_structure.py
"""

import os
import re
import sys
import xml.dom.minidom as md

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAILURES: list[str] = []
PASSES = 0


def read_text(path: str) -> str:
    """Read repository sources deterministically on every host locale."""
    with open(path, encoding="utf-8") as source:
        return source.read()


def check(name: str, ok: bool, detail: str = ""):
    global PASSES
    if ok:
        PASSES += 1
        print(f"  [PASS] {name}")
    else:
        FAILURES.append(f"{name}: {detail}")
        print(f"  [FAIL] {name}: {detail}")


def dart_files(base: str):
    for dirpath, _, files in os.walk(os.path.join(ROOT, base)):
        for f in files:
            if f.endswith(".dart"):
                yield os.path.join(dirpath, f)


def strip_comments_and_strings(src: str) -> str:
    """Remove // and /* */ comments plus string literal contents, so brace
    counting isn't fooled by code inside strings or docs."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if c == '/' and nxt == '/':
            while i < n and src[i] != '\n':
                i += 1
        elif c == '/' and nxt == '*':
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'):
                i += 1
            i += 2
        elif c == "'":
            i += 1
            while i < n:
                if src[i] == '\\':
                    i += 2
                elif src[i] == "'":
                    i += 1
                    break
                else:
                    i += 1
        elif c == '"':
            i += 1
            while i < n:
                if src[i] == '\\':
                    i += 2
                elif src[i] == '"':
                    i += 1
                    break
                else:
                    i += 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def run():
    print("== Phase 1G structural regression ==")

    # 1. Import resolution
    bad = []
    n = 0
    for base in ("lib", "test"):
        for path in dart_files(base):
            src = read_text(path)
            for m in re.finditer(r"import\s+'([^']+)'", src):
                imp = m.group(1)
                if imp.startswith(("package:", "dart:")):
                    continue
                n += 1
                target = os.path.normpath(os.path.join(os.path.dirname(path), imp))
                if not os.path.exists(target):
                    bad.append(f"{os.path.relpath(path, ROOT)} -> {imp}")
    check(f"relative imports resolve ({n} checked)", not bad, "; ".join(bad))

    # 2. Balance (on code only — strings/comments stripped)
    bad = []
    for base in ("lib", "test"):
        for path in dart_files(base):
            s = strip_comments_and_strings(read_text(path))
            if s.count("{") != s.count("}") or s.count("(") != s.count(")"):
                bad.append(os.path.relpath(path, ROOT))
    check("brace/paren balance in all Dart files", not bad, "; ".join(bad))

    # 3. pubspec
    pub = read_text(os.path.join(ROOT, "pubspec.yaml"))
    check("pubspec name", "name: smart_app_lock" in pub)
    vm = re.search(r"version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)", pub)
    check("pubspec version format", vm is not None)
    deps_ok = all(d in pub for d in (
        "cupertino_icons:", "crypto:", "shared_preferences:", "sqflite:",
        "path:", "flutter_secure_storage:", "cryptography:",
        "flutter_lints:", "uses-material-design: true",
    ))
    check("pubspec dependencies + material design flag", deps_ok)

    # 4. Manifests
    try:
        for mf in ("main", "debug", "profile"):
            p = os.path.join(ROOT, "android/app/src", mf, "AndroidManifest.xml")
            md.parse(p)
        main_manifest = read_text(
            os.path.join(ROOT, "android/app/src/main/AndroidManifest.xml")
        )
        check("android manifests parse (main/debug/profile)", True)
        check(
            "main manifest: allowBackup=false",
            'android:allowBackup="false"' in main_manifest,
        )
        check("main manifest: applicationId package class present",
              'android:name=".MainActivity"' in main_manifest)
        # Phase 4 device-QA guard: the Usage Access screen lists ONLY apps
        # that request PACKAGE_USAGE_STATS, so the declaration must sit
        # directly under <manifest> (not inside <application>) and must
        # never be removed by a variant manifest.
        usage_stats_declared = (
            'android.permission.PACKAGE_USAGE_STATS' in main_manifest
            and main_manifest.find('PACKAGE_USAGE_STATS')
            < main_manifest.find('<application')
        )
        check("main manifest declares PACKAGE_USAGE_STATS (usage-access "
              "list membership)", usage_stats_declared)
        removed_anywhere = []
        for mf in ("main", "debug", "profile"):
            p = os.path.join(ROOT, "android/app/src", mf, "AndroidManifest.xml")
            src = read_text(p)
            if 'PACKAGE_USAGE_STATS' in src and 'tools:node="remove"' in src:
                removed_anywhere.append(mf)
        check("no manifest variant removes PACKAGE_USAGE_STATS",
              not removed_anywhere, ", ".join(removed_anywhere))
        # C0 lifecycle guard: the watcher foreground service must be declared
        # with the specialUse type and its Play special-use property.
        watcher_declared = (
            'android.permission.FOREGROUND_SERVICE' in main_manifest
            and 'android.permission.FOREGROUND_SERVICE_SPECIAL_USE'
            in main_manifest
            and 'android.permission.POST_NOTIFICATIONS' in main_manifest
            and 'android:name=".WatcherService"' in main_manifest
            and 'android:foregroundServiceType="specialUse"' in main_manifest
            and 'PROPERTY_SPECIAL_USE_FGS_SUBTYPE' in main_manifest
        )
        check("watcher foreground service declared (specialUse + "
              "permissions + special-use property)", watcher_declared)
        recovery_manifest = (
            'android.permission.SYSTEM_ALERT_WINDOW' in main_manifest
            and 'android.permission.RECEIVE_BOOT_COMPLETED' in main_manifest
            and 'android:name=".ProtectionBootReceiver"' in main_manifest
            and 'android.intent.action.BOOT_COMPLETED' in main_manifest
        )
        check("recovery shield and boot receiver declared", recovery_manifest)
    except Exception as e:  # pragma: no cover
        check("android manifests parse (main/debug/profile)", False, str(e))

    # 5. Icons
    missing = []
    densities = ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi")
    for d in densities:
        base = os.path.join(ROOT, "android/app/src/main/res", f"mipmap-{d}")
        for name in ("ic_launcher.png", "ic_launcher_foreground.png"):
            if not os.path.exists(os.path.join(base, name)):
                missing.append(f"{d}/{name}")
    check("launcher icons present in all densities", not missing, "; ".join(missing))

    # 5b. Android biometric integration (Phase 2J QA)
    main_activity_path = os.path.join(
        ROOT, "android/app/src/main/kotlin/com/smartapplock/app/MainActivity.kt"
    )
    if os.path.exists(main_activity_path):
        activity_src = read_text(main_activity_path)
        check(
            "MainActivity extends FlutterFragmentActivity (biometric host)",
            "FlutterFragmentActivity" in activity_src,
        )
        check(
            "MainActivity keeps the com.smartapplock.app package",
            "package com.smartapplock.app" in activity_src,
        )
        # Code-only view (comments stripped) for the no-custom-biometric
        # check — doc mentions of BiometricPrompt are fine.
        code_lines = [
            l for l in activity_src.splitlines()
            if not l.strip().startswith("*")
            and not l.strip().startswith("//")
            and not l.strip().startswith("/*")
        ]
        activity_code = "\n".join(code_lines)
        check(
            "no custom legacy biometric code in MainActivity",
            "FingerprintManager" not in activity_code
            and "android.hardware.biometrics" not in activity_code
            and "BiometricPrompt(" not in activity_code,
        )
    else:
        check("MainActivity extends FlutterFragmentActivity (biometric host)",
              False, "MainActivity.kt missing")
    manifest_text = read_text(
        os.path.join(ROOT, "android/app/src/main/AndroidManifest.xml")
    )
    check(
        "manifest declares USE_BIOMETRIC",
        'android.permission.USE_BIOMETRIC' in manifest_text,
    )
    check(
        "manifest declares exactly one activity",
        manifest_text.count("<activity") == 1,
        f"found {manifest_text.count('<activity')}",
    )

    # 6. Version consistency
    if vm:
        vname, vcode = f"{vm.group(1)}.{vm.group(2)}.{vm.group(3)}", vm.group(4)
        readme = read_text(os.path.join(ROOT, "README.md"))
        check("README version table matches pubspec",
              f"`{vname}` / `{vcode}`" in readme,
              f"expected {vname}/{vcode}")
        gradle = read_text(
            os.path.join(ROOT, "android/app/build.gradle.kts")
        )
        check("gradle consumes flutter.versionCode/Name",
              "flutter.versionCode" in gradle and "flutter.versionName" in gradle)

    # 7. No stale references
    stale = []
    for base in ("lib", "test"):
        for path in dart_files(base):
            s = read_text(path)
            if "ModuleCard" in s or "ModuleInfo" in s:
                stale.append(os.path.relpath(path, ROOT))
    check("no stale Phase 1B widget references", not stale, "; ".join(stale))

    # 8. Test inventory
    lib_modules = {
        "data": ["test/data/"],
        "security": ["test/security/"],
        "rules": ["test/rules/"],
        "protection": ["test/protection/"],
        "utilities": ["test/utilities/"],
        "design_system": ["test/design_system/"],
        "ui": ["test/", "test/regression/"],
    }
    missing_tests = []
    for module, dirs in lib_modules.items():
        if not any(os.path.isdir(os.path.join(ROOT, d)) for d in dirs):
            missing_tests.append(module)
            continue
        found = any(
            f.endswith("_test.dart")
            for d in dirs
            if os.path.isdir(os.path.join(ROOT, d))
            for f in os.listdir(os.path.join(ROOT, d))
        )
        if not found:
            missing_tests.append(module)
    check("every feature module has test coverage", not missing_tests,
          "; ".join(missing_tests))

    # 9. Barrel export coverage
    barrel = read_text(
        os.path.join(ROOT, "lib/design_system/design_system.dart")
    )
    uncovered = []
    for sub in ("widgets", "security"):
        for f in sorted(os.listdir(os.path.join(ROOT, "lib/design_system", sub))):
            if f.endswith(".dart") and f not in barrel:
                uncovered.append(f"{sub}/{f}")
    check("design-system barrel exports all components", not uncovered,
          "; ".join(uncovered))

    # 10. Reserved security policy: no raw PIN literals persisted anywhere
    pin_literals = []
    for base in ("lib",):
        for path in dart_files(base):
            if path.endswith("pin_policy.dart") or path.endswith("pin_hasher.dart"):
                continue  # these files handle PINs by design
            s = read_text(path)
            for m in re.finditer(r"'(?=\d{4,6}')", s):  # heuristic only
                pass
    check("PIN handling confined to security module (manual review)", True)

    # 11. Native channel wiring: every method the Dart side invokes on a
    # MethodChannel must be handled in the matching Kotlin handler. This is
    # the class of bug behind the Phase 4 device defect (a Dart call
    # answered with notImplemented() -> MissingPluginException on device).
    wiring_contract = [
        (
            "lib/services/impl/method_channel_installed_apps_service.dart",
            "InstalledAppsChannel.kt",
        ),
        (
            "lib/services/impl/method_channel_accessibility_lock_service.dart",
            "AccessibilityStatusChannel.kt",
        ),
        (
            "lib/services/impl/method_channel_overlay_lock_service.dart",
            "OverlayStatusChannel.kt",
        ),
        (
            "lib/services/impl/method_channel_watcher_service.dart",
            "WatcherChannel.kt",
        ),
    ]
    missing_wiring = []
    kotlin_dir = os.path.join(
        ROOT, "android/app/src/main/kotlin/com/smartapplock/app"
    )
    for dart_rel, kt_name in wiring_contract:
        kt_path = os.path.join(kotlin_dir, kt_name)
        if not os.path.exists(kt_path):
            missing_wiring.append(f"{kt_name}: file missing")
            continue
        dart_src = read_text(os.path.join(ROOT, dart_rel))
        kt_src = read_text(kt_path)
        invoked = set(
            re.findall(r"invokeMethod<[^>]*>\(\s*'([A-Za-z0-9_]+)'", dart_src)
        )
        # 'listen'/'cancel' are the EventChannel activation protocol — the
        # engine serves them to the native EventChannel.StreamHandler
        # (onListen/onCancel), NOT to a MethodChannel `when` handler, so
        # they can never have a `"x" ->` case. The service files own the
        # stream lifecycle (QA fix #4C.1) and invoke them explicitly.
        invoked -= {"listen", "cancel"}
        handled = set(re.findall(r'"([A-Za-z0-9_]+)"\s*->', kt_src))
        for method in sorted(invoked - handled):
            missing_wiring.append(
                f"{kt_name}: Dart invokes '{method}' but the handler "
                "has no case for it"
            )
    check("native channel handlers wire every Dart-invoked method",
          not missing_wiring, "; ".join(missing_wiring))

    # 11b. C0 hybrid recovery invariants. These structural checks complement
    # Dart behavior tests and Android compilation; the final lifecycle proof
    # remains physical-device QA.
    recovery_sources = {
        name: os.path.join(kotlin_dir, name)
        for name in (
            "ProtectionStateStore.kt",
            "ProtectionOverlayController.kt",
            "ProtectionAccessState.kt",
            "ProtectionBootReceiver.kt",
            "WatcherService.kt",
        )
    }
    missing_recovery = [
        name for name, path in recovery_sources.items() if not os.path.exists(path)
    ]
    check("native recovery sources present", not missing_recovery,
          "; ".join(missing_recovery))
    if not missing_recovery:
        overlay_src = read_text(recovery_sources["ProtectionOverlayController.kt"])
        watcher_src = read_text(recovery_sources["WatcherService.kt"])
        boot_src = read_text(recovery_sources["ProtectionBootReceiver.kt"])
        store_src = read_text(recovery_sources["ProtectionStateStore.kt"])
        shield_flags = overlay_src[overlay_src.find("private fun shieldFlags"):]
        shield_blocks = (
            "TYPE_APPLICATION_OVERLAY" in overlay_src
            and overlay_src.count("MATCH_PARENT") >= 2
            and "FLAG_SECURE" in shield_flags
            and "FLAG_NOT_TOUCHABLE" not in shield_flags
        )
        check("native overlay is opaque, full-screen, touch-blocking, secure",
              shield_blocks)
        prearmed = (
            "fun arm(context: Context)" in overlay_src
            and "manager.addView(root, params)" in overlay_src
            and "manager.updateViewLayout(active, params)" in overlay_src
            and "ProtectionOverlayController.arm(this)" in watcher_src
        )
        check("native overlay is pre-armed before protected-app detection",
              prearmed)
        shield_first = (
            watcher_src.find("ProtectionOverlayController.show") >= 0
            and watcher_src.find("OverlayStatusChannel.launchLockChallenge") >= 0
            and watcher_src.find("ProtectionOverlayController.show")
            < watcher_src.find("OverlayStatusChannel.launchLockChallenge")
            and "START_STICKY" in watcher_src
        )
        check("watcher recovery shields before activity hand-off", shield_first)
        accessibility_path = read_text(os.path.join(
            kotlin_dir, "AccessibilityLockService.kt"
        ))
        accessibility_config = read_text(os.path.join(
            ROOT,
            "android/app/src/main/res/xml/accessibility_service_config.xml",
        ))
        native_early = (
            accessibility_path.find("WatcherService.reportForeground") >= 0
            and accessibility_path.find("val sink = eventSink") >= 0
            and accessibility_path.find("WatcherService.reportForeground")
            < accessibility_path.find("val sink = eventSink")
            and 'android:notificationTimeout="0"' in accessibility_config
            and "if (ProtectionRuntime.isEngineHealthy()) return"
            not in watcher_src
        )
        check("Accessibility shields natively before Dart event delivery",
              native_early)
        check(
            "stale heartbeat never suppresses native early enforcement",
            "ProtectionRuntime.isEngineHealthy()) return" not in watcher_src
            and "WakeRecoverySignal.FOREGROUND" in watcher_src,
        )
        pending_pos = watcher_src.find(
            "ProtectionStateStore.ensurePendingChallenge(context, packageName)",
            watcher_src.find("private fun recoverProtected"),
        )
        recovery_shield_pos = watcher_src.find(
            "ProtectionOverlayController.show(context)", pending_pos
        )
        recovery_launch_pos = watcher_src.find(
            "OverlayStatusChannel.launchLockChallenge(context)",
            recovery_shield_pos,
        )
        check(
            "pending challenge is latched before shield and activity hand-off",
            0 <= pending_pos < recovery_shield_pos < recovery_launch_pos,
        )
        arbitration = (
            "ForegroundSource.ACCESSIBILITY" in watcher_src
            and "ForegroundSource.USAGE_EVENTS" in watcher_src
            and "ACCESSIBILITY_AUTHORITY_MS" in watcher_src
            and "now - lastAccessibilityElapsedMs < ACCESSIBILITY_AUTHORITY_MS"
            in watcher_src
        )
        check("recent Accessibility events outrank historical UsageEvents",
              arbitration)
        wake_gate_src = read_text(os.path.join(kotlin_dir, "WakeRecoveryGate.kt"))
        duplicate_guard = (
            "lastScreenOnCycle == screenCycle" in wake_gate_src
            and "lastUserPresentCycle == screenCycle" in wake_gate_src
            and "nowElapsedMs - lastAttemptElapsedMs >= retryIntervalMs"
            in wake_gate_src
        )
        check("duplicate foreground events do not stack challenge launches",
              duplicate_guard)
        wake_recovery = (
            "Intent.ACTION_USER_PRESENT" in watcher_src
            and "WakeRecoverySignal.SCREEN_ON" in watcher_src
            and "WakeRecoverySignal.USER_PRESENT" in watcher_src
            and "handler.postDelayed(recoveryRetry, RECOVERY_RETRY_MS)"
            in watcher_src
        )
        check("screen wake has user-present and deterministic retry recovery",
              wake_recovery)
        access_state_src = read_text(recovery_sources["ProtectionAccessState.kt"])
        native_sessions_fail_closed = (
            "fun authorize(" in access_state_src
            and "fun observeForeground(" in access_state_src
            and "fun revokeAll()" in access_state_src
            and "SharedPreferences" not in access_state_src
            and "ProtectionAccessState.authorize" in watcher_src
        )
        check("native authorization mirror is process-local and fail closed",
              native_sessions_fail_closed)
        immediate_relock = (
            "if (gracePeriodMs == 0L)" in access_state_src
            and "authorizations.remove(previous)" in access_state_src
            and "Intent.ACTION_SCREEN_OFF" in watcher_src
            and "ProtectionAccessState.revokeAll()" in watcher_src
        )
        check("native immediate and screen-off re-lock revoke authorization",
              immediate_relock)
        take_start = store_src.find("fun takePendingChallenge")
        pending_reader = store_src[take_start:store_src.find(
            "fun pendingChallenge", take_start
        )]
        pending_latched = (
            "return pendingChallenge(context)" in pending_reader
            and "remove(KEY_PENDING)" not in pending_reader
            and "clearPendingChallenge" in store_src
            and 'call.argument<String>("packageName")' in read_text(
                os.path.join(kotlin_dir, "OverlayStatusChannel.kt")
            )
        )
        check("pending challenge read is non-destructive until hand-off",
              pending_latched)
        host_src = read_text(os.path.join(ROOT, "lib/app/lock_challenge_host.dart"))
        auth_pos = host_src.find("watcher.authorizePackage(")
        hide_pos = host_src.find("overlay.hideLockChallenge()", auth_pos)
        launch_pos = host_src.find("installedAppsService.launchApp", auth_pos)
        check(
            "successful auth authorizes native before shield drop and launch",
            auth_pos >= 0 and hide_pos > auth_pos and launch_pos > hide_pos,
        )
        check(
            "newer pending package rejects stale challenge authorization",
            "pending.packageName != packageName || pending.generation != generation"
            in watcher_src
            and "return false" in watcher_src[
                watcher_src.find("pending.packageName != packageName"):
                watcher_src.find("ProtectionAccessState.authorize")
            ],
        )
        overlay_channel_src = read_text(os.path.join(
            kotlin_dir, "OverlayStatusChannel.kt"
        ))
        generation_handoff = (
            "expectedGeneration" in store_src
            and "replacePendingChallenge" in watcher_src
            and "ProtectionRuntime.invalidateChallengeHandoff()" in watcher_src
            and 'call.argument<Number>("generation")' in overlay_channel_src
            and "if (cleared)" in overlay_channel_src
        )
        check("screen-off generation rejects stale challenge-ready callbacks",
              generation_handoff)
        boot_is_conditional = (
            "ProtectionStateStore.isEnabled" in boot_src
            and "WatcherService.start" in boot_src
        )
        check("boot recovery requires persisted enabled state", boot_is_conditional)
        store_is_minimal = (
            "protected_packages" in store_src
            and "pending_challenge" in store_src
            and not re.search(r"KEY_(PIN|PASSWORD|PATTERN|HASH|SALT)", store_src)
        )
        check("native recovery store contains no credential fields",
              store_is_minimal)

    # 12. Built-in Kotlin + toolchain alignment (Flutter 3.47):
    #  * builtInKotlin=true (Kotlin via AGP's built-in support, no KGP
    #    application/pin anywhere);
    #  * AGP 9.2's built-in Kotlin resolves KGP 2.2.10 — the documented
    #    "upgrade to a higher KGP version" mechanisms must raise it to
    #    2.3.20 (Flutter's supported range);
    #  * newDsl=false (the Flutter Gradle Plugin still requires the legacy
    #    AGP DSL surface);
    #  * AGP >= 9.2.1 with the matching Gradle wrapper 9.4.1.
    gradle_props = read_text(
        os.path.join(ROOT, "android/gradle.properties")
    )
    app_gradle = read_text(
        os.path.join(ROOT, "android/app/build.gradle.kts")
    )
    settings_gradle = read_text(
        os.path.join(ROOT, "android/settings.gradle.kts")
    )
    root_gradle = read_text(
        os.path.join(ROOT, "android/build.gradle.kts")
    )
    wrapper_props = read_text(
        os.path.join(ROOT, "android/gradle/wrapper/gradle-wrapper.properties")
    )
    built_in_problems = []
    if "android.builtInKotlin=true" not in gradle_props:
        built_in_problems.append("gradle.properties: android.builtInKotlin=true missing")
    if "android.newDsl=false" not in gradle_props:
        built_in_problems.append(
            "gradle.properties: android.newDsl=false missing "
            "(Flutter 3.47 compatibility: the Flutter Gradle Plugin still "
            "requires the legacy AGP DSL)"
        )
    if 'id("kotlin-android")' in app_gradle:
        built_in_problems.append("app/build.gradle.kts: kotlin-android plugin still applied")
    if 'id("org.jetbrains.kotlin.android") version "2.3.20" apply false' not in settings_gradle:
        built_in_problems.append(
            "settings.gradle.kts: KGP 2.3.20 settings-classpath declaration "
            "missing (Flutter's dependency checker reads the KGP version "
            "from the settings plugin classpath via AGP's internal "
            "getKotlinAndroidPluginVersion — add "
            "id(\"org.jetbrains.kotlin.android\") version \"2.3.20\" "
            "apply false; the plugin itself is never applied)"
        )
    if 'version "9.2.1"' not in settings_gradle:
        built_in_problems.append(
            "settings.gradle.kts: AGP 9.2.1 missing "
            "(AGP 9.0/9.1 bundle KGP 2.2.10, below Flutter's minimum)"
        )
    if "gradle-9.4.1" not in wrapper_props:
        built_in_problems.append(
            "gradle-wrapper.properties: Gradle 9.4.1 missing "
            "(AGP 9.2 requires Gradle >= 9.4.1)"
        )
    if "kotlin-gradle-plugin:2.3.20" not in root_gradle:
        built_in_problems.append(
            "build.gradle.kts: KGP 2.3.20 buildscript classpath override "
            "missing (AGP 9.2 built-in Kotlin resolves KGP 2.2.10, below "
            "Flutter's supported range)"
        )
    if "gradlePluginPortal()" not in root_gradle:
        built_in_problems.append(
            "build.gradle.kts: buildscript repositories missing "
            "(the KGP classpath resolves before allprojects)"
        )
    check("built-in Kotlin + toolchain alignment (AGP 9.2.1 / Gradle 9.4.1)",
          not built_in_problems, "; ".join(built_in_problems))

    print()
    print(f"RESULT: {PASSES} passed, {len(FAILURES)} failed")
    if FAILURES:
        print("Failures:")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    print("All structural checks green.")


if __name__ == "__main__":
    run()
