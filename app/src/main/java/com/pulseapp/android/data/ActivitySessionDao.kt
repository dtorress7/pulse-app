package com.pulseapp.android.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query

@Dao
interface ActivitySessionDao {

    @Insert
    suspend fun save(session: ActivitySession): Long
    
    @androidx.room.Update
    suspend fun update(session: ActivitySession)

    @Query("SELECT * FROM activity_sessions ORDER BY startMillis DESC")
    suspend fun getAll(): List<ActivitySession>

    @Query("SELECT * FROM activity_sessions WHERE id = :id LIMIT 1")
    suspend fun getById(id: Long): ActivitySession?
}
