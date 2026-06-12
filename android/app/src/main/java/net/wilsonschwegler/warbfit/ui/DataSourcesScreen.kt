package net.wilsonschwegler.warbfit.ui

import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.filled.FileUpload
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import net.wilsonschwegler.warbfit.data.DataBackup
import net.wilsonschwegler.warbfit.data.ImportSummary
import net.wilsonschwegler.warbfit.ingest.AppleHealthImporter
import net.wilsonschwegler.warbfit.ingest.HealthConnectImporter
import net.wilsonschwegler.warbfit.ingest.TrackerCsvImporter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Data Sources — ports the macOS DataSourcesView (Strand/Screens/DataSourcesView.swift)
 * onto the locked Android component system (ScreenScaffold / WarbFitCard / StatePill /
 * Overline / WarbFitType / Palette).
 *
 * The macOS screen is built around "bring your history in once, then it's yours": three
 * source cards (TRACKER Export, Apple Health, Live BLE) plus on-device file import. On
 * Android the on-device store is a single Room/SQLite file, and the real, working
 * migration path is whole-store export/import via [DataBackup] (a SAF document the user
 * picks). So this screen keeps the macOS structure but maps each card to what Android
 * actually has:
 *
 *   - TRACKER data    — live counts of the cached "my-tracker" history, plus a working import
 *                     of a TRACKER .zip/.csv export (app.tracker.com → Data Management) via
 *                     [net.wilsonschwegler.warbfit.ingest.TrackerCsvImporter].
 *   - Apple Health  — live counts of cached "apple-health" data, plus a working streaming
 *                     import of an Apple Health export.zip/export.xml via
 *                     [net.wilsonschwegler.warbfit.ingest.AppleHealthImporter].
 *   - Health Connect— native Android import (steps/HR/HRV/sleep/SpO₂/weight/workouts) via
 *                     [net.wilsonschwegler.warbfit.ingest.HealthConnectImporter], gated on runtime permission.
 *   - TRACKER Strap   — the live BLE bond/stream status, straight from the LiveState flow.
 *   - Backup        — Export / Import the whole on-device database through [DataBackup],
 *                     wired to ActivityResult document launchers.
 */
