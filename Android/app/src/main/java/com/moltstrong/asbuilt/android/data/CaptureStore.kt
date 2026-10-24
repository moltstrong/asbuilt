package com.moltstrong.asbuilt.android.data

import com.moltstrong.asbuilt.core.recon.FolderBuildHost
import com.moltstrong.asbuilt.core.recon.ReconJson
import com.moltstrong.asbuilt.core.recon.RemoteBuild
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import java.io.File
import java.util.UUID

@Serializable
data class CaptureMeta(
    val id: String,
    val title: String,
    val createdAtMs: Long,
    val photoCount: Int = 0,
    val grade: String? = null,
    val gradeFix: String? = null,
    /** Demo/sample entries (screenshots, the bundled sample model). */
    val isSample: Boolean = false,
)

/** One row of the job list: capture + its Mac build. */
data class CaptureItem(val meta: CaptureMeta, val build: RemoteBuild?, val dir: File) {
    val modelFile: File get() = File(dir, RemoteBuild.MODEL_FILE)
    val hasModel: Boolean get() = modelFile.isFile && modelFile.length() > 0
}

/**
 * Captures on disk (files/captures/<id>/): capture.json, Images/IMG_0001.jpg…, poses.json,
 * coach-report.txt, build.json (RemoteBuild), model.glb. Persisted locally so the job list survives
 * restarts; every read tolerates partial/corrupt files.
 */
class CaptureStore(val root: File) {
    private val _items = MutableStateFlow<List<CaptureItem>>(emptyList())
    val items: StateFlow<List<CaptureItem>> = _items.asStateFlow()

    init {
        root.mkdirs()
        refresh()
    }

    fun dir(id: String) = File(root, id)

    @Synchronized
    fun refresh() {
        val list = (root.listFiles() ?: emptyArray()).filter { it.isDirectory }.mapNotNull { d -> load(d) }
        _items.value = list.sortedByDescending { it.meta.createdAtMs }
    }

    private fun load(d: File): CaptureItem? = try {
        val meta = ReconJson.decodeFromString<CaptureMeta>(File(d, "capture.json").readText())
        val build = File(d, "build.json").takeIf { it.isFile }?.let {
            try {
                ReconJson.decodeFromString<RemoteBuild>(it.readText())
            } catch (_: Exception) {
                null
            }
        }
        CaptureItem(meta, build, d)
    } catch (_: Exception) {
        null
    }

    fun item(id: String): CaptureItem? = _items.value.firstOrNull { it.meta.id == id } ?: load(dir(id))

    @Synchronized
    fun create(title: String, isSample: Boolean = false, id: String = UUID.randomUUID().toString().uppercase()): CaptureMeta {
        val meta = CaptureMeta(id, title, System.currentTimeMillis(), isSample = isSample)
        val d = dir(id)
        File(d, "Images").mkdirs()
        writeMeta(meta)
        refresh()
        return meta
    }

    @Synchronized
    fun writeMeta(meta: CaptureMeta) {
        val d = dir(meta.id)
        d.mkdirs()
        val tmp = File(d, "capture.json.tmp")
        tmp.writeText(ReconJson.encodeToString(meta))
        if (!tmp.renameTo(File(d, "capture.json"))) {
            File(d, "capture.json").delete(); tmp.renameTo(File(d, "capture.json"))
        }
    }

    fun host(id: String, onSaved: (RemoteBuild) -> Unit = {}): FolderBuildHost? {
        val item = item(id) ?: return null
        return FolderBuildHost(item.dir, id, item.meta.title) { b ->
            onSaved(b)
            updateBuildInList(id, b)
        }
    }

    /** Cheap in-memory update for progress ticks (no directory rescan). */
    fun updateBuildInList(id: String, build: RemoteBuild) {
        val list = _items.value
        val idx = list.indexOfFirst { it.meta.id == id }
        if (idx < 0) {
            refresh(); return
        }
        _items.value = list.toMutableList().also { it[idx] = it[idx].copy(build = build) }
    }

    fun saveBuild(id: String, build: RemoteBuild) {
        host(id)?.save(build)
    }

    @Synchronized
    fun delete(id: String) {
        dir(id).deleteRecursively()
        refresh()
    }
}
