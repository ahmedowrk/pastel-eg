package com.pasteleg.app

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import com.tiktok.open.sdk.auth.AuthApi
import com.tiktok.open.sdk.auth.AuthRequest
import com.tiktok.open.sdk.auth.AuthResponse
import com.tiktok.open.sdk.auth.utils.PKCEUtils
import com.tiktok.open.sdk.core.appcheck.TikTokAppCheckUtil
import com.tiktok.open.sdk.core.constants.Constants
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL_NAME = "com.pasteleg.app/tiktok_sdk"
        private const val DEFAULT_REDIRECT_URI = "https://pastel-eg.com/social-connections/tiktok/callback"
        private const val PREFS_NAME = "pastel_tiktok_auth_state"
        private const val KEY_VERIFIER = "pending_code_verifier"
        private const val KEY_STATE = "pending_state"
        private const val KEY_REDIRECT_URI = "pending_redirect_uri"
    }

    private lateinit var authApi: AuthApi
    private var methodChannel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Active PKCE & state session bound to the in-flight native authorization request
    private var pendingResult: MethodChannel.Result? = null
    private var pendingCodeVerifier: String? = null
    private var pendingState: String? = null
    private var pendingRedirectUri: String = DEFAULT_REDIRECT_URI
    private var hasLeftActivityForAuth: Boolean = false
    private var pendingPostCreationPayload: Map<String, Any?>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        authApi = AuthApi(activity = this)
        restorePendingSession(savedInstanceState)
        handleTikTokAuthIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        authApi = AuthApi(activity = this)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isTikTokInstalled" -> {
                    val installed = TikTokAppCheckUtil.isTikTokAppInstalled(this)
                    result.success(installed)
                }
                "getCookiesForUrl" -> {
                    val url = call.argument<String>("url") ?: "https://pastel-eg.com"
                    val cookies = CookieManager.getInstance().getCookie(url) ?: ""
                    result.success(cookies)
                }
                "authorize" -> handleAuthorize(call, result)
                "cancel" -> {
                    clearPendingSession()
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
    }

    override fun onPause() {
        super.onPause()
        if (pendingResult != null || pendingCodeVerifier != null) {
            hasLeftActivityForAuth = true
        }
    }

    override fun onResume() {
        super.onResume()
        if (hasLeftActivityForAuth && (pendingResult != null || pendingCodeVerifier != null)) {
            // Delay slightly so onNewIntent (if triggered by a valid TikTok callback) executes first
            mainHandler.postDelayed({
                if (hasLeftActivityForAuth && (pendingResult != null || pendingCodeVerifier != null)) {
                    val activeRes = pendingResult
                    val usedNativeApp = TikTokAppCheckUtil.isTikTokAppInstalled(this)
                    clearPendingSession()
                    val cancelPayload = mapOf(
                        "status" to "cancelled",
                        "errorCode" to Constants.BaseError.CANCELLED,
                        "authError" to "user_cancelled",
                        "errorMessage" to "تم إلغاء عملية تسجيل الدخول عبر تيك توك.",
                        "usedNativeApp" to usedNativeApp
                    )
                    if (activeRes != null) {
                        activeRes.success(cancelPayload)
                    } else {
                        methodChannel?.invokeMethod("onAuthResponse", cancelPayload)
                    }
                }
            }, 650L)
        }
    }

    private fun handleAuthorize(call: MethodCall, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error(
                "DUPLICATE_REQUEST",
                "A TikTok authorization request is already in progress.",
                null
            )
            return
        }

        val clientKey = call.argument<String>("clientKey")?.trim().orEmpty()
        val scope = call.argument<String>("scope")?.trim().orEmpty()
        val redirectUri = call.argument<String>("redirectUri")?.trim().takeUnless { it.isNullOrEmpty() }
            ?: DEFAULT_REDIRECT_URI
        val state = call.argument<String>("state")?.trim().orEmpty()
        val preferNative = call.argument<Boolean>("preferNative") ?: true
        val language = call.argument<String>("language") ?: "ar"

        if (clientKey.isEmpty() || scope.isEmpty() || redirectUri.isEmpty()) {
            result.error(
                "INVALID_ARGS",
                "clientKey, scope, and redirectUri are required for TikTok OpenSDK authorization.",
                null
            )
            return
        }

        // Generate cryptographically secure PKCE code_verifier using official TikTok OpenSDK PKCEUtils.
        // AuthRequest.toBundle() and WebAuthHelper internally call PKCEUtils.generateCodeChallenge(codeVerifier)
        // which produces the official TikTok OpenSDK hex-encoded SHA-256 digest.
        val codeVerifier = PKCEUtils.generateCodeVerifier()

        pendingResult = result
        pendingCodeVerifier = codeVerifier
        pendingState = state.ifEmpty { null }
        pendingRedirectUri = redirectUri
        hasLeftActivityForAuth = false
        persistPendingSession(codeVerifier, pendingState, redirectUri)

        val authRequest = AuthRequest(
            clientKey = clientKey,
            scope = scope,
            redirectUri = redirectUri,
            codeVerifier = codeVerifier,
            autoAuthDisabled = false,
            state = pendingState,
            language = language
        )

        val authMethod = if (preferNative) {
            AuthApi.AuthMethod.TikTokApp
        } else {
            AuthApi.AuthMethod.ChromeTab
        }

        val isNativeAppInstalled = TikTokAppCheckUtil.isTikTokAppInstalled(this)
        val launched = authApi.authorize(
            request = authRequest,
            authMethod = authMethod
        )

        if (!launched) {
            val activeRes = pendingResult
            clearPendingSession()
            activeRes?.success(
                mapOf(
                    "status" to "unsupported",
                    "errorMessage" to "تعذر تشغيل مصادقة تيك توك (TikTok OpenSDK).",
                    "usedNativeApp" to isNativeAppInstalled
                )
            )
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleTikTokAuthIntent(intent)
    }

    private fun handleTikTokAuthIntent(currentIntent: Intent?) {
        if (currentIntent == null) return
        if (!::authApi.isInitialized) {
            authApi = AuthApi(activity = this)
        }

        val response: AuthResponse = authApi.getAuthResponseFromIntent(currentIntent, pendingRedirectUri)
            ?: return

        val activeResult = pendingResult
        val verifier = pendingCodeVerifier
        val expectedState = pendingState
        val redirectUri = pendingRedirectUri
        val usedNativeApp = TikTokAppCheckUtil.isTikTokAppInstalled(this)

        clearPendingSession()

        if (response.isSuccess && response.authCode.isNotEmpty()) {
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
                return
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
                return
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

            val errorMsg = response.authErrorDescription
                ?: response.errorMsg
                ?: response.authError
                ?: "تم إلغاء أو رفض عملية المصادقة من تيك توك."

            val payload = mapOf(
                "status" to status,
                "errorCode" to response.errorCode,
                "authError" to (response.authError ?: ""),
                "errorMessage" to errorMsg,
                "usedNativeApp" to usedNativeApp
            )
            dispatchToFlutter(activeResult, payload)
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

    private fun persistPendingSession(verifier: String, state: String?, redirectUri: String) {
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
            .putString(KEY_VERIFIER, verifier)
            .putString(KEY_STATE, state)
            .putString(KEY_REDIRECT_URI, redirectUri)
            .apply()
    }

    private fun restorePendingSession(savedInstanceState: Bundle?) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        pendingCodeVerifier = savedInstanceState?.getString(KEY_VERIFIER)
            ?: prefs.getString(KEY_VERIFIER, null)
        pendingState = savedInstanceState?.getString(KEY_STATE)
            ?: prefs.getString(KEY_STATE, null)
        pendingRedirectUri = savedInstanceState?.getString(KEY_REDIRECT_URI)
            ?: prefs.getString(KEY_REDIRECT_URI, DEFAULT_REDIRECT_URI)
            ?: DEFAULT_REDIRECT_URI
    }

    private fun clearPendingSession() {
        mainHandler.removeCallbacksAndMessages(null)
        pendingResult = null
        pendingCodeVerifier = null
        pendingState = null
        hasLeftActivityForAuth = false
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit().clear().apply()
    }
}