@Composable
fun DataSourcesScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val live by vm.live.collectAsStateWithLifecycle()

    // Cached-store counts, loaded once from the repo (newest data is fine to recount).
    var trackerDays by remember { mutableStateOf<Int?>(null) }
    var trackerWorkouts by remember { mutableStateOf<Int?>(null) }
    var trackerHasHr by remember { mutableStateOf(false) }
    var appleDays by remember { mutableStateOf<Int?>(null) }
    var appleWorkouts by remember { mutableStateOf<Int?>(null) }

    LaunchedEffect(Unit) {
        val now = System.currentTimeMillis() / 1000
        trackerDays = vm.repo.days("my-tracker").size
        trackerWorkouts = vm.repo.workouts("my-tracker", 0L, now).size
        trackerHasHr = vm.repo.latestHrSampleTs("my-tracker") != null
        appleDays = vm.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31").size
        appleWorkouts = vm.repo.workouts("apple-health", 0L, now).size
    }

    // Whole-store backup: export to a user-created document; import from a picked one.
    var busy by remember { mutableStateOf(false) }
    var restartNeeded by remember { mutableStateOf(false) }

    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream"),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        busy = true
        scope.launch {
            val message = withContext(Dispatchers.IO) {
                runCatching { DataBackup.exportTo(context, uri) }
                    .fold({ "Backup saved." }, { "Backup failed: ${it.message}" })
            }
            busy = false
            Toast.makeText(context, message, Toast.LENGTH_LONG).show()
        }
    }

    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        busy = true
        scope.launch {
            val result = withContext(Dispatchers.IO) { DataBackup.importFrom(context, uri) }
            busy = false
            when (result) {
                is DataBackup.ImportResult.NeedsRestart -> {
                    restartNeeded = true
                    Toast.makeText(
                        context,
                        "Imported. Fully close and reopen Strand to load it.",
                        Toast.LENGTH_LONG,
                    ).show()
                }
                is DataBackup.ImportResult.Failed ->
                    Toast.makeText(context, result.message, Toast.LENGTH_LONG).show()
            }
        }
    }

    suspend fun refreshCounts() {
        val nowS = System.currentTimeMillis() / 1000
        trackerDays = vm.repo.days("my-tracker").size
        trackerWorkouts = vm.repo.workouts("my-tracker", 0L, nowS).size
        trackerHasHr = vm.repo.latestHrSampleTs("my-tracker") != null
        appleDays = vm.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31").size
        appleWorkouts = vm.repo.workouts("apple-health", 0L, nowS).size
    }

    // Run an importer off the main thread, refresh the counts, then toast the result.
    fun runImport(block: suspend () -> ImportSummary) {
        busy = true
        scope.launch {
            val summary = withContext(Dispatchers.IO) {
                runCatching { block() }.getOrElse { ImportSummary.failure("Import", it.message ?: "failed") }
            }
            refreshCounts()
            busy = false
            Toast.makeText(context, summary.message, Toast.LENGTH_LONG).show()
        }
    }

    // SAF pickers — the importers auto-detect zip vs csv/xml from the file's content.
    val trackerImportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> if (uri != null) runImport { TrackerCsvImporter.importZip(context, uri, vm.repo) } }

    val appleImportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> if (uri != null) runImport { AppleHealthImporter.importExport(context, uri, vm.repo) } }

    // Health Connect permission request → import once granted.
    val hcPermissionLauncher = rememberLauncherForActivityResult(
        PermissionController.createRequestPermissionResultContract(),
    ) { granted ->
        if (granted.containsAll(HealthConnectImporter.PERMISSIONS)) {
            runImport { HealthConnectImporter.import(context, vm.repo) }
        } else {
            Toast.makeText(context, "Health Connect access not granted.", Toast.LENGTH_LONG).show()
        }
    }

    val healthConnectAvailable = remember {
        HealthConnectImporter.sdkStatus(context) == HealthConnectClient.SDK_AVAILABLE
    }

    // Import directly if permissions already granted, otherwise request them first.
    fun startHealthConnect() {
        scope.launch {
            val granted = runCatching {
                HealthConnectImporter.client(context).permissionController.getGrantedPermissions()
            }.getOrDefault(emptySet())
            if (granted.containsAll(HealthConnectImporter.PERMISSIONS)) {
                runImport { HealthConnectImporter.import(context, vm.repo) }
            } else {
                hcPermissionLauncher.launch(HealthConnectImporter.PERMISSIONS)
            }
        }
    }

    ScreenScaffold(
        title = "Data Sources",
        subtitle = "Everything stays on this phone. Bring your history in once, then it's yours.",
    ) {
        // --- Fitness tracker data (cached history) ---
        SourceCard(
            title = "Fitness tracker history",
            icon = Icons.Filled.MonitorHeart,
            subtitle = "Recovery, strain, sleep and workouts, stored locally. Import a full " +
                "fitness tracker data export (.zip) from your data export portal and it " +
                "backfills your whole history in about a minute. Working now on Android.",
        ) {
            StatePill(
                title = if (trackerHasHr) "Streaming locally" else "No samples yet",
                tone = if (trackerHasHr) StrandTone.Positive else StrandTone.Neutral,
                showsDot = true,
            )
            CountLine(
                primary = trackerDays?.let { "$it days" } ?: "—",
                secondary = trackerWorkouts?.let { "$it workouts stored" } ?: "Counting…",
            )
            BackupButton(
                label = "Import fitness tracker export (.zip)",
                icon = Icons.Filled.FileUpload,
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            ) { trackerImportLauncher.launch(arrayOf("*/*")) }
        }

        // --- Apple Health ---
        SourceCard(
            title = "Apple Health",
            icon = Icons.Filled.FavoriteBorder,
            subtitle = "Import HR, HRV, sleep, SpO₂ and steps from an Apple Health export. On " +
                "an iPhone: Health app → tap your photo → Export All Health Data, then " +
                "import the .zip here. Working now on Android.",
        ) {
            val hasApple = (appleDays ?: 0) > 0 || (appleWorkouts ?: 0) > 0
            StatePill(
                title = if (hasApple) "Imported" else "Nothing imported",
                tone = if (hasApple) StrandTone.Accent else StrandTone.Neutral,
                showsDot = true,
            )
            CountLine(
                primary = appleDays?.let { "$it days" } ?: "—",
                secondary = appleWorkouts?.let { "$it workouts" } ?: "Counting…",
            )
            BackupButton(
                label = "Import Apple Health export…",
                icon = Icons.Filled.FileUpload,
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            ) { appleImportLauncher.launch(arrayOf("*/*")) }
        }

        // --- Health Connect (native Android health data) ---
        SourceCard(
            title = "Health Connect",
            icon = Icons.Filled.MonitorHeart,
            subtitle = "Pull steps, heart rate, HRV, sleep, SpO₂, weight and workouts straight from " +
                "Android's Health Connect — no file needed. Read-only, on-device; it never overwrites " +
                "richer fitness tracker data.",
        ) {
            if (healthConnectAvailable) {
                BackupButton(
                    label = "Import from Health Connect",
                    icon = Icons.Filled.FileUpload,
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                ) { startHealthConnect() }
            } else {
                RoadmapNote("Health Connect isn't set up on this device — install it from Google Play, then return here to import.")
            }
        }

        // --- Live fitness tracker strap over BLE ---
        SourceCard(
            title = "Fitness tracker strap (Live BLE)",
            icon = Icons.Filled.Bluetooth,
            subtitle = "Pairs directly with your strap over Bluetooth — no fitness tracker app, no cloud.",
        ) {
            val (label, tone) = when {
                live.bonded -> "Bonded — streaming." to StrandTone.Positive
                live.connected -> "Connected — pairing…" to StrandTone.Warning
                else -> "Not connected — open Live to pair." to StrandTone.Critical
            }
            StatePill(title = label, tone = tone, showsDot = true, pulsing = live.connected && !live.bonded)
        }

        // --- Whole-store backup (the real Android migration path) ---
        SourceCard(
            title = "Backup & Move",
            icon = Icons.Filled.FileDownload,
            subtitle = "Your whole history is one file on this phone. Export it to keep a copy " +
                "or move to a new phone, then import it there. Nothing leaves the device " +
                "except through the file you choose.",
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                BackupButton(
                    label = "Export…",
                    icon = Icons.Filled.FileDownload,
                    enabled = !busy,
                    modifier = Modifier.weight(1f),
                ) { exportLauncher.launch("strand-backup.warbfitdb") }
                BackupButton(
                    label = "Import…",
                    icon = Icons.Filled.FileUpload,
                    enabled = !busy,
                    modifier = Modifier.weight(1f),
                ) { importLauncher.launch(arrayOf("*/*")) }
            }
            if (busy) {
                Text("Working…", style = WarbFitType.footnote, color = Palette.textTertiary)
            }
            if (restartNeeded) {
                Text(
                    "Import staged. Fully close and reopen Strand to load the new data.",
                    style = WarbFitType.subhead,
                    color = Palette.statusWarning,
                )
            }
        }
    }
}

