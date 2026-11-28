/// The web has no files: an input's size comes from the host
/// (`PreparationInput.byteSize`), and outputs live in memory.
Future<int> $lengthOf(String path) async => 0;

/// Nothing to delete on the web.
void $delete(String path) {}

/// Nothing to write on the web: a thumbnail stays in memory.
bool $write(String path, List<int> bytes) => false;
