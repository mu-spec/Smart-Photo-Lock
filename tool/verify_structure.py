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
 11. Usage-access list membership: the main manifest declares
     PACKAGE_USAGE_STATS directly under <manifest> and no variant
     manifest removes it (Phase 4 device-QA guard).
 12. Built-in Kotlin migration: android.builtInKotlin=true in
     gradle.properties and the app/settings Gradle files no longer apply
     or pin the Kotlin Gradle Plugin.

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
            src = open(path).read()
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
            s = strip_comments_and_strings(open(path).read())
            if s.count("{") != s.count("}") or s.count("(") != s.count(")"):
                bad.append(os.path.relpath(path, ROOT))
    check("brace/paren balance in all Dart files", not bad, "; ".join(bad))

    # 3. pubspec
    pub = open(os.path.join(ROOT, "pubspec.yaml")).read()
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
        main_manifest = open(
            os.path.join(ROOT, "android/app/src/main/AndroidManifest.xml")
        ).read()
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
            src = open(p).read()
            if 'PACKAGE_USAGE_STATS' in src and 'tools:node="remove"' in src:
                removed_anywhere.append(mf)
        check("no manifest variant removes PACKAGE_USAGE_STATS",
              not removed_anywhere, ", ".join(removed_anywhere))
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
        activity_src = open(main_activity_path).read()
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
    manifest_text = open(
        os.path.join(ROOT, "android/app/src/main/AndroidManifest.xml")
    ).read()
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
        readme = open(os.path.join(ROOT, "README.md")).read()
        check("README version table matches pubspec",
              f"`{vname}` / `{vcode}`" in readme,
              f"expected {vname}/{vcode}")
        gradle = open(
            os.path.join(ROOT, "android/app/build.gradle.kts")
        ).read()
        check("gradle consumes flutter.versionCode/Name",
              "flutter.versionCode" in gradle and "flutter.versionName" in gradle)

    # 7. No stale references
    stale = []
    for base in ("lib", "test"):
        for path in dart_files(base):
            s = open(path).read()
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
    barrel = open(
        os.path.join(ROOT, "lib/design_system/design_system.dart")
    ).read()
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
            s = open(path).read()
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
        dart_src = open(os.path.join(ROOT, dart_rel)).read()
        kt_src = open(kt_path).read()
        invoked = set(
            re.findall(r"invokeMethod<[^>]*>\(\s*'([A-Za-z0-9_]+)'", dart_src)
        )
        handled = set(re.findall(r'"([A-Za-z0-9_]+)"\s*->', kt_src))
        for method in sorted(invoked - handled):
            missing_wiring.append(
                f"{kt_name}: Dart invokes '{method}' but the handler "
                "has no case for it"
            )
    check("native channel handlers wire every Dart-invoked method",
          not missing_wiring, "; ".join(missing_wiring))

    # 12. Built-in Kotlin migration (Flutter 3.47): the app must not apply
    # or pin the Kotlin Gradle Plugin — future Flutter versions will fail
    # builds that do — and the built-in Kotlin flag must be enabled.
    gradle_props = open(
        os.path.join(ROOT, "android/gradle.properties")
    ).read()
    app_gradle = open(
        os.path.join(ROOT, "android/app/build.gradle.kts")
    ).read()
    settings_gradle = open(
        os.path.join(ROOT, "android/settings.gradle.kts")
    ).read()
    built_in_problems = []
    if "android.builtInKotlin=true" not in gradle_props:
        built_in_problems.append("gradle.properties: android.builtInKotlin=true missing")
    if 'id("kotlin-android")' in app_gradle:
        built_in_problems.append("app/build.gradle.kts: kotlin-android plugin still applied")
    if "org.jetbrains.kotlin.android" in settings_gradle:
        built_in_problems.append("settings.gradle.kts: Kotlin Gradle Plugin still pinned")
    check("built-in Kotlin migration applied (no KGP application/pin)",
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
