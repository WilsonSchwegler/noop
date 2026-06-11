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
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Vibration
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
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.delay
import java.util.Locale
import kotlin.math.max
import kotlin.math.min

// MARK: - IntervalsScreen (ported from Strand/Screens/IntervalTimerView.swift)
//
// Silent haptic HIIT interval timer. Train hands-free: the strap buzzes every
// transition so you never have to look at the screen. Strong triple-buzz at the
// start of each WORK block, a short single buzz into REST, a 3-2-1 tick on the last
// seconds of every phase, and a long 5-loop buzz when the whole session finishes.
// With no strap bonded it still works as a big glanceable visual timer (no haptics).

private enum class IntervalPhase(val label: String) {
    Work("WORK"),
    Rest("REST"),
    Done("DONE"),
}

/**
 * Silent haptic HIIT interval timer: configurable work/rest/rounds, a big glanceable
 * countdown ring, phase + round read-out, Start/Pause/Reset, a session overview, and
 * a strap buzz on every transition (triple into WORK, single into REST, a 3-2-1 tick,
 * a long 5-loop buzz on completion). Buzz cues are skipped entirely when no strap is
 * bonded, so it degrades cleanly to a pure visual timer.
 */
@Composable
fun IntervalsScreen(vm: AppViewModel) {
    val live by vm.live.collectAsStateWithLifecycle()

    // Config (persisted only in-view), mirroring the macOS defaults.
    var workSeconds by remember { mutableIntStateOf(30) }
    var restSeconds by remember { mutableIntStateOf(15) }
    var rounds by remember { mutableIntStateOf(8) }

    // Run state.
    var phase by remember { mutableStateOf(IntervalPhase.Work) }
    var currentRound by remember { mutableIntStateOf(1) }
    var remaining by remember { mutableIntStateOf(30) }   // seconds left in the current phase
    var running by remember { mutableStateOf(false) }
    var elapsed by remember { mutableIntStateOf(0) }      // total elapsed seconds across the session

    val isFinished = phase == IntervalPhase.Done

    // Buzz only when bonded — keep it a pure visual tool otherwise.
    fun buzz(loops: Int) {
        if (live.bonded) vm.buzz(loops)
    }

    fun resetToStart() {
        phase = IntervalPhase.Work
        currentRound = 1
        remaining = max(1, workSeconds)
        elapsed = 0
    }

    // Editing config while paused snaps the run state back to a clean start, matching
    // the macOS onChange handlers. While running, config is locked (steppers disabled).
    LaunchedEffect(workSeconds, restSeconds, rounds) {
        if (currentRound > rounds) currentRound = rounds
        if (!running) resetToStart()
    }

    // 1 Hz engine — runs only while `running`. Drives the countdown, the 3-2-1 tick,
    // and phase/round advancement with the appropriate buzz cue at each transition.
    LaunchedEffect(running) {
        if (!running) return@LaunchedEffect
        while (true) {
            delay(1000)
            if (isFinished) return@LaunchedEffect

            // 3-2-1 tick on the last seconds of the current phase.
            if (remaining in 1..3) buzz(loops = 1)

            if (remaining > 1) {
                remaining -= 1
                elapsed += 1
                continue
            }

            // remaining hits 0 — advance phase/round.
            elapsed += 1
            when (phase) {
                IntervalPhase.Work -> {
                    if (currentRound >= rounds) {
                        // Last work block finished → session complete.
                        phase = IntervalPhase.Done
                        remaining = 0
                        running = false
                        buzz(loops = 5)            // long completion cue
                        return@LaunchedEffect
                    } else {
                        phase = IntervalPhase.Rest
                        remaining = max(1, restSeconds)
                        buzz(loops = 1)            // short cue into rest
                    }
                }
                IntervalPhase.Rest -> {
                    currentRound += 1
                    phase = IntervalPhase.Work
                    remaining = max(1, workSeconds)
                    buzz(loops = 3)                // strong cue into work
                }
                IntervalPhase.Done -> return@LaunchedEffect
            }
        }
    }

    DisposableEffect(Unit) { onDispose { running = false } }

    // Derived geometry.
    val phaseDuration = when (phase) {
        IntervalPhase.Work -> max(1, workSeconds)
        IntervalPhase.Rest -> max(1, restSeconds)
        IntervalPhase.Done -> 1
    }
    val intervalProgress = ((phaseDuration - remaining).toDouble() / phaseDuration.toDouble())
        .coerceIn(0.0, 1.0)
    val totalPlanned =
        if (rounds > 0) workSeconds * rounds + restSeconds * max(0, rounds - 1) else 0
    val sessionProgress =
        if (totalPlanned > 0) (elapsed.toDouble() / totalPlanned.toDouble()).coerceIn(0.0, 1.0) else 0.0
    val phaseColor = when (phase) {
        IntervalPhase.Work -> Palette.accent
        IntervalPhase.Rest -> Palette.metricCyan
        IntervalPhase.Done -> Palette.statusPositive
    }
    val atCleanStart = !running && remaining == phaseDuration &&
        currentRound == 1 && phase == IntervalPhase.Work && elapsed == 0

    fun toggleRunning() {
        if (isFinished) return
        if (running) {
            running = false
        } else {
            val startingFresh = phase == IntervalPhase.Work && currentRound == 1 &&
                remaining == max(1, workSeconds) && elapsed == 0
            running = true
            if (startingFresh) buzz(loops = 3)     // opening WORK cue
        }
    }

    ScreenScaffold(
        title = "Interval Timer",
        subtitle = "Silent haptic HIIT — the strap buzzes the transitions",
    ) {
        // --- Status row ---
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            if (live.bonded) {
                StatePill("Buzz cues on", tone = StrandTone.Positive)
            } else {
                StatePill("Connect strap for buzz cues", tone = StrandTone.Warning)
            }
            Spacer(Modifier.weight(1f))
            when {
                running -> StatePill("Running", tone = StrandTone.Accent, pulsing = true)
                isFinished -> StatePill("Complete", tone = StrandTone.Positive)
                else -> StatePill("Paused", tone = StrandTone.Neutral, showsDot = false)
            }
        }

        // --- Stage card: the big glanceable face ---
        WarbFitCard(padding = 24.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
                // Phase + round line.
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        phase.label,
                        style = WarbFitType.number(34f).copy(letterSpacing = 2.sp),
                        color = phaseColor,
                    )
                    Spacer(Modifier.weight(1f))
                    Row(verticalAlignment = Alignment.Bottom) {
                        Overline("Round")
                        Spacer(Modifier.width(6.dp))
                        Text(
                            min(currentRound, rounds).toString(),
                            style = WarbFitType.number(20f),
                            color = Palette.textPrimary,
                        )
                        Spacer(Modifier.width(2.dp))
                        Text(
                            "/ $rounds",
                            style = WarbFitType.number(20f),
                            color = Palette.textTertiary,
                        )
                    }
                }

                // The ring + countdown.
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(260.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    IntervalRing(
                        progress = if (isFinished) 1.0 else intervalProgress,
                        color = phaseColor,
                    )
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(
                            if (isFinished) "✓" else remaining.toString(),
                            style = WarbFitType.number(96f, weight = androidx.compose.ui.text.font.FontWeight.Bold),
                            color = if (isFinished) Palette.statusPositive else Palette.textPrimary,
                        )
                        Text(
                            if (isFinished) "SESSION DONE" else "SECONDS",
                            style = WarbFitType.footnote.copy(letterSpacing = 1.2.sp),
                            color = Palette.textTertiary,
                        )
                    }
                }

                // Controls.
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Button(
                        onClick = {
                            if (isFinished) resetToStart()
                            toggleRunning()
                        },
                        modifier = Modifier.weight(1f),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent,
                            contentColor = Palette.surfaceBase,
                        ),
                    ) {
                        Icon(
                            if (running) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                            contentDescription = null,
                            modifier = Modifier.padding(end = 6.dp),
                        )
                        Text(
                            if (running) "Pause" else if (isFinished) "Restart" else "Start",
                            style = WarbFitType.headline,
                        )
                    }
                    OutlinedButton(
                        onClick = {
                            running = false
                            resetToStart()
                        },
                        modifier = Modifier.weight(1f),
                        enabled = !atCleanStart,
                        colors = ButtonDefaults.outlinedButtonColors(
                            contentColor = Palette.textSecondary,
                        ),
                    ) {
                        Icon(
                            Icons.Filled.Refresh,
                            contentDescription = null,
                            modifier = Modifier.padding(end = 6.dp),
                        )
                        Text("Reset", style = WarbFitType.headline)
                    }
                }

                if (!live.bonded) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            Icons.Filled.Vibration,
                            contentDescription = null,
                            tint = Palette.textTertiary,
                            modifier = Modifier.size(14.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            "Bond your strap on the Live screen to feel the transitions hands-free.",
                            style = WarbFitType.footnote,
                            color = Palette.textTertiary,
                            textAlign = TextAlign.Center,
                        )
                    }
                }
            }
        }

        // --- Overview card: elapsed / planned ---
        WarbFitCard {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.Bottom,
                ) {
                    Overline("Session")
                    Spacer(Modifier.weight(1f))
                    Text(
                        "${timeString(elapsed)} / ${timeString(totalPlanned)}",
                        style = WarbFitType.bodyNumber,
                        color = Palette.textPrimary,
                    )
                }

                // Slim total-session progress bar.
                val animatedSession by animateFloatAsState(
                    targetValue = sessionProgress.toFloat(),
                    animationSpec = tween(900, easing = Motion.easeOut),
                    label = "session",
                )
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(8.dp)
                        .clip(RoundedCornerShape(50))
                        .background(Palette.surfaceInset),
                ) {
                    if (animatedSession > 0f) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth(animatedSession)
                                .height(8.dp)
                                .clip(RoundedCornerShape(50))
                                .background(Palette.accent),
                        )
                    }
                }

                Row(modifier = Modifier.fillMaxWidth()) {
                    OverviewStat(Modifier.weight(1f), "Work", "${workSeconds}s", Palette.accent)
                    OverviewStat(Modifier.weight(1f), "Rest", "${restSeconds}s", Palette.metricCyan)
                    OverviewStat(Modifier.weight(1f), "Rounds", rounds.toString(), Palette.textPrimary)
                    OverviewStat(
                        Modifier.weight(1f), "Remaining",
                        timeString(max(0, totalPlanned - elapsed)), Palette.textSecondary,
                    )
                }
            }
        }

        // --- Config card ---
        WarbFitCard {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Overline("Configure")
                ConfigStepper(
                    title = "Work", unit = "sec", value = workSeconds,
                    range = 5..600, step = 5, tint = Palette.accent, enabled = !running,
                    onChange = { workSeconds = it },
                )
                Divider()
                ConfigStepper(
                    title = "Rest", unit = "sec", value = restSeconds,
                    range = 5..600, step = 5, tint = Palette.metricCyan, enabled = !running,
                    onChange = { restSeconds = it },
                )
                Divider()
                ConfigStepper(
                    title = "Rounds", unit = null, value = rounds,
                    range = 1..30, step = 1, tint = Palette.textPrimary, enabled = !running,
                    onChange = { rounds = it },
                )
                if (running) {
                    Text(
                        "Pause to change work, rest, or rounds.",
                        style = WarbFitType.footnote,
                        color = Palette.textTertiary,
                    )
                }
            }
        }
    }
}

