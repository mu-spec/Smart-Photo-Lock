import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/repositories/installed_apps_repository.dart';
import '../../design_system/design_system.dart';

/// Launcher icon of an installed app, loaded on demand from the shared
/// [InstalledAppsRepository] (icon bytes are cached at the service level).
///
/// Renders a neutral placeholder while loading or when the system cannot
/// provide an icon — every row keeps a stable rounded tile.
class AppIcon extends StatefulWidget {
  const AppIcon({
    super.key,
    required this.packageName,
    required this.repository,
    this.size = 40,
  });

  final String packageName;
  final InstalledAppsRepository repository;
  final double size;

  @override
  State<AppIcon> createState() => _AppIconState();
}

class _AppIconState extends State<AppIcon> {
  Uint8List? _bytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AppIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.packageName != widget.packageName) {
      _bytes = null;
      _loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    final result = await widget.repository.getAppIcon(widget.packageName);
    if (!mounted) {
      return;
    }
    setState(() {
      _bytes = result.valueOrNull;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final DsPalette palette = context.dsColors;
    final Uint8List? bytes = _bytes;
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: palette.surfaceElevated.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(DsRadii.md),
      ),
      clipBehavior: Clip.antiAlias,
      child: bytes != null
          ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
          : Icon(
              _loading ? Icons.hourglass_empty : Icons.android,
              size: widget.size * 0.55,
              color: palette.textSecondary,
            ),
    );
  }
}
