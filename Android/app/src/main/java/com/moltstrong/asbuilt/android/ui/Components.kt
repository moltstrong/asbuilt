package com.moltstrong.asbuilt.android.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.moltstrong.asbuilt.core.coach.CoverageSnapshot
import com.moltstrong.asbuilt.core.recon.RemoteBuild

private val stepLabels = listOf("Pack", "Send", "Build", "Download")
private val stepIcons = listOf(Icons.Filled.Inventory2, Icons.Filled.CloudUpload, Icons.Filled.Memory, Icons.Filled.Download)

/** Pack / Send / Build / Download progress card (same states and copy as the iOS app). */
@Composable
fun BuildProgressCard(
    build: RemoteBuild,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
    onCancel: (() -> Unit)? = null,
    onOpen: (() -> Unit)? = null,
) {
    val failed = build.phase == RemoteBuild.Phase.FAILED || build.phase == RemoteBuild.Phase.CANCELLED
    val waiting = build.phase == RemoteBuild.Phase.WAITING_FOR_MAC
    val done = build.phase == RemoteBuild.Phase.DONE
    val accent = when {
        failed -> MaterialTheme.colorScheme.error
        waiting -> AsBuiltColors.Warning
        done -> AsBuiltColors.Good
        else -> MaterialTheme.colorScheme.primary
    }
    val progress by animateFloatAsState(build.overallFraction.toFloat(), label = "progress")
    Card(
        modifier = modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
        shape = RoundedCornerShape(18.dp),
    ) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    when {
                        failed -> Icons.Filled.ErrorOutline
                        waiting -> Icons.Filled.WifiOff
                        done -> Icons.Filled.CheckCircle
                        else -> stepIcons[build.step.coerceIn(0, 3)]
                    },
                    contentDescription = null, tint = accent, modifier = Modifier.size(22.dp),
                )
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(build.headline, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(
                        build.detailLine, style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 3, overflow = TextOverflow.Ellipsis,
                    )
                }
                if (!failed && !done) {
                    Text("${(progress * 100).toInt()}%", style = MaterialTheme.typography.titleMedium, color = accent, fontWeight = FontWeight.Bold)
                }
            }
            if (!failed) {
                Spacer(Modifier.height(12.dp))
                LinearProgressIndicator(
                    progress = { progress }, color = accent, trackColor = MaterialTheme.colorScheme.surfaceVariant,
                    strokeCap = StrokeCap.Round, modifier = Modifier.fillMaxWidth().height(8.dp).clip(RoundedCornerShape(4.dp)),
                )
                Spacer(Modifier.height(12.dp))
                StepRow(build.step, accent)
            }
            if (onRetry != null || onCancel != null || onOpen != null) {
                Row(Modifier.fillMaxWidth().padding(top = 6.dp), horizontalArrangement = Arrangement.End) {
                    if (onCancel != null) TextButton(onClick = onCancel) { Text("Cancel") }
                    if (onRetry != null) TextButton(onClick = onRetry) { Text("Retry") }
                    if (onOpen != null) TextButton(onClick = onOpen) { Text("View in 3D") }
                }
            }
        }
    }
}

@Composable
private fun StepRow(step: Int, accent: Color) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        stepLabels.forEachIndexed { i, label ->
            val state = when {
                step > i -> 2
                step == i -> 1
                else -> 0
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier.size(10.dp).clip(CircleShape).background(
                        when (state) {
                            2 -> AsBuiltColors.Good
                            1 -> accent
                            else -> MaterialTheme.colorScheme.outlineVariant
                        },
                    ),
                )
                Spacer(Modifier.width(5.dp))
                Text(
                    label, style = MaterialTheme.typography.labelMedium,
                    color = if (state == 0) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                    fontWeight = if (state == 1) FontWeight.Bold else FontWeight.Normal,
                )
            }
        }
    }
}

/**
 * Coverage ring: 12 directions x 3 heights around the object (inner ring = low, outer = high), the
 * current cell outlined, the requested next band pulsing in the guidance chip.
 */
@Composable
fun CoverageRing(snapshot: CoverageSnapshot, modifier: Modifier = Modifier) {
    val empty = Color.White.copy(alpha = 0.18f)
    val good = AsBuiltColors.Good
    val current = Color.White
    Canvas(modifier) {
        val c = Offset(size.width / 2, size.height / 2)
        val maxR = size.minDimension / 2
        val ringW = maxR * 0.2f
        for (band in 0 until 3) {
            val r = maxR * 0.45f + band * (ringW + maxR * 0.04f)
            for (s in 0 until 12) {
                val fill = snapshot.fill[band][s]
                // Sector 0 at the top, clockwise (azimuth increases clockwise seen from above).
                val start = -90f + s * 30f + 1.5f
                val color = if (fill >= 1f) good else lerp(empty, good.copy(alpha = 0.55f), fill)
                drawArc(color, start, 27f, false, topLeft = Offset(c.x - r, c.y - r), size = Size(2 * r, 2 * r),
                    style = Stroke(width = ringW))
                if (snapshot.currentBand?.ordinal == band && snapshot.currentSector == s) {
                    drawArc(current, start, 27f, false, topLeft = Offset(c.x - r, c.y - r), size = Size(2 * r, 2 * r),
                        style = Stroke(width = ringW * 0.28f))
                }
            }
        }
    }
}

private fun lerp(a: Color, b: Color, t: Float) = Color(
    a.red + (b.red - a.red) * t, a.green + (b.green - a.green) * t, a.blue + (b.blue - a.blue) * t, a.alpha + (b.alpha - a.alpha) * t,
)

@Composable
fun SectionLabel(text: String, icon: ImageVector? = null) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 6.dp)) {
        if (icon != null) {
            Icon(icon, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(6.dp))
        }
        Text(text.uppercase(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
