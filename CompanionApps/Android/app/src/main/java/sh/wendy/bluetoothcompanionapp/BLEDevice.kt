package sh.wendy.bluetoothcompanionapp

import android.bluetooth.BluetoothDevice
import android.os.ParcelUuid

data class BLEDevice(
    val address: String,
    val name: String,
    val rssi: Int,
    val serviceUuids: List<ParcelUuid>,
    val manufacturerData: ByteArray?,
    val txPowerLevel: Int?,
    val isConnectable: Boolean,
    val discoveredAt: Long = System.currentTimeMillis()
) {
    val displayName: String
        get() = name.ifEmpty { "Unknown" }

    val rssiDescription: String
        get() = when {
            rssi >= -50 -> "Excellent"
            rssi >= -60 -> "Good"
            rssi >= -70 -> "Fair"
            else -> "Weak"
        }

    fun matchesFuzzySearch(query: String): Boolean {
        if (query.isEmpty()) return true

        val lowercasedQuery = query.lowercase()
        val lowercasedName = displayName.lowercase()

        // Exact substring match
        if (lowercasedName.contains(lowercasedQuery)) {
            return true
        }

        // Fuzzy match: check if all characters appear in order
        var queryIndex = 0
        for (char in lowercasedName) {
            if (queryIndex < lowercasedQuery.length && char == lowercasedQuery[queryIndex]) {
                queryIndex++
            }
        }

        if (queryIndex == lowercasedQuery.length) {
            return true
        }

        // Also search in service UUIDs
        for (uuid in serviceUuids) {
            if (uuid.toString().lowercase().contains(lowercasedQuery)) {
                return true
            }
        }

        // Search in address
        if (address.lowercase().contains(lowercasedQuery)) {
            return true
        }

        return false
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as BLEDevice
        return address == other.address
    }

    override fun hashCode(): Int {
        return address.hashCode()
    }
}
