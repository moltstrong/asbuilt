package com.moltstrong.asbuilt.android.ui

import android.util.Log
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ViewInAr
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import io.github.sceneview.Scene
import io.github.sceneview.math.Position
import io.github.sceneview.node.ModelNode
import io.github.sceneview.rememberCameraManipulator
import io.github.sceneview.rememberCameraNode
import io.github.sceneview.rememberEngine
import io.github.sceneview.rememberEnvironment
import io.github.sceneview.rememberEnvironmentLoader
import io.github.sceneview.rememberMainLightNode
import io.github.sceneview.rememberModelLoader
import io.github.sceneview.rememberNodes
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel

/** Where the model comes from: a downloaded file, or a bundled asset (sample). */
sealed class ModelSource {
    data class FileSource(val file: File) : ModelSource()
    data class Asset(val path: String) : ModelSource()
}

/**
 * Filament (SceneView) viewer: orbit (one finger), zoom (pinch), pan (two fingers); lit by the bundled
 * neutral IBL + a sun light; the model is centred and scaled to fit. Loading happens off the main
 * thread (the GLB is memory-mapped), and anything that fails shows a message instead of crashing.
 */
@Composable
fun ModelViewer(source: ModelSource, modifier: Modifier = Modifier, onStatus: (String) -> Unit = {}) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val engine = rememberEngine()
    val modelLoader = rememberModelLoader(engine)
    val environmentLoader = rememberEnvironmentLoader(engine)
    val environment = rememberEnvironment(environmentLoader, isOpaque = true)
    val childNodes = rememberNodes()
    val cameraNode = rememberCameraNode(engine) { position = Position(0f, 0.15f, 1.6f) }
    val mainLight = rememberMainLightNode(engine) { intensity = 70_000f }
    var state by remember(source) { mutableStateOf<String?>("Loading model…") }
    var error by remember(source) { mutableStateOf<String?>(null) }

    LaunchedEffect(source) {
        try {
            val buffer = withContext(Dispatchers.IO) { readBuffer(source, context) }
            // Filament objects must be created on the main thread.
            val instance = modelLoader.createModelInstance(buffer)
            val node = ModelNode(modelInstance = instance, scaleToUnits = 1.0f, centerOrigin = Position(0f, 0f, 0f))
            childNodes.clear()
            childNodes.add(node)
            state = null
            Log.i("AsBuiltViewer", "model loaded: ${buffer.capacity()} bytes")
            onStatus("loaded")
        } catch (e: Throwable) {
            Log.e("AsBuiltViewer", "model load failed", e)
            error = when (e) {
                is OutOfMemoryError -> "This model is too big for this phone's memory. Build it again with 2K or 4K textures (Settings)."
                else -> "Couldn't open this model (${e.javaClass.simpleName})."
            }
            state = null
            onStatus("error")
        }
    }

    Box(modifier.background(Color(0xFF101014))) {
        if (error == null) {
            Scene(
                modifier = Modifier.fillMaxSize(),
                engine = engine,
                modelLoader = modelLoader,
                environmentLoader = environmentLoader,
                environment = environment,
                cameraNode = cameraNode,
                mainLightNode = mainLight,
                childNodes = childNodes,
                cameraManipulator = rememberCameraManipulator(
                    orbitHomePosition = Position(0f, 0.15f, 1.6f),
                    targetPosition = Position(0f, 0f, 0f),
                ),
            )
        }
        val msg = error ?: state
        if (msg != null) {
            Column(
                Modifier.align(Alignment.Center).padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                if (error == null) CircularProgressIndicator() else Icon(Icons.Filled.ViewInAr, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(12.dp))
                Text(msg, style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurface)
            }
        }
    }
}

private fun readBuffer(source: ModelSource, context: android.content.Context): ByteBuffer = when (source) {
    is ModelSource.FileSource -> RandomAccessFile(source.file, "r").use { raf ->
        // Memory-mapped: a 30-100 MB GLB never sits on the Java heap.
        raf.channel.map(FileChannel.MapMode.READ_ONLY, 0, raf.length()).order(ByteOrder.nativeOrder())
    }
    is ModelSource.Asset -> context.assets.openFd(source.path).use { fd ->
        fd.createInputStream().channel.map(FileChannel.MapMode.READ_ONLY, fd.startOffset, fd.declaredLength)
    }
}
