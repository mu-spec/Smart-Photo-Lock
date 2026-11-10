// Phase 12 / Milestone 3 — Intruder Settings (PRD: "Allow configuration").
//
// Owner configuration of the failure threshold plus status of the M2
// opt-ins (photo / alarm switches stay on the Security screen, where the
// consent flow lives), camera-permission status (QUERY ONLY — this screen
// never requests a permission), evidence storage and retention info
// (count / size only, no decryption of images), the owner-only evidence
// viewer and clear-all. Every change requires a FRESH primary PIN/pattern
// verification plus a fresh credential status re-check; values shown are
// always the persisted ones re-read after a write. Nothing here touches
// the credential document, attempt counters, cooldown or lockout.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_container.dart';
import '../../../design_system/design_system.dart';
import '../../../security/credentials/auth_type.dart';
import '../../../security/intruder/intruder_defense_settings.dart';
import '../../../security/intruder/intruder_evidence_service.dart';
import '../../../security/intruder/intruder_evidence_store.dart';
import 'intruder_evidence_screen.dart';
import 'intruder_owner_verification.dart';

const String intruderSettingsRouteName = '/security/intruder';

abstract final class IntruderSettingsText {
  static const String title = 'Intruder settings';
  static const String thresholdTitle = 'Trigger after';
  static const String notChanged =
      'Not changed. Verify with your app PIN or pattern to change this.';
  static const String couldNotSave = 'Couldn\'t save. Nothing was changed.';
  static const String unavailable =
      'Intruder protection settings could not be read on this device.';
  static const String retention =
      'Up to 10 photos and 2.5 MB, each kept for 30 days; the oldest is '
      'removed first. Photos are encrypted and never leave this device.';
  static const String safety =
      'Changing these settings or deleting photos never resets attempt '
      'counters or lock-out timers. Lock-outs always end after at most 10 '
      'minutes.';
  static const String switchesHint =
      'Turn intruder photo and alarm on or off on the Security screen.';
}

String thresholdLabel(int n) =>
    n == 1 ? '1 wrong attempt' : '$n wrong attempts';

class IntruderSettingsScreen extends StatefulWidget {
  const IntruderSettingsScreen({super.key, required this.container});

  final AppContainer container;

  @override
  State<IntruderSettingsScreen> createState() => _IntruderSettingsScreenState();
}

