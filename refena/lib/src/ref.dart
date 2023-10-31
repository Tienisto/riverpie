import 'dart:async';

import 'package:refena/src/action/dispatcher.dart';
import 'package:refena/src/container.dart';
import 'package:refena/src/notifier/base_notifier.dart';
import 'package:refena/src/notifier/listener.dart';
import 'package:refena/src/notifier/notifier_event.dart';
import 'package:refena/src/notifier/rebuildable.dart';
import 'package:refena/src/notifier/types/async_notifier.dart';
import 'package:refena/src/notifier/types/future_family_provider_notifier.dart';
import 'package:refena/src/notifier/types/immutable_notifier.dart';
import 'package:refena/src/observer/event.dart';
import 'package:refena/src/provider/base_provider.dart';
import 'package:refena/src/provider/types/async_notifier_provider.dart';
import 'package:refena/src/provider/types/redux_provider.dart';
import 'package:refena/src/provider/watchable.dart';

/// The base ref to read and notify providers.
/// These methods can be called anywhere.
/// Even within dispose methods.
/// The primary difficulty is to get the [Ref] in the first place.
///
/// {@category Introduction}
abstract interface class Ref {
  /// Get the current value of a provider without listening to changes.
  T read<N extends BaseNotifier<T>, T>(BaseProvider<N, T> provider);

  /// Get the notifier of a provider.
  N notifier<N extends BaseNotifier<T>, T>(NotifyableProvider<N, T> provider);

  /// Get a proxy class to dispatch actions to a [ReduxNotifier].
  Dispatcher<N, T> redux<N extends BaseReduxNotifier<T>, T, E extends Object>(
    ReduxProvider<N, T> provider,
  );

  /// Listen for changes to a provider.
  ///
  /// Do not call this method during build as you
  /// will create a new listener every time.
  ///
  /// You need to dispose the subscription manually.
  Stream<NotifierEvent<T>> stream<N extends BaseNotifier<T>, T>(
    BaseProvider<N, T> provider,
  );

  /// Get the [Future] of an [AsyncNotifierProvider].
  Future<T> future<N extends AsyncNotifier<T>, T>(
    AsyncNotifierProvider<N, T> provider,
  );

  /// Disposes a [provider].
  /// Be aware that streams (ref.stream) are closed also.
  /// You may call this method in the dispose method of a stateful widget.
  /// Note: The [provider] will be initialized again on next access.
  void dispose<N extends BaseNotifier<T>, T>(BaseProvider<N, T> provider);

  /// Emits a message to the observer.
  /// This might be handy if you use [RefenaTracingPage].
  void message(String message);

  /// Returns the backing container.
  /// The container exposes more advanced methods for edge cases.
  RefenaContainer get container;

  /// Returns the owner of this [Ref].
  /// Usually, this is a notifier or a widget.
  /// Used by [Ref.redux] to log the origin of the action.
  String get debugOwnerLabel;
}

/// The ref available in a [State] with the mixin or in a [ViewProvider].
abstract interface class WatchableRef implements Ref {
  /// Get the current value of a provider and listen to changes.
  /// The listener will be disposed automatically when the widget is disposed.
  ///
  /// Optionally, you can pass a [rebuildWhen] function to control when the
  /// widget should rebuild.
  ///
  /// Instead of `ref.watch(provider)`, you can also
  /// use `ref.watch(provider.select((state) => state.attribute))` to
  /// select a part of the state and only rebuild when this part changes.
  ///
  /// Do NOT execute this method multiple times as only the last one
  /// will be used for the rebuild condition.
  /// Instead, you should use *Records* to combine multiple values:
  /// final (a, b) = ref.watch(provider.select((state) => state.a, state.b));
  ///
  /// Only call this method during build or inside a [ViewProvider].
  R watch<N extends BaseNotifier<T>, T, R>(
    Watchable<N, T, R> watchable, {
    ListenerCallback<T>? listener,
    bool Function(T prev, T next)? rebuildWhen,
  });
}

/// The actual implementation of [WatchableRef].
/// This decoupling is used to discourage access to [rebuildable]
/// and [trackNotifier].
class WatchableRefImpl implements WatchableRef {
  WatchableRefImpl({
    required RefenaContainer ref,
    required this.rebuildable,
  }) : _ref = ref;

