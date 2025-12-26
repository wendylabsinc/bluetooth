package sh.wendy.bluetoothcompanionapp

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.ParcelUuid
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

enum class BluetoothState {
    UNKNOWN,
    UNSUPPORTED,
    DISABLED,
    NO_PERMISSION,
    READY
}

class BLEScanner : ViewModel() {

    private val _devices = MutableStateFlow<Map<String, BLEDevice>>(emptyMap())
    val devices: StateFlow<Map<String, BLEDevice>> = _devices.asStateFlow()

    private val _isScanning = MutableStateFlow(false)
    val isScanning: StateFlow<Boolean> = _isScanning.asStateFlow()

    private val _bluetoothState = MutableStateFlow(BluetoothState.UNKNOWN)
    val bluetoothState: StateFlow<BluetoothState> = _bluetoothState.asStateFlow()

    private var bluetoothAdapter: BluetoothAdapter? = null
    private var bluetoothLeScanner: BluetoothLeScanner? = null

    val sortedDevices: List<BLEDevice>
        get() = _devices.value.values.sortedByDescending { it.rssi }

    val canScan: Boolean
        get() = _bluetoothState.value == BluetoothState.READY

    val isUnauthorized: Boolean
        get() = _bluetoothState.value == BluetoothState.NO_PERMISSION

    private val scanCallback = object : ScanCallback() {
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            val scanRecord = result.scanRecord

            val bleDevice = BLEDevice(
                address = device.address,
                name = device.name ?: scanRecord?.deviceName ?: "",
                rssi = result.rssi,
                serviceUuids = scanRecord?.serviceUuids ?: emptyList(),
                manufacturerData = scanRecord?.bytes,
                txPowerLevel = scanRecord?.txPowerLevel,
                isConnectable = result.isConnectable
            )

            _devices.update { currentDevices ->
                currentDevices + (device.address to bleDevice)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            _isScanning.value = false
        }
    }

    fun initialize(context: Context) {
        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        bluetoothAdapter = bluetoothManager?.adapter

        if (bluetoothAdapter == null) {
            _bluetoothState.value = BluetoothState.UNSUPPORTED
            return
        }

        bluetoothLeScanner = bluetoothAdapter?.bluetoothLeScanner
        updateBluetoothState()
    }

    fun updateBluetoothState() {
        _bluetoothState.value = when {
            bluetoothAdapter == null -> BluetoothState.UNSUPPORTED
            !bluetoothAdapter!!.isEnabled -> BluetoothState.DISABLED
            bluetoothLeScanner == null -> BluetoothState.DISABLED
            else -> BluetoothState.READY
        }

        // Refresh scanner reference when Bluetooth is enabled
        if (bluetoothAdapter?.isEnabled == true) {
            bluetoothLeScanner = bluetoothAdapter?.bluetoothLeScanner
        }
    }

    fun setPermissionDenied() {
        _bluetoothState.value = BluetoothState.NO_PERMISSION
    }

    fun setPermissionGranted() {
        updateBluetoothState()
    }

    @SuppressLint("MissingPermission")
    fun startScanning() {
        if (!canScan || _isScanning.value) return

        _devices.value = emptyMap()
        _isScanning.value = true

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        bluetoothLeScanner?.startScan(null, settings, scanCallback)
    }

    @SuppressLint("MissingPermission")
    fun stopScanning() {
        if (_isScanning.value) {
            bluetoothLeScanner?.stopScan(scanCallback)
            _isScanning.value = false
        }
    }

    fun toggleScanning() {
        if (_isScanning.value) {
            stopScanning()
        } else {
            startScanning()
        }
    }

    fun clearDevices() {
        _devices.value = emptyMap()
    }

    override fun onCleared() {
        super.onCleared()
        stopScanning()
    }
}
