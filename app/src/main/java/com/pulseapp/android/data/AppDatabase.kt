package com.pulseapp.android.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(
    entities = [UserProfile::class, DailyMetrics::class, ActivitySession::class],
    version = 10,
    exportSchema = false
)
abstract class AppDatabase : RoomDatabase() {

    abstract fun userProfileDao(): UserProfileDao
    abstract fun dailyMetricsDao(): DailyMetricsDao
    abstract fun activitySessionDao(): ActivitySessionDao

    companion object {
        @Volatile private var INSTANCE: AppDatabase? = null

        private val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS daily_metrics (
                        date TEXT NOT NULL PRIMARY KEY,
                        restingHr INTEGER,
                        avgHrv REAL,
                        sleepMinutes INTEGER,
                        strain REAL,
                        vo2Max REAL,
                        caloriesKcal REAL
                    )
                    """.trimIndent()
                )
            }
        }

        private val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS activity_sessions (
                        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                        startMillis INTEGER NOT NULL,
                        endMillis INTEGER NOT NULL,
                        avgHr INTEGER NOT NULL,
                        maxHr INTEGER NOT NULL,
                        strain REAL NOT NULL,
                        caloriesKcal REAL NOT NULL,
                        minutesZone1 INTEGER NOT NULL,
                        minutesZone2 INTEGER NOT NULL,
                        minutesZone3 INTEGER NOT NULL,
                        minutesZone4 INTEGER NOT NULL,
                        minutesZone5 INTEGER NOT NULL
                    )
                    """.trimIndent()
                )
            }
        }

        private val MIGRATION_3_4 = object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE activity_sessions ADD COLUMN type TEXT NOT NULL DEFAULT 'Sin clasificar'")
                db.execSQL("ALTER TABLE activity_sessions ADD COLUMN autoDetected INTEGER NOT NULL DEFAULT 0")
            }
        }

        private val MIGRATION_4_5 = object : Migration(4, 5) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE user_profile ADD COLUMN vo2Max REAL")
                db.execSQL("ALTER TABLE user_profile ADD COLUMN vo2MaxUpdatedDate TEXT")
            }
        }

        private val MIGRATION_5_6 = object : Migration(5, 6) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE daily_metrics ADD COLUMN sleepStartMinuteOfDay INTEGER")
                db.execSQL("ALTER TABLE daily_metrics ADD COLUMN sleepEndMinuteOfDay INTEGER")
                db.execSQL("ALTER TABLE daily_metrics ADD COLUMN sleepEfficiencyPct INTEGER")
            }
        }

        private val MIGRATION_6_7 = object : Migration(6, 7) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE daily_metrics ADD COLUMN respiratoryRate REAL")
            }
        }

        private val MIGRATION_7_8 = object : Migration(7, 8) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE activity_sessions ADD COLUMN minutesZone0 INTEGER NOT NULL DEFAULT 0")
            }
        }

        /** 17/10: fases de cada noche para las tendencias semanales de Sueño. Solo añade columnas: no se pierde nada. */
        private val MIGRATION_8_9 = object : Migration(8, 9) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE daily_metrics ADD COLUMN lightMinutes INTEGER")
                db.execSQL("ALTER TABLE daily_metrics ADD COLUMN deepMinutes INTEGER")
                db.execSQL("ALTER TABLE daily_metrics ADD COLUMN remMinutes INTEGER")
                db.execSQL("ALTER TABLE daily_metrics ADD COLUMN awakeMinutes INTEGER")
                db.execSQL("ALTER TABLE daily_metrics ADD COLUMN wakeEpisodes INTEGER")
                db.execSQL("ALTER TABLE daily_metrics ADD COLUMN latencyMinutes INTEGER")
            }
        }

        /** 23/10: notas oficiales de WHOOP en los días importados del export. Solo añade columnas: no se pierde nada. */
        private val MIGRATION_9_10 = object : Migration(9, 10) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE daily_metrics ADD COLUMN whoopRecovery INTEGER")
                db.execSQL("ALTER TABLE daily_metrics ADD COLUMN whoopSleepScore INTEGER")
                db.execSQL("ALTER TABLE daily_metrics ADD COLUMN whoopConsistency INTEGER")
                db.execSQL("ALTER TABLE daily_metrics ADD COLUMN whoopSleepNeed INTEGER")
            }
        }

        fun getInstance(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "pulseapp.db"
                )
                    .addMigrations(MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5, MIGRATION_5_6, MIGRATION_6_7, MIGRATION_7_8, MIGRATION_8_9, MIGRATION_9_10)
                    .build().also { INSTANCE = it }
            }
        }
    }
}
