package net.wilsonschwegler.warbfit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

// MARK: - OnboardingScreen
//
// The app's first-run experience. macOS has a full paged OnboardingWizard (welcome →
// what-it-does → expectations → bluetooth → wear → scan → bond → profile → import → done);
// Android had NO onboarding at all. This is the calm, single-scroll Android equivalent:
//
//  • a welcome header — large "WarbFit", the "all your data, none of the cloud" line, and a
//    one-line intro (the macOS WelcomeStep copy)
//  • the SAME four expectation cards used in the changelog sheet and the macOS
//    ExpectationsStep (AppChangelog.expectations), so the honest framing lands up front
//  • a primary "Get started" button → onFinished()
//
// Pairing is deliberately NOT handled here — the Live screen + ConnectionHelp own scanning
// and bonding. This screen only sets expectations and hands off. Built from the locked
// design system (Surface(surfaceBase), WarbFitType, Palette, WarbFitCard, the expectation row
// styling mirrored from WhatsNewSheet's ExpectationsCard).

@Composable
fun OnboardingScreen(onFinished: () -> Unit) {
    Surface(
        modifier = Modifier.fillMaxSize(),
        color = Palette.surfaceBase,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 28.dp, vertical = 40.dp),
            verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap),
        ) {
            WelcomeHeader()

            Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                AppChangelog.expectations.forEach { e ->
                    ExpectationCard(e)
                }
            }

            Spacer(Modifier.height(4.dp))

            Button(
                onClick = onFinished,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Palette.accent,
                    contentColor = Palette.surfaceBase,
                ),
                contentPadding = ButtonDefaults.ContentPadding,
            ) {
                Text("Get started", style = WarbFitType.headline)
            }
        }
    }
}

// MARK: - Welcome header (mirrors the macOS WelcomeStep copy)

@Composable
private fun WelcomeHeader() {
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Spacer(Modifier.height(8.dp))
        Text(
            "WarbFit",
            style = WarbFitType.display(64f),
            color = Palette.textPrimary,
        )
        Text(
            "all your data, none of the cloud",
            style = WarbFitType.title2,
            color = Palette.textSecondary,
            textAlign = TextAlign.Center,
        )
        Text(
            "A private window into your recovery, sleep and strain — read straight from your strap, kept only on this phone.",
            style = WarbFitType.body,
            color = Palette.textTertiary,
            textAlign = TextAlign.Center,
        )
    }
}

// MARK: - Expectation card (one inset card per expectation — icon + title + body)
//
// Mirrors the macOS ExpectationsStep rows (surfaceRaised well + hairline border) and the
// WhatsNewSheet expectation styling, so the framing reads identically across surfaces.

@Composable
private fun ExpectationCard(e: AppChangelog.Expectation) {
    val shape = RoundedCornerShape(14.dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Palette.surfaceRaised)
            .border(1.dp, Palette.hairline, shape)
            .padding(14.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            e.icon,
            contentDescription = null,
            tint = Palette.accent,
            modifier = Modifier
                .padding(top = 2.dp)
                .size(22.dp),
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Text(e.title, style = WarbFitType.headline, color = Palette.textPrimary)
            Text(e.body, style = WarbFitType.subhead, color = Palette.textSecondary)
        }
    }
}
