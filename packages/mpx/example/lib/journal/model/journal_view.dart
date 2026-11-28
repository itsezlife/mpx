import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/journal/model/diagnostics_entry.dart';

/// One correlation id a filter can hold, by the name an `MpxEvent` carries
/// it under.
enum JournalIdKind {
  /// A transfer's or a publish job's id.
  jobId,

  /// The host's id of an item of a job.
  itemId,

  /// The encoded media key.
  mediaKey,

  /// The host's job tag.
  tag;

  /// The id of this kind in [ids], or null.
  String? of(Map<String, String> ids) => ids[name];
}

/// Which records the journal shows: enabled [levels], the [categories] (every
/// one when null) and the correlation [ids] a record must carry, every one.
@immutable
final class JournalFilter {
  /// A filter.
  JournalFilter({
    required Set<MpxEventLevel> levels,
    Set<String>? categories,
    Map<JournalIdKind, String> ids = const {},
  }) : levels = Set.unmodifiable(levels),
       categories = switch (categories) {
         final categories? => Set.unmodifiable(categories),
         null => null,
       },
       ids = Map.unmodifiable(ids);

  /// Every level and category, no id.
  factory JournalFilter.all() =>
      JournalFilter(levels: MpxEventLevel.values.toSet());

  /// The records of the item with [itemId], every level and category:
  /// "logs of this item".
  factory JournalFilter.ofItem(String itemId) => JournalFilter(
    levels: MpxEventLevel.values.toSet(),
    ids: {JournalIdKind.itemId: itemId},
  );

  /// The records of the media with [mediaKey] (its encoded form), every
  /// level and category.
  factory JournalFilter.ofMediaKey(String mediaKey) => JournalFilter(
    levels: MpxEventLevel.values.toSet(),
    ids: {JournalIdKind.mediaKey: mediaKey},
  );

  /// Levels that pass.
  final Set<MpxEventLevel> levels;

  /// Categories that pass, by name; null passes every one.
  final Set<String>? categories;

  /// Ids a record must carry.
  final Map<JournalIdKind, String> ids;

  /// Whether [record] passes every part.
  bool accepts(DiagnosticsEntry record) =>
      levels.contains(record.level) && matchesBesidesLevel(record);

  /// Whether [record] passes the categories and the ids, whatever its level,
  /// so the level chips can count what each level would add.
  bool matchesBesidesLevel(DiagnosticsEntry record) =>
      (categories?.contains(record.category) ?? true) &&
      ids.entries.every((entry) => entry.key.of(record.ids) == entry.value);

  /// [level] turned off when on, on when off.
  JournalFilter toggleLevel(MpxEventLevel level) => _with(
    levels: levels.contains(level)
        ? ({...levels}..remove(level))
        : {...levels, level},
  );

  /// Only [level]; every level again when it is already the only one.
  JournalFilter soloLevel(MpxEventLevel level) => _with(
    levels: levels.length == 1 && levels.contains(level)
        ? MpxEventLevel.values.toSet()
        : {level},
  );

  /// Only [category]; every category again when it is already the only one.
  JournalFilter soloCategory(String category) => JournalFilter(
    levels: levels,
    categories: switch (categories) {
      final only? when only.length == 1 && only.contains(category) => null,
      _ => {category},
    },
    ids: ids,
  );

  /// [kind] set to [id], or dropped when [id] is blank.
  JournalFilter withId(JournalIdKind kind, String id) => _with(
    ids: switch (id.trim()) {
      '' => {...ids}..remove(kind),
      final id => {...ids, kind: id},
    },
  );

  JournalFilter _with({
    Set<MpxEventLevel>? levels,
    Map<JournalIdKind, String>? ids,
  }) => JournalFilter(
    levels: levels ?? this.levels,
    categories: categories,
    ids: ids ?? this.ids,
  );

  /// The filter as plain values, for an export's header.
  Map<String, Object> toJson() => {
    'levels': [for (final level in levels) level.name],
    'categories': ?categories?.toList(),
    'ids': {for (final MapEntry(:key, :value) in ids.entries) key.name: value},
  };
}

/// The journal's view of its records under a [JournalFilter].
@immutable
final class JournalSnapshot {
  const JournalSnapshot._({
    required this.visible,
    required this.total,
    required this.categories,
    required Map<MpxEventLevel, int> countByLevel,
  }) : _countByLevel = countByLevel;

  /// Projects [records] (oldest first, as the journal holds them) through
  /// [filter].
  factory JournalSnapshot.of(
    Iterable<DiagnosticsEntry> records,
    JournalFilter filter,
  ) {
    final visible = <DiagnosticsEntry>[];
    final countByLevel = <MpxEventLevel, int>{};
    final categories = <String>{};
    var total = 0;
    for (final record in records) {
      total++;
      categories.add(record.category);
      if (!filter.matchesBesidesLevel(record)) continue;
      countByLevel.update(record.level, (n) => n + 1, ifAbsent: () => 1);
      if (filter.levels.contains(record.level)) visible.add(record);
    }
    return JournalSnapshot._(
      visible: List.unmodifiable(visible.reversed),
      total: total,
      categories: List.unmodifiable(categories.toList()..sort()),
      countByLevel: Map.unmodifiable(countByLevel),
    );
  }

  /// Records that pass the filter, newest first.
  final List<DiagnosticsEntry> visible;

  /// Records before filtering.
  final int total;

  /// The categories of every record, by name, sorted.
  final List<String> categories;

  final Map<MpxEventLevel, int> _countByLevel;

  /// Records of [level] that pass the rest of the filter, whether or not
  /// [level] is on.
  int countOf(MpxEventLevel level) => _countByLevel[level] ?? 0;
}
