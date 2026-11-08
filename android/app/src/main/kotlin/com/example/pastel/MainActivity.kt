package com.pasteleg.app

import android.content.Intent
import android.os.Bundle
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
    }

    private lateinit var authApi: AuthApi
    private var methodChannel: MethodChannel? = null

    // Active PKCE & state session bound to the in-flight native authorization request
    private var pendingResult: MethodChannel.Result? = null
    private var pendingCodeVerifier: String? = null
    private var pendingState: String? = null
    private var pendingRedirectUri: String = DEFAULT_REDIRECT_URI

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        authApi = AuthApi(activity = this)
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
                "authorize" -> handleAuthorize(call, result)
                "cancel" -> {
                    clearPendingSession()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        methodChannel = channel
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
        // Note: AuthRequest.toBundle() and WebAuthHelper internally call PKCEUtils.generateCodeChallenge(codeVerifier)
        // which produces the official TikTok OpenSDK hex-encoded SHA-256 digest.
        val codeVerifier = PKCEUtils.generateCodeVerifier()

        pendingResult = result
        pendingCodeVerifier = codeVerifier
        pendingState = state.ifEmpty { null }
        pendingRedirectUri = redirectUri

        val authRequest = AuthRequest(
            clientKey = clientKey,
            scope = scope,
            redirectUri = redirectUri,
            codeVerifier = codeVerifier,
            autoAuthDisabled = false,
            state = pendingState,
            language = language
        )

        // AuthMethod.TikTokApp checks TikTokAppCheckUtil.getInstalledTikTokApp(activity) first
        // and launches openauthorize.AwemeAuthorizedActivity natively; if TikTok is not installed,
        // AuthApi.authorize automatically falls back to AuthMethod.ChromeTab (CustomTabsIntent).
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
            if (!expectedState.isNullOrEmpty() && response.state != expectedState) {
                val payload = mapOf(
                    "status" to "failed",
                    "errorCode" to -1,
                    "authError" to "state_mismatch",
                    "errorMessage" to "فشل التحقق الأمني: عدم تطابق رمز الحماية (State Mismatch).",
                    "usedNativeApp" to usedNativeApp
                )
                if (activeResult != null) {
                    activeResult.success(payload)
                } else {
                    methodChannel?.invokeMethod("onAuthResponse", payload)
                }
                return
            }

            val payload = mapOf(
                "status" to "success",
                "code" to response.authCode,
                "codeVerifier" to (verifier ?: ""),
                "state" to (response.state ?: expectedState ?: ""),
                "redirectUri" to redirectUri,
                "grantedPermissions" to response.grantedPermissions,
                "usedNativeApp" to usedNativeApp
            )
            if (activeResult != null) {
                activeResult.success(payload)
            } else {
                methodChannel?.invokeMethod("onAuthResponse", payload)
            }
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
            if (activeResult != null) {
                activeResult.success(payload)
            } else {
                methodChannel?.invokeMethod("onAuthResponse", payload)
            }
        }
    }

    private fun clearPendingSession() {
        pendingResult = null
        pendingCodeVerifier = null
        pendingState = null
    }
}
