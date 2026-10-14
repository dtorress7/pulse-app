package com.pulseapp.android.data

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "user_profile")
data class UserProfile(
    @PrimaryKey val id: Int = 0,
    val birthdayMillis: Long,
    val weightKg: Float,
    val heightCm: Float,
    val sex: String,
    val vo2Max: Double? = null,
    val vo2MaxUpdatedDate: String? = null // "yyyy-MM-dd" de la última vez que se recalculó
) {
    fun ageYears(): Int {
        val now = System.currentTimeMillis()
        val diffMillis = now - birthdayMillis
        return (diffMillis / (365.25 * 24 * 60 * 60 * 1000)).toInt()
    }
}
