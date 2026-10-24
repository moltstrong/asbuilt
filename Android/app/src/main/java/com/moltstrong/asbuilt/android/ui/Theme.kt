package com.moltstrong.asbuilt.android.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

object AsBuiltColors {
    val Good = Color(0xFF34C759)
    val Warning = Color(0xFFFF9F0A)
    val Problem = Color(0xFFFF453A)
    val Accent = Color(0xFF0A84FF)
}

private val scheme = darkColorScheme(
    primary = AsBuiltColors.Accent,
    onPrimary = Color.White,
    secondary = Color(0xFF64D2FF),
    background = Color(0xFF000000),
    onBackground = Color(0xFFF2F2F7),
    surface = Color(0xFF0B0B0F),
    onSurface = Color(0xFFF2F2F7),
    surfaceVariant = Color(0xFF2C2C2E),
    onSurfaceVariant = Color(0xFFAEAEB2),
    surfaceContainerHigh = Color(0xFF1C1C1E),
    surfaceContainer = Color(0xFF151517),
    outlineVariant = Color(0xFF48484A),
    error = AsBuiltColors.Problem,
)

/** Root Surface sets LocalContentColor = onBackground, so plain Text on non-Scaffold screens is readable. */
@Composable
fun AsBuiltTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = scheme) {
        androidx.compose.material3.Surface(color = scheme.background, contentColor = scheme.onBackground, content = content)
    }
}
