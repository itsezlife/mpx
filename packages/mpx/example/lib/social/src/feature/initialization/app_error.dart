import 'package:flutter/material.dart';
import 'package:mpx_example/social/src/common/theme/app_theme.dart';

/// What the app shows when it could not start: the error and where it came
/// from, selectable, so it can be copied into a report.
class AppError extends StatelessWidget {
  const AppError({this.error, this.stackTrace, super.key});

  final Object? error;
  final StackTrace? stackTrace;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Social feed',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.dark(),
    themeMode: ThemeMode.dark,
    home: Builder(
      builder: (context) {
        final textTheme = Theme.of(context).textTheme;
        final trace = stackTrace?.toString().trim() ?? '';
        return Scaffold(
          body: SafeArea(
            child: Center(
              // A long platform error must stay readable on a small screen.
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.l),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'The app could not start',
                      style: textTheme.titleLarge,
                    ),
                    const SizedBox(height: AppSpacing.m),
                    SelectableText(
                      error?.toString() ?? 'Unknown error',
                      textScaler: TextScaler.noScaling,
                    ),
                    if (trace.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.m),
                      SelectableText(
                        trace,
                        style: textTheme.bodySmall,
                        textScaler: TextScaler.noScaling,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
