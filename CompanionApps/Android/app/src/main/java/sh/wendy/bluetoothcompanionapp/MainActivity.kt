package sh.wendy.bluetoothcompanionapp

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import sh.wendy.bluetoothcompanionapp.ui.theme.BluetoothCompanionAppTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            BluetoothCompanionAppTheme {
                DevicesListPage()
            }
        }
    }
}
