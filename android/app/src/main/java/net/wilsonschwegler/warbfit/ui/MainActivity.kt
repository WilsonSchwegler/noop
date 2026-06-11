package net.wilsonschwegler.warbfit.ui

import android.Manifest
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.view.WindowCompat
import androidx.lifecycle.lifecycleScope

/**
 * Single-activity host. Requests the runtime BLE permissions the strap connection
 * needs, then renders the Compose tree under [WarbFitTheme]. The design system is
 * dark-only, so we draw edge-to-edge over the near-black [Palette.surfaceBase].
 */
class MainActivity : ComponentActivity() {

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            // Permission results flow back into the BLE client's own runtime checks;
            // the UI simply reflects connection state. No blocking here.
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)

        requestBlePermissions()

        setContent {
            WarbFitTheme {
                WarbFitRoot()
            }
        }
    }

    /** Request the BLE permissions appropriate to the running OS version. */
    private fun requestBlePermissions() {
        val needed = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Android 12+: granular Bluetooth permissions.
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.BLUETOOTH_CONNECT)
            } else {
                // Pre-12: location is required for BLE scanning.
                add(Manifest.permission.ACCESS_FINE_LOCATION)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }.toTypedArray()

        if (needed.isNotEmpty()) permissionLauncher.launch(needed)
    }
}

// MARK: - First-run / changelog gating (mirrors macOS ContentView.swift)
//
// Two persisted flags decide what the user sees on launch, exactly like the macOS
// ZStack-over-RootView:
//   • "warbfit.onboarded"               (Boolean, default false)
//   • "warbfit.lastSeenChangelogVersion" (String,  default "")
//
// Gate:
//   !onboarded                              → OnboardingScreen. On finish, mark onboarded
//                                             AND set lastSeen = CURRENT_VERSION, so a brand-new
//                                             user who just read the expectations doesn't ALSO
//                                             get the changelog popped at them.
//   onboarded && lastSeen != CURRENT_VERSION → existing user who updated: show WhatsNewSheet once,
//                                             over the live AppRoot, until they dismiss it.
//
// SharedPreferences isn't reactive, so each value is read once into a remembered
// mutableState and writes go through .edit().apply() + a state update to recompose.

/** Shared accessor for the onboarding / changelog flags (the macOS @AppStorage equivalent). */
object WarbFitPrefs {
    const val NAME = "warbfit_prefs"
    const val KEY_ONBOARDED = "warbfit.onboarded"
    const val KEY_LAST_SEEN_CHANGELOG = "warbfit.lastSeenChangelogVersion"

    fun of(context: Context): SharedPreferences =
        context.getSharedPreferences(NAME, Context.MODE_PRIVATE)
}

/**
 * Root gate around [AppRoot]. Reads the two prefs once, then renders onboarding,
 * the changelog sheet, or just the app shell, updating both the store and local
 * state on each transition.
 */
@Composable
fun WarbFitRoot() {
    val context = LocalContext.current
    val prefs = remember { WarbFitPrefs.of(context) }

    var onboarded by remember {
        mutableStateOf(prefs.getBoolean(WarbFitPrefs.KEY_ONBOARDED, false))
    }
    var lastSeenChangelog by remember {
        mutableStateOf(prefs.getString(WarbFitPrefs.KEY_LAST_SEEN_CHANGELOG, "") ?: "")
    }

    if (!onboarded) {
        OnboardingScreen(
            onFinished = {
                // A brand-new user just saw the expectations in onboarding — don't also pop the
                // changelog at them; mark them current (mirrors macOS ContentView onFinished).
                prefs.edit()
                    .putBoolean(WarbFitPrefs.KEY_ONBOARDED, true)
                    .putString(WarbFitPrefs.KEY_LAST_SEEN_CHANGELOG, AppChangelog.CURRENT_VERSION)
                    .apply()
                lastSeenChangelog = AppChangelog.CURRENT_VERSION
                onboarded = true
            },
        )
        return
    }

    // Existing, onboarded user: render the app, and if they've updated since last launch
    // (stored version behind current), show "What's New" once over the top.
    AppRoot()

    if (lastSeenChangelog != AppChangelog.CURRENT_VERSION) {
        Dialog(
            onDismissRequest = {
                prefs.edit()
                    .putString(WarbFitPrefs.KEY_LAST_SEEN_CHANGELOG, AppChangelog.CURRENT_VERSION)
                    .apply()
                lastSeenChangelog = AppChangelog.CURRENT_VERSION
            },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                WhatsNewSheet(
                    onClose = {
                        prefs.edit()
                            .putString(WarbFitPrefs.KEY_LAST_SEEN_CHANGELOG, AppChangelog.CURRENT_VERSION)
                            .apply()
                        lastSeenChangelog = AppChangelog.CURRENT_VERSION
                    },
                )
            }
        }
    }
}
