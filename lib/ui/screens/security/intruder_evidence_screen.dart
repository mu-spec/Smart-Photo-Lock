// Phase 12 / Milestone 3 — owner-only intruder evidence viewer.
//
// Opened only through [openIntruderEvidence]: fresh primary PIN/pattern
// verification + fresh credential status re-check -> a short-lived,
// in-memory [IntruderOwnerSession]. The list shows metadata only (no
// thumbnails); the detail decrypts ONE image inside the valid session with
// a bounded decode and FLAG_SECURE set first (fail closed: no FLAG_SECURE,
// no image). The session ends — and every evidence route closes — on app
// backgrounding, screen-off, expiry (absolute, never extended), navigation
// away or a credential change. Delete and clear-all always require their
// own fresh verification. No share, export, clipboard, file or log output.
// FLAG_SECURE is intentionally NOT cleared on exit (fail-safe privacy; the
// lock host clears it at the end of its own loop).
//
// Commit-readiness gate (Q-M3-2): a route that the evidence flow did not
// push (e.g. a lock challenge presented while the app stays resumed) ends
// the session the moment it covers the list or the detail — the host may
// clear FLAG_SECURE when that challenge ends, so pixels must never come
// back. Session cleanup never pops such a foreign route; the evidence
// routes close themselves when they surface again. Every time the detail
// surfaces from one of its own routes it re-runs the secure load
// (FLAG_SECURE, credential re-check, decrypt) before rendering pixels.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../app/app_container.dart';
import '../../../design_system/design_system.dart';
import '../../../security/credentials/auth_type.dart';
import '../../../security/intruder/intruder_evidence_store.dart';
import '../../../security/intruder/intruder_owner_session.dart';
import '../../../services/screen_state_service.dart';
import '../../../utilities/result.dart';
import 'app_credential_verification.dart';
import 'intruder_owner_verification.dart';

const String intruderEvidenceRouteName = '/security/intruder/evidence';
const String intruderEvidenceDetailRouteName =
    '/security/intruder/evidence/detail';
const String intruderEvidenceConfirmRouteName =
    '/security/intruder/evidence/confirm';

/// Routes pushed by the evidence flow itself (list, detail, confirm dialog,
/// owner verification). Anything else above an evidence route is foreign.
bool isIntruderEvidenceFlowRoute(Route<Object?> r) {
  final String? n = r.settings.name;
  return n == intruderEvidenceRouteName ||
      n == intruderEvidenceDetailRouteName ||
      n == intruderEvidenceConfirmRouteName ||
      n == appCredentialVerifyRouteName;
}

/// The top-most route of [navigator] (side-effect free: the predicate
/// accepts the first route, so nothing is popped).
Route<Object?>? _topRoute(NavigatorState navigator) {
  Route<Object?>? top;
  navigator.popUntil((Route<Object?> r) {
    top = r;
    return true;
  });
  return top;
}

abstract final class IntruderEvidenceText {
  static const String title = 'Intruder photos';
  static const String empty = 'No intruder photos are stored.';
  static const String notVerified =
      'Not opened. Verify with your app PIN or pattern to view intruder '
      'photos.';
  static const String unsupported =
      'Intruder photos were stored by a newer version of the app and can\'t '
      'be shown or changed here.';
  static const String unreadable = 'Intruder photos could not be read.';
  static const String unavailable =
      'This photo is unavailable (missing or damaged). You can still '
      'delete it.';
  static const String secureFailed =
      'This photo can\'t be shown because screen-capture protection could '
      'not be enabled.';
  static const String deleteTitle = 'Delete this photo?';
  static const String deleteAllTitle = 'Delete all intruder photos?';
  static const String deleteBody =
      'Deleted photos can\'t be recovered. Your lock history, attempt '
      'counters and lock-out timers are not changed.';
  static const String notDeleted =
      'Not deleted. Verify with your app PIN or pattern to delete.';
  static const String deleteFailed = 'Couldn\'t delete. Nothing was changed.';
  static const String deleted = 'Photo deleted.';
  static const String clearedAll = 'All intruder photos deleted.';
  static const String sessionEnded = 'Intruder photos closed for privacy.';
}

