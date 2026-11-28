import 'package:web/web.dart' as web;

/// The web hook: the text kept under [path] in the page's local storage,
/// or null when there is none.
String? $readText(String path) {
  try {
    return web.window.localStorage.getItem(path);
  } on Object {
    return null;
  }
}

/// The web hook: keeps [text] under [path] in the page's local storage.
void $writeText(String path, String text) {
  try {
    web.window.localStorage.setItem(path, text);
  } on Object {
    // Storage refused (a private window): the settings last for the page.
  }
}

/// The web hook: a reload of the page, the web's nearest to a kill.
void $killProcess() => web.window.location.reload();
