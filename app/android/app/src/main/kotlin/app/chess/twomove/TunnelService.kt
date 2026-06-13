package app.chess.twomove

import android.app.Notification as AndroidNotification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.system.OsConstants
import android.util.Log
import io.nekohasekai.libbox.BoxService
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.Notification as LibboxNotification
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.io.File
import java.net.NetworkInterface as JavaNetworkInterface
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface

/**
 * Minimal sing-box (libbox) tunnel as an Android VpnService.
 * Implements the 18-method PlatformInterface of libbox v1.10.7. Reads the embedded
 * sing-box client config from assets and brings the tunnel up. This is the "engine
 * test" core; the chess UI sits on top later.
 */
class TunnelService : VpnService(), PlatformInterface {

    companion object {
        const val TAG = "TunnelService"
        const val ACTION_START = "app.chess.twomove.START"
        const val ACTION_STOP = "app.chess.twomove.STOP"
        const val CHANNEL_ID = "session"
        @Volatile var running = false
        @Volatile var lastStatus = "disconnected"
        var statusListener: ((String) -> Unit)? = null
    }

    private var boxService: BoxService? = null
    private var tunFd: ParcelFileDescriptor? = null
    private var configOverride: String? = null
    private val connectivity by lazy { getSystemService(ConnectivityManager::class.java) }
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var defaultListener: InterfaceUpdateListener? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A null intent means Android auto-restarted us after killing the process (low
        // memory). We must NOT silently resume: the original profile config is gone, so
        // we'd come up on the empty placeholder config — a tunnel-LESS service that would
        // still report "connected" while traffic flows in the CLEAR. That fail-open leak
        // is the worst outcome for a censorship tool, so stay DOWN (fail-closed) instead
        // and let the user re-arm. START_NOT_STICKY also stops Android from doing this.
        if (intent == null || intent.action == ACTION_STOP) {
            stopTunnel()
            return START_NOT_STICKY
        }
        configOverride = intent.getStringExtra("config")
        startForegroundInnocuous()
        Thread { startTunnel() }.start()
        return START_NOT_STICKY
    }

    private fun startTunnel() {
        try {
            val base = filesDir.absolutePath
            val work = File(base, "work").apply { mkdirs() }.absolutePath
            Libbox.setup(SetupOptions().apply {
                basePath = base
                workingPath = work
                tempPath = cacheDir.absolutePath
                username = ""
                isTVOS = false
                fixAndroidStack = true   // workaround "runtime: stack split at bad time" in cgo callbacks
            })
            val config = configOverride
                ?: assets.open("singbox-client.json").bufferedReader().use { it.readText() }
            val svc = Libbox.newService(config, this)
            svc.start()
            boxService = svc
            setStatus("connected")
            Log.i(TAG, "tunnel up")
        } catch (e: Exception) {
            Log.e(TAG, "start failed", e)
            setStatus("error: ${e.message}")
            stopTunnel()
        }
    }

    private fun stopTunnel() {
        try { boxService?.close() } catch (_: Exception) {}
        boxService = null
        try { tunFd?.close() } catch (_: Exception) {}
        tunFd = null
        networkCallback?.let { cb -> try { connectivity.unregisterNetworkCallback(cb) } catch (_: Exception) {} }
        networkCallback = null
        defaultListener = null
        setStatus("disconnected")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION") stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() { stopTunnel(); super.onDestroy() }
    override fun onRevoke() { stopTunnel() }

    private fun setStatus(s: String) {
        running = s == "connected"
        lastStatus = s
        statusListener?.invoke(s)
    }

    private fun startForegroundInnocuous() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Game", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val n = AndroidNotification.Builder(this, CHANNEL_ID)
            .setContentTitle("Chess")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .build()
        startForeground(1, n)
    }

