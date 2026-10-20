package io.github.sxpsimon.handwriting

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.net.ProxySelector
import java.net.Proxy
import java.net.URI
import java.net.InetSocketAddress

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var pendingPath: String? = null
    private var pendingBuild: Long = 0
    private var pendingHash: String? = null
    private val verifier = Executors.newSingleThreadExecutor()
    private val permissionRequest = 7821

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "io.github.sxpsimon.panache/updates").setMethodCallHandler { call, result ->
            when (call.method) {
                "supportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                "cacheDirectory" -> result.success(File(cacheDir, "updates").absolutePath)
                "proxyForUrl" -> {
                    try {
                        val proxy = ProxySelector.getDefault()?.select(URI(call.arguments as String))?.firstOrNull()
                        val address = proxy?.address() as? InetSocketAddress
                        result.success(if (proxy?.type() == Proxy.Type.HTTP && address != null)
                            "PROXY ${address.hostString}:${address.port}" else "DIRECT")
                    } catch (_: Exception) { result.success("DIRECT") }
                }
                "install" -> {
                    if (pending != null) {
                        result.error("busy", "An installation request is already open", null)
                    } else {
                        pending = result
                        pendingPath = call.argument<String>("path")
                        pendingBuild = call.argument<Number>("buildNumber")?.toLong() ?: 0
                        pendingHash = call.argument<String>("sha256")
                        verifyAndInstall(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun validateApk(): File {
        val root = File(cacheDir, "updates").canonicalFile
        val file = File(pendingPath ?: "").canonicalFile
        require(file.parentFile?.parentFile == root &&
            file.parentFile?.name?.startsWith("download-") == true && file.isFile && file.extension == "apk")
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(65536)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                hash.update(buffer, 0, count)
            }
        }
        require(hash.digest().joinToString("") { "%02x".format(it) } == pendingHash)
        val archive = packageManager.getPackageArchiveInfo(file.path, 0)
            ?: error("Cannot read APK")
        val current = packageManager.getPackageInfo(packageName, 0)
        val archiveVersion = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode else archive.versionCode.toLong()
        val currentVersion = if (Build.VERSION.SDK_INT >= 28) current.longVersionCode else current.versionCode.toLong()
        require(archive.packageName == packageName && archiveVersion == pendingBuild && archiveVersion > currentVersion)
        return file
    }

    private fun verifyAndInstall(allowPermissionRequest: Boolean) {
        verifier.execute {
            try {
                val file = validateApk()
                runOnUiThread {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            !packageManager.canRequestPackageInstalls()) {
                            check(allowPermissionRequest) { "Installation permission was not granted" }
                            startActivityForResult(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")), permissionRequest)
                        } else launchInstaller(file)
                    } catch (error: Exception) { fail(error) }
                }
            } catch (error: Exception) { runOnUiThread { fail(error) } }
        }
    }

    private fun launchInstaller(file: File) {
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
        pending?.success(null)
        pending = null
        pendingPath = null
    }

    private fun fail(error: Exception) {
        pending?.error("install_unavailable", error.message, null)
        pending = null
        pendingPath = null
    }

    @Deprecated("Android activity permission flow still delivers this callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != permissionRequest || pending == null) return
        verifyAndInstall(false)
    }
}
