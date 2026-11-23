import 'package:flutter/material.dart';
import 'package:flutter_md/flutter_md.dart';
import 'package:mpx_example/social/src/common/theme/app_theme.dart';
import 'package:mpx_example/social/src/feature/app/router/routes.dart';
import 'package:squid/squid.dart';
import 'package:url_launcher/url_launcher.dart';

/// A post's text, drawn from its Markdown: links open in the browser, a
/// hashtag opens its timeline, a mention opens the account's page, and the
/// text is selected by a long press and a drag, in this post: it has a
/// selection of its own, in the list's group (a selection that starts in
/// another post ends it).
///
/// With [maxLines] it shows that many lines and a "Show more" under them
/// when there are more; the cut falls on a line boundary. A selection that
/// starts on the clipped text opens it, since a selection reads a whole text
/// and would highlight and copy words that are not shown.
class PostTextView extends StatefulWidget {
  const PostTextView({
    required this.markdown,
    required this.documentId,
    required this.host,
    this.maxLines,
    this.selectionGroup,
    this.selectable = true,
    super.key,
  });

  /// The text, parsed. The very object the selection holds for
  /// [documentId] (`PostSelection.markdownOf`): a copy is read from it.
  final Markdown markdown;

  /// Names this text to the selection.
  final Object documentId;

  /// The server the post was read from: its tags open on it.
  final String host;

  /// How many lines show before "Show more"; all when null.
  final int? maxLines;

  /// The group this text's selection joins: at most one selection of the
  /// group is live at a time. None means the selection is its own.
  final MarkdownSelectionGroup? selectionGroup;

  /// Whether the text may be selected at all: not while a content warning
  /// covers it.
  final bool selectable;

  @override
  State<PostTextView> createState() => _PostTextViewState();
}

class _PostTextViewState extends State<PostTextView> {
  bool _expanded = false;
  final GlobalKey _bodyKey = GlobalKey(debugLabel: 'PostTextBody');
  late final MarkdownSelectionController _selection =
      MarkdownSelectionController(group: widget.selectionGroup);

  // The clamp for one width: laying a document out is not free, and the
  // width does not change while a post scrolls.
  double? _clampedFor;
  MarkdownLineClamp? _clamp;

  @override
  void initState() {
    super.initState();
    _register();
  }

  @override
  void didUpdateWidget(PostTextView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.markdown, oldWidget.markdown)) {
      _clampedFor = null;
      _register();
    }
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  // The selection reads this text, by the object the widget draws.
  void _register() => _selection.setDocuments([
    MarkdownDocumentRef(
      id: widget.documentId,
      model: widget.markdown,
      order: 0,
    ),
  ]);

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _onLinkTap(String title, String url) => _open(url);

  // A hashtag has no id, its tag is the `name`; a mention has an id (the
  // account's address) and the name it shows.
  void _onMentionTap(String scheme, String? id, String name) {
    switch (scheme) {
      case 'hashtag':
        context.navigation.push(
          TagRoute(host: widget.host, tag: Uri.decodeComponent(name)),
        );
      case 'mention':
        if (id != null) _open(Uri.decodeComponent(id));
    }
  }

  MarkdownLineClamp? _clampAt(MarkdownThemeData theme, double width) {
    final lines = widget.maxLines;
    if (lines == null) return null;
    if (_clampedFor != width) {
      _clampedFor = width;
      _clamp = clampMarkdownToLines(
        markdown: widget.markdown,
        theme: theme,
        maxWidth: width,
        maxLines: lines,
      );
    }
    return _clamp;
  }

  @override
  Widget build(BuildContext context) {
    final materialTheme = Theme.of(context);
    final theme = MarkdownThemeData.mergeTheme(materialTheme).copyWith(
      textStyle: materialTheme.textTheme.bodyLarge,
      onLinkTap: _onLinkTap,
      onMentionTap: _onMentionTap,
    );
    // The body keeps its element (and its selection surface) as the text is
    // opened: it moves from the clipped box to the plain one.
    final body = KeyedSubtree(
      key: _bodyKey,
      child: MarkdownWidget(
        markdown: widget.markdown,
        documentId: widget.documentId,
        theme: theme,
      ),
    );
    // The scope stays where it is for the whole life of the text, so a press
    // that began on clipped lines goes on after they open.
    return MarkdownSelectionScope(
      controller: _selection,
      enabled: widget.selectable,
      selectionColor: materialTheme.colorScheme.primary.withValues(alpha: 0.35),
      // A selection that starts on clipped text opens it: a selection reads a
      // whole text, and what it covers is shown, not guessed at.
      onSelectionChanged: (selection) {
        if (selection != null && !selection.isCollapsed && !_expanded) {
          setState(() => _expanded = true);
        }
      },
      child: widget.maxLines == null || _expanded
          ? body
          : LayoutBuilder(
              builder: (context, constraints) {
                final clamp = _clampAt(theme, constraints.maxWidth);
                if (clamp == null || !clamp.overflows) return body;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: clamp.clampedHeight,
                      child: ClipRect(
                        // The text's render object turns itself into a
                        // repaint boundary when it gets its selection
                        // controller, after the compositing bits are
                        // settled, so a clip above it does not know to clip a
                        // layer: the text paints past the cut. A boundary of
                        // our own, always one, makes the clip a layer's.
                        child: RepaintBoundary(
                          child: OverflowBox(
                            alignment: Alignment.topLeft,
                            minHeight: 0,
                            maxHeight: double.infinity,
                            child: body,
                          ),
                        ),
                      ),
                    ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _expanded = true),
                      child: Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.xs),
                        child: Text(
                          'Show more',
                          style: materialTheme.textTheme.labelLarge?.copyWith(
                            color: materialTheme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}
