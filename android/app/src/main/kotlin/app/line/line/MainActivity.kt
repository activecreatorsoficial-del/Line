package app.line.line

import android.app.Activity
import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var exports: List<String> = emptyList()
    private val worker = Executors.newSingleThreadExecutor()
    private var askedNotifications = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.line/network")
            .setMethodCallHandler { call, result ->
                if (call.method != "wifiAddresses" && call.method != "internetAddresses") {
                    result.notImplemented(); return@setMethodCallHandler
                }
                try {
                    val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    @Suppress("DEPRECATION")
                    val addresses = connectivity.allNetworks.filter { network ->
                        val capabilities = connectivity.getNetworkCapabilities(network)
                        if (call.method == "wifiAddresses") capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                        else capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
                    }.flatMap { network ->
                        connectivity.getLinkProperties(network)?.linkAddresses?.mapNotNull { link ->
                            val address = link.address
                            if (address.isLoopbackAddress || address.isLinkLocalAddress) null
                            else address.hostAddress?.substringBefore('%')
                        } ?: emptyList()
                    }.distinct()
                    result.success(addresses)
                } catch (e: Exception) { result.error("network", "Unable to read this device's network addresses.", null) }
            }
        val session = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.line/session")
        LineSessionService.onStopRequested = { session.invokeMethod("stopRequested", null) }
        session.setMethodCallHandler { call, result ->
            if (call.method != "setActive") { result.notImplemented(); return@setMethodCallHandler }
            try {
                val service = Intent(this, LineSessionService::class.java)
                    .putExtra("hosting", call.argument<Boolean>("hosting") ?: false)
                if (call.argument<Boolean>("active") == true) {
                    if (Build.VERSION.SDK_INT >= 33 && !askedNotifications &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        askedNotifications = true
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 5412)
                    }
                    if (Build.VERSION.SDK_INT >= 26) startForegroundService(service) else startService(service)
                } else { stopService(service) }
                result.success(null)
            } catch (e: Exception) { result.error("session", "Unable to keep this sharing session active.", null) }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.line/files")
            .setMethodCallHandler { call, result ->
                if (call.method != "exportFiles") { result.notImplemented(); return@setMethodCallHandler }
                if (pending != null) { result.error("busy", "Files are already being saved.", null); return@setMethodCallHandler }
                val paths = call.argument<List<String>>("paths") ?: emptyList()
                // Only the app's own received files can be exported by this bridge.
                val appRoot = applicationInfo.dataDir.let { File(it).canonicalFile }
                if (paths.isEmpty() || paths.any {
                        val file = File(it).canonicalFile
                        !file.path.startsWith(appRoot.path + File.separator) || !file.isFile
                    }) {
                    result.error("paths", "Invalid source files.", null)
                    return@setMethodCallHandler
                }
                exports = paths; pending = result
                try {
                    startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }, 5311)
                } catch (e: Exception) {
                    pending = null; exports = emptyList()
                    result.error("picker", "Unable to open the folder picker.", null)
                }
            }
    }

    override fun onDestroy() {
        if (!isChangingConfigurations) {
            LineSessionService.onStopRequested = null
            stopService(Intent(this, LineSessionService::class.java))
        }
        super.onDestroy()
    }

    @Deprecated("Uses activity result for the Flutter host")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 5311) return
        val result = pending ?: return
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            pending = null; exports = emptyList(); result.success(null); return
        }
        val paths = exports.toList()
        worker.execute {
            var count = 0
            var activeDocument: Uri? = null
            try {
                val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                for (path in paths) {
                    val input = File(path)
                    activeDocument = DocumentsContract.createDocument(contentResolver, parent, "application/octet-stream", input.name)
                        ?: throw IllegalStateException("Unable to create the file.")
                    contentResolver.openOutputStream(activeDocument, "w").use { output ->
                        requireNotNull(output)
                        // Fixed 64 KiB copy buffer, regardless of the file's size.
                        input.inputStream().use { source -> source.copyTo(output, 64 * 1024) }
                    }
                    activeDocument = null; count++
                }
                Handler(Looper.getMainLooper()).post {
                    pending = null; exports = emptyList(); result.success(count)
                }
            } catch (e: Exception) {
                activeDocument?.let { uri -> runCatching { DocumentsContract.deleteDocument(contentResolver, uri) } }
                Handler(Looper.getMainLooper()).post {
                    pending = null; exports = emptyList()
                    result.error("export", "Saved $count file(s). Check available space and permissions to save the rest.", null)
                }
            }
        }
    }
}
