package dev.herdrmobile.herdr_mobile

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.ViewTreeObserver
import com.dexterous.flutterlocalnotifications.ForegroundService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter syncs the keyboard's animation with the window's insets from API 30
 * (`TextInputPlugin` installs `ImeSyncDeferringInsetsCallback` there) and stops
 * taking the navigation bar off them from API 35. Only in between is the bug
 * below reachable; everywhere else this activity is a plain `FlutterActivity`.
 */
private val engineSubtractsNavigationBar = Build.VERSION.SDK_INT in 30..34

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!engineSubtractsNavigationBar) return
        // Flutter clears the flag when Dart asks for edge to edge, and on every
        // resume; whenever the window lays out, put it back.
        window.decorView.viewTreeObserver.addOnGlobalLayoutListener(
            ViewTreeObserver.OnGlobalLayoutListener { layoutBehindNavigationBar() },
        )
    }

    override fun onPostResume() {
        super.onPostResume()
        if (engineSubtractsNavigationBar) layoutBehindNavigationBar()
    }

    /**
     * The quiet "Watching N agents" notice (flutter_local_notifications'
     * service) stands for the connections this activity's Dart isolate holds.
     * Whenever the activity goes for good (finished by Back, or destroyed by
     * the system while the app is in the background: `isFinishing` is false
     * then, and the service would keep an empty process alive) the isolate and
     * its connections are gone, so the notice must go too. A configuration
     * change recreates the activity around the same engine: that one stays.
     */
    override fun onDestroy() {
        if (!isChangingConfigurations) stopService(Intent(this, ForegroundService::class.java))
        super.onDestroy()
    }

    /**
     * Back at the app's root would finish the activity and end the engine. While
     * agents are watched Dart asks for the task to go to the background
     * instead, as Home does.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.herdrmobile/task")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "moveTaskToBack" -> result.success(moveTaskToBack(true))
                    // Android 13+ confirms a clipboard write itself.
                    "sdkInt" -> result.success(android.os.Build.VERSION.SDK_INT)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Flutter 3.44+ draws edge to edge with `setDecorFitsSystemWindows(false)`
     * and leaves the legacy layout flags at 0. Its keyboard animation sync still
     * reads "no LAYOUT_HIDE_NAVIGATION" as "the navigation bar is not under the
     * view" and takes the bar's height off every animated inset, while the
     * inset it reports once the keyboard has settled keeps it. The layout then
     * runs one bar's height (48 dp here) short during the whole animation and
     * snaps on the last frame (flutter/flutter#190974, #191094).
     *
     * The window already extends under the bar, so the flag changes no layout
     * (the padding the app sees is the same with and without it): it only makes
     * the engine report the system's insets as they are. Remove it once an
     * engine with the fix ships.
     */
    @Suppress("DEPRECATION")
    private fun layoutBehindNavigationBar() {
        val decor = window.decorView
        val flags = decor.systemUiVisibility
        if (flags and View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION == 0) {
            decor.systemUiVisibility = flags or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        }
    }
}
