package com.moltstrong.asbuilt.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.ViewInAr
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.moltstrong.asbuilt.android.data.CaptureItem
import com.moltstrong.asbuilt.core.recon.RemoteBuild
import java.text.DateFormat
import java.util.Date

/** Home: the persisted list of captures and their Mac builds. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun JobListScreen(
    items: List<CaptureItem>,
    serverConfigured: Boolean,
    onNewCapture: () -> Unit,
    onOpen: (CaptureItem) -> Unit,
    onRetry: (CaptureItem) -> Unit,
    onCancel: (CaptureItem) -> Unit,
    onDelete: (CaptureItem) -> Unit,
    onBuild: (CaptureItem) -> Unit,
    onSettings: () -> Unit,
) {
    var confirmDelete by remember { mutableStateOf<CaptureItem?>(null) }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("AsBuilt", fontWeight = FontWeight.Bold) },
                actions = {
                    IconButton(onClick = onSettings) { Icon(Icons.Filled.Settings, contentDescription = "Settings") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = onNewCapture,
                icon = { Icon(Icons.Filled.CameraAlt, null) },
                text = { Text("New capture") },
                containerColor = MaterialTheme.colorScheme.primary,
            )
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { pad ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(pad),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 96.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (!serverConfigured) {
                item {
                    Card(
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
                        modifier = Modifier.fillMaxWidth().clickable(onClick = onSettings),
                    ) {
                        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.Warning, null, tint = AsBuiltColors.Warning)
                            Spacer(Modifier.width(12.dp))
                            Text("No build server set. Tap to add your Mac's address and key.", style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
            }
            if (items.isEmpty()) {
                item { EmptyState() }
            }
            items(items, key = { it.meta.id }) { item ->
                CaptureRow(
                    item,
                    onOpen = { onOpen(item) },
                    onRetry = { onRetry(item) },
                    onCancel = { onCancel(item) },
                    onDelete = { confirmDelete = item },
                    onBuild = { onBuild(item) },
                )
            }
        }
    }
    confirmDelete?.let { item ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            title = { Text("Delete “${item.meta.title}”?") },
            text = { Text("The photos and the downloaded model are removed from this phone.") },
            confirmButton = {
                TextButton(onClick = { onDelete(item); confirmDelete = null }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = null }) { Text("Keep") } },
        )
    }
}

@Composable
private fun EmptyState() {
    Column(
        Modifier.fillMaxWidth().padding(top = 72.dp, start = 24.dp, end = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Filled.ViewInAr, null, Modifier.size(56.dp), tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.height(16.dp))
        Text("Scan an object", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Text(
            "Walk around it while AsBuilt takes sharp photos from every side. Your Mac turns them into a full-detail textured 3D model.",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun CaptureRow(
    item: CaptureItem,
    onOpen: () -> Unit,
    onRetry: () -> Unit,
    onCancel: () -> Unit,
    onDelete: () -> Unit,
    onBuild: () -> Unit,
) {
    val b = item.build
    Column {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.weight(1f)) {
                Text(item.meta.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                val bits = buildList {
                    add(DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(item.meta.createdAtMs)))
                    if (item.meta.photoCount > 0) add("${item.meta.photoCount} photos")
                    item.meta.grade?.let { add("grade $it") }
                }
                Text(bits.joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            IconButton(onClick = onDelete) { Icon(Icons.Filled.Delete, contentDescription = "Delete", tint = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        Spacer(Modifier.height(6.dp))
        when {
            b != null -> BuildProgressCard(
                b,
                onRetry = if (b.phase == RemoteBuild.Phase.FAILED || b.phase == RemoteBuild.Phase.CANCELLED || b.phase == RemoteBuild.Phase.WAITING_FOR_MAC) onRetry else null,
                onCancel = if (b.isActive && b.phase != RemoteBuild.Phase.DOWNLOADING) onCancel else null,
                onOpen = if (item.hasModel || (b.phase == RemoteBuild.Phase.DONE && item.meta.isSample)) onOpen else null,
            )
            item.hasModel -> Card(
                Modifier.fillMaxWidth().clickable(onClick = onOpen), shape = RoundedCornerShape(18.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
            ) {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.ViewInAr, null, tint = AsBuiltColors.Good)
                    Spacer(Modifier.width(12.dp))
                    Text("View in 3D", style = MaterialTheme.typography.titleMedium)
                }
            }
            else -> Card(
                Modifier.fillMaxWidth(), shape = RoundedCornerShape(18.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
            ) {
                Row(Modifier.padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Not built yet", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    TextButton(onClick = onBuild, enabled = item.meta.photoCount > 0) { Text("Build full detail") }
                }
            }
        }
    }
}

@Composable
fun CenteredMessage(title: String, body: String, modifier: Modifier = Modifier, action: (@Composable () -> Unit)? = null) {
    Box(modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
            Spacer(Modifier.height(10.dp))
            Text(body, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            if (action != null) {
                Spacer(Modifier.height(20.dp))
                action()
            }
        }
    }
}