  final RefenaContainer _ref;
  final Rebuildable rebuildable;

  @override
  T read<N extends BaseNotifier<T>, T>(BaseProvider<N, T> provider) {
    if (_onAccessNotifier == null) {
      return _ref.read<N, T>(provider);
    }

    final notifier = _ref.anyNotifier<N, T>(provider);
    _onAccessNotifier!(notifier);
    return notifier.state;
  }

  @override
  N notifier<N extends BaseNotifier<T>, T>(NotifyableProvider<N, T> provider) {
    final notifier = _ref.notifier<N, T>(provider);
    _onAccessNotifier?.call(notifier);
    return notifier;
  }

  @override
  Dispatcher<N, T> redux<N extends BaseReduxNotifier<T>, T, E extends Object>(
    ReduxProvider<N, T> provider,
  ) {
    final notifier = _ref.anyNotifier(provider);
    _onAccessNotifier?.call(notifier);
    return Dispatcher(
      notifier: notifier,
      debugOrigin: debugOwnerLabel,
      debugOriginRef: rebuildable,
    );
  }

  @override
  Stream<NotifierEvent<T>> stream<N extends BaseNotifier<T>, T>(
    BaseProvider<N, T> provider,
  ) {
    if (_onAccessNotifier == null) {
      return _ref.stream<N, T>(provider);
    }

    final notifier = _ref.anyNotifier<N, T>(provider);
    _onAccessNotifier!(notifier);
    return notifier.getStream();
  }

  @override
  Future<T> future<N extends AsyncNotifier<T>, T>(
    AsyncNotifierProvider<N, T> provider,
  ) {
    if (_onAccessNotifier == null) {
      return _ref.future<N, T>(provider);
    }

    final notifier = _ref.anyNotifier(provider);
    _onAccessNotifier!(notifier);
    return notifier.future; // ignore: invalid_use_of_protected_member
  }

  @override
  void dispose<N extends BaseNotifier<T>, T>(BaseProvider<N, T> provider) {
    _ref.internalDispose<N, T>(provider, rebuildable);
  }

  @override
  void message(String message) {
    _ref.observer?.internalHandleEvent(MessageEvent(message, rebuildable));
  }

  @override
  RefenaContainer get container => _ref;

  @override
  R watch<N extends BaseNotifier<T>, T, R>(
    Watchable<N, T, R> watchable, {
    ListenerCallback<T>? listener,
    bool Function(T prev, T next)? rebuildWhen,
  }) {
    final notifier = _ref.anyNotifier(watchable.provider);
    if (notifier is! ImmutableNotifier) {
      // We need to add a listener to the notifier
      // to rebuild the widget when the state changes.
      if (watchable is SelectedWatchable<N, T, R>) {
        if (watchable is FamilySelectedWatchable) {
          // start future
          final familyNotifier = notifier as FutureFamilyProviderNotifier;
          final familyWatchable = watchable as FamilySelectedWatchable;
          familyNotifier.startFuture(familyWatchable.param);
        }
        notifier.addListener(
          rebuildable,
          ListenerConfig<T>(
            callback: listener,
            rebuildWhen: (prev, next) {
              if (rebuildWhen?.call(prev, next) == false) {
                return false;
              }
              return watchable.getSelectedState(notifier, prev) !=
                  watchable.getSelectedState(notifier, next);
            },
          ),
        );
      } else {
        notifier.addListener(
          rebuildable,
          ListenerConfig<T>(
            callback: listener,
            rebuildWhen: rebuildWhen,
          ),
        );
      }
    }

    _onAccessNotifier?.call(notifier);

    return watchable.getSelectedState(notifier, notifier.state);
  }

  @override
  String get debugOwnerLabel => rebuildable.debugLabel;

  /// This function is always called when a [BaseNotifier] is accessed.
  /// Used to determine the dependency graph.
  void Function(BaseNotifier)? _onAccessNotifier;

  /// Runs [run] and calls [onAccess] for every [BaseNotifier]
  R trackNotifier<R>({
    required void Function(BaseNotifier) onAccess,
    required R Function() run,
  }) {
    _onAccessNotifier = onAccess;
    final result = run();
    _onAccessNotifier = null;
    return result;
  }
}
