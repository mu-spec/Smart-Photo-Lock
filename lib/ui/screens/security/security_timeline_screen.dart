// Phase 13 / Milestone 1 — owner-only Security timeline.
//
// Opened only through [openSecurityTimeline]: fresh primary PIN/pattern
// verification -> a short-lived, in-memory session from the timeline's OWN
// session gate (never shared with the evidence viewer). Before any history
// is read, FLAG_SECURE is enabled; if that fails the timeline fails closed
// and reads nothing. The credential is re-checked before every load.
//
// The session ends on app backgrounding (any lifecycle state other than
// resumed), screen-off, absolute expiry, a credential change, or ANY route
// covering the timeline (it has no child routes of its own in M1). When it
// ends, the loaded history is dropped from state, nothing is rendered, and
// the timeline closes itself (immediately if it is on top, otherwise when
// it surfaces again — a foreign route is never popped).
//
// Metadata only. No share, export, clipboard, selection, file or log
// output. FLAG_SECURE is intentionally NOT cleared on exit (same as the
// Phase 12 evidence viewer; the lock host clears it at its own loop end).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_container.dart';
import '../../../design_system/design_system.dart';
import '../../../security/credentials/auth_type.dart';
import '../../../security/credentials/verified_attempt.dart';
import '../../../security/intruder/failed_attempt_event.dart';
import '../../../security/intruder/intruder_owner_session.dart';
import '../../../security/timeline/security_timeline.dart';
import '../../../services/screen_state_service.dart';
import '../../../utilities/result.dart';
import 'intruder_owner_verification.dart';

const String securityTimelineRouteName = '/security/timeline';

abstract final class SecurityTimelineText {
  static const String title = 'Security timeline';
  static const String rowTitle = 'Security timeline';
  static const String rowSubtitle =
      'Failed unlocks and security events (PIN or pattern required)';
  static const String loading = 'Loading…';
  static const String empty = 'No security events are recorded.';
  static const String secureFailed =
      'The timeline can\'t be shown because screen-capture protection could '
      'not be enabled.';
  static const String sessionEnded = 'Security timeline closed for privacy.';
  static const String showOlder = 'Show older';
  static const String footer =
      'This timeline shows security events kept on this device (up to 30 '
      'days, within storage limits). It is not a complete forensic record.';

  static String sourceName(TimelineSource s) => switch (s) {
        TimelineSource.failedAttempts => 'Failed-unlock history',
        TimelineSource.journal => 'Security journal',
      };

  static String unavailable(TimelineSource s, TimelineSourceState st) =>
      st == TimelineSourceState.unavailableNewerVersion
          ? '${sourceName(s)} was saved by a newer version of the app and '
              'can\'t be shown here.'
          : '${sourceName(s)} couldn\'t be read. This does not mean there '
              'are no events.';

  static String discarded(TimelineSource s, int n) =>
      '${sourceName(s)}: $n older ${n == 1 ? 'event is' : 'events are'} no '
      'longer kept.';

  static String lost(TimelineSource s, int n) =>
      '${sourceName(s)}: $n ${n == 1 ? 'event' : 'events'} couldn\'t be '
      'recorded.';

  static String damaged(TimelineSource s) =>
      '${sourceName(s)}: earlier history was damaged and couldn\'t be kept.';

  static String integrityUnknown(TimelineSource s) =>
      '${sourceName(s)}: couldn\'t confirm that earlier history is intact.';
}

Future<bool> openSecurityTimeline(
  BuildContext context,
  AppContainer container,
) async {
  final NavigatorState navigator = Navigator.of(context);
  final AuthType? method = await verifyIntruderOwner(navigator, container.auth);
  if (method == null) return false;
  final IntruderOwnerSession session =
      container.securityTimelineSessions.begin(method);
  try {
    await navigator.push<void>(MaterialPageRoute<void>(
      settings: const RouteSettings(name: securityTimelineRouteName),
      builder: (_) =>
          SecurityTimelineScreen(container: container, session: session),
    ));
  } finally {
    session.invalidate('closed');
  }
  return true;
}

String _fmtTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}';
}

class SecurityTimelineScreen extends StatefulWidget {
  const SecurityTimelineScreen({
    super.key,
    required this.container,
    required this.session,
  });

  final AppContainer container;
  final IntruderOwnerSession session;

  @override
  State<SecurityTimelineScreen> createState() => _SecurityTimelineScreenState();
}

