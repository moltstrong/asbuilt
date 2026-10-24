package com.moltstrong.asbuilt.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.moltstrong.asbuilt.android.BuildConfig
import com.moltstrong.asbuilt.android.data.ServerSettings
import com.moltstrong.asbuilt.core.recon.ReconClient
import kotlinx.coroutines.launch

/** Server settings: built-in (CI) config status, optional encrypted override, connection test, texture size. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(settings: ServerSettings, lastCrash: String?, onBack: () -> Unit) {
    var url by remember { mutableStateOf(settings.overrideBaseUrl) }
    var key by remember { mutableStateOf(settings.overrideApiKey) }
    var discovery by remember { mutableStateOf(settings.overrideDiscoveryUrl) }
    var texture by remember { mutableIntStateOf(settings.glbTextureSize) }
    var status by remember { mutableStateOf<String?>(null) }
    var testing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            SectionLabel("Build server")
            Text(
                if (settings.builtInConfigured) "This build is preconfigured for your Mac. Leave the fields empty to use it."
                else "This build has no server built in. Paste your Mac's address and key.",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedTextField(
                value = url, onValueChange = { url = it }, label = { Text("Server URL (https://…)") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = key, onValueChange = { key = it }, label = { Text("API key") }, singleLine = true,
                visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = discovery, onValueChange = { discovery = it }, label = { Text("Discovery URL (optional)") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), modifier = Modifier.fillMaxWidth(),
            )
            if (!settings.encryptedStorageAvailable) {
                Text("Encrypted storage isn't available on this phone, so overrides can't be saved.", color = AsBuiltColors.Warning,
                    style = MaterialTheme.typography.bodySmall)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Button(onClick = {
                    val bad = url.isNotBlank() && !ReconClient.isValidBase(url.trim())
                    if (bad) {
                        status = "The server URL must start with https://"
                    } else {
                        settings.overrideBaseUrl = url
                        settings.overrideApiKey = key
                        settings.overrideDiscoveryUrl = discovery
                        status = "Saved."
                    }
                }) { Text("Save") }
                OutlinedButton(enabled = !testing, onClick = {
                    testing = true
                    status = "Testing…"
                    scope.launch {
                        status = try {
                            val client = ReconClient(settings.config(), userAgent = "AsBuilt-Android/${BuildConfig.VERSION_NAME}")
                            val base = client.baseUrl()
                            val r = client.health(base)
                            when (r.code) {
                                200 -> "Connected to your Mac."
                                401 -> "The Mac rejected the key."
                                else -> "The Mac answered ${r.code}."
                            }
                        } catch (e: Exception) {
                            ReconClient.offlineMessage(e) ?: "Couldn't reach the Mac (${e.javaClass.simpleName})."
                        }
                        testing = false
                    }
                }) { Text("Test connection") }
                if (settings.hasOverride) {
                    OutlinedButton(onClick = {
                        settings.clearOverride(); url = ""; key = ""; discovery = ""; status = "Using the built-in server."
                    }) { Text("Reset") }
                }
            }
            status?.let { Text(it, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold) }

            Spacer(Modifier.height(8.dp))
            SectionLabel("Model textures on this phone")
            Text(
                "The Mac bakes 8K textures. 4K looks nearly identical on a phone screen and needs a quarter of the memory.",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ServerSettings.TEXTURE_CHOICES.forEach { size ->
                    FilterChip(selected = texture == size, onClick = { texture = size; settings.glbTextureSize = size },
                        label = { Text("${size / 1024}K") })
                }
            }

            Spacer(Modifier.height(8.dp))
            SectionLabel("About")
            Text("AsBuilt for Android ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", style = MaterialTheme.typography.bodyMedium)
            if (lastCrash != null) {
                Text("Last crash report:", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(lastCrash.take(600), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}
