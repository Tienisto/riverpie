import 'dart:async';

import 'package:riverpie/src/action/dispatcher.dart';
import 'package:riverpie/src/async_value.dart';
import 'package:riverpie/src/container.dart';
import 'package:riverpie/src/notifier/base_notifier.dart';
import 'package:riverpie/src/notifier/listener.dart';
import 'package:riverpie/src/notifier/notifier_event.dart';
import 'package:riverpie/src/notifier/rebuildable.dart';
import 'package:riverpie/src/notifier/types/async_notifier.dart';
import 'package:riverpie/src/notifier/types/future_family_provider_notifier.dart';
import 'package:riverpie/src/notifier/types/immutable_notifier.dart';
import 'package:riverpie/src/observer/event.dart';
import 'package:riverpie/src/provider/base_provider.dart';
import 'package:riverpie/src/provider/types/async_notifier_provider.dart';
import 'package:riverpie/src/provider/types/redux_provider.dart';
import 'package:riverpie/src/provider/watchable.dart';

/// The base ref to read and notify providers.
/// These methods can be called anywhere.
/// Even within dispose methods.
/// The primary difficulty is to get the [Ref] in the first place.
abstract class Ref {
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
  /// This might be handy if you use [RiverpieTracingPage].
  void message(String message);

  /// Returns the owner of this [Ref].
  /// Usually, this is a notifier or a widget.
  /// Used by [Ref.redux] to log the origin of the action.
  String get debugOwnerLabel;
}

/// The ref available in a [State] with the mixin or in a [ViewProvider].
class WatchableRef extends Ref {
  WatchableRef({
    required RiverpieContainer ref,
    required Rebuildable rebuildable,
  })  : _ref = ref,
        _rebuildable = rebuildable;

  final RiverpieContainer _ref;
  final Rebuildable _rebuildable;

  @override
  T read<N extends BaseNotifier<T>, T>(BaseProvider<N, T> provider) {
    return _ref.read<N, T>(provider);
  }

  @override
  N notifier<N extends BaseNotifier<T>, T>(NotifyableProvider<N, T> provider) {
    return _ref.notifier<N, T>(provider);
  }

  @override
  Dispatcher<N, T> redux<N extends BaseReduxNotifier<T>, T, E extends Object>(
    ReduxProvider<N, T> provider,
  ) {
    return Dispatcher(
      notifier: _ref.notifier(provider),
      debugOrigin: debugOwnerLabel,
      debugOriginRef: _rebuildable,
    );
  }

  @override
  Stream<NotifierEvent<T>> stream<N extends BaseNotifier<T>, T>(
    BaseProvider<N, T> provider,
  ) {
    return _ref.stream<N, T>(provider);
  }

  @override
  Future<T> future<N extends AsyncNotifier<T>, T>(
    AsyncNotifierProvider<N, T> provider,
  ) {
    return _ref.future<N, T>(provider);
  }

  @override
  void dispose<N extends BaseNotifier<T>, T>(BaseProvider<N, T> provider) {
    _ref.dispose<N, T>(provider);
  }

  @override
  void message(String message) {
    _ref.observer?.handleEvent(MessageEvent(message, _rebuildable));
  }

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
  /// Only call [watch] during build.
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
          _rebuildable,
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
          _rebuildable,
          ListenerConfig<T>(
            callback: listener,
            rebuildWhen: rebuildWhen,
          ),
        );
      }
    }

    return watchable.getSelectedState(notifier, notifier.state);
  }

  /// Similar to [watch] but also returns the previous value.
  /// Only works with [AsyncNotifierProvider].
  ChronicleSnapshot<T> watchWithPrev<N extends AsyncNotifier<T>, T>(
    AsyncNotifierProvider<N, T> provider, {
    ListenerCallback<AsyncValue<T>>? listener,
    bool Function(AsyncValue<T> prev, AsyncValue<T> next)? rebuildWhen,
  }) {
    final notifier = _ref.anyNotifier(provider);
    notifier.addListener(
      _rebuildable,
      ListenerConfig(
        callback: listener,
        rebuildWhen: rebuildWhen,
      ),
    );

    // ignore: invalid_use_of_protected_member
    return ChronicleSnapshot(notifier.prev, notifier.state);
  }

  @override
  String get debugOwnerLabel => _rebuildable.debugLabel;
}

class ChronicleSnapshot<T> {
  /// The state of the notifier before the latest [future] was set.
  /// This is null if [AsyncNotifier.savePrev] is false
  /// or the future has never changed.
  final AsyncValue<T>? prev;

  /// The current state of the notifier.
  final AsyncValue<T> curr;

  ChronicleSnapshot(this.prev, this.curr);
}