// MARK: - Countdown ring (mirrors IntervalTimerView.intervalRing)
//
// A full 360° ring: a thick surface-inset track, a 1px hairline inset, and a sweep
// of the phase color filled to `progress`, drawn from 12 o'clock clockwise with a
// round cap, animating to each new progress value.

@Composable
private fun IntervalRing(
    progress: Double,
    color: Color,
    modifier: Modifier = Modifier,
    diameter: androidx.compose.ui.unit.Dp = 240.dp,
    lineWidth: androidx.compose.ui.unit.Dp = 18.dp,
) {
    val animated by animateFloatAsState(
        targetValue = progress.toFloat().coerceIn(0f, 1f),
        animationSpec = tween(900, easing = Motion.easeOut),
        label = "ringFill",
    )
    Box(
        modifier = modifier.size(diameter),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(diameter)
                .drawBehind {
                    val stroke = lineWidth.toPx()
                    val radius = (min(size.width, size.height) - stroke) / 2f
                    val center = Offset(size.width / 2f, size.height / 2f)
                    val topLeft = Offset(center.x - radius, center.y - radius)
                    val arcSize = Size(radius * 2f, radius * 2f)
                    val cap = Stroke(width = stroke, cap = StrokeCap.Round)

                    // Full-circle track.
                    drawArc(
                        color = Palette.surfaceInset,
                        startAngle = 0f,
                        sweepAngle = 360f,
                        useCenter = false,
                        topLeft = topLeft,
                        size = arcSize,
                        style = Stroke(width = stroke),
                    )
                    // Hairline inset ring.
                    drawCircle(
                        color = Palette.hairline,
                        radius = radius - stroke / 2f - 8f,
                        center = center,
                        style = Stroke(width = 1f),
                    )
                    // Progress sweep (from 12 o'clock, clockwise).
                    if (animated > 0.001f) {
                        val sweep = Brush.sweepGradient(
                            0f to color.copy(alpha = 0.6f),
                            1f to color,
                            center = center,
                        )
                        drawArc(
                            brush = sweep,
                            startAngle = -90f,
                            sweepAngle = 360f * animated,
                            useCenter = false,
                            topLeft = topLeft,
                            size = arcSize,
                            style = cap,
                        )
                    }
                },
        )
    }
}

