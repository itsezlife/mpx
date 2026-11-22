import 'package:control/control.dart';
import 'package:l/l.dart';

/// Single observer for every controller: logs lifecycle, handler durations,
/// state transitions and handler errors.
class ControllerObserver implements IControllerObserver {
  const ControllerObserver();

  static String _kind(Controller controller) =>
      controller is StateController ? 'StateController' : 'Controller';

  @override
  void onCreate(Controller controller) =>
      l.v6('${_kind(controller)} | ${controller.name}.new');

  @override
  void onDispose(Controller controller) =>
      l.v5('${_kind(controller)} | ${controller.name}.disposed');

  @override
  void onHandler(HandlerContext context) {
    final label =
        '${_kind(context.controller)} | '
        '${context.controller.name}.${context.name}';
    final stopwatch = Stopwatch()..start();
    l.d(label, context.meta);
    context.done.whenComplete(() {
      stopwatch.stop();
      l.d('$label | duration: ${stopwatch.elapsed}', context.meta);
    });
  }

  @override
  void onStateChanged<S extends Object>(
    StateController<S> controller,
    S prevState,
    S nextState,
  ) {
    final context = Controller.context;
    if (context == null) {
      // State change occurred outside of a handler.
      l.d('StateController | ${controller.name} | $prevState -> $nextState');
    } else {
      l.d(
        'StateController | ${controller.name}.${context.name} | '
        '$prevState -> $nextState',
        context.meta,
      );
    }
  }

  @override
  void onError(Controller controller, Object error, StackTrace stackTrace) {
    final context = Controller.context;
    l.w(
      '${_kind(controller)} | ${controller.name}'
      '${context == null ? '' : '.${context.name}'} | $error',
      stackTrace,
      context?.meta,
    );
  }
}
