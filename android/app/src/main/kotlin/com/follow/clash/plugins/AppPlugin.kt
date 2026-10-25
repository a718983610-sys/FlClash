package com.follow.clash.plugins

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.ContextCompat.getSystemService
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import androidx.core.net.toUri
import androidx.core.view.OnApplyWindowInsetsListener
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.follow.clash.R
import com.follow.clash.common.Components
import com.follow.clash.common.GlobalState
import com.follow.clash.common.PendingCallback
import com.follow.clash.common.QuickAction
import com.follow.clash.common.quickIntent
import com.follow.clash.common.registerReceiverCompat
import com.follow.clash.common.shortcutId
import com.follow.clash.getPackageIconPath
import com.follow.clash.packages.PackageResolver
import com.follow.clash.showToast
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class AppPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

    private var activity: Activity? = null

    private var activityBinding: ActivityPluginBinding? = null

    private val activityResultListener =
        PluginRegistry.ActivityResultListener(::onActivityResult)

    private val permissionsResultListener =
        PluginRegistry.RequestPermissionsResultListener(::onRequestPermissionsResultListener)

    private lateinit var channel: MethodChannel

    private lateinit var scope: CoroutineScope

    private val vpnPrepareCallback = PendingCallback<Boolean>()

    private val requestNotificationCallback = PendingCallback<Boolean>()

    private val requestInstalledAppsCallback = PendingCallback<Boolean>()

    private val requestLocalNetworkCallback = PendingCallback<Boolean>()

    private var isRequestingNotificationPermission = false

    private var isRequestingLocalNetworkPermission = false

    private var skipLocalNetworkPermissionRequest = false

    private val gson = Gson()

    private val packageResolver by lazy {
        PackageResolver(
            GlobalState.application.packageManager,
            GlobalState.application.packageName,
        )
    }

    private var packageChangeContext: Context? = null

    private val packageChangeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent == null || intent.data?.schemeSpecificPart == GlobalState.application.packageName) {
                return
            }
            val addedByUpdate = intent.action == Intent.ACTION_PACKAGE_ADDED &&
                intent.getBooleanExtra(Intent.EXTRA_REPLACING, false)
            if (addedByUpdate) {
                return
            }
            packageResolver.invalidate()
            channel.invokeMethod("packagesChanged", null)
        }
    }

    private var skipNotificationPermissionRequest = false

    @Suppress("DEPRECATION")
    private val isTelevision by lazy {
        val packageManager = GlobalState.application.packageManager
        packageManager.hasSystemFeature(PackageManager.FEATURE_TELEVISION) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }

    private var floatingIme = false

    // A TV keyboard floats over the app and reports a zero-height IME inset.
    private val imeInsetsListener = OnApplyWindowInsetsListener { view, insets ->
        val ime = WindowInsetsCompat.Type.ime()
        reportFloatingIme(insets.isVisible(ime) && insets.getInsets(ime).bottom == 0)
        ViewCompat.onApplyWindowInsets(view, insets)
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * The permission and consent hops below touch the Activity — starting an
     * activity for result, raising a permission prompt — and read the state that
     * tracks whether one is already up. Their callers are coroutines on
     * [Dispatchers.Default], while the answers come back on the main thread
     * through the ActivityAware listeners, so main is the one thread both ends
     * can agree on. A plain main-looper post rather than the plugin scope: the
     * scope is cancelled when the engine detaches, and a request dropped there
     * would leave its caller waiting for a callback that can no longer run.
     */
    private fun onMainThread(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            mainHandler.post(block)
        }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "moveTaskToBack" -> {
                activity?.moveTaskToBack(true)
                result.success(true)
            }

            "getSimCountry" -> {
                val telephony = appContext.getSystemService(
                    android.telephony.TelephonyManager::class.java,
                )
                val country = telephony?.networkCountryIso?.takeIf { it.isNotEmpty() }
                    ?: telephony?.simCountryIso?.takeIf { it.isNotEmpty() }
                result.success(country)
            }

            "updateExcludeFromRecents" -> {
                val value = call.argument<Boolean>("value")
                updateExcludeFromRecents(value)
                result.success(true)
            }

            "initShortcuts" -> {
                val labels = shortcutLabels(call.arguments)
                if (labels == null) {
                    result.error(
                        "INVALID_ARGUMENT",
                        "Shortcut labels must map every quick action to a string",
                        null,
                    )
                } else {
                    initShortcuts(labels)
                    result.success(true)
                }
            }

            "getPackages" -> reply(result) {
                gson.toJson(packageResolver.installedPackages)
            }

            "getChinaPackageNames" -> reply(result) {
                gson.toJson(packageResolver.getChinaPackageNames())
            }

            "isInstalledAppsPermissionGranted" -> reply(result) {
                packageResolver.hasInstalledAppsPermission()
            }

            "requestInstalledAppsPermission" -> {
                requestInstalledAppsPermission { granted -> result.success(granted) }
            }

            "getPackageIcon" -> {
                handleGetPackageIcon(call, result)
            }

            "tip" -> {
                val message = call.argument<String>("message")
                GlobalState.application.showToast(message)
                result.success(true)
            }

            "openAppSettings" -> {
                result.success(openAppSettings())
            }

            "installApk" -> {
                result.success(openApkInstaller(call.argument<String>("path")))
            }

            "installApkSilent" -> {
                installApkSilently(call.argument<String>("path"), result)
            }

            "openUnknownAppSettings" -> {
                result.success(openUnknownAppSettings())
            }

            "getLastExitInfo" -> reply(result) {
                GlobalState.lastExitInfo()
            }

            else -> {
                result.notImplemented()
            }
        }
    }

    private fun handleGetPackageIcon(call: MethodCall, result: Result) = reply(result) {
        val packageName = call.argument<String>("packageName") ?: ""
        GlobalState.application.packageManager.getPackageIconPath(packageName)
    }

    // A throw inside the plugin scope has no handler and ends the process;
    // the Dart caller gets a PlatformException to handle instead.
    private fun reply(result: Result, block: suspend () -> Any?) {
        scope.launch(Dispatchers.IO) {
            try {
                result.success(block())
            } catch (error: Exception) {
                GlobalState.log("Platform call failed: $error")
                result.error("PLATFORM_ERROR", error.toString(), null)
            }
        }
    }

    private fun shortcutLabels(arguments: Any?): Map<QuickAction, String>? {
        val map = arguments as? Map<*, *> ?: return null
        return QuickAction.entries.associateWith { action ->
            map[action.shortcutId] as? String ?: return null
        }
    }

    private fun initShortcuts(labels: Map<QuickAction, String>) {
        val shortcuts = SHORTCUT_ORDER.mapIndexed { rank, action ->
            with(ShortcutInfoCompat.Builder(GlobalState.application, action.shortcutId)) {
                setShortLabel(labels.getValue(action))
                setIcon(IconCompat.createWithResource(GlobalState.application, action.shortcutIcon))
                setIntent(action.quickIntent)
                setRank(rank)
                build()
            }
        }
        ShortcutManagerCompat.setDynamicShortcuts(GlobalState.application, shortcuts)
    }

    // Plain circles, not adaptive icons: an adaptive shortcut icon takes the
    // launcher's own mask, which is a square on many devices.
    private val QuickAction.shortcutIcon: Int
        get() = when (this) {
            QuickAction.START -> R.drawable.ic_shortcut_start
            QuickAction.STOP -> R.drawable.ic_shortcut_stop
            QuickAction.TOGGLE -> R.drawable.ic_shortcut_toggle
        }

    // Dart contract: "launched" / "needs_permission" / "failed".
    private fun openApkInstaller(path: String?): String {
        val activity = activity ?: return "failed"
        if (path.isNullOrEmpty()) return "failed"
        val file = java.io.File(path)
        if (!file.exists() || !file.isFile) return "failed"
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !activity.packageManager.canRequestPackageInstalls()
            ) {
                return "needs_permission"
            }
            val uri = androidx.core.content.FileProvider.getUriForFile(
                activity,
                "${activity.packageName}.fileprovider",
                file,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_ACTIVITY_NEW_TASK,
                )
            }
            activity.startActivity(intent)
            "launched"
        } catch (_: Exception) {
            "failed"
        }
    }

    // Dart contract: "success" / "pending_user_action" /
    // "needs_permission" / "failed".
    private fun installApkSilently(path: String?, result: Result) {
        val context = appContext
        if (path.isNullOrEmpty() ||
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S
        ) {
            result.success("failed")
            return
        }
        val file = java.io.File(path)
        if (!file.exists() || !file.isFile) {
            result.success("failed")
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !context.packageManager.canRequestPackageInstalls()
        ) {
            result.success("needs_permission")
            return
        }
        val answered = java.util.concurrent.atomic.AtomicBoolean(false)
        lateinit var receiver: BroadcastReceiver
        fun answer(value: String) {
            if (answered.compareAndSet(false, true)) {
                runCatching { context.unregisterReceiver(receiver) }
                onMainThread { result.success(value) }
            }
        }
        receiver = object : BroadcastReceiver() {
            override fun onReceive(receiverContext: Context?, intent: Intent?) {
                val status = intent?.getIntExtra(
                    android.content.pm.PackageInstaller.EXTRA_STATUS,
                    android.content.pm.PackageInstaller.STATUS_FAILURE,
                ) ?: android.content.pm.PackageInstaller.STATUS_FAILURE
                answer(
                    when (status) {
                        android.content.pm.PackageInstaller.STATUS_SUCCESS ->
                            "success"
                        android.content.pm.PackageInstaller.STATUS_PENDING_USER_ACTION ->
                            "pending_user_action"
                        else -> "failed"
                    },
                )
            }
        }
        ContextCompat.registerReceiver(
            context,
            receiver,
            IntentFilter(SILENT_INSTALL_STATUS_ACTION),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        mainHandler.postDelayed({ answer("failed") }, SILENT_INSTALL_TIMEOUT_MS)
        scope.launch(Dispatchers.IO) {
            var session: android.content.pm.PackageInstaller.Session? = null
            try {
                val installer = context.packageManager.packageInstaller
                val params = android.content.pm.PackageInstaller.SessionParams(
                    android.content.pm.PackageInstaller.SessionParams.MODE_FULL_INSTALL,
                ).apply {
                    setRequireUserAction(
                        android.content.pm.PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED,
                    )
                }
                session = installer.openSession(installer.createSession(params))
                session.openWrite("qf-update", 0, file.length()).use { out ->
                    file.inputStream().use { input -> input.copyTo(out) }
                    session.fsync(out)
                }
                val statusIntent = Intent(SILENT_INSTALL_STATUS_ACTION).setPackage(
                    context.packageName,
                )
                val pendingIntent = android.app.PendingIntent.getBroadcast(
                    context,
                    SILENT_INSTALL_REQUEST_CODE,
                    statusIntent,
                    android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                        android.app.PendingIntent.FLAG_MUTABLE,
                )
                session.commit(pendingIntent.intentSender)
            } catch (error: Exception) {
                GlobalState.log("Silent install failed: $error")
                runCatching { session?.abandon() }
                answer("failed")
            } finally {
                runCatching { session?.close() }
            }
        }
    }

    private fun openUnknownAppSettings(): Boolean {
        val activity = activity ?: return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (activity.packageManager.canRequestPackageInstalls()) return false
        return try {
            val settings = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                data = "package:${activity.packageName}".toUri()
            }
            activity.startActivity(settings)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun openAppSettings(): Boolean {
        val activity = activity ?: return false
        return try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = "package:${GlobalState.application.packageName}".toUri()
            }
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun updateExcludeFromRecents(value: Boolean?) {
        val taskId = activity?.taskId ?: return
        val am = getSystemService(GlobalState.application, ActivityManager::class.java)
        val task = am?.appTasks?.firstOrNull {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                it.taskInfo?.taskId == taskId
            } else {
                it.taskInfo?.id == taskId
            }
        }
        task?.setExcludeFromRecents(value ?: false)
    }

    fun requestNotificationPermission(callback: (Boolean) -> Unit) = onMainThread {
        requestNotificationCallback.replace(callback, supersededValue = false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val permission = ContextCompat.checkSelfPermission(
                GlobalState.application,
                Manifest.permission.POST_NOTIFICATIONS,
            )
            if (permission == PackageManager.PERMISSION_GRANTED || skipNotificationPermissionRequest) {
                invokeRequestNotificationCallback(true)
                return@onMainThread
            }
            if (isRequestingNotificationPermission) {
                return@onMainThread
            }
            isRequestingNotificationPermission = true
            activity?.let {
                ActivityCompat.requestPermissions(
                    it,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    NOTIFICATION_PERMISSION_REQUEST_CODE,
                )
            } ?: invokeRequestNotificationCallback(true)
            return@onMainThread
        }
        invokeRequestNotificationCallback(true)
    }

    private fun invokeRequestNotificationCallback(shouldStart: Boolean) {
        isRequestingNotificationPermission = false
        requestNotificationCallback.resolve(shouldStart)
    }

    fun requestLocalNetworkPermission(callback: (Boolean) -> Unit) = onMainThread {
        requestLocalNetworkCallback.replace(callback, supersededValue = false)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.CINNAMON_BUN || hasLocalNetworkPermission()) {
            invokeRequestLocalNetworkCallback(true)
            return@onMainThread
        }
        if (skipLocalNetworkPermissionRequest) {
            invokeRequestLocalNetworkCallback(false)
            return@onMainThread
        }
        if (isRequestingLocalNetworkPermission) {
            return@onMainThread
        }
        val activity = activity
        if (activity == null) {
            invokeRequestLocalNetworkCallback(false)
            return@onMainThread
        }
        isRequestingLocalNetworkPermission = true
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.ACCESS_LOCAL_NETWORK),
            LOCAL_NETWORK_PERMISSION_REQUEST_CODE,
        )
    }

    private fun hasLocalNetworkPermission(): Boolean = ContextCompat.checkSelfPermission(
        GlobalState.application,
        Manifest.permission.ACCESS_LOCAL_NETWORK,
    ) == PackageManager.PERMISSION_GRANTED

    private fun invokeRequestLocalNetworkCallback(granted: Boolean) {
        isRequestingLocalNetworkPermission = false
        requestLocalNetworkCallback.resolve(granted)
    }

    private fun requestInstalledAppsPermission(callback: (Boolean) -> Unit) = onMainThread {
        requestInstalledAppsCallback.replace(callback, supersededValue = false)
        val activity = activity
        if (packageResolver.hasInstalledAppsPermission()) {
            invokeRequestInstalledAppsCallback(true)
            return@onMainThread
        }
        if (activity == null) {
            invokeRequestInstalledAppsCallback(false)
            return@onMainThread
        }
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(PackageResolver.GET_INSTALLED_APPS),
            INSTALLED_APPS_PERMISSION_REQUEST_CODE,
        )
    }

    private fun invokeRequestInstalledAppsCallback(granted: Boolean) {
        if (granted) {
            packageResolver.invalidate()
        }
        requestInstalledAppsCallback.resolve(granted)
    }

    fun prepareVpn(needPrepare: Boolean, callback: (Boolean) -> Unit) = onMainThread {
        vpnPrepareCallback.replace(callback, supersededValue = false)
        if (!needPrepare) {
            invokeVpnPrepareCallback(true)
            return@onMainThread
        }
        val intent = VpnService.prepare(GlobalState.application)
        if (intent != null) {
            val activity = activity
            if (activity == null) {
                invokeVpnPrepareCallback(false)
            } else {
                @Suppress("DEPRECATION")
                activity.startActivityForResult(intent, VPN_PERMISSION_REQUEST_CODE)
            }
            return@onMainThread
        }
        invokeVpnPrepareCallback(true)
    }

    // Posted rather than run where the cancellation lands, so it stays ordered
    // behind the prepareVpn that installed the callback it is cancelling.
    fun cancelVpnPreparation(callback: (Boolean) -> Unit) = onMainThread {
        vpnPrepareCallback.cancel(callback)
    }

    private fun invokeVpnPrepareCallback(granted: Boolean) {
        vpnPrepareCallback.resolve(granted)
    }

    private lateinit var appContext: android.content.Context

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        appContext = flutterPluginBinding.applicationContext
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        channel =
            MethodChannel(flutterPluginBinding.binaryMessenger, "${Components.PACKAGE_NAME}/app")
        channel.setMethodCallHandler(this)
        watchPackageChanges(flutterPluginBinding.applicationContext)
    }

    private fun watchPackageChanges(context: Context) {
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addAction(Intent.ACTION_PACKAGE_REPLACED)
            addAction(Intent.ACTION_PACKAGE_FULLY_REMOVED)
            addDataScheme("package")
        }
        context.registerReceiverCompat(packageChangeReceiver, filter)
        packageChangeContext = context
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        packageChangeContext?.unregisterReceiver(packageChangeReceiver)
        packageChangeContext = null
        channel.setMethodCallHandler(null)
        scope.cancel()
        invokeVpnPrepareCallback(false)
        invokeRequestNotificationCallback(false)
        invokeRequestLocalNetworkCallback(false)
        invokeRequestInstalledAppsCallback(false)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attachToActivity(binding)
    }

    private fun attachToActivity(binding: ActivityPluginBinding) {
        detachFromActivity()
        activityBinding = binding
        activity = binding.activity
        binding.addActivityResultListener(activityResultListener)
        binding.addRequestPermissionsResultListener(permissionsResultListener)
        if (isTelevision) {
            ViewCompat.setOnApplyWindowInsetsListener(
                binding.activity.window.decorView,
                imeInsetsListener,
            )
        }
    }

    private fun detachFromActivity() {
        if (isTelevision) {
            activity?.window?.decorView?.let {
                ViewCompat.setOnApplyWindowInsetsListener(it, null)
            }
            reportFloatingIme(false)
        }
        activity = null
        val binding = activityBinding ?: return
        activityBinding = null
        binding.removeActivityResultListener(activityResultListener)
        binding.removeRequestPermissionsResultListener(permissionsResultListener)
    }

    private fun reportFloatingIme(floating: Boolean) {
        if (floating == floatingIme) {
            return
        }
        floatingIme = floating
        channel.invokeMethod("floatingImeChanged", floating)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachFromActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attachToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        channel.invokeMethod("exit", null)
        detachFromActivity()
        invokeVpnPrepareCallback(false)
        invokeRequestNotificationCallback(false)
        invokeRequestLocalNetworkCallback(false)
        invokeRequestInstalledAppsCallback(false)
    }

    private fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != VPN_PERMISSION_REQUEST_CODE) {
            return false
        }
        invokeVpnPrepareCallback(resultCode == Activity.RESULT_OK)
        return true
    }

    private fun onRequestPermissionsResultListener(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ): Boolean = when (requestCode) {
        NOTIFICATION_PERMISSION_REQUEST_CODE -> {
            skipNotificationPermissionRequest = true
            invokeRequestNotificationCallback(true)
            true
        }

        INSTALLED_APPS_PERMISSION_REQUEST_CODE -> {
            invokeRequestInstalledAppsCallback(
                grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED,
            )
            true
        }

        LOCAL_NETWORK_PERMISSION_REQUEST_CODE -> {
            skipLocalNetworkPermissionRequest = true
            invokeRequestLocalNetworkCallback(
                grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED,
            )
            true
        }

        else -> false
    }

    private companion object {
        val SHORTCUT_ORDER = listOf(QuickAction.START, QuickAction.STOP, QuickAction.TOGGLE)
        const val VPN_PERMISSION_REQUEST_CODE = 1001
        const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1002
        const val INSTALLED_APPS_PERMISSION_REQUEST_CODE = 1003
        const val LOCAL_NETWORK_PERMISSION_REQUEST_CODE = 1004
        const val SILENT_INSTALL_REQUEST_CODE = 1005
        const val SILENT_INSTALL_STATUS_ACTION =
            "com.follow.clash.SILENT_INSTALL_STATUS"
        const val SILENT_INSTALL_TIMEOUT_MS = 90_000L
    }
}
