package com.pulseapp.android.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface DailyMetricsDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun save(metrics: DailyMetrics)

    @Query("SELECT * FROM daily_metrics WHERE date = :date LIMIT 1")
    suspend fun getByDate(date: String): DailyMetrics?

    @Query("SELECT * FROM daily_metrics ORDER BY date DESC LIMIT :days")
    suspend fun getLastDays(days: Int): List<DailyMetrics>
}
