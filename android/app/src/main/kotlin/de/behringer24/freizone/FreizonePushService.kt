package de.behringer24.freizone

import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService

/**
 * Handles a refreshed FCM token even when the app is closed (APP-12).
 *
 * `firebase_messaging`'s own service only does
 * `FlutterFirebaseTokenLiveData.postToken(token)` on [onNewToken] -- an
 * in-process LiveData. With no live Flutter engine observing it, a token that
 * rotates while the app is dead goes nowhere and is never persisted, so the
 * server keeps the stale one: the gateway's next send returns UNREGISTERED,
 * freizone-server drops the push target, and no wake arrives again until the
 * user happens to open the app -- which they have no reason to do, precisely
 * because nothing is notifying them. The plugin offers no background hook for
 * tokens the way it does for messages, so we start our own engine.
 *
 * This *subclasses* the plugin's service rather than replacing its behaviour:
 * [onNewToken] calls `super` first, so the foreground `onTokenRefresh` stream
 * keeps working exactly as before, and message delivery is untouched (the
 * plugin handles that in its own broadcast receiver, not here).
 *
 * The manifest must remove the plugin's own service declaration in favour of
 * this one -- only one service may claim `com.google.firebase.MESSAGING_EVENT`,
 * and two claiming it is undefined behaviour.
 */
class FreizonePushService : FlutterFirebaseMessagingService() {

    override fun onNewToken(token: String) {
        // Keeps the plugin's own LiveData path intact for the case where the
        // app *is* running and Dart is already listening.
        super.onNewToken(token)
        startRefreshEngine()
    }

    /**
     * Runs [ENTRYPOINT] in a throwaway engine, which re-registers every stored
     * account with its own server.
     *
     * The engine is created on the main looper (FlutterEngine requires it) even
     * though onNewToken arrives on a background thread, and torn down when Dart
     * reports it is finished -- with a timeout as a backstop, so a Dart-side
     * failure leaks an engine at worst until the process dies rather than
     * forever.
     */
    private fun startRefreshEngine() {
        Handler(Looper.getMainLooper()).post {
            try {
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(applicationContext)
                loader.ensureInitializationComplete(applicationContext, null)

                val engine = FlutterEngine(applicationContext)
                var channel: MethodChannel? = null

                // Guarded so the timeout and the "done" callback cannot both
                // destroy the same engine.
                var finished = false
                val finish = {
                    if (!finished) {
                        finished = true
                        channel?.setMethodCallHandler(null)
                        engine.destroy()
                    }
                }

                channel = MethodChannel(
                    engine.dartExecutor.binaryMessenger,
                    CHANNEL,
                ).apply {
                    setMethodCallHandler { call, result ->
                        if (call.method == "done") {
                            result.success(null)
                            finish()
                        } else {
                            result.notImplemented()
                        }
                    }
                }

                engine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(
                        loader.findAppBundlePath(),
                        LIBRARY_URI,
                        ENTRYPOINT,
                    ),
                )

                // Registering every account means one network round trip each,
                // against servers we don't control -- generous enough not to cut
                // a slow-but-working run short.
                Handler(Looper.getMainLooper()).postDelayed(finish, TIMEOUT_MS)
            } catch (e: Exception) {
                // A token refresh we cannot act on is no worse than the old
                // behaviour of losing it entirely -- never take the process down.
            }
        }
    }

    private companion object {
        const val CHANNEL = "freizone/push_token_refresh"
        const val LIBRARY_URI = "package:freizone/push/push_manager.dart"
        const val ENTRYPOINT = "pushTokenRefreshEntrypoint"
        const val TIMEOUT_MS = 60_000L
    }
}