// MARK: - Source card (mirrors the macOS private `card(...)` builder)

@Composable
private fun SourceCard(
    title: String,
    icon: ImageVector,
    subtitle: String,
    content: @Composable () -> Unit,
) {
    WarbFitCard(padding = 18.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(20.dp),
                )
                Text(title, style = WarbFitType.headline, color = Palette.textPrimary)
            }
            Text(subtitle, style = WarbFitType.subhead, color = Palette.textSecondary)
            content()
        }
    }
}

// MARK: - "N days · N workouts stored" footnote line (mirrors the macOS counts line)

@Composable
private fun CountLine(primary: String, secondary: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(primary, style = WarbFitType.captionNumber, color = Palette.textSecondary)
        Text("  ·  ", style = WarbFitType.footnote, color = Palette.textTertiary)
        Text(secondary, style = WarbFitType.footnote, color = Palette.textTertiary)
    }
}

@Composable
private fun RoadmapNote(text: String) {
    Text(text, style = WarbFitType.footnote, color = Palette.textTertiary)
}

// MARK: - Backup action button (matches the accent fill used by CoachPrimaryButton)

@Composable
private fun BackupButton(
    label: String,
    icon: ImageVector,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(14.dp)
    val tint = if (enabled) Palette.accent else Palette.accent.copy(alpha = Palette.disabledOpacity)
    Row(
        modifier = modifier
            .height(48.dp)
            .clip(shape)
            .background(Palette.accentMuted)
            .border(1.dp, tint.copy(alpha = 0.4f), shape)
            .let { if (enabled) it.clickable(onClick = onClick) else it }
            .padding(horizontal = 14.dp)
            .semantics { contentDescription = label },
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(label, style = WarbFitType.headline, color = tint)
    }
}
