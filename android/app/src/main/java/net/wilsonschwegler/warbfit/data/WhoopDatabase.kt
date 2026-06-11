package net.wilsonschwegler.warbfit.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

/**
 * Local Room database — the Android port of the GRDB store in
 * Packages/WhoopStore (Database.swift schema). Holds phone-collected raw streams
 * AND the offline cache of server-computed derived metrics.
 *
 * The schema bundles every Swift migration (v1..v9) into a single fresh shape, since the
 * Android app starts from an empty store (no in-place migration from a prior Android version).
 * version 2 adds the v8 journal/workout/appleDaily caches; fallbackToDestructiveMigration()
 * (below) rebuilds the file rather than crashing, which is safe on this fresh, user-less app.
 * exportSchema = false: no schema JSON is emitted.
 */
@Database(
    entities = [
        DeviceRow::class,
        HrSample::class,
        RrInterval::class,
        EventRow::class,
        BatterySample::class,
        Spo2Sample::class,
        SkinTempSample::class,
        RespSample::class,
        GravitySample::class,
        DailyMetric::class,
        SleepSession::class,
        MetricSeriesRow::class,
        JournalEntry::class,
        WorkoutRow::class,
        AppleDaily::class,
    ],
    version = 2,
    exportSchema = false,
)
abstract class WhoopDatabase : RoomDatabase() {
    abstract fun whoopDao(): WhoopDao

    companion object {
        const val DB_NAME = "warbfit_whoop.db"

        @Volatile
        private var instance: WhoopDatabase? = null

        /** Process-wide singleton. Safe to call from any thread. */
        fun get(context: Context): WhoopDatabase =
            instance ?: synchronized(this) {
                instance ?: build(context.applicationContext).also { instance = it }
            }

        /**
         * Close and forget the singleton so all file handles on [DB_NAME] are released.
         * The next [get] call rebuilds against whatever file is on disk — used by
         * [DataBackup.importFrom] to swap the database file underneath the app.
         */
        fun close() {
            synchronized(this) {
                instance?.close()
                instance = null
            }
        }

        private fun build(appContext: Context): WhoopDatabase =
            Room.databaseBuilder(appContext, WhoopDatabase::class.java, DB_NAME)
                // Schema only ever moves forward from a fresh install; if a future entity
                // change bumps the version, rebuild rather than crash on a missing migration.
                .fallbackToDestructiveMigration()
                .build()
    }
}