/// Fresh verification -> session -> viewer. Returns false when the owner
/// could not be verified (nothing was shown). The session is invalidated
/// when the viewer closes, whatever the reason.
Future<bool> openIntruderEvidence(
  BuildContext context,
  AppContainer container,
) async {
  final NavigatorState navigator = Navigator.of(context);
  final AuthType? method = await verifyIntruderOwner(navigator, container.auth);
  if (method == null) return false;
  final IntruderOwnerSession session =
      container.intruderOwnerSessions.begin(method);
  try {
    await navigator.push<void>(MaterialPageRoute<void>(
      settings: const RouteSettings(name: intruderEvidenceRouteName),
      builder: (_) =>
          IntruderEvidenceScreen(container: container, session: session),
    ));
  } finally {
    session.invalidate('closed');
  }
  return true;
}

/// Owner clear-all (shared by the settings screen and the viewer).
///
/// Confirm -> fresh verification (-> the viewer's session must still be
/// valid and for the same credential) -> coordinator epoch bump + capture
/// abort (synchronous) -> store clear with the coordinator's highest handled
/// seq as the resurrection floor. Returns null when not confirmed/verified.
Future<EvidenceClearResult?> clearAllIntruderEvidence(
  BuildContext context,
  AppContainer container, {
  IntruderOwnerSession? session,
}) async {
  final NavigatorState navigator = Navigator.of(context);
  final bool confirmed = await _confirm(
    context,
    IntruderEvidenceText.deleteAllTitle,
    confirmKey: 'intruder_clear_all_confirm',
  );
  if (!confirmed) return null;
  if (session != null && !session.isValid) return null;
  final AuthType? method = await verifyIntruderOwner(navigator, container.auth);
  if (method == null) return null;
  if (session != null && (!session.isValid || session.method != method)) {
    session.invalidate('credentialChanged');
    return null;
  }
  container.intruderDefense.onEvidenceCleared();
  return container.intruderEvidence.clearAll(
    floorSeq: container.intruderDefense.highestHandledSeq,
    stillValid: () => session == null || session.isValid,
  );
}

