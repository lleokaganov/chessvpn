package app.chess.twomove

import android.content.Intent
import android.net.VpnService
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "twomove/vpn"
    private var channel: MethodChannel? = null
    private var pending: MethodChannel.Result? = null
    private var pendingConfig: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "connect" -> {
                    pendingConfig = call.argument<String>("config")
                    val intent = VpnService.prepare(this)
                    if (intent != null) {
                        pending = result
                        startActivityForResult(intent, REQ_VPN)
                    } else {
                        startTunnel()
                        result.success("starting")
                    }
                }
                "disconnect" -> { stopTunnel(); result.success("stopping") }
                "status" -> result.success(TunnelService.lastStatus)
                else -> result.notImplemented()
            }
        }
        // push live status from the service up to Dart
        TunnelService.statusListener = { s -> runOnUiThread { channel?.invokeMethod("status", s) } }
    }

    private fun startTunnel() {
        val i = Intent(this, TunnelService::class.java).setAction(TunnelService.ACTION_START)
        pendingConfig?.let { i.putExtra("config", it) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i) else startService(i)
    }

    private fun stopTunnel() {
        startService(Intent(this, TunnelService::class.java).setAction(TunnelService.ACTION_STOP))
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_VPN) {
            if (resultCode == RESULT_OK) {
                startTunnel()
                pending?.success("starting")
            } else {
                pending?.error("denied", "vpn permission denied", null)
            }
            pending = null
        }
    }

    companion object { private const val REQ_VPN = 1001 }
}