// MARK: - Overview stat cell (mirrors IntervalTimerView.overviewStat)

@Composable
private fun OverviewStat(
    modifier: Modifier,
    label: String,
    value: String,
    color: Color,
) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(label.uppercase(), style = WarbFitType.footnote, color = Palette.textTertiary)
        Text(value, style = WarbFitType.number(18f), color = color, maxLines = 1)
    }
}

// MARK: - Config stepper (mirrors IntervalTimerView.configStepper)
//
// A titled row with the current value and -/+ steppers, clamped to `range`. Disabled
// (dimmed, non-interactive) while a session is running.

@Composable
private fun ConfigStepper(
    title: String,
    unit: String?,
    value: Int,
    range: IntRange,
    step: Int,
    tint: Color,
    enabled: Boolean,
    onChange: (Int) -> Unit,
) {
    val dim = if (enabled) 1f else Palette.disabledOpacity
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = WarbFitType.headline, color = Palette.textPrimary.copy(alpha = dim))
            Text(
                "${range.first}–${range.last}${unit?.let { " $it" } ?: ""} · step $step",
                style = WarbFitType.footnote,
                color = Palette.textTertiary.copy(alpha = dim),
            )
        }
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                value.toString(),
                style = WarbFitType.number(24f),
                color = tint.copy(alpha = dim),
                textAlign = TextAlign.End,
                modifier = Modifier.width(44.dp),
            )
            if (unit != null) {
                Spacer(Modifier.width(4.dp))
                Text(
                    unit,
                    style = WarbFitType.caption,
                    color = Palette.textTertiary.copy(alpha = dim),
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        StepperButton(
            icon = Icons.Filled.Remove,
            description = "Decrease $title",
            enabled = enabled && value > range.first,
            tint = tint,
        ) { onChange((value - step).coerceIn(range.first, range.last)) }
        Spacer(Modifier.width(8.dp))
        StepperButton(
            icon = Icons.Filled.Add,
            description = "Increase $title",
            enabled = enabled && value < range.last,
            tint = tint,
        ) { onChange((value + step).coerceIn(range.first, range.last)) }
    }
}

@Composable
private fun StepperButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    description: String,
    enabled: Boolean,
    tint: Color,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(10.dp)
    val content = if (enabled) tint else Palette.textTertiary.copy(alpha = Palette.disabledOpacity)
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        shape = shape,
        contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp),
        colors = ButtonDefaults.outlinedButtonColors(
            contentColor = content,
            disabledContentColor = Palette.textTertiary.copy(alpha = Palette.disabledOpacity),
        ),
        modifier = Modifier
            .size(40.dp)
            .semantics { contentDescription = description },
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
    }
}

// MARK: - Divider hairline

@Composable
private fun Divider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(Palette.hairline),
    )
}

// MARK: - Formatting

private fun timeString(seconds: Int): String {
    val s = max(0, seconds)
    return String.format(Locale.US, "%d:%02d", s / 60, s % 60)
}
