package com.pasteleg.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
import android.webkit.CookieManager
import com.tiktok.open.sdk.auth.AuthApi
import com.tiktok.open.sdk.auth.AuthRequest
import com.tiktok.open.sdk.auth.AuthResponse
import com.tiktok.open.sdk.auth.utils.PKCEUtils
import com.tiktok.open.sdk.core.appcheck.TikTokAppCheckUtil
import com.tiktok.open.sdk.core.constants.Constants
import com.tiktok.open.sdk.core.utils.AppUtils
import com.tiktok.open.sdk.core.utils.SignatureUtils
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "PastelTikTokAuth"
        private const val CHANNEL_NAME = "com.pasteleg.app/tiktok_sdk"
        private const val DEFAULT_REDIRECT_URI = "https://pastel-eg.com/social-connections/tiktok/callback"
        private const val ALT_REDIRECT_URI = "https://pastel-eg.com/provider/automation-settings/provider/social-connections/tiktok/callback"
        private const val PREFS_NAME = "pastel_tiktok_auth_state"
        private const val KEY_VERIFIER = "pending_code_verifier"
        private const val KEY_STATE = "pending_state"
        private const val KEY_REDIRECT_URI = "pending_redirect_uri"
        private const val KEY_TIMESTAMP = "pending_timestamp_ms"
        // Maximum validity window for an active/restored authorization session (2 minutes, matching Dart kAuthTimeout)
        private const val MAX_PENDING_AGE_MS = 2 * 60 * 1000L

        private val KNOWN_TIKTOK_PACKAGES = listOf(
            "com.zhiliaoapp.musically",
            "com.ss.android.ugc.trill",
            "com.zhiliaoapp.musically.go"
        )
    }

    private lateinit var authApi: AuthApi
    private var methodChannel: MethodChannel? = null

    // Active PKCE & state session bound to the in-flight native authorization request
    private var pendingResult: MethodChannel.Result? = null
    private var pendingCodeVerifier: String? = null
    private var pendingState: String? = null
    private var pendingRedirectUri: String = DEFAULT_REDIRECT_URI
    private var pendingTimestampMs: Long = 0L
    private var pendingPostCreationPayload: Map<String, Any?>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        authApi = AuthApi(activity = this)
        restorePendingSession(savedInstanceState)
        handleTikTokAuthIntent(intent, source = "onCreate")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        authApi = AuthApi(activity = this)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isTikTokInstalled" -> {
                    val installed = TikTokAppCheckUtil.isTikTokAppInstalled(this) ||
                        findExportedTikTokAuthPackage() != null
                    result.success(installed)
                }
                "getCookiesForUrl" -> {
                    val url = call.argument<String>("url") ?: "https://pastel-eg.com"
                    val cookies = CookieManager.getInstance().getCookie(url) ?: ""
                    result.success(cookies)
                }
                "authorize" -> handleAuthorize(call, result)
                "cancel" -> {
                    cancelActivePendingSession()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        methodChannel = channel

        // Deliver any callback payload captured during activity recreation before FlutterEngine was ready
        pendingPostCreationPayload?.let { payload ->
            pendingPostCreationPayload = null
            channel.invokeMethod("onAuthResponse", payload)
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        pendingCodeVerifier?.let { outState.putString(KEY_VERIFIER, it) }
        pendingState?.let { outState.putString(KEY_STATE, it) }
        outState.putString(KEY_REDIRECT_URI, pendingRedirectUri)
        if (pendingTimestampMs > 0L) {
            outState.putLong(KEY_TIMESTAMP, pendingTimestampMs)
        }
    }

    private fun isPendingSessionExpired(): Boolean {
        if (pendingTimestampMs <= 0L) return true
        return (System.currentTimeMillis() - pendingTimestampMs) > MAX_PENDING_AGE_MS
    }

    private fun getFormattedCallerSha256(): String {
        return try {
            val raw = SignatureUtils.getCallerSHA256Certificates(this, packageName)
            val colonSeparated = raw.split(",").joinToString(", ") { hex ->
                hex.chunked(2).joinToString(":")
            }
            "$raw ($colonSeparated)"
        } catch (e: Exception) {
            "unavailable: ${e.message}"
        }
    }

    /**
     * Checks if any known TikTok package on the device exposes an exported
     * `openauthorize.AwemeAuthorizedActivity`, even if its Play Store signing
     * certificate was rotated after TikTok OpenSDK 2.4.0 was published.
     */
    private fun findExportedTikTokAuthPackage(): String? {
        for (pkg in KNOWN_TIKTOK_PACKAGES) {
            try {
                val component = ComponentName(
                    pkg,
                    AppUtils.concatPackageAndClassPath(pkg, Constants.TIKTOK.AUTH_ACTIVITY_NAME)
                )
                val actInfo = Intent().apply { this.component = component }
                    .resolveActivityInfo(packageManager, PackageManager.MATCH_DEFAULT_ONLY)
                if (actInfo != null && actInfo.exported) {
                    return pkg
                }
            } catch (_: Exception) {
            }
        }
        return null
    }

    private fun logTikTokEnvironmentDiagnostics(
        clientKey: String,
        redirectUri: String,
        scope: String,
        preferNative: Boolean
    ) {
        val callerCert = getFormattedCallerSha256()
        Log.i(TAG, "=== TikTok OpenSDK 2.4.0 Authorize Diagnostics ===")
        Log.i(TAG, "Caller packageName: $packageName")
        Log.i(TAG, "Caller SHA-256 Signing Certificate: $callerCert")
        Log.i(TAG, "Request clientKey: $clientKey | scope: $scope | preferNative: $preferNative")
        Log.i(TAG, "Request redirectUri: $redirectUri")

        for (pkg in KNOWN_TIKTOK_PACKAGES) {
            try {
                val pkgInfo = packageManager.getPackageInfo(pkg, 0)
                val component = ComponentName(
                    pkg,
                    AppUtils.concatPackageAndClassPath(pkg, Constants.TIKTOK.AUTH_ACTIVITY_NAME)
                )
                val actInfo = Intent().apply { this.component = component }
                    .resolveActivityInfo(packageManager, PackageManager.MATCH_DEFAULT_ONLY)
                Log.i(
                    TAG,
                    "Package [$pkg]: installed=true (versionName=${pkgInfo.versionName}), " +
                        "AwemeAuthorizedActivity resolved=${actInfo != null}, exported=${actInfo?.exported}"
                )
            } catch (e: Exception) {
                Log.i(TAG, "Package [$pkg]: installed=false (${e.javaClass.simpleName})")
            }
        }

        val detectedApp = TikTokAppCheckUtil.getInstalledTikTokApp(this)
        Log.i(
            TAG,
            "TikTokAppCheckUtil.getInstalledTikTokApp result: " +
                (detectedApp?.appPackageName ?: "NULL (not detected or signature mismatch)")
        )
    }

    private fun launchNativeTikTokComponentDirectly(
        authRequest: AuthRequest,
        targetPackageName: String
    ): Boolean {
        val normalizedRequest = authRequest.copy(scope = authRequest.scope.replace(" ", ""))
        if (targetPackageName.isEmpty() || !normalizedRequest.validate()) {
            return false
        }
        val bundle = normalizedRequest.toBundle()
        val targetClass = AppUtils.concatPackageAndClassPath(
            targetPackageName,
            Constants.TIKTOK.AUTH_ACTIVITY_NAME
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            component = ComponentName(targetPackageName, targetClass)
            putExtras(bundle)
        }
        Log.i(
            TAG,
            "Direct Native Launch -> Intent(action=${intent.action}, component=${intent.component?.flattenToString()}, " +
                "clientKey=${normalizedRequest.clientKey}, redirectUri=${normalizedRequest.redirectUri}, scope=${normalizedRequest.scope})"
        )
        return try {
            startActivityForResult(intent, 0)
            true
        } catch (e: Exception) {
            Log.e(TAG, "Direct Native Launch failed for $targetPackageName/$targetClass: ${e.message}", e)
            false
        }
    }

    private fun handleAuthorize(call: MethodCall, result: MethodChannel.Result) {
        // Active-request protection:
        // Never cancel or overwrite an active, non-expired authorization session.
        // Only recover if a prior session genuinely exceeded MAX_PENDING_AGE_MS (2 minutes).
        if (pendingResult != null || pendingCodeVerifier != null) {
            if (!isPendingSessionExpired()) {
                Log.w(TAG, "Rejected duplicate authorize() call while an active request is in progress.")
                result.error(
                    "DUPLICATE_REQUEST",
                    "A TikTok authorization request is already in progress.",
                    null
                )
                return
            }
            cancelActivePendingSession()
        }

        val clientKey = call.argument<String>("clientKey")?.trim().orEmpty()
        val scope = call.argument<String>("scope")?.trim().orEmpty()
        val redirectUri = call.argument<String>("redirectUri")?.trim().takeUnless { it.isNullOrEmpty() }
            ?: DEFAULT_REDIRECT_URI
        val state = call.argument<String>("state")?.trim().orEmpty()
        val preferNative = call.argument<Boolean>("preferNative") ?: true
        val language = call.argument<String>("language") ?: "ar"

        if (clientKey.isEmpty() || scope.isEmpty() || redirectUri.isEmpty() || state.isEmpty()) {
            result.error(
                "INVALID_ARGS",
                "clientKey, scope, redirectUri, and state are required for TikTok OpenSDK authorization.",
                null
            )
            return
        }

        logTikTokEnvironmentDiagnostics(clientKey, redirectUri, scope, preferNative)

        val sdkDetectedApp = TikTokAppCheckUtil.getInstalledTikTokApp(this)
        val fallbackNativePkg = if (sdkDetectedApp == null) findExportedTikTokAuthPackage() else null
        val resolvedNativePkg = sdkDetectedApp?.appPackageName ?: fallbackNativePkg
        val isNativeAppInstalled = resolvedNativePkg != null

        // Generate cryptographically secure PKCE code_verifier using official TikTok OpenSDK PKCEUtils.
        // AuthRequest.toBundle() and WebAuthHelper internally call PKCEUtils.generateCodeChallenge(codeVerifier)
        // which produces the official TikTok OpenSDK hex-encoded SHA-256 digest.
        val codeVerifier = PKCEUtils.generateCodeVerifier()
        val now = System.currentTimeMillis()

        pendingResult = result
        pendingCodeVerifier = codeVerifier
        pendingState = state
        pendingRedirectUri = redirectUri
        pendingTimestampMs = now
        persistPendingSession(codeVerifier, state, redirectUri, now)

        val authRequest = AuthRequest(
            clientKey = clientKey,
            scope = scope,
            redirectUri = redirectUri,
            codeVerifier = codeVerifier,
            autoAuthDisabled = false,
            state = state,
            language = language
        )

        val launched: Boolean = when {
            preferNative && sdkDetectedApp != null -> {
                Log.i(
                    TAG,
                    "Invoking official AuthApi.authorize(AuthMethod.TikTokApp) -> " +
                        "${sdkDetectedApp.appPackageName}/${sdkDetectedApp.appPackageName}.${Constants.TIKTOK.AUTH_ACTIVITY_NAME}"
                )
                authApi.authorize(
                    request = authRequest,
                    authMethod = AuthApi.AuthMethod.TikTokApp
                )
            }
            preferNative && fallbackNativePkg != null -> {
                Log.w(
                    TAG,
                    "TikTokAppCheckUtil returned null due to certificate rotation, but exported " +
                        "AwemeAuthorizedActivity was found in [$fallbackNativePkg]. Launching native component directly without ChromeTab."
                )
                launchNativeTikTokComponentDirectly(authRequest, fallbackNativePkg)
            }
            !preferNative -> {
                Log.i(TAG, "preferNative=false; invoking AuthApi.authorize(AuthMethod.ChromeTab)")
                authApi.authorize(
                    request = authRequest,
                    authMethod = AuthApi.AuthMethod.ChromeTab
                )
            }
            else -> {
                Log.e(
                    TAG,
                    "No installed TikTok package with AwemeAuthorizedActivity found on device, " +
                        "and preferNative=true suppresses browser/chooser fallback."
                )
                false
            }
        }

        Log.i(TAG, "TikTok native authorization launch result: launched=$launched (resolvedNativePkg=$resolvedNativePkg)")

        if (!launched) {
            val activeRes = pendingResult
            clearPendingSession()
            activeRes?.success(
                mapOf(
                    "status" to "unsupported",
                    "errorMessage" to "تعذر فتح تطبيق تيك توك الرسمي للمصادقة المباشرة. يرجى التأكد من تثبيت تطبيق TikTok وتحديثه.",
                    "usedNativeApp" to isNativeAppInstalled
                )
            )
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleTikTokAuthIntent(intent, source = "onNewIntent")
    }

    private fun parseTikTokResponseFromIntent(currentIntent: Intent): AuthResponse? {
        if (!::authApi.isInitialized) {
            authApi = AuthApi(activity = this)
        }
        // Check primary pendingRedirectUri first, then default and alternate callback paths
        authApi.getAuthResponseFromIntent(currentIntent, pendingRedirectUri)?.let { return it }
        if (pendingRedirectUri != DEFAULT_REDIRECT_URI) {
            authApi.getAuthResponseFromIntent(currentIntent, DEFAULT_REDIRECT_URI)?.let { return it }
        }
        if (pendingRedirectUri != ALT_REDIRECT_URI) {
            authApi.getAuthResponseFromIntent(currentIntent, ALT_REDIRECT_URI)?.let { return it }
        }
        return null
    }

    private fun handleTikTokAuthIntent(currentIntent: Intent?, source: String): Boolean {
        if (currentIntent == null) return false

        val extras = currentIntent.extras
        val intentType = extras?.getInt("_bytedance_params_type", 0) ?: 0
        val intentDataStr = currentIntent.dataString

        if (intentType != 0 || (intentDataStr != null && intentDataStr.contains("/tiktok/callback"))) {
            Log.i(
                TAG,
                "[$source] Received TikTok callback Intent: action=${currentIntent.action}, " +
                    "data=$intentDataStr, _bytedance_params_type=$intentType, " +
                    "errorCode=${extras?.getInt("_bytedance_params_error_code")}, " +
                    "authError=${extras?.getString("_bytedance_params_auth_error")}, " +
                    "authErrorDescription=${extras?.getString("_bytedance_params_auth_error_description")}, " +
                    "errorMsg=${extras?.getString("_bytedance_params_error_msg")}"
            )
        }

        val response: AuthResponse = parseTikTokResponseFromIntent(currentIntent)
            ?: return false

        // Consume and sanitize the callback Intent immediately so activity recreation
        // or duplicate intent delivery can never process the same response twice.
        sanitizeConsumedAuthIntent(currentIntent)

        // Ignore duplicate/stale Intent redeliveries if there is no active pending session
        if (pendingResult == null && pendingCodeVerifier == null && pendingState == null) {
            Log.w(TAG, "[$source] Ignoring TikTok callback Intent because no pending session is active.")
            return false
        }

        val activeResult = pendingResult
        val verifier = pendingCodeVerifier
        val expectedState = pendingState
        val redirectUri = pendingRedirectUri
        val usedNativeApp = TikTokAppCheckUtil.isTikTokAppInstalled(this) ||
            findExportedTikTokAuthPackage() != null

        clearPendingSession()

        if (response.isSuccess && response.authCode.isNotEmpty()) {
            Log.i(
                TAG,
                "[$source] TikTok AuthResponse SUCCESS: code length=${response.authCode.length}, " +
                    "grantedPermissions=${response.grantedPermissions}, stateMatches=${response.state == expectedState}"
            )
            // Strict state verification for anti-CSRF & replay protection
            if (expectedState.isNullOrEmpty() || response.state != expectedState) {
                val payload = mapOf(
                    "status" to "failed",
                    "errorCode" to -1,
                    "authError" to "state_mismatch",
                    "errorMessage" to "فشل التحقق الأمني: عدم تطابق رمز الحماية (State Mismatch).",
                    "usedNativeApp" to usedNativeApp
                )
                dispatchToFlutter(activeResult, payload)
                return true
            }

            if (verifier.isNullOrEmpty()) {
                val payload = mapOf(
                    "status" to "failed",
                    "errorCode" to -1,
                    "authError" to "missing_pkce_verifier",
                    "errorMessage" to "فشل استرجاع مفتاح التحقق الأمني (PKCE Verifier).",
                    "usedNativeApp" to usedNativeApp
                )
                dispatchToFlutter(activeResult, payload)
                return true
            }

            val payload = mapOf(
                "status" to "success",
                "code" to response.authCode,
                "codeVerifier" to verifier,
                "state" to (response.state ?: expectedState),
                "redirectUri" to redirectUri,
                "grantedPermissions" to response.grantedPermissions,
                "usedNativeApp" to usedNativeApp
            )
            dispatchToFlutter(activeResult, payload)
            return true
        } else {
            val status = when (response.errorCode) {
                Constants.BaseError.CANCELLED -> "cancelled"
                Constants.BaseError.ERROR_DENIED -> "denied"
                else -> if (response.authError == "access_denied" || response.authError == "user_cancelled") {
                    "cancelled"
                } else {
                    "failed"
                }
            }

            val rawDetails = listOfNotNull(
                response.authError?.takeIf { it.isNotBlank() },
                response.authErrorDescription?.takeIf { it.isNotBlank() },
                response.errorMsg?.takeIf { it.isNotBlank() }
            ).distinct().joinToString(" — ")

            val errorMsg = if (rawDetails.isNotEmpty()) {
                "تعذر الربط مع تيك توك ($rawDetails | code=${response.errorCode})"
            } else {
                "تم إلغاء أو رفض عملية المصادقة من تيك توك (code=${response.errorCode})."
            }

            Log.e(
                TAG,
                "[$source] TikTok AuthResponse ERROR: status=$status, errorCode=${response.errorCode}, " +
                    "authError=${response.authError}, authErrorDescription=${response.authErrorDescription}, " +
                    "errorMsg=${response.errorMsg}, callerCert=${getFormattedCallerSha256()}"
            )

            val payload = mapOf(
                "status" to status,
                "errorCode" to response.errorCode,
                "authError" to (response.authError ?: ""),
                "errorMessage" to errorMsg,
                "usedNativeApp" to usedNativeApp
            )
            dispatchToFlutter(activeResult, payload)
            return true
        }
    }

    private fun sanitizeConsumedAuthIntent(consumedIntent: Intent) {
        consumedIntent.removeExtra("_bytedance_params_type")
        consumedIntent.removeExtra("_bytedance_params_error_code")
        consumedIntent.removeExtra("_bytedance_params_error_msg")
        consumedIntent.removeExtra("_bytedance_params_authcode")
        consumedIntent.removeExtra("_bytedance_params_state")
        consumedIntent.removeExtra("_bytedance_params_granted_permission")
        consumedIntent.removeExtra("_bytedance_params_auth_error")
        consumedIntent.removeExtra("_bytedance_params_auth_error_description")
        consumedIntent.data = null
        setIntent(Intent(Intent.ACTION_MAIN))
    }

    private fun cancelActivePendingSession() {
        val activeRes = pendingResult
        val usedNativeApp = TikTokAppCheckUtil.isTikTokAppInstalled(this) ||
            findExportedTikTokAuthPackage() != null
        clearPendingSession()
        if (activeRes != null) {
            activeRes.success(
                mapOf(
                    "status" to "cancelled",
                    "errorCode" to Constants.BaseError.CANCELLED,
                    "authError" to "user_cancelled",
                    "errorMessage" to "تم إلغاء عملية تسجيل الدخول عبر تيك توك.",
                    "usedNativeApp" to usedNativeApp
                )
            )
        }
    }

    private fun dispatchToFlutter(activeResult: MethodChannel.Result?, payload: Map<String, Any?>) {
        if (activeResult != null) {
            activeResult.success(payload)
        } else if (methodChannel != null) {
            methodChannel?.invokeMethod("onAuthResponse", payload)
        } else {
            pendingPostCreationPayload = payload
        }
    }

    private fun persistPendingSession(verifier: String, state: String, redirectUri: String, timestampMs: Long) {
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
            .putString(KEY_VERIFIER, verifier)
            .putString(KEY_STATE, state)
            .putString(KEY_REDIRECT_URI, redirectUri)
            .putLong(KEY_TIMESTAMP, timestampMs)
            .apply()
    }

    private fun restorePendingSession(savedInstanceState: Bundle?) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val savedTimestamp = savedInstanceState?.getLong(KEY_TIMESTAMP, 0L)?.takeIf { it > 0L }
            ?: prefs.getLong(KEY_TIMESTAMP, 0L)
        val isExpired = savedTimestamp <= 0L || (System.currentTimeMillis() - savedTimestamp) > MAX_PENDING_AGE_MS

        if (isExpired && savedInstanceState == null) {
            prefs.edit().clear().apply()
            return
        }

        pendingCodeVerifier = savedInstanceState?.getString(KEY_VERIFIER)
            ?: prefs.getString(KEY_VERIFIER, null)
        pendingState = savedInstanceState?.getString(KEY_STATE)
            ?: prefs.getString(KEY_STATE, null)
        pendingRedirectUri = savedInstanceState?.getString(KEY_REDIRECT_URI)
            ?: prefs.getString(KEY_REDIRECT_URI, DEFAULT_REDIRECT_URI)
            ?: DEFAULT_REDIRECT_URI
        pendingTimestampMs = savedTimestamp
    }

    private fun clearPendingSession() {
        pendingResult = null
        pendingCodeVerifier = null
        pendingState = null
        pendingTimestampMs = 0L
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit().clear().apply()
    }
}
