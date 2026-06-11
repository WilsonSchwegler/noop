package net.wilsonschwegler.warbfit.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import net.wilsonschwegler.warbfit.analytics.Hrv
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import java.util.Locale

// MARK: - Pace presets (ported from BreathingView.Pace)

private enum class Pace(
    val label: String,
    val inhale: Double,
    val exhale: Double,
    val tagline: String,
) {
    Relax("Relax 4-6", 4.0, 6.0, "Long exhale · downshift to rest"),
    Coherence("Coherence 5.5", 5.5, 5.5, "Equal breath · ~5.5 br/min coherence"),
    Box("Box 4-4", 4.0, 4.0, "Square breath · steady focus");

    val cycle: Double get() = inhale + exhale
    val bpm: Double get() = 60.0 / cycle
}

private enum class Phase { Inhale, Exhale }

/**
 * Breathe — HRV haptic breathing biofeedback. The strap both measures HRV (R-R
 * intervals) and buzzes (haptic motor), so we pace the breath with a felt cue and
 * watch HRV respond live. One pulse on the inhale, two on the exhale. Live HR + a
 * rolling RMSSD show the autonomic response building. Ports BreathingView.swift.
 */
@Composable
fun BreatheScreen(viewModel: AppViewModel) {
    val live by viewModel.live.collectAsStateWithLifecycle()
    val bpm by viewModel.bpm.collectAsStateWithLifecycle()

    var pace by remember { mutableStateOf(Pace.Coherence) }
    var running by remember { mutableStateOf(false) }
    var phase by remember { mutableStateOf(Phase.Inhale) }
    var sessionSeconds by remember { mutableIntStateOf(0) }
    var breathCount by remember { mutableIntStateOf(0) }

    // Rolling R-R buffer + RMSSD (computed by the shared analytics Hrv).
    val rrBuffer = remember { mutableStateOf<List<Int>>(emptyList()) }
    var rmssd by remember { mutableStateOf<Double?>(null) }
    val rrWindow = 30

    // Orb expansion 0..1; driven by an eased animation per breath phase.
    val orbTarget = if (running && phase == Phase.Inhale) 1f else 0f
    val phaseDurationMs = ((if (phase == Phase.Inhale) pace.inhale else pace.exhale) * 1000).toInt()
    val orbProgress by animateFloatAsState(
        targetValue = orbTarget,
        animationSpec = tween(if (running) phaseDurationMs else 800, easing = Motion.easeInOut),
        label = "orb",
    )

    // Ingest new R-R intervals into the rolling buffer and recompute RMSSD.
    // Collect the BLE state flow directly so updates are observed reactively.
    LaunchedEffect(Unit) {
        viewModel.live
            .map { it.rr }
            .distinctUntilChanged()
            .collect { rr ->
                if (rr.isEmpty()) return@collect
                val merged = (rrBuffer.value + rr).takeLast(rrWindow)
                rrBuffer.value = merged
                rmssd = if (merged.size >= 2) Hrv.rmssd(merged) else null
            }
    }

    // Session clock — ticks only while running.
    LaunchedEffect(running) {
        if (!running) return@LaunchedEffect
        while (true) {
            delay(1000)
            sessionSeconds += 1
        }
    }

    // The breath engine: alternate phases, firing the haptic cue at the START of
    // each phase (1 pulse on inhale, 2 on exhale) — mirrors BreathingView.armPhase.
    LaunchedEffect(running, pace) {
        if (!running) return@LaunchedEffect
        while (true) {
            // Inhale: cue, then hold for the inhale duration.
            phase = Phase.Inhale
            viewModel.buzz(loops = 1)
            delay((pace.inhale * 1000).toLong())
            // Exhale: cue, then hold for the exhale duration.
            phase = Phase.Exhale
            viewModel.buzz(loops = 2)
            delay((pace.exhale * 1000).toLong())
            breathCount += 1
        }
    }

    DisposableEffect(Unit) { onDispose { running = false } }

    ScreenScaffold(
        title = "Breathe",
        subtitle = "Haptic-paced breathing · watch your HRV respond",
    ) {
        // Status row.
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            StatePill(
                if (running) "Session live" else "Ready",
                tone = if (running) StrandTone.Accent else StrandTone.Neutral,
                pulsing = running,
            )
            Spacer(Modifier.width(8.dp))
            if (live.bonded) {
                StatePill("Haptics on", tone = StrandTone.Positive)
            } else {
                StatePill("Visual only", tone = StrandTone.Warning)
            }
            Spacer(Modifier.weight(1f))
            Text(timeString(sessionSeconds), style = WarbFitType.number(15f), color = Palette.textPrimary)
            Spacer(Modifier.width(6.dp))
            Text("$breathCount breaths", style = WarbFitType.captionNumber, color = Palette.textSecondary)
        }

        // The orb card.
        WarbFitCard(padding = 24.dp) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Overline(pace.label)
                    Spacer(Modifier.weight(1f))
                    Text(
                        String.format(Locale.US, "%.1f br/min", pace.bpm),
                        style = WarbFitType.captionNumber, color = Palette.textSecondary,
                    )
                }

                BreathingOrb(progress = orbProgress, bpm = bpm, modifier = Modifier.height(280.dp))

                Text(
                    text = if (running) phaseWord(phase) else pace.tagline,
                    style = WarbFitType.subhead,
                    color = if (running) Palette.accent else Palette.textSecondary,
                )

                SegmentedPillControl(
                    items = Pace.entries.toList(),
                    selection = pace,
                    label = { it.label },
                    onSelect = { pace = it },
                )
            }
        }

        // Controls.
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap), modifier = Modifier.fillMaxWidth()) {
            Button(
                onClick = {
                    running = !running
                    if (running) { sessionSeconds = 0; breathCount = 0 }
                },
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (running) Palette.statusCritical else Palette.accent,
                    contentColor = Palette.surfaceBase,
                ),
            ) {
                Icon(
                    if (running) Icons.Filled.Stop else Icons.Filled.PlayArrow,
                    contentDescription = null,
                    modifier = Modifier.padding(end = 6.dp),
                )
                Text(if (running) "Stop session" else "Start session", style = WarbFitType.headline)
            }

            OutlinedButton(
                onClick = { viewModel.buzz(loops = 1) },
                enabled = live.bonded,
                colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
            ) {
                Icon(Icons.Filled.GraphicEq, contentDescription = null, modifier = Modifier.padding(end = 6.dp))
                Text("Test buzz", style = WarbFitType.body)
            }
        }

        // Readout tiles.
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            ReadoutTile(
                modifier = Modifier.weight(1f),
                label = "Heart rate",
                value = bpm?.toString() ?: "—",
                unit = "bpm",
                accent = Palette.metricRose,
                caption = if (live.worn) "Live" else "Strap not worn",
            )
            ReadoutTile(
                modifier = Modifier.weight(1f),
                label = "HRV (RMSSD)",
                value = rmssd?.let { String.format(Locale.US, "%.0f", it) } ?: "—",
                unit = "ms",
                accent = Palette.metricPurple,
                caption = if (rrBuffer.value.isEmpty()) "Waiting for R-R" else "Last ${rrBuffer.value.size} beats",
            )
            ReadoutTile(
                modifier = Modifier.weight(1f),
                label = "Pace",
                value = String.format(Locale.US, "%.1f", pace.bpm),
                unit = "br/min",
                accent = Palette.accent,
                caption = String.format(Locale.US, "%.0f / %.0fs", pace.inhale, pace.exhale),
            )
        }

        // Coherence estimate.
        CoherenceCard(rmssd)

        if (!live.bonded) HapticHint()
    }
}

