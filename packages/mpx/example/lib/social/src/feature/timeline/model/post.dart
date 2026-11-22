import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';

/// The server's id of a post, opaque and ordered as the server orders it.
extension type const PostId(String value) implements String {}

/// How a post's attachment plays.
enum PostMediaKind {
  /// A still picture.
  photo,

  /// A video with a sound track, played by the player in the viewer and the
  /// reels.
  video,

  /// A silent loop (a GIF the server turned into a clip): plays by itself,
  /// with no timeline.
  gif,
}

/// Who wrote a post.
@immutable
final class Account extends Equatable {
  const Account({
    required this.handle,
    required this.displayName,
    required this.avatar,
    this.bot = false,
  });

  /// `name@server`, as the account is written in a mention.
  final String handle;

  /// The name the account shows; the handle's name when it has none.
  final String displayName;

  /// The account's picture, or null when it has none.
  final MediaKey? avatar;

  /// Whether a program runs the account.
  final bool bot;

  @override
  List<Object?> get props => [handle, displayName, avatar, bot];
}

/// One picture, video or GIF of a post.
@immutable
final class PostMedia extends Equatable {
  const PostMedia({
    required this.key,
    required this.kind,
    this.width,
    this.height,
    this.duration,
    this.byteSize,
    this.alt,
  });

  /// Which media; the origin of its bytes is the host's, never part of it.
  final MediaKey key;

  final PostMediaKind kind;

  /// The source size in pixels, when the server says.
  final int? width;
  final int? height;

  /// How long one pass of a video runs, when the server says.
  final Duration? duration;

  /// The file's size, estimated from the bitrate for a clip (the server does
  /// not send a size), when known: the auto-download policy weighs it.
  final int? byteSize;

  /// The author's description of the picture, for those who cannot see it.
  final String? alt;

  /// Width over height; square when the server does not say.
  double get aspect {
    final w = width;
    final h = height;
    return w == null || h == null || w <= 0 || h <= 0 ? 1 : w / h;
  }

  /// Whether it moves: a video or a GIF.
  bool get plays => kind != PostMediaKind.photo;

  @override
  List<Object?> get props => [
    key,
    kind,
    width,
    height,
    duration,
    byteSize,
    alt,
  ];
}

/// A post's text: the Markdown a widget draws, and the same words with no
/// markup. The server's HTML never leaves the data layer.
@immutable
final class PostText extends Equatable {
  const PostText({required this.markdown, required this.plain});

  static const PostText empty = PostText(markdown: '', plain: '');

  /// The text as Markdown: links, `[@name](mention:id)` and
  /// `[#tag](hashtag:tag)`, paragraphs split by a blank line.
  final String markdown;

  /// What a screen reader or a share carries: no markup.
  final String plain;

  bool get isEmpty => plain.trim().isEmpty;

  @override
  List<Object?> get props => [markdown, plain];
}

/// One post of a timeline.
@immutable
final class Post extends Equatable {
  const Post({
    required this.id,
    required this.host,
    required this.author,
    required this.createdAt,
    required this.text,
    required this.media,
    required this.url,
    this.warning = '',
    this.sensitive = false,
    this.boostedBy,
    this.replies = 0,
    this.boosts = 0,
    this.likes = 0,
  });

  final PostId id;

  /// The server the post was read from; its tags open on it.
  final String host;

  final Account author;
  final DateTime createdAt;
  final PostText text;

  /// What the post attaches, in the order the author gave: one to a few.
  final List<PostMedia> media;

  /// The post's page on the web.
  final String url;

  /// The author's content warning; empty when there is none. The text and
  /// the media wait behind it.
  final String warning;

  /// Whether the author marked the media as sensitive: it shows covered.
  final bool sensitive;

  /// Who boosted the post into this timeline, when someone did.
  final Account? boostedBy;

  final int replies;
  final int boosts;
  final int likes;

  /// Whether the text and the media show covered until the reader asks.
  bool get covered => warning.isNotEmpty || (sensitive && media.isNotEmpty);

  @override
  List<Object?> get props => [
    id,
    host,
    author,
    createdAt,
    text,
    media,
    url,
    warning,
    sensitive,
    boostedBy,
    replies,
    boosts,
    likes,
  ];
}
