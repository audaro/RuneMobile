package dev.audaro.runemobile

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily

/*
 * The OSRS-flavoured Compose theme for the native plugin panel / config UI (UX-XCUT-05).
 *
 * The Compose layer previously read as a generic dark-Material settings app bolted onto the well-styled
 * in-game veneers. This establishes a small, conservative theme — a warm parchment/stone/amber palette on
 * near-black surfaces + the shipped RuneScape typeface — so the Material defaults (Switch / Slider / TextField
 * accents, text colour) pick up the OSRS skin without touching the existing per-widget hardcoded colours.
 *
 * Deliberately minimal: this wires the palette + font through MaterialTheme; it does not restyle each control.
 */

// --- OSRS palette -------------------------------------------------------------------------------------------
// Warm amber/gold primary (the classic interface gold), muted stone secondary, parchment off-white text on a
// near-black stone surface. Accents are kept legible against the dark surfaces the panel already uses.
private val OsrsGold = Color(0xFFE0A33B) // primary — OSRS interface gold/amber
private val OsrsGoldDim = Color(0xFF8C6322) // primary container — a dimmer gold for filled tonals
private val OsrsStone = Color(0xFFA8997E) // secondary — muted parchment stone
private val OsrsStoneDim = Color(0xFF4A4234) // secondary container
private val OsrsParchment = Color(0xFFE8E0D0) // onSurface — warm off-white "parchment" text
private val OsrsParchmentDim = Color(0xFFB9AE97)
private val OsrsSurface = Color(0xFF1B1B1B) // near-black stone surface (matches existing 0xFF1B1B1B usage)
private val OsrsSurfaceLow = Color(0xFF141414) // the sheet body colour already used by SheetScaffold
private val OsrsInk = Color(0xFF1A140A) // onPrimary — dark ink over the gold accents
private val OsrsError = Color(0xFFE57373) // matches the existing "couldn't start" / reset red

private val OsrsColorScheme =
    darkColorScheme(
        primary = OsrsGold,
        onPrimary = OsrsInk,
        primaryContainer = OsrsGoldDim,
        onPrimaryContainer = OsrsParchment,
        secondary = OsrsStone,
        onSecondary = OsrsInk,
        secondaryContainer = OsrsStoneDim,
        onSecondaryContainer = OsrsParchment,
        tertiary = Color(0xFF80CBC4), // the teal already used for section labels / hints
        background = OsrsSurfaceLow,
        onBackground = OsrsParchment,
        surface = OsrsSurface,
        onSurface = OsrsParchment,
        surfaceVariant = OsrsSurfaceLow,
        onSurfaceVariant = OsrsParchmentDim,
        error = OsrsError,
        onError = OsrsInk,
        outline = Color(0x55E0A33B), // faint gold hairline
    )

/**
 * Load the shipped RuneScape typeface as a Compose FontFamily, falling back to the platform default if the
 * asset is missing (ChatPillView loads the same file via Typeface.createFromAsset). Loaded once per context.
 */
@Composable
private fun runeScapeFontFamily(): FontFamily? {
    val context = LocalContext.current
    return remember(context) {
        try {
            FontFamily(Font("tabassets/runescape.ttf", context.assets))
        } catch (t: Throwable) {
            null // missing/corrupt asset -> fall back to the Material default typeface gracefully
        }
    }
}

/** Material3 Typography with the RuneScape face applied to titles + default body text (when the asset loads). */
@Composable
private fun osrsTypography(): Typography {
    val rs = runeScapeFontFamily() ?: return Typography() // no asset -> stock typography, no crash
    val base = Typography()

    fun TextStyle.withRs(): TextStyle = copy(fontFamily = rs)
    return base.copy(
        // Titles + headers get the RS face for the OSRS feel; body/label keep RS too for one coherent skin.
        titleLarge = base.titleLarge.withRs(),
        titleMedium = base.titleMedium.withRs(),
        titleSmall = base.titleSmall.withRs(),
        bodyLarge = base.bodyLarge.withRs(),
        bodyMedium = base.bodyMedium.withRs(),
        bodySmall = base.bodySmall.withRs(),
        labelLarge = base.labelLarge.withRs(),
        labelMedium = base.labelMedium.withRs(),
        labelSmall = base.labelSmall.withRs(),
    )
}

/**
 * Wrap the native Compose UI (plugin panel + config sheets) so Material defaults pick up the OSRS palette + the
 * RuneScape typeface. Conservative by design: the existing per-widget colour literals are left as-is; this only
 * sets the theme defaults underneath them.
 */
@Composable
fun RuneMobileTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = OsrsColorScheme,
        typography = osrsTypography(),
        content = content,
    )
}
