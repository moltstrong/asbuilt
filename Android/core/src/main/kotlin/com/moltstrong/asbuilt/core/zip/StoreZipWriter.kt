package com.moltstrong.asbuilt.core.zip

import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.util.zip.CRC32

/**
 * Streaming STORE (uncompressed) zip writer, like AsBuiltCore's StreamingZipWriter: JPEGs are already
 * compressed, so STORE keeps packing fast and the Mac's `ditto`/`unzip` both accept it. ZIP64 records are
 * written automatically when the archive passes 4 GB / 65535 entries.
 *
 * Each entry is CRC'd in a first pass and then copied, so the local header has exact sizes (no data
 * descriptors; maximally compatible).
 */
class StoreZipWriter(private val out: OutputStream) : AutoCloseable {
    constructor(file: File) : this(BufferedOutputStream(FileOutputStream(file), 1 shl 16))

    private class Entry(val name: ByteArray, val crc: Long, val size: Long, val offset: Long, val dosTime: Int, val dosDate: Int)

    private val entries = ArrayList<Entry>()
    private var offset = 0L
    private var closed = false

    val bytesWritten: Long get() = offset

    fun addFile(name: String, file: File, timeMs: Long = file.lastModified()) {
        val crc = CRC32()
        file.inputStream().use { crc.updateFrom(it) }
        file.inputStream().use { addStream(name, it, file.length(), crc.value, timeMs) }
    }

    fun addBytes(name: String, data: ByteArray, timeMs: Long = System.currentTimeMillis()) {
        val crc = CRC32().apply { update(data) }
        addStream(name, data.inputStream(), data.size.toLong(), crc.value, timeMs)
    }

    private fun addStream(name: String, input: InputStream, size: Long, crc: Long, timeMs: Long) {
        check(!closed) { "zip closed" }
        require(name.isNotEmpty() && !name.startsWith("/") && !name.contains("..")) { "bad entry name" }
        val nameBytes = name.toByteArray(Charsets.UTF_8)
        val (dosTime, dosDate) = dos(timeMs)
        val zip64 = size >= 0xFFFFFFFFL || offset >= 0xFFFFFFFFL
        val local = ByteSink()
        local.u32(0x04034b50)
        local.u16(if (zip64) 45 else 20)
        local.u16(0x0800) // UTF-8 names
        local.u16(0) // STORE
        local.u16(dosTime); local.u16(dosDate)
        local.u32(crc)
        local.u32(if (zip64) 0xFFFFFFFFL else size)
        local.u32(if (zip64) 0xFFFFFFFFL else size)
        local.u16(nameBytes.size)
        local.u16(if (zip64) 20 else 0)
        local.bytes(nameBytes)
        if (zip64) {
            local.u16(0x0001); local.u16(16); local.u64(size); local.u64(size)
        }
        val start = offset
        write(local.toByteArray())
        val buf = ByteArray(1 shl 16)
        var copied = 0L
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            out.write(buf, 0, n)
            copied += n
        }
        check(copied == size) { "entry $name changed while zipping ($copied != $size)" }
        offset += copied
        entries.add(Entry(nameBytes, crc, size, start, dosTime, dosDate))
    }

    override fun close() {
        if (closed) return
        closed = true
        val cdStart = offset
        for (e in entries) {
            val needs64 = e.size >= 0xFFFFFFFFL || e.offset >= 0xFFFFFFFFL
            val c = ByteSink()
            c.u32(0x02014b50)
            c.u16(if (needs64) 45 else 20) // made by
            c.u16(if (needs64) 45 else 20) // needed
            c.u16(0x0800); c.u16(0)
            c.u16(e.dosTime); c.u16(e.dosDate)
            c.u32(e.crc)
            c.u32(if (needs64) 0xFFFFFFFFL else e.size)
            c.u32(if (needs64) 0xFFFFFFFFL else e.size)
            c.u16(e.name.size)
            c.u16(if (needs64) 28 else 0)
            c.u16(0); c.u16(0); c.u16(0)
            c.u32(0)
            c.u32(if (needs64) 0xFFFFFFFFL else e.offset)
            c.bytes(e.name)
            if (needs64) {
                c.u16(0x0001); c.u16(24); c.u64(e.size); c.u64(e.size); c.u64(e.offset)
            }
            write(c.toByteArray())
        }
        val cdSize = offset - cdStart
        val zip64 = entries.size >= 0xFFFF || cdStart >= 0xFFFFFFFFL || cdSize >= 0xFFFFFFFFL
        if (zip64) {
            val z = ByteSink()
            val z64Start = offset
            z.u32(0x06064b50); z.u64(44); z.u16(45); z.u16(45); z.u32(0); z.u32(0)
            z.u64(entries.size.toLong()); z.u64(entries.size.toLong()); z.u64(cdSize); z.u64(cdStart)
            z.u32(0x07064b50); z.u32(0); z.u64(z64Start); z.u32(1)
            write(z.toByteArray())
        }
        val end = ByteSink()
        end.u32(0x06054b50); end.u16(0); end.u16(0)
        end.u16(minOf(entries.size, 0xFFFF)); end.u16(minOf(entries.size, 0xFFFF))
        end.u32(if (zip64) 0xFFFFFFFFL else cdSize)
        end.u32(if (zip64) 0xFFFFFFFFL else cdStart)
        end.u16(0)
        write(end.toByteArray())
        out.flush()
        out.close()
    }

    private fun write(b: ByteArray) {
        out.write(b)
        offset += b.size
    }

    private fun dos(timeMs: Long): Pair<Int, Int> {
        val c = java.util.Calendar.getInstance().apply { timeInMillis = timeMs }
        val year = maxOf(1980, c.get(java.util.Calendar.YEAR))
        val time = (c.get(java.util.Calendar.HOUR_OF_DAY) shl 11) or (c.get(java.util.Calendar.MINUTE) shl 5) or (c.get(java.util.Calendar.SECOND) / 2)
        val date = ((year - 1980) shl 9) or ((c.get(java.util.Calendar.MONTH) + 1) shl 5) or c.get(java.util.Calendar.DAY_OF_MONTH)
        return time to date
    }

    private class ByteSink {
        private val b = java.io.ByteArrayOutputStream()
        fun u16(v: Int) { b.write(v and 0xff); b.write((v ushr 8) and 0xff) }
        fun u32(v: Long) { for (i in 0 until 4) b.write(((v ushr (8 * i)) and 0xff).toInt()) }
        fun u32(v: Int) = u32(v.toLong() and 0xFFFFFFFFL)
        fun u64(v: Long) { for (i in 0 until 8) b.write(((v ushr (8 * i)) and 0xff).toInt()) }
        fun bytes(a: ByteArray) = b.write(a)
        fun toByteArray(): ByteArray = b.toByteArray()
    }
}

private fun CRC32.updateFrom(input: InputStream) {
    val buf = ByteArray(1 shl 16)
    while (true) {
        val n = input.read(buf)
        if (n < 0) break
        update(buf, 0, n)
    }
}