// MARK: - Breathing orb

@Composable
private fun BreathingOrb(progress: Float, bpm: Int?, modifier: Modifier = Modifier) {
    val minScale = 0.42f
    val scale = minScale + (1f - minScale) * progress
    Box(
        modifier = modifier
            .fillMaxWidth()
            .aspectRatio(1f),
        contentAlignment = Alignment.Center,
    ) {
        // Static guide ring at the inhale extent.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .clip(CircleShape)
                .border(1.dp, Palette.hairline, CircleShape),
        )
        // Outer halo.
        Box(
            modifier = Modifier
                .fillMaxWidth(scale * 1.35f)
                .aspectRatio(1f)
                .clip(CircleShape)
                .background(
                    Brush.radialGradient(
                        colors = listOf(Palette.accent.copy(alpha = 0.22f), Color.Transparent),
                    ),
                ),
        )
        // Orb body — soft accent gradient.
        Box(
            modifier = Modifier
                .fillMaxWidth(scale)
                .aspectRatio(1f)
                .clip(CircleShape)
                .background(
                    Brush.radialGradient(
                        colors = listOf(
                            Palette.accentHover.copy(alpha = 0.85f),
                            Palette.accent.copy(alpha = 0.55f),
                            Palette.accentMuted.copy(alpha = 0.85f),
                        ),
                    ),
                )
                .border(1.dp, Palette.accent.copy(alpha = 0.45f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(bpm?.toString() ?: "—", style = WarbFitType.number(40f), color = Palette.textPrimary)
                Text("BPM", style = WarbFitType.footnote.copy(letterSpacing = 0.8.sp), color = Palette.textTertiary)
            }
        }
    }
}

