import 'package:flutter/material.dart';

import 'l10n/app_locale.dart';
import 'l10n/app_strings.dart';

void main() {
  runApp(const PathGuideWebPreviewApp());
}

class PathGuideWebPreviewApp extends StatelessWidget {
  const PathGuideWebPreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppStrings.current.appTitle,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          brightness: Brightness.dark,
        ),
      ),
      home: const _PreviewHomePage(),
    );
  }
}

class _PreviewHomePage extends StatelessWidget {
  const _PreviewHomePage();

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.current;
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F13),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    strings.homeTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const _PreviewNotice(),
                  const SizedBox(height: 24),
                  _ModeButton(
                    icon: Icons.explore,
                    label: strings.modeGuidance,
                    hint: strings.modeGuidanceHint,
                    onTap: () => _openPreview(context, _PreviewMode.guidance),
                  ),
                  const SizedBox(height: 16),
                  _ModeButton(
                    icon: Icons.text_fields,
                    label: strings.modeReadText,
                    hint: strings.modeReadTextHint,
                    onTap: () => _openPreview(context, _PreviewMode.readText),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openPreview(BuildContext context, _PreviewMode mode) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _PreviewModePage(mode: mode),
      ),
    );
  }
}

enum _PreviewMode { guidance, readText }

class _PreviewModePage extends StatefulWidget {
  const _PreviewModePage({required this.mode});

  final _PreviewMode mode;

  @override
  State<_PreviewModePage> createState() => _PreviewModePageState();
}

class _PreviewModePageState extends State<_PreviewModePage> {
  bool _started = false;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.current;
    final guidance = widget.mode == _PreviewMode.guidance;
    final chinese = strings.language == AppLanguage.zh;
    final title = guidance ? strings.homeTitle : strings.modeReadText;
    final status = guidance
        ? (_started
              ? (chinese ? '網頁預覽示範中' : 'Web preview demo running')
              : strings.cameraNotStarted)
        : strings.readTextReady;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F13),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: ColoredBox(
                    color: const Color(0xFF11161C),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          status,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Container(
                  width: double.infinity,
                  color: const Color(0xFF161B22),
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _PreviewNotice(compact: true),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 56,
                        child: FilledButton.icon(
                          onPressed: () => setState(() => _started = !_started),
                          icon: Icon(
                            guidance
                                ? (_started ? Icons.stop : Icons.play_arrow)
                                : Icons.refresh,
                          ),
                          label: Text(
                            guidance
                                ? (_started
                                      ? strings.stopGuidance
                                      : strings.startGuidance)
                                : strings.readAgain,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 48,
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.arrow_back, size: 22),
                          label: Text(strings.backToHome),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewNotice extends StatelessWidget {
  const _PreviewNotice({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final chinese = AppStrings.current.language == AppLanguage.zh;
    final text = chinese
        ? '網頁預覽：相機、物件識別及語音功能未提供'
        : 'Web preview only: camera, object detection, and speech are unavailable';
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: EdgeInsets.all(compact ? 10 : 12),
        decoration: BoxDecoration(
          color: const Color(0xFF242A31),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF68737F)),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.icon,
    required this.label,
    required this.hint,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 88,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20),
        ),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white70,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