    // ---------------- PlatformInterface (libbox v1.10.7) ----------------

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("missing vpn permission")
        val b = Builder()
        b.setSession("Chess")
        b.setMtu(options.mtu)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) b.setMetered(false)

        val a4 = options.inet4Address
        while (a4.hasNext()) { val p = a4.next(); b.addAddress(p.address(), p.prefix()) }
        val a6 = options.inet6Address
        while (a6.hasNext()) { val p = a6.next(); b.addAddress(p.address(), p.prefix()) }

        if (options.autoRoute) {
            val r4 = options.inet4RouteAddress
            if (r4.hasNext()) {
                while (r4.hasNext()) { val p = r4.next(); b.addRoute(p.address(), p.prefix()) }
            } else {
                b.addRoute("0.0.0.0", 0)
            }
            val r6 = options.inet6RouteAddress
            if (r6.hasNext()) {
                while (r6.hasNext()) { val p = r6.next(); b.addRoute(p.address(), p.prefix()) }
            } else {
                // Mirror the IPv4 default-route fallback: capture ALL IPv6 too, so it
                // can't leak past the tunnel on dual-stack networks (fail-closed).
                b.addRoute("::", 0)
            }
            try {
                val dns = options.dnsServerAddress
                if (dns != null && dns.value.isNotEmpty()) b.addDnsServer(dns.value)
            } catch (_: Exception) {}
        }

        val pfd = b.establish() ?: error("VpnService.establish() returned null")
        tunFd = pfd
        return pfd.fd
    }

    override fun autoDetectInterfaceControl(fd: Int) {
        if (!protect(fd)) error("protect($fd) failed")
    }

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true
    override fun usePlatformDefaultInterfaceMonitor(): Boolean = true
    override fun usePlatformInterfaceGetter(): Boolean = true
    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q
    override fun underNetworkExtension(): Boolean = false
    override fun includeAllNetworks(): Boolean = false
    override fun clearDNSCache() {}
    override fun readWIFIState(): WIFIState? = null
    override fun sendNotification(notification: LibboxNotification) {}
    override fun writeLog(message: String) { Log.i("sing-box", message) }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        defaultListener = listener
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = pushDefault(network)
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = pushDefault(network)
            override fun onLost(network: Network) { defaultListener?.updateDefaultInterface("", -1) }
        }
        networkCallback = cb
        connectivity.registerDefaultNetworkCallback(cb)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        networkCallback?.let { cb -> try { connectivity.unregisterNetworkCallback(cb) } catch (_: Exception) {} }
        networkCallback = null
        defaultListener = null
    }

    private fun pushDefault(network: Network) {
        val name = connectivity.getLinkProperties(network)?.interfaceName ?: return
        val idx = try { JavaNetworkInterface.getByName(name)?.index ?: -1 } catch (_: Exception) { -1 }
        defaultListener?.updateDefaultInterface(name, idx)
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val out = ArrayList<LibboxNetworkInterface>()
        val ifaces = JavaNetworkInterface.getNetworkInterfaces() ?: return Ifaces(out.iterator())
        for (ni in ifaces) {
            val bi = LibboxNetworkInterface()
            bi.name = ni.name
            bi.index = try { ni.index } catch (_: Exception) { -1 }
            try { bi.mtu = ni.mtu } catch (_: Exception) {}
            val addrs = ni.interfaceAddresses.mapNotNull { ia ->
                // strip IPv6 zone (e.g. "fe80::1%dummy0") — Go's netip rejects zones in a prefix
                ia.address.hostAddress?.substringBefore("%")?.let { "$it/${ia.networkPrefixLength}" }
            }
            bi.addresses = Strings(addrs)
            var flags = OsConstants.IFF_UP or OsConstants.IFF_RUNNING
            if (ni.isLoopback) flags = flags or OsConstants.IFF_LOOPBACK
            if (ni.isPointToPoint) flags = flags or OsConstants.IFF_POINTOPOINT
            if (ni.supportsMulticast()) flags = flags or OsConstants.IFF_MULTICAST
            bi.flags = flags
            out.add(bi)
        }
        return Ifaces(out.iterator())
    }

    // process-routing hooks — unused (config has no process rules)
    override fun findConnectionOwner(p: Int, sa: String, sp: Int, da: String, dp: Int): Int = error("not supported")
    override fun packageNameByUid(uid: Int): String = error("not supported")
    override fun uidByPackageName(name: String): Int = error("not supported")

    // ---- libbox iterator adapters ----
    private class Strings(private val list: List<String>) : StringIterator {
        private val it = list.iterator()
        override fun len(): Int = list.size
        override fun hasNext(): Boolean = it.hasNext()
        override fun next(): String = it.next()
    }
    private class Ifaces(private val it: Iterator<LibboxNetworkInterface>) : NetworkInterfaceIterator {
        override fun hasNext(): Boolean = it.hasNext()
        override fun next(): LibboxNetworkInterface = it.next()
    }
}