class _SecurityTimelineScreenState extends State<SecurityTimelineScreen>
    with WidgetsBindingObserver {
  SecurityTimelineSnapshot? _snapshot;
  int _visible = SecurityTimelineReader.pageSize;
  bool _secureFailed = false;
  bool _closing = false;
  bool _covered = false;
  bool _paging = false;
  int _loadOp = 0;
  Timer? _expiry;
  StreamSubscription<Result<ScreenStateEvent>>? _screen;

  IntruderOwnerSession get session => widget.session;

  void _onInvalidated(String reason) {
    // Drop history from memory now; navigation happens in a microtask
    // (listeners may fire during build).
    _snapshot = null;
    _loadOp++;
    scheduleMicrotask(() {
      if (mounted) _onSessionEnded();
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_onInvalidated);
    if (!session.isValid) _onInvalidated('expired');
    _expiry = Timer(session.remaining, () => session.invalidate('expired'));
    _screen = widget.container.screenState.events.listen(
      (Result<ScreenStateEvent> r) {
        if (r.isFailure || r.valueOrNull == ScreenStateEvent.screenOff) {
          session.invalidate('screenOff');
        }
      },
      onError: (Object _) => session.invalidate('screenStateError'),
    );
    unawaited(_load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      session.invalidate('lifecycle:${state.name}');
    }
  }

  void _onSessionEnded() {
    if (_closing) return;
    setState(() => _snapshot = null);
    final ModalRoute<Object?>? me = ModalRoute.of(context);
    if (me == null || !me.isActive) {
      _closing = true; // already leaving
      return;
    }
    if (!me.isCurrent) return; // covered: close when it surfaces again
    _closing = true;
    final NavigatorState navigator = Navigator.of(context);
    final ScaffoldMessengerState? messenger =
        ScaffoldMessenger.maybeOf(context);
    navigator.pop();
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      const SnackBar(content: Text(SecurityTimelineText.sessionEnded)),
    );
  }

  Future<void> _load() async {
    final int op = ++_loadOp;
    final AppContainer c = widget.container;
    if (!session.isValid) return;
    final Result<void> secure = await c.overlay.setSecureWindow(true);
    if (!mounted || !session.isValid || op != _loadOp) return;
    if (secure.isFailure) {
      setState(() => _secureFailed = true); // fail closed: nothing is read
      return;
    }
    if (!await intruderOwnerStillCurrent(c.auth, session.method)) {
      session.invalidate('credentialChanged');
      return;
    }
    if (!mounted || !session.isValid || op != _loadOp) return;
    final SecurityTimelineSnapshot snap = await c.securityTimeline.load();
    if (!mounted || !session.isValid || op != _loadOp) return;
    setState(() => _snapshot = snap);
  }

  Future<void> _showOlder() async {
    if (_paging || !session.isValid) return;
    _paging = true;
    try {
      final AppContainer c = widget.container;
      if (!await intruderOwnerStillCurrent(c.auth, session.method)) {
        session.invalidate('credentialChanged');
        return;
      }
      if (!mounted || !session.isValid) return;
      setState(() => _visible += SecurityTimelineReader.pageSize);
    } finally {
      _paging = false;
    }
  }

  @override
  void dispose() {
    _expiry?.cancel();
    unawaited(_screen?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_onInvalidated);
    session.invalidate('closed');
    _snapshot = null;
    super.dispose();
  }

  /// Cover tracking (called from build; acts in a microtask). The timeline
  /// pushes no routes of its own, so any route above it is foreign.
  void _trackCover(ModalRoute<Object?>? me) {
    final bool top = me?.isCurrent ?? false;
    if (!top && !_covered) {
      _covered = true;
      scheduleMicrotask(() {
        if (!mounted) return;
        final ModalRoute<Object?>? r = ModalRoute.of(context);
        if (r != null && r.isActive && !r.isCurrent) {
          session.invalidate('covered');
        }
      });
    } else if (top && _covered) {
      _covered = false;
      scheduleMicrotask(() {
        if (mounted && !session.isValid) _onSessionEnded();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ModalRoute<Object?>? me = ModalRoute.of(context);
    _trackCover(me);
    final bool show = session.isValid && !_covered && (me?.isCurrent ?? false);
    final SecurityTimelineSnapshot? snap = show ? _snapshot : null;
    final Widget body;
    if (!show) {
      body = const SizedBox.shrink();
    } else if (_secureFailed) {
      body = const _Message(
        SecurityTimelineText.secureFailed,
        key: Key('security_timeline_secure_failed'),
      );
    } else if (snap == null) {
      body = const _Message(SecurityTimelineText.loading);
    } else {
      body = _TimelineList(
        snapshot: snap,
        visible: _visible,
        onShowOlder: _showOlder,
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text(SecurityTimelineText.title)),
      body: body,
    );
  }
}

class _TimelineList extends StatelessWidget {
  const _TimelineList({
    required this.snapshot,
    required this.visible,
    required this.onShowOlder,
  });

  final SecurityTimelineSnapshot snapshot;
  final int visible;
  final VoidCallback onShowOlder;

  @override
  Widget build(BuildContext context) {
    final List<Widget> rows = <Widget>[];
    for (final TimelineSourceStatus s in snapshot.sources) {
      if (!s.available) {
        rows.add(_Notice(
          key: Key('security_timeline_unavailable_${s.source.name}'),
          icon: Icons.error_outline,
          text: SecurityTimelineText.unavailable(s.source, s.state),
        ));
      }
      if (s.damagedEarlier == true) {
        rows.add(_Notice(
          key: Key('security_timeline_damaged_${s.source.name}'),
          icon: Icons.report_outlined,
          text: SecurityTimelineText.damaged(s.source),
        ));
      } else if (s.damagedEarlier == null) {
        rows.add(_Notice(
          key: Key('security_timeline_integrity_unknown_${s.source.name}'),
          icon: Icons.help_outline,
          text: SecurityTimelineText.integrityUnknown(s.source),
        ));
      }
      if (s.discarded > 0) {
        rows.add(_Notice(
          key: Key('security_timeline_discarded_${s.source.name}'),
          icon: Icons.history_toggle_off,
          text: SecurityTimelineText.discarded(s.source, s.discarded),
        ));
      }
      if (s.lost > 0) {
        rows.add(_Notice(
          key: Key('security_timeline_lost_${s.source.name}'),
          icon: Icons.warning_amber_outlined,
          text: SecurityTimelineText.lost(s.source, s.lost),
        ));
      }
    }
    final List<TimelineEntry> entries = snapshot.entries;
    if (snapshot.confirmedEmpty) {
      rows.add(const Padding(
        key: Key('security_timeline_empty'),
        padding: EdgeInsets.all(DsSpacing.xl),
        child: Text(SecurityTimelineText.empty, textAlign: TextAlign.center),
      ));
    }
    final int shown = visible < entries.length ? visible : entries.length;
    for (int i = 0; i < shown; i++) {
      rows.add(_EntryTile(entries[i]));
      rows.add(const Divider(height: 1));
    }
    if (shown < entries.length) {
      rows.add(Center(
        child: TextButton(
          key: const Key('security_timeline_show_older'),
          onPressed: onShowOlder,
          child: const Text(SecurityTimelineText.showOlder),
        ),
      ));
    }
    rows.add(const Padding(
      key: Key('security_timeline_footer'),
      padding: EdgeInsets.all(DsSpacing.lg),
      child: Text(SecurityTimelineText.footer),
    ));
    return ListView(
      key: const Key('security_timeline_list'),
      children: rows,
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile(this.e);

  final TimelineEntry e;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String title, String subtitle) = switch (e.kind) {
      TimelineEntryKind.failedUnlock => (
          Icons.lock_outline,
          e.method == FailedAttemptMethod.pattern
              ? 'Failed pattern attempt'
              : 'Failed PIN attempt',
          '${e.surface == AuthAttemptSurface.protectedAppChallenge ? (e.packageName ?? 'Protected app') : 'Smart App Lock'}'
              '${e.lockoutTriggered ? ' · lock-out started' : ''}',
        ),
      TimelineEntryKind.journalStarted => (
          Icons.play_circle_outline,
          'Security journal first used',
          'No journal events were recorded before this time.',
        ),
      TimelineEntryKind.journalRecovered => (
          Icons.report_outlined,
          'Security journal was damaged and reset',
          'Earlier journal events may be missing.',
        ),
    };
    return ListTile(
      key: Key('security_timeline_entry_${e.source.name}_${e.sourceSeq}'),
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text('${_fmtTime(e.at)} · $subtitle'),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon),
        title: Text(text),
      );
}

class _Message extends StatelessWidget {
  const _Message(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(DsSpacing.xl),
          child: Text(text, textAlign: TextAlign.center),
        ),
      );
}
