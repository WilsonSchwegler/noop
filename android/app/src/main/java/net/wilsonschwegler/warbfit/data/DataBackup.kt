package net.wilsonschwegler.warbfit.data

import android.content.Context
import android.net.Uri
import java.io.File
import java.io.FileOutputStream
import java.io.IOException

/**
 * Whole-store EXPORT / IMPORT for device migration.
 *
 * WarbFit keeps everything on-device in a single Room/SQLite file ([TrackerDatabase.DB_NAME]).
 * Moving to a new phone therefore means moving exactly that one file. There is no cloud,
 * no account, nothing leaves the device except through these two explicit, user-driven
 * file operations (a SAF document the user picks).
 *
 * Export: checkpoint the WAL into the main db file, then byte-copy that file to the
 * chosen SAF [Uri].
 *
 * Import: validate the picked file is a SQLite database, close the live Room singleton,
 * snapshot the current db (so a bad import is recoverable), overwrite the db file with the
 * chosen one and drop the stale `-wal` / `-shm` sidecars. The caller then instructs the
 * user to restart the app so Room re-opens the new file fresh.
 */
object DataBackup {

    /** First 16 bytes of every SQLite 3 file: "SQLite format 3\0". */
    private val SQLITE_MAGIC: ByteArray =
        byteArrayOf(
            0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66,
            0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00,
        )

    /** Outcome of an [importFrom] call. On success the app must be restarted. */
    sealed interface ImportResult {
        /** The new database is in place; tell the user to relaunch WarbFit. */
        data object NeedsRestart : ImportResult

        /** Import failed and the original database is untouched. */
        data class Failed(val message: String) : ImportResult
    }

    /**
     * Copy the live database to [uri] (a writable SAF document, typically created with
     * `ActivityResultContracts.CreateDocument("application/octet-stream")`).
     *
     * Runs a `PRAGMA wal_checkpoint(TRUNCATE)` first so the single db file is fully
     * consistent — no un-checkpointed pages left in the `-wal`. Throws on failure so the
     * caller can surface the message in a toast/snackbar.
     */
    @Throws(IOException::class)
    fun exportTo(context: Context, uri: Uri) {
        val appContext = context.applicationContext

        // Fold the WAL back into the main file so a plain byte-copy is a complete snapshot.
        val db = TrackerDatabase.get(appContext)
        db.query("PRAGMA wal_checkpoint(TRUNCATE)", null).use { cursor ->
            cursor.moveToFirst()
        }

        val dbFile = appContext.getDatabasePath(TrackerDatabase.DB_NAME)
        if (!dbFile.exists()) {
            throw IOException("No database to export yet.")
        }

        val resolver = appContext.contentResolver
        val output = resolver.openOutputStream(uri)
            ?: throw IOException("Could not open the chosen file for writing.")
        output.use { out ->
            dbFile.inputStream().use { input ->
                input.copyTo(out)
            }
            out.flush()
        }
    }

    /**
     * Replace the live database with the file at [uri] (picked with
     * ActivityResultContracts.OpenDocument for any mime type).
     *
     * On any error the current database is left exactly as it was. On success the caller
     * MUST instruct the user to fully restart the app — the Room singleton has been closed
     * and the underlying file swapped, so the process needs a clean re-open.
     */
    fun importFrom(context: Context, uri: Uri): ImportResult {
        val appContext = context.applicationContext
        val resolver = appContext.contentResolver

        // 1. Validate the picked file really is a SQLite database before we touch anything.
        try {
            val header = ByteArray(SQLITE_MAGIC.size)
            val read = resolver.openInputStream(uri)?.use { input ->
                readFully(input, header)
            } ?: return ImportResult.Failed("Could not open the chosen file.")
            if (read < SQLITE_MAGIC.size || !header.contentEquals(SQLITE_MAGIC)) {
                return ImportResult.Failed("That file is not a WarbFit backup.")
            }
        } catch (e: IOException) {
            return ImportResult.Failed("Could not read the chosen file: ${e.message}")
        }

        val dbFile = appContext.getDatabasePath(TrackerDatabase.DB_NAME)
        val walFile = File(dbFile.path + "-wal")
        val shmFile = File(dbFile.path + "-shm")
        val rollbackFile = File(dbFile.path + ".import-bak")

        // 2. Close the live Room singleton so the file handles are released.
        TrackerDatabase.close()

        // 3. Snapshot the current db so a failed copy can be rolled back.
        try {
            rollbackFile.delete()
            if (dbFile.exists()) {
                dbFile.copyTo(rollbackFile, overwrite = true)
            }
        } catch (e: IOException) {
            return ImportResult.Failed("Could not back up the current data: ${e.message}")
        }

        // 4. Overwrite the db file with the chosen backup, then drop the stale sidecars.
        try {
            dbFile.parentFile?.mkdirs()
            resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(dbFile).use { out ->
                    input.copyTo(out)
                    out.flush()
                }
            } ?: throw IOException("Could not re-open the chosen file.")

            // The imported file's data lives entirely in the main db (it was checkpointed
            // on export); any leftover WAL/SHM from the old db would corrupt the new one.
            walFile.delete()
            shmFile.delete()
        } catch (e: IOException) {
            // Roll back to the snapshot so the user is never left worse off.
            runCatching {
                if (rollbackFile.exists()) {
                    rollbackFile.copyTo(dbFile, overwrite = true)
                }
            }
            rollbackFile.delete()
            return ImportResult.Failed("Import failed, your data is unchanged: ${e.message}")
        }

        rollbackFile.delete()
        return ImportResult.NeedsRestart
    }

    /** Read up to [buffer].size bytes, looping over short reads. Returns bytes read. */
    private fun readFully(input: java.io.InputStream, buffer: ByteArray): Int {
        var offset = 0
        while (offset < buffer.size) {
            val n = input.read(buffer, offset, buffer.size - offset)
            if (n < 0) break
            offset += n
        }
        return offset
    }
}
