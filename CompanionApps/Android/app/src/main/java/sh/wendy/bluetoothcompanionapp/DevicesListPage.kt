package sh.wendy.bluetoothcompanionapp

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesListPage(
    scanner: BLEScanner = viewModel()
) {
    val context = LocalContext.current
    val devices by scanner.devices.collectAsState()
    val isScanning by scanner.isScanning.collectAsState()
    val bluetoothState by scanner.bluetoothState.collectAsState()

    var searchText by remember { mutableStateOf("") }
    var permissionsRequested by remember { mutableStateOf(false) }

    val requiredPermissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        arrayOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.ACCESS_FINE_LOCATION
        )
    } else {
        arrayOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION
        )
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        val allGranted = permissions.values.all { it }
        if (allGranted) {
            scanner.setPermissionGranted()
            scanner.startScanning()
        } else {
            scanner.setPermissionDenied()
        }
    }

    LaunchedEffect(Unit) {
        scanner.initialize(context)
    }

    LaunchedEffect(bluetoothState, permissionsRequested) {
        if (bluetoothState == BluetoothState.READY && !isScanning) {
            scanner.startScanning()
        } else if (bluetoothState == BluetoothState.UNKNOWN && !permissionsRequested) {
            permissionsRequested = true
            permissionLauncher.launch(requiredPermissions)
        }
    }

    val filteredDevices = remember(devices, searchText) {
        val sorted = devices.values.sortedByDescending { it.rssi }
        if (searchText.isEmpty()) {
            sorted
        } else {
            sorted.filter { it.matchesFuzzySearch(searchText) }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("BLE Devices") },
                actions = {
                    IconButton(onClick = { scanner.clearDevices() }) {
                        Icon(Icons.Default.Delete, contentDescription = "Clear")
                    }
                    IconButton(onClick = { scanner.toggleScanning() }) {
                        if (isScanning) {
                            Icon(Icons.Default.Stop, contentDescription = "Stop")
                        } else {
                            Icon(Icons.Default.Sensors, contentDescription = "Scan")
                        }
                    }
                }
            )
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
        ) {
            // Search bar
            OutlinedTextField(
                value = searchText,
                onValueChange = { searchText = it },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                placeholder = { Text("Search devices...") },
                leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                trailingIcon = {
                    if (searchText.isNotEmpty()) {
                        IconButton(onClick = { searchText = "" }) {
                            Icon(Icons.Default.Clear, contentDescription = "Clear search")
                        }
                    }
                },
                singleLine = true
            )

            when {
                bluetoothState == BluetoothState.NO_PERMISSION -> {
                    BluetoothUnavailableContent(
                        title = "Bluetooth Permission Required",
                        message = "This app needs Bluetooth permission to discover nearby BLE devices. Please enable Bluetooth access in Settings.",
                        showSettingsButton = true,
                        onOpenSettings = {
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.fromParts("package", context.packageName, null)
                            }
                            context.startActivity(intent)
                        }
                    )
                }
                bluetoothState == BluetoothState.DISABLED -> {
                    BluetoothUnavailableContent(
                        title = "Bluetooth Disabled",
                        message = "Please enable Bluetooth to scan for devices.",
                        showSettingsButton = true,
                        onOpenSettings = {
                            val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
                            context.startActivity(intent)
                        }
                    )
                }
                bluetoothState == BluetoothState.UNSUPPORTED -> {
                    BluetoothUnavailableContent(
                        title = "Bluetooth Unsupported",
                        message = "This device does not support Bluetooth LE.",
                        showSettingsButton = false,
                        onOpenSettings = {}
                    )
                }
                filteredDevices.isEmpty() && !isScanning -> {
                    EmptyStateContent(onStartScan = { scanner.startScanning() })
                }
                else -> {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(vertical = 8.dp)
                    ) {
                        if (isScanning) {
                            item {
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(16.dp),
                                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    CircularProgressIndicator(modifier = Modifier.size(20.dp))
                                    Text(
                                        "Scanning for devices...",
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                        }

                        if (filteredDevices.isNotEmpty()) {
                            item {
                                Text(
                                    "${filteredDevices.size} device${if (filteredDevices.size == 1) "" else "s"} found",
                                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }

                        items(filteredDevices, key = { it.address }) { device ->
                            DeviceRow(device = device)
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun DeviceRow(device: BLEDevice) {
    val rssiColor = when {
        device.rssi >= -50 -> Color(0xFF4CAF50) // Green
        device.rssi >= -60 -> Color(0xFF2196F3) // Blue
        device.rssi >= -70 -> Color(0xFFFF9800) // Orange
        else -> Color(0xFFF44336) // Red
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // RSSI indicator circle
        Box(
            modifier = Modifier
                .size(44.dp)
                .background(rssiColor.copy(alpha = 0.15f), CircleShape),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                Icons.Default.Wifi,
                contentDescription = null,
                tint = rssiColor,
                modifier = Modifier.size(24.dp)
            )
        }

        // Device info
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    device.displayName,
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                if (device.isConnectable) {
                    Icon(
                        Icons.Default.Link,
                        contentDescription = "Connectable",
                        tint = Color(0xFF4CAF50),
                        modifier = Modifier.size(16.dp)
                    )
                }
            }

            if (device.serviceUuids.isNotEmpty()) {
                Text(
                    device.serviceUuids.joinToString(", ") { it.uuid.toString().take(8) },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }

            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text(
                    "RSSI: ${device.rssi} dBm",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
                )
                device.txPowerLevel?.let { txPower ->
                    Text(
                        "TX: $txPower",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
                    )
                }
                if (device.manufacturerData != null) {
                    Icon(
                        Icons.Default.Business,
                        contentDescription = "Has manufacturer data",
                        modifier = Modifier.size(12.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
                    )
                }
            }
        }

        // RSSI value and description
        Column(
            horizontalAlignment = Alignment.End
        ) {
            Text(
                "${device.rssi}",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = rssiColor
            )
            Text(
                device.rssiDescription,
                style = MaterialTheme.typography.labelSmall,
                color = rssiColor
            )
        }
    }
}

@Composable
fun BluetoothUnavailableContent(
    title: String,
    message: String,
    showSettingsButton: Boolean,
    onOpenSettings: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(
            Icons.Default.BluetoothDisabled,
            contentDescription = null,
            modifier = Modifier.size(64.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.height(16.dp))
        Text(
            title,
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onSurface
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 16.dp)
        )
        if (showSettingsButton) {
            Spacer(modifier = Modifier.height(24.dp))
            Button(onClick = onOpenSettings) {
                Text("Open Settings")
            }
        }
    }
}

@Composable
fun EmptyStateContent(onStartScan: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(
            Icons.Default.Sensors,
            contentDescription = null,
            modifier = Modifier.size(64.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.height(16.dp))
        Text(
            "No Devices",
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onSurface
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            "Start scanning to discover nearby BLE devices.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.height(24.dp))
        Button(onClick = onStartScan) {
            Text("Start Scanning")
        }
    }
}