Future<bool> _confirm(
  BuildContext context,
  String title, {
  required String confirmKey,
}) async {
  final bool? ok = await showDialog<bool>(
    context: context,
    routeSettings: const RouteSettings(name: intruderEvidenceConfirmRouteName),
    builder: (BuildContext ctx) => AlertDialog(
      title: Text(title),
      content: const Text(IntruderEvidenceText.deleteBody),
      actions: <Widget>[
        TextButton(
          key: const Key('intruder_delete_cancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: Key(confirmKey),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Replaces any visible message (latest outcome wins; no stale queue).
void _snack(BuildContext context, SnackBar bar) {
  final ScaffoldMessengerState? m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(bar);
}

String _fmtTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}';
}

String _fmtSize(int bytes) => bytes < 1024
    ? '$bytes B'
    : '${(bytes / 1024).toStringAsFixed(bytes < 10240 ? 1 : 0)} KB';

class IntruderEvidenceScreen extends StatefulWidget {
  const IntruderEvidenceScreen({
    super.key,
    required this.container,
    required this.session,
  });

  final AppContainer container;
  final IntruderOwnerSession session;

  @override
  State<IntruderEvidenceScreen> createState() => _IntruderEvidenceScreenState();
}

class _IntruderEvidenceScreenState extends State<IntruderEvidenceScreen>
    with WidgetsBindingObserver {
  List<EvidenceItem>? _items;
  EvidenceIndexHealth _health = EvidenceIndexHealth.ok;
  bool _busy = false;
  bool _closing = false;
  Timer? _expiry;
  StreamSubscription<Result<ScreenStateEvent>>? _screen;
  int _loadOp = 0;
  bool _covered = false;

  IntruderOwnerSession get session => widget.session;

  void _onInvalidated(String reason) {
    // May be called synchronously from inside build (lazy expiry): never
    // touch the navigator or setState here; build already renders nothing.
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
    // One-shot UI privacy timer (widget-scoped, cancelled on dispose): the
    // viewer closes when the absolute session lifetime ends even if idle.
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
    final NavigatorState navigator = Navigator.of(context);
    final ModalRoute<Object?>? me = ModalRoute.of(context);
    if (me != null && me.isActive) {
      // Pops the detail, any confirm dialog and any verification route
      // above this list (an interrupted verification resolves as denied),
      // then the list itself — but NEVER a foreign route (a lock challenge):
      // cleanup then resumes when this list surfaces again.
      Route<Object?>? stoppedAt;
      navigator.popUntil((Route<Object?> r) {
        stoppedAt = r;
        return r == me || !isIntruderEvidenceFlowRoute(r);
      });
      if (stoppedAt != me) return;
      _closing = true;
      if (navigator.canPop()) navigator.pop();
    } else {
      _closing = true;
    }
    _snack(
      context,
      const SnackBar(content: Text(IntruderEvidenceText.sessionEnded)),
    );
  }

  Future<void> _load() async {
    final int op = ++_loadOp;
    final AppContainer c = widget.container;
    if (!session.isValid) return;
    // FLAG_SECURE before any evidence metadata renders. A failure is
    // re-checked by the detail (which then refuses the image).
    await c.overlay.setSecureWindow(true);
    if (!mounted || !session.isValid || op != _loadOp) return;
    if (!await intruderOwnerStillCurrent(c.auth, session.method)) {
      session.invalidate('credentialChanged');
      return;
    }
    if (!mounted || !session.isValid || op != _loadOp) return;
    await c.intruderEvidence.enforceRetention();
    if (!mounted || !session.isValid || op != _loadOp) return;
    final (List<EvidenceItem> items, EvidenceIndexHealth health) =
        await c.intruderEvidence.snapshot();
    if (!mounted || !session.isValid || op != _loadOp) return;
    setState(() {
      _items = items.reversed.toList(); // newest first
      _health = health;
    });
  }

  Future<void> _openDetail(EvidenceItem item) async {
    if (_busy || !session.isValid) return;
    final bool? changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        settings: const RouteSettings(name: intruderEvidenceDetailRouteName),
        builder: (_) => IntruderEvidenceDetailScreen(
          container: widget.container,
          session: session,
          item: item,
        ),
      ),
    );
    if (!mounted || !session.isValid) return;
    if (changed ?? false) {
      _snack(
        context,
        const SnackBar(content: Text(IntruderEvidenceText.deleted)),
      );
    }
    await _load();
  }

  Future<void> _clearAll() async {
    if (_busy || !session.isValid) return;
    setState(() => _busy = true);
    try {
      final EvidenceClearResult? r = await clearAllIntruderEvidence(
        context,
        widget.container,
        session: session,
      );
      if (!mounted || !session.isValid) return;
      final String msg = switch (r) {
        null => IntruderEvidenceText.notDeleted,
        EvidenceClearResult.cleared => IntruderEvidenceText.clearedAll,
        EvidenceClearResult.unsupportedSchema =>
          IntruderEvidenceText.unsupported,
        EvidenceClearResult.cancelled ||
        EvidenceClearResult.storageFailed =>
          IntruderEvidenceText.deleteFailed,
      };
      _snack(context, SnackBar(content: Text(msg)));
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _expiry?.cancel();
    unawaited(_screen?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_onInvalidated);
    session.invalidate('closed');
    super.dispose();
  }

  /// Cover/surface tracking (called from build; acts in a microtask).
  void _trackCover(bool top) {
    if (!top && !_covered) {
      _covered = true;
      scheduleMicrotask(() {
        if (!mounted) return;
        final Route<Object?>? t = _topRoute(Navigator.of(context));
        if (t != null && !isIntruderEvidenceFlowRoute(t)) {
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
    _trackCover(ModalRoute.of(context)?.isCurrent ?? false);
    final bool valid = session.isValid;
    final List<EvidenceItem>? items = valid ? _items : null;
    return Scaffold(
      appBar: AppBar(
        title: const Text(IntruderEvidenceText.title),
        actions: <Widget>[
          if (items != null &&
              items.isNotEmpty &&
              _health == EvidenceIndexHealth.ok)
            IconButton(
              key: const Key('intruder_evidence_clear_all'),
              tooltip: 'Delete all',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _busy ? null : _clearAll,
            ),
        ],
      ),
      body: !valid
          ? const SizedBox.shrink()
          : items == null
              ? const Center(child: CircularProgressIndicator())
              : _health == EvidenceIndexHealth.unsupported
                  ? const _Message(IntruderEvidenceText.unsupported)
                  : _health == EvidenceIndexHealth.unreadable
                      ? const _Message(IntruderEvidenceText.unreadable)
                      : items.isEmpty
                          ? const _Message(IntruderEvidenceText.empty)
                          : ListView.separated(
                              padding: const EdgeInsets.all(DsSpacing.lg),
                              itemCount: items.length,
                              separatorBuilder: (_, __) => const Divider(),
                              itemBuilder: (BuildContext _, int i) {
                                final EvidenceItem e = items[i];
                                return ListTile(
                                  key: ValueKey<String>(
                                      'intruder_evidence_item_${e.seq}'),
                                  leading:
                                      const Icon(Icons.photo_camera_outlined),
                                  title: Text(_fmtTime(e.at)),
                                  subtitle: Text(
                                      '${e.packageName ?? 'Unknown app'} · '
                                      '${_fmtSize(e.bytes)}'),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: _busy ? null : () => _openDetail(e),
                                );
                              },
                            ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(DsSpacing.xl),
          child: Text(text, textAlign: TextAlign.center),
        ),
      );
}

enum _DetailState { loading, shown, unavailable, secureFailed }

class IntruderEvidenceDetailScreen extends StatefulWidget {
  const IntruderEvidenceDetailScreen({
    super.key,
    required this.container,
    required this.session,
    required this.item,
  });

  /// Upper bound on the decoded width (memory bound for the viewer).
  static const int maxDecodeWidth = 1080;

  final AppContainer container;
  final IntruderOwnerSession session;
  final EvidenceItem item;

  @override
  State<IntruderEvidenceDetailScreen> createState() =>
      _IntruderEvidenceDetailScreenState();
}

class _IntruderEvidenceDetailScreenState
    extends State<IntruderEvidenceDetailScreen> {
  _DetailState _state = _DetailState.loading;
  Uint8List? _bytes;
  ImageProvider<Object>? _provider;
  int _op = 0;
  bool _busy = false;
  bool _covered = false;

  IntruderOwnerSession get session => widget.session;

  /// Cover/surface tracking (called from build; acts in a microtask).
  /// Covered by a foreign route: the session ends. Covered by an own route
  /// (confirm / verification): the image is dropped and, on surfacing, the
  /// whole secure load runs again before any pixel renders.
  void _trackCover(bool top) {
    if (!top && !_covered) {
      _covered = true;
      scheduleMicrotask(() {
        if (!mounted) return;
        final Route<Object?>? t = _topRoute(Navigator.of(context));
        if (t != null && !isIntruderEvidenceFlowRoute(t)) {
          session.invalidate('covered');
        } else {
          setState(_dropImage);
        }
      });
    } else if (top && _covered) {
      _covered = false;
      scheduleMicrotask(() {
        if (!mounted) return;
        final ModalRoute<Object?>? me = ModalRoute.of(context);
        if (!session.isValid) {
          // Deferred cleanup (a foreign route was on top): close this route.
          if (me != null && me.isCurrent) Navigator.of(context).pop();
          return;
        }
        unawaited(_load());
      });
    }
  }

  @override
  void initState() {
    super.initState();
    session.addListener(_onInvalidated);
    unawaited(_load());
  }

  void _onInvalidated(String _) {
    // Possibly inside build: defer; build already renders nothing.
    scheduleMicrotask(() {
      if (!mounted) return;
      setState(_dropImage);
    });
  }

  Future<void> _load() async {
    final int op = ++_op;
    final AppContainer c = widget.container;
    if (!session.isValid) return;
    final Result<void> secure = await c.overlay.setSecureWindow(true);
    if (!mounted || !session.isValid || op != _op) return;
    if (secure.isFailure) {
      setState(() => _state = _DetailState.secureFailed);
      return;
    }
    if (!await intruderOwnerStillCurrent(c.auth, session.method)) {
      session.invalidate('credentialChanged');
      return;
    }
    if (!mounted || !session.isValid || op != _op) return;
    final Uint8List? bytes =
        await c.intruderEvidence.readImage(widget.item.seq);
    if (!mounted || !session.isValid || op != _op) {
      _zero(bytes);
      return;
    }
    if (bytes == null) {
      setState(() => _state = _DetailState.unavailable);
      return;
    }
    setState(() {
      _bytes = bytes;
      _provider = ResizeImage(
        MemoryImage(bytes),
        width: IntruderEvidenceDetailScreen.maxDecodeWidth,
      );
      _state = _DetailState.shown;
    });
  }

  static void _zero(Uint8List? b) {
    if (b != null) b.fillRange(0, b.length, 0);
  }

  /// Evicts the decoded image from the cache (live included) and zero-fills
  /// the buffer. Best effort: no claim of secure memory erasure.
  void _dropImage() {
    _op++;
    final ImageProvider<Object>? p = _provider;
    _provider = null;
    if (p != null) unawaited(p.evict());
    _zero(_bytes);
    _bytes = null;
    if (_state == _DetailState.shown) _state = _DetailState.loading;
  }

  Future<void> _delete() async {
    if (_busy || !session.isValid) return;
    setState(() => _busy = true);
    final NavigatorState navigator = Navigator.of(context);
    try {
      final bool confirmed = await _confirm(
        context,
        IntruderEvidenceText.deleteTitle,
        confirmKey: 'intruder_delete_confirm',
      );
      if (!confirmed || !mounted || !session.isValid) return;
      final AppContainer c = widget.container;
      final AuthType? method = await verifyIntruderOwner(navigator, c.auth);
      if (!mounted) return;
      if (method == null) {
        _snack(
          context,
          const SnackBar(content: Text(IntruderEvidenceText.notDeleted)),
        );
        return;
      }
      if (!session.isValid || method != session.method) {
        session.invalidate('credentialChanged');
        return;
      }
      final EvidenceDeleteResult r = await c.intruderEvidence.delete(
        widget.item.seq,
        // Commit point: evaluated inside the store's serialized section,
        // immediately before the index rewrite.
        stillValid: () => mounted && session.isValid,
      );
      if (!mounted) return;
      switch (r) {
        case EvidenceDeleteResult.deleted:
        case EvidenceDeleteResult.notFound:
          setState(_dropImage);
          navigator.pop(true);
        case EvidenceDeleteResult.unsupportedSchema:
          _snack(
            context,
            const SnackBar(content: Text(IntruderEvidenceText.unsupported)),
          );
        case EvidenceDeleteResult.cancelled:
        case EvidenceDeleteResult.storageFailed:
          _snack(
            context,
            const SnackBar(content: Text(IntruderEvidenceText.deleteFailed)),
          );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    session.removeListener(_onInvalidated);
    _dropImage();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Pixels render only while the session is valid AND this route is the
    // top-most one (a dialog or verification route above hides them).
    final bool top = ModalRoute.of(context)?.isCurrent ?? false;
    _trackCover(top);
    final bool valid = session.isValid;
    final ImageProvider<Object>? provider = valid ? _provider : null;
    Widget body;
    switch (_state) {
      case _DetailState.loading:
        body = const Center(child: CircularProgressIndicator());
      case _DetailState.unavailable:
        body = const _Message(IntruderEvidenceText.unavailable);
      case _DetailState.secureFailed:
        body = const _Message(IntruderEvidenceText.secureFailed);
      case _DetailState.shown:
        body = provider == null || !top
            ? const SizedBox.shrink()
            : Center(
                child: Image(
                  key: const Key('intruder_evidence_image'),
                  image: provider,
                  gaplessPlayback: false,
                  fit: BoxFit.contain,
                  errorBuilder: (BuildContext _, Object __, StackTrace? ___) =>
                      const _Message(IntruderEvidenceText.unavailable),
                ),
              );
    }
    // Nothing renders while invalid or covered (no pixels, no spinner).
    if (!valid || !top) body = const SizedBox.shrink();
    return Scaffold(
      appBar: AppBar(
        title: Text(_fmtTime(widget.item.at)),
        actions: <Widget>[
          IconButton(
            key: const Key('intruder_evidence_delete'),
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: _busy || !valid ? null : _delete,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(child: body),
          if (valid)
            Padding(
              padding: const EdgeInsets.all(DsSpacing.lg),
              child: Text(
                '${widget.item.packageName ?? 'Unknown app'} · '
                '${_fmtSize(widget.item.bytes)}',
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}