// MARK: - Readout tile

@Composable
private fun ReadoutTile(
    label: String,
    value: String,
    unit: String,
    accent: Color,
    caption: String,
    modifier: Modifier = Modifier,
) {
    WarbFitCard(modifier = modifier.height(Metrics.tileHeight), padding = 14.dp) {
        Column {
            Overline(label)
            Spacer(Modifier.weight(1f))
            Row(verticalAlignment = Alignment.Bottom) {
                Text(value, style = WarbFitType.number(26f), color = accent, maxLines = 1)
                Spacer(Modifier.width(4.dp))
                Text(unit, style = WarbFitType.caption, color = Palette.textTertiary)
            }
            Text(
                caption, style = WarbFitType.footnote, color = Palette.textTertiary,
                maxLines = 1, modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

// MARK: - Coherence card

@Composable
private fun CoherenceCard(rmssd: Double?) {
    val frac = (rmssd?.let { (it / 120.0).coerceIn(0.0, 1.0) } ?: 0.0).toFloat()
    val (label, tone) = coherenceState(rmssd)
    WarbFitCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Overline("Coherence estimate")
                Spacer(Modifier.weight(1f))
                StatePill(label, tone = tone)
            }
            // Normalized bar — RMSSD 0..120ms → 0..1.
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(10.dp)
                    .clip(RoundedCornerShape(50))
                    .background(Palette.surfaceInset),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(frac.coerceAtLeast(0.02f))
                        .height(10.dp)
                        .clip(RoundedCornerShape(50))
                        .background(
                            Brush.horizontalGradient(
                                listOf(Palette.accent.copy(alpha = 0.7f), Palette.accentHover),
                            ),
                        ),
                )
            }
            Text(
                "Estimate only — a higher RMSSD while paced usually means your parasympathetic \"rest\" branch is engaging. It is not a clinical reading; trends over a session matter more than any single number.",
                style = WarbFitType.footnote, color = Palette.textTertiary,
            )
        }
    }
}

private fun coherenceState(rmssd: Double?): Pair<String, StrandTone> = when {
    rmssd == null -> "No data" to StrandTone.Neutral
    rmssd < 20 -> "Building" to StrandTone.Warning
    rmssd < 45 -> "Settling" to StrandTone.Neutral
    rmssd < 80 -> "Coherent" to StrandTone.Positive
    else -> "Deep calm" to StrandTone.Positive
}

// MARK: - Haptic hint

@Composable
private fun HapticHint() {
    val shape = RoundedCornerShape(Metrics.cardRadius)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Palette.statusWarning.copy(alpha = 0.08f), shape)
            .border(1.dp, Palette.statusWarning.copy(alpha = 0.25f), shape)
            .padding(14.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Filled.GraphicEq, contentDescription = null, tint = Palette.statusWarning)
        Text(
            "Connect your strap for haptic guidance — you'll feel one pulse on the inhale, two on the exhale, so you can breathe with your eyes closed.",
            style = WarbFitType.footnote, color = Palette.textSecondary,
        )
    }
}

private fun phaseWord(phase: Phase): String = when (phase) {
    Phase.Inhale -> "Breathe in…"
    Phase.Exhale -> "Breathe out…"
}

private fun timeString(total: Int): String =
    String.format(Locale.US, "%02d:%02d", total / 60, total % 60)