class _IntruderSettingsScreenState extends State<IntruderSettingsScreen>
    with WidgetsBindingObserver {
  IntruderSettingsRead? _settings;
  CameraPermissionState? _permission;
  bool _permissionUnknown = false;
  EvidenceSummary? _summary;
  bool _busy = false;
  int _loadOp = 0;

  AppContainer get _c => widget.container;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The owner may have revoked the camera permission in system settings.
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load() async {
    final int op = ++_loadOp;
    final IntruderSettingsRead settings =
        await _c.intruderDefenseSettings.read();
    CameraPermissionState? permission;
    bool unknown = false;
    try {
      permission = await _c.intruderEvidenceService.cameraPermission();
    } catch (_) {
      unknown = true;
    }
    final EvidenceSummary summary = await _c.intruderEvidence.summary();
    if (!mounted || op != _loadOp) return;
    setState(() {
      _settings = settings;
      _permission = permission;
      _permissionUnknown = unknown;
      _summary = summary;
    });
  }

  void _say(String msg) {
    final ScaffoldMessengerState? m = ScaffoldMessenger.maybeOf(context);
    m?.hideCurrentSnackBar();
    m?.showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _setThreshold(int? value) async {
    final IntruderSettingsRead? current = _settings;
    if (value == null ||
        _busy ||
        current == null ||
        !current.writable ||
        value == current.settings.threshold) {
      return;
    }
    setState(() => _busy = true);
    try {
      final AuthType? method =
          await verifyIntruderOwner(Navigator.of(context), _c.auth);
      if (!mounted) return;
      if (method == null) {
        _say(IntruderSettingsText.notChanged);
        return;
      }
      final IntruderDefenseSettings? saved = await _c.intruderDefenseSettings
          .update((IntruderDefenseSettings s) => s.copyWith(threshold: value));
      if (!mounted) return;
      if (saved == null) _say(IntruderSettingsText.couldNotSave);
      // A threshold-only change never aborts a pending capture or alarm;
      // the coordinator reads the new value for the next event.
    } finally {
      if (mounted) setState(() => _busy = false);
      if (mounted) await _load(); // always show the persisted value
    }
  }

  Future<void> _viewEvidence() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bool opened = await openIntruderEvidence(context, _c);
      if (!mounted) return;
      if (!opened) _say(IntruderEvidenceText.notVerified);
    } finally {
      if (mounted) setState(() => _busy = false);
      if (mounted) await _load();
    }
  }

  Future<void> _clearAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final EvidenceClearResult? r =
          await clearAllIntruderEvidence(context, _c);
      if (!mounted) return;
      _say(switch (r) {
        null => IntruderEvidenceText.notDeleted,
        EvidenceClearResult.cleared => IntruderEvidenceText.clearedAll,
        EvidenceClearResult.unsupportedSchema =>
          IntruderEvidenceText.unsupported,
        EvidenceClearResult.cancelled ||
        EvidenceClearResult.storageFailed =>
          IntruderEvidenceText.deleteFailed,
      });
    } finally {
      if (mounted) setState(() => _busy = false);
      if (mounted) await _load();
    }
  }

  String _permissionText() {
    if (_permissionUnknown) return 'Unknown';
    return switch (_permission) {
      CameraPermissionState.granted => 'Allowed',
      CameraPermissionState.denied => 'Not allowed',
      CameraPermissionState.unavailable => 'No front camera',
      null => '…',
    };
  }

  String _storageText(EvidenceSummary s) => switch (s.health) {
        EvidenceIndexHealth.unsupported => IntruderEvidenceText.unsupported,
        EvidenceIndexHealth.unreadable => IntruderEvidenceText.unreadable,
        EvidenceIndexHealth.ok => s.count == 0
            ? 'No photos stored'
            : '${s.count} ${s.count == 1 ? 'photo' : 'photos'} · '
                '${(s.totalBytes / 1024).toStringAsFixed(0)} KB',
      };

  @override
  Widget build(BuildContext context) {
    final IntruderSettingsRead? read = _settings;
    final EvidenceSummary? summary = _summary;
    final bool writable = read?.writable ?? false;
    final IntruderDefenseSettings s =
        read?.settings ?? IntruderDefenseSettings.disabled;
    final bool canManage =
        !_busy && summary != null && summary.health == EvidenceIndexHealth.ok;
    return Scaffold(
      appBar: AppBar(title: const Text(IntruderSettingsText.title)),
      body: read == null || summary == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(DsSpacing.lg),
              children: <Widget>[
                if (!writable) ...<Widget>[
                  const Text(IntruderSettingsText.unavailable),
                  const SizedBox(height: DsSpacing.md),
                ],
                DsCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _InfoRow(
                        key: const Key('intruder_status_photo'),
                        label: 'Intruder photo',
                        value: s.evidenceEnabled ? 'On' : 'Off',
                      ),
                      _InfoRow(
                        key: const Key('intruder_status_alarm'),
                        label: 'Intruder alarm',
                        value: s.alarmEnabled ? 'On' : 'Off',
                      ),
                      _InfoRow(
                        key: const Key('intruder_status_permission'),
                        label: 'Camera permission',
                        value: _permissionText(),
                      ),
                      const SizedBox(height: DsSpacing.sm),
                      const Text(IntruderSettingsText.switchesHint),
                    ],
                  ),
                ),
                const SizedBox(height: DsSpacing.lg),
                DsCard(
                  child: Row(
                    children: <Widget>[
                      const Expanded(
                        child: Text(IntruderSettingsText.thresholdTitle),
                      ),
                      DropdownButton<int>(
                        key: const Key('intruder_threshold_dropdown'),
                        value: s.threshold,
                        onChanged: writable && !_busy ? _setThreshold : null,
                        items: <DropdownMenuItem<int>>[
                          for (int n = IntruderDefenseSettings.minThreshold;
                              n <= IntruderDefenseSettings.maxThreshold;
                              n++)
                            DropdownMenuItem<int>(
                              key: ValueKey<String>('intruder_threshold_$n'),
                              value: n,
                              child: Text(thresholdLabel(n)),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: DsSpacing.lg),
                DsCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _storageText(summary),
                        key: const Key('intruder_storage_summary'),
                      ),
                      const SizedBox(height: DsSpacing.sm),
                      const Text(IntruderSettingsText.retention),
                      const SizedBox(height: DsSpacing.md),
                      DsButton(
                        key: const Key('intruder_view_evidence'),
                        label: 'View intruder photos',
                        icon: Icons.photo_library_outlined,
                        variant: DsButtonVariant.secondary,
                        expand: true,
                        onPressed: canManage ? _viewEvidence : null,
                      ),
                      const SizedBox(height: DsSpacing.sm),
                      DsButton(
                        key: const Key('intruder_clear_all'),
                        label: 'Delete all intruder photos',
                        icon: Icons.delete_sweep_outlined,
                        variant: DsButtonVariant.danger,
                        expand: true,
                        onPressed:
                            canManage && summary.count > 0 ? _clearAll : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: DsSpacing.lg),
                const Text(IntruderSettingsText.safety),
              ],
            ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: DsSpacing.xs),
        child: Row(
          children: <Widget>[
            Expanded(child: Text(label)),
            Text(value),
          ],
        ),
      );
}
