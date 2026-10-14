package com.pulseapp.android.data

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "activity_sessions")
data class ActivitySession(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val startMillis: Long,
    val endMillis: Long,
    val avgHr: Int,
    val maxHr: Int,
    val strain: Double,
    val caloriesKcal: Double,
    val minutesZone1: Int,
    val minutesZone2: Int,
    val minutesZone3: Int,
    val minutesZone4: Int,
    val minutesZone5: Int,
    val type: String = "Sin clasificar",
    val autoDetected: Boolean = false,
    val minutesZone0: Int = 0
)
