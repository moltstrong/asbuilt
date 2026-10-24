package com.moltstrong.asbuilt.core.recon

import kotlinx.serialization.Serializable
import java.io.File
import java.io.FileInputStream
import java.io.RandomAccessFile
import java.security.MessageDigest

@Serializable
data class ReconChunk(val index: Int, val fileName: String, val bytes: Int, val sha256: String)

@Serializable
data class ReconChunkPlan(val totalBytes: Long, val sha256: String, val chunkSize: Int, val chunks: List<ReconChunk>)

/** Mirrors iOS ReconChunker: whole-file sha + `chunk-<n>.bin` files cut last-first (needs one chunk of extra disk). */
object ReconChunker {
    /** What the phone uses: small enough that a dropped mobile connection loses seconds, not minutes. */
    const val CHUNK_SIZE = 8 * 1024 * 1024
    const val MAX_IN_FLIGHT = 3

    fun chunkCount(totalBytes: Long, chunkSize: Int): Int {
        if (totalBytes <= 0 || chunkSize <= 0) return 0
        return ((totalBytes + chunkSize - 1) / chunkSize).toInt()
    }

    /** Inclusive byte range of chunk [index]. */
    fun range(index: Int, totalBytes: Long, chunkSize: Int): LongRange {
        val start = index.toLong() * chunkSize
        val end = minOf(start + chunkSize, totalBytes)
        return start until end
    }

    fun chunkFileName(index: Int) = "chunk-$index.bin"

    fun sha256(file: File, isCancelled: () -> Boolean = { false }): String {
        val md = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buf = ByteArray(1 shl 20)
            while (true) {
                if (isCancelled()) throw java.util.concurrent.CancellationException()
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().toHex()
    }

    fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).toHex()

    /**
     * Hashes [zip], then cuts it into chunk files in [dir], last chunk first, truncating the zip after
     * each cut so the extra disk needed is one chunk, not a full copy. The zip is gone afterwards.
     */
    fun split(zip: File, dir: File, chunkSize: Int = CHUNK_SIZE, isCancelled: () -> Boolean = { false }): ReconChunkPlan {
        dir.mkdirs()
        val total = zip.length()
        if (total <= 0) throw ReconFatal("The photo archive is empty.")
        val whole = sha256(zip, isCancelled)
        val count = chunkCount(total, chunkSize)
        val chunks = ArrayList<ReconChunk>(count)
        RandomAccessFile(zip, "rw").use { raf ->
            val buf = ByteArray(1 shl 20)
            for (index in count - 1 downTo 0) {
                if (isCancelled()) throw java.util.concurrent.CancellationException()
                val r = range(index, total, chunkSize)
                val out = File(dir, chunkFileName(index))
                out.delete()
                val md = MessageDigest.getInstance("SHA-256")
                raf.seek(r.first)
                var left = (r.last - r.first + 1).toInt()
                out.outputStream().use { w ->
                    while (left > 0) {
                        val n = raf.read(buf, 0, minOf(left, buf.size))
                        if (n <= 0) throw ReconFatal("The photo archive ended early.")
                        md.update(buf, 0, n)
                        w.write(buf, 0, n)
                        left -= n
                    }
                }
                chunks.add(ReconChunk(index, out.name, (r.last - r.first + 1).toInt(), md.digest().toHex()))
                raf.setLength(r.first)
            }
        }
        zip.delete()
        return ReconChunkPlan(total, whole, chunkSize, chunks.sortedBy { it.index })
    }
}

fun ByteArray.toHex(): String {
    val hex = "0123456789abcdef"
    val sb = StringBuilder(size * 2)
    for (b in this) {
        val v = b.toInt() and 0xff
        sb.append(hex[v ushr 4]).append(hex[v and 0x0f])
    }
    return sb.toString()
}
