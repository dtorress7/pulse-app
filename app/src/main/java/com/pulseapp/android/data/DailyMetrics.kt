package com.pulseapp.android.data

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "daily_metrics")
data class DailyMetrics(
    @PrimaryKey val date: String,
    val restingHr: Int?,
    val avgHrv: Double?,
    val sleepMinutes: Int?,
    val strain: Double?,
    val vo2Max: Double?,
    val caloriesKcal: Double?,
    val sleepStartMinuteOfDay: Int? = null,
    val sleepEndMinuteOfDay: Int? = null,
    val sleepEfficiencyPct: Int? = null,
    val respiratoryRate: Double? = null
)
