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
import java.net.ProxySelector
import java.net.Proxy
import java.net.URI
import java.net.InetSocketAddress

class MainActivity : FlutterActivity() {
    private class InstallRequest(
        val result: MethodChannel.Result, val path: String?, val build: Long, val hash: String?
    )
    private var pending: InstallRequest? = null
    private var updates: MethodChannel? = null
    private lateinit var installSession: ApkInstallSession

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        installSession = ApkInstallSession { task -> runOnUiThread(task) }
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "io.github.sxpsimon.panache/updates")
        updates = channel
        channel.setMethodCallHandler { call, result ->
            if (updates !== channel) {
                result.error("install_unavailable", "Activity detached", null)
                return@setMethodCallHandler
            }
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
                        pending = InstallRequest(result, call.argument<String>("path"),
                            call.argument<Number>("buildNumber")?.toLong() ?: 0, call.argument<String>("sha256"))
                        verifyAndInstall(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        updates?.setMethodCallHandler(null)
        updates = null
        installSession.close()
        val result = pending?.result
        pending = null
        result?.error("install_unavailable", "Activity detached", null)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    @Suppress("DEPRECATION")
    private fun validateApk(request: InstallRequest): File {
        val root = File(cacheDir, "updates").canonicalFile
        val file = File(request.path ?: "").canonicalFile
        require(file.parentFile?.parentFile == root &&
            file.parentFile?.name?.startsWith("download-") == true && file.isFile && file.extension == "apk")
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(65536)
            while (true) {
                if (Thread.currentThread().isInterrupted) throw InterruptedException("Activity detached")
                val count = stream.read(buffer)
                if (count < 0) break
                hash.update(buffer, 0, count)
            }
        }
        require(hash.digest().joinToString("") { "%02x".format(it) } == request.hash)
        val archive = packageManager.getPackageArchiveInfo(file.path, 0)
            ?: error("Cannot read APK")
        val current = packageManager.getPackageInfo(packageName, 0)
        val archiveVersion = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode else archive.versionCode.toLong()
        val currentVersion = if (Build.VERSION.SDK_INT >= 28) current.longVersionCode else current.versionCode.toLong()
        require(archive.packageName == packageName && archiveVersion == request.build && archiveVersion > currentVersion)
        return file
    }

    private fun verifyAndInstall(allowPermissionRequest: Boolean) {
        val request = pending ?: return
        installSession.verify({ validateApk(request) }, onVerified@{ file ->
            if (pending !== request) return@onVerified
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()) {
                check(allowPermissionRequest) { "Installation permission was not granted" }
                startActivityForResult(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")), installSession.beginPermissionRequest())
            } else launchInstaller(file)
        }, { error -> if (pending === request) fail(error) })
    }

    private fun launchInstaller(file: File) {
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            // Replacing this app tears down its activities. Keep the system
            // installer's completion screen in its own task so Open can launch
            // the newly installed app independently of the old activity.
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
        val result = pending?.result
        pending = null
        result?.success(null)
    }

    private fun fail(error: Exception) {
        val result = pending?.result
        pending = null
        result?.error("install_unavailable", error.message, null)
    }

    @Deprecated("Android activity permission flow still delivers this callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (pending == null || !installSession.consumePermissionResult(requestCode)) return
        verifyAndInstall(false)
    }
}
