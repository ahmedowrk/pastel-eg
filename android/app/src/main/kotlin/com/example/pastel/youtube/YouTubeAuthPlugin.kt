package com.pasteleg.app.youtube

import android.accounts.Account
import android.accounts.AccountManager
import android.app.Activity
import android.content.Intent
import android.util.Log
import androidx.credentials.ClearCredentialStateRequest
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.ClearCredentialException
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.AccountPicker
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.common.api.Scope
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Isolated Native Android handler for YouTube Google Account Selection and
 * YouTube Data API v3 OAuth 2.0 Authorization.
 *
 * Completely independent from Meta / Facebook SDK (`flutter_facebook_auth`).
 */
class YouTubeAuthPlugin(
    private val activity: Activity,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {

    companion object {
        private const val TAG = "YouTubeOAuthDebug"
        private const val CHANNEL_NAME = "com.pasteleg.app/youtube_auth"
        private const val REQUEST_CODE_SYSTEM_ACCOUNT_PICKER = 9401
        private const val REQUEST_CODE_YOUTUBE_AUTHORIZATION = 9402
        private const val GOOGLE_ACCOUNT_TYPE = "com.google"
    }

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val credentialManager: CredentialManager by lazy {
        CredentialManager.create(activity)
    }
    private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private var pendingAccountPickResult: MethodChannel.Result? = null
    private var pendingAuthorizeResult: MethodChannel.Result? = null
    private var pendingRequestedAccountEmail: String? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "[MethodChannel] Received method call: ${call.method}")
        when (call.method) {
            "pickGoogleAccount" -> handlePickGoogleAccount(call, result)
            "authorizeYouTubeScopes" -> handleAuthorizeYouTubeScopes(call, result)
            "clearSelectedAccountSession" -> handleClearSelectedAccountSession(result)
            else -> {
                Log.w(TAG, "[MethodChannel] Unimplemented method: ${call.method}")
                result.notImplemented()
            }
        }
    }

    private fun handlePickGoogleAccount(call: MethodCall, result: MethodChannel.Result) {
        if (pendingAccountPickResult != null) {
            Log.w(TAG, "[Stage 1] pickGoogleAccount rejected: picker_already_active")
            sendResultToFlutter(
                stage = "Stage 6 - pickGoogleAccount (picker_already_active)",
                result = result,
                payload = mapOf(
                    "status" to "error",
                    "errorCode" to "picker_already_active",
                    "errorMessage" to "توجد نافذة اختيار حساب Google مفتوحة بالفعل."
                )
            )
            return
        }

        val serverClientId = call.argument<String>("serverClientId")?.trim().orEmpty()
        val filterByAuthorizedAccounts =
            call.argument<Boolean>("filterByAuthorizedAccounts") ?: false
        val forceAccountSelection =
            call.argument<Boolean>("forceAccountSelection") ?: true

        Log.d(
            TAG,
            "[Stage 1] pickGoogleAccount START | " +
                "filterByAuthorizedAccounts=$filterByAuthorizedAccounts, " +
                "forceAccountSelection=$forceAccountSelection, " +
                "hasServerClientId=${serverClientId.isNotEmpty()}"
        )

        mainScope.launch {
            if (forceAccountSelection) {
                try {
                    Log.d(TAG, "[Stage 1] Clearing previous CredentialManager state...")
                    credentialManager.clearCredentialState(ClearCredentialStateRequest())
                    Log.d(TAG, "[Stage 1] CredentialManager state cleared successfully")
                } catch (e: ClearCredentialException) {
                    logExceptionDetails("Stage 1 - clearCredentialState (ClearCredentialException)", e)
                } catch (e: Exception) {
                    logExceptionDetails("Stage 1 - clearCredentialState (Exception)", e)
                }
            }

            if (serverClientId.isEmpty()) {
                Log.w(TAG, "[Stage 1] serverClientId is empty, falling back to system AccountPicker")
                launchSystemAccountPickerFallback(result, reason = "empty_server_client_id")
                return@launch
            }

            try {
                Log.d(TAG, "[Stage 1] Requesting Google ID credential via CredentialManager.getCredential...")
                val googleIdOption = GetGoogleIdOption.Builder()
                    .setFilterByAuthorizedAccounts(filterByAuthorizedAccounts)
                    .setServerClientId(serverClientId)
                    .setAutoSelectEnabled(false)
                    .build()

                val request = GetCredentialRequest.Builder()
                    .addCredentialOption(googleIdOption)
                    .build()

                val response = credentialManager.getCredential(
                    request = request,
                    context = activity
                )

                val credential = response.credential
                Log.d(
                    TAG,
                    "[Stage 2] CredentialManager returned credential | " +
                        "class=${credential.javaClass.name}, type=${credential.type}"
                )

                if (credential is CustomCredential &&
                    credential.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL
                ) {
                    val googleIdCredential = GoogleIdTokenCredential.createFrom(credential.data)
                    Log.d(
                        TAG,
                        "[Stage 2] Account selection SUCCESS via CredentialManager | " +
                            "hasEmail=${googleIdCredential.id.isNotEmpty()}, " +
                            "hasDisplayName=${!googleIdCredential.displayName.isNullOrEmpty()}, " +
                            "hasProfilePicture=${googleIdCredential.profilePictureUri != null}, " +
                            "hasIdToken=${googleIdCredential.idToken.isNotEmpty()}"
                    )
                    sendResultToFlutter(
                        stage = "Stage 6 - pickGoogleAccount (credential_manager_success)",
                        result = result,
                        payload = mapOf(
                            "status" to "selected",
                            "email" to googleIdCredential.id,
                            "displayName" to googleIdCredential.displayName,
                            "profilePictureUri" to googleIdCredential.profilePictureUri?.toString(),
                            "idToken" to googleIdCredential.idToken,
                            "selectionSource" to "credential_manager"
                        )
                    )
                } else {
                    Log.w(
                        TAG,
                        "[Stage 1] CredentialManager returned unexpected credential type (${credential.type}), " +
                            "falling back to system AccountPicker"
                    )
                    launchSystemAccountPickerFallback(result, reason = "unexpected_credential_type_${credential.type}")
                }
            } catch (e: GetCredentialCancellationException) {
                logExceptionDetails("Stage 1 - CredentialManager.getCredential (Cancelled)", e)
                sendResultToFlutter(
                    stage = "Stage 6 - pickGoogleAccount (credential_manager_cancelled)",
                    result = result,
                    payload = mapOf(
                        "status" to "cancelled",
                        "errorCode" to "user_cancelled",
                        "errorMessage" to "تم إلغاء اختيار حساب Google."
                    )
                )
            } catch (e: NoCredentialException) {
                logExceptionDetails("Stage 1 - CredentialManager.getCredential (NoCredentialException -> fallback)", e)
                launchSystemAccountPickerFallback(result, reason = "NoCredentialException:${e.type}")
            } catch (e: GetCredentialException) {
                logExceptionDetails("Stage 1 - CredentialManager.getCredential (GetCredentialException -> fallback)", e)
                launchSystemAccountPickerFallback(result, reason = "GetCredentialException:${e.type}")
            } catch (e: Exception) {
                logExceptionDetails("Stage 1 - CredentialManager.getCredential (Exception -> fallback)", e)
                launchSystemAccountPickerFallback(result, reason = "Exception:${e.javaClass.simpleName}")
            }
        }
    }

    private fun launchSystemAccountPickerFallback(
        result: MethodChannel.Result,
        reason: String
    ) {
        Log.d(
            TAG,
            "[Stage 1] Launching system AccountPicker fallback | " +
                "reason=$reason, requestCode=$REQUEST_CODE_SYSTEM_ACCOUNT_PICKER"
        )
        try {
            val options = AccountPicker.AccountChooserOptions.Builder()
                .setAllowableAccountsTypes(listOf(GOOGLE_ACCOUNT_TYPE))
                .setAlwaysShowAccountPicker(true)
                .build()
            val intent = AccountPicker.newChooseAccountIntent(options)
            pendingAccountPickResult = result
            activity.startActivityForResult(intent, REQUEST_CODE_SYSTEM_ACCOUNT_PICKER)
            Log.d(TAG, "[Stage 1] System AccountPicker startActivityForResult invoked successfully")
        } catch (e: Exception) {
            pendingAccountPickResult = null
            logExceptionDetails("Stage 1 - launchSystemAccountPickerFallback", e)
            sendResultToFlutter(
                stage = "Stage 6 - pickGoogleAccount (account_picker_unavailable)",
                result = result,
                payload = mapOf(
                    "status" to "error",
                    "errorCode" to "account_picker_unavailable",
                    "errorMessage" to (e.localizedMessage
                        ?: "تعذر فتح نافذة اختيار حسابات Google على هذا الجهاز.")
                )
            )
        }
    }

    private fun handleAuthorizeYouTubeScopes(call: MethodCall, result: MethodChannel.Result) {
        if (pendingAuthorizeResult != null) {
            Log.w(TAG, "[Stage 3] authorizeYouTubeScopes rejected: authorization_already_active")
            sendResultToFlutter(
                stage = "Stage 6 - authorizeYouTubeScopes (authorization_already_active)",
                result = result,
                payload = mapOf(
                    "status" to "error",
                    "errorCode" to "authorization_already_active",
                    "errorMessage" to "توجد عملية تفويض صلاحيات YouTube جارية بالفعل."
                )
            )
            return
        }

        val accountEmail = call.argument<String>("accountEmail")?.trim().orEmpty()
        val serverClientId = call.argument<String>("serverClientId")?.trim().orEmpty()
        val rawScopes = call.argument<List<String>>("scopes").orEmpty()
        val forceCodeForRefreshToken =
            call.argument<Boolean>("forceCodeForRefreshToken") ?: true

        Log.d(
            TAG,
            "[Stage 3] authorizeYouTubeScopes START | " +
                "hasAccountEmail=${accountEmail.isNotEmpty()}, " +
                "hasServerClientId=${serverClientId.isNotEmpty()}, " +
                "forceCodeForRefreshToken=$forceCodeForRefreshToken, " +
                "requestedScopesCount=${rawScopes.size}, " +
                "requestedScopes=${rawScopes.joinToString()}"
        )

        if (accountEmail.isEmpty()) {
            Log.e(TAG, "[Stage 3] authorizeYouTubeScopes failed: missing_account_email")
            sendResultToFlutter(
                stage = "Stage 6 - authorizeYouTubeScopes (missing_account_email)",
                result = result,
                payload = mapOf(
                    "status" to "error",
                    "errorCode" to "missing_account_email",
                    "errorMessage" to "لم يتم تحديد بريد حساب Google المراد تفويضه."
                )
            )
            return
        }

        val requestedScopes = rawScopes
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .map { Scope(it) }

        if (requestedScopes.isEmpty()) {
            Log.e(TAG, "[Stage 3] authorizeYouTubeScopes failed: missing_youtube_scopes")
            sendResultToFlutter(
                stage = "Stage 6 - authorizeYouTubeScopes (missing_youtube_scopes)",
                result = result,
                payload = mapOf(
                    "status" to "error",
                    "selectedAccountEmail" to accountEmail,
                    "errorCode" to "missing_youtube_scopes",
                    "errorMessage" to "لم يتم تحديد صلاحيات YouTube المطلوبة."
                )
            )
            return
        }

        try {
            val builder = AuthorizationRequest.Builder()
                .setRequestedScopes(requestedScopes)
                .setAccount(Account(accountEmail, GOOGLE_ACCOUNT_TYPE))

            if (serverClientId.isNotEmpty()) {
                builder.requestOfflineAccess(serverClientId, forceCodeForRefreshToken)
            }

            val authorizationRequest = builder.build()
            Log.d(
                TAG,
                "[Stage 3] Invoking Identity.getAuthorizationClient(activity).authorize(...) | " +
                    "accountType=$GOOGLE_ACCOUNT_TYPE, " +
                    "offlineAccessRequested=${serverClientId.isNotEmpty()}"
            )

            Identity.getAuthorizationClient(activity)
                .authorize(authorizationRequest)
                .addOnSuccessListener { authorizationResult ->
                    Log.d(
                        TAG,
                        "[Stage 4] AuthorizationClient.authorize onSuccess | " +
                            "hasResolution=${authorizationResult.hasResolution()}, " +
                            "hasPendingIntent=${authorizationResult.pendingIntent != null}, " +
                            "hasAccessToken=${!authorizationResult.accessToken.isNullOrEmpty()}, " +
                            "hasServerAuthCode=${!authorizationResult.serverAuthCode.isNullOrEmpty()}, " +
                            "grantedScopesCount=${authorizationResult.grantedScopes.size}, " +
                            "grantedScopes=${authorizationResult.grantedScopes.joinToString()}"
                    )
                    if (authorizationResult.hasResolution()) {
                        val pendingIntent = authorizationResult.pendingIntent
                        if (pendingIntent != null) {
                            try {
                                pendingAuthorizeResult = result
                                pendingRequestedAccountEmail = accountEmail
                                Log.d(
                                    TAG,
                                    "[Stage 4] Launching Google OAuth consent resolution via startIntentSenderForResult " +
                                        "(requestCode=$REQUEST_CODE_YOUTUBE_AUTHORIZATION, " +
                                        "creatorPackage=${pendingIntent.creatorPackage})"
                                )
                                activity.startIntentSenderForResult(
                                    pendingIntent.intentSender,
                                    REQUEST_CODE_YOUTUBE_AUTHORIZATION,
                                    null,
                                    0,
                                    0,
                                    0
                                )
                            } catch (e: Exception) {
                                pendingAuthorizeResult = null
                                pendingRequestedAccountEmail = null
                                logExceptionDetails("Stage 4 - startIntentSenderForResult", e)
                                sendResultToFlutter(
                                    stage = "Stage 6 - authorizeYouTubeScopes (resolution_launch_failed)",
                                    result = result,
                                    payload = mapOf(
                                        "status" to "error",
                                        "selectedAccountEmail" to accountEmail,
                                        "errorCode" to "resolution_launch_failed",
                                        "errorMessage" to (e.localizedMessage
                                            ?: "تعذر فتح شاشة الموافقة على صلاحيات YouTube.")
                                    )
                                )
                            }
                        } else {
                            Log.e(TAG, "[Stage 4] hasResolution=true but pendingIntent is null!")
                            sendResultToFlutter(
                                stage = "Stage 6 - authorizeYouTubeScopes (missing_resolution_intent)",
                                result = result,
                                payload = mapOf(
                                    "status" to "error",
                                    "selectedAccountEmail" to accountEmail,
                                    "errorCode" to "missing_resolution_intent",
                                    "errorMessage" to "تعذر بدء شاشة موافقة Google لصلاحيات YouTube."
                                )
                            )
                        }
                    } else {
                        Log.d(TAG, "[Stage 4] hasResolution=false (permissions already granted), completing directly")
                        completeWithAuthorizationResult(
                            result = result,
                            accountEmail = accountEmail,
                            authResult = authorizationResult
                        )
                    }
                }
                .addOnFailureListener { e ->
                    logExceptionDetails("Stage 4 - AuthorizationClient.authorize.addOnFailureListener", e)
                    val statusCode = (e as? ApiException)?.statusCode
                    val isCancelled = statusCode == CommonStatusCodes.CANCELED
                    sendResultToFlutter(
                        stage = "Stage 6 - authorizeYouTubeScopes (authorize_onFailure)",
                        result = result,
                        payload = mapOf(
                            "status" to if (isCancelled) "cancelled" else "error",
                            "selectedAccountEmail" to accountEmail,
                            "errorCode" to (statusCode?.toString() ?: "authorize_failed"),
                            "errorMessage" to (e.localizedMessage
                                ?: "تعذر تفويض صلاحيات YouTube عبر Google Play Services.")
                        )
                    )
                }
        } catch (e: Exception) {
            logExceptionDetails("Stage 3 - handleAuthorizeYouTubeScopes (outer catch)", e)
            sendResultToFlutter(
                stage = "Stage 6 - authorizeYouTubeScopes (authorize_exception)",
                result = result,
                payload = mapOf(
                    "status" to "error",
                    "selectedAccountEmail" to accountEmail,
                    "errorCode" to "authorize_exception",
                    "errorMessage" to (e.localizedMessage ?: "حدث خطأ غير متوقع أثناء تفويض YouTube.")
                )
            )
        }
    }

    private fun handleClearSelectedAccountSession(result: MethodChannel.Result) {
        Log.d(TAG, "[Session] clearSelectedAccountSession called")
        mainScope.launch {
            try {
                credentialManager.clearCredentialState(ClearCredentialStateRequest())
                Log.d(TAG, "[Session] clearSelectedAccountSession completed")
            } catch (e: Exception) {
                logExceptionDetails("Session - clearSelectedAccountSession", e)
            }
            result.success(null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == REQUEST_CODE_SYSTEM_ACCOUNT_PICKER) {
            Log.d(
                TAG,
                "[Stage 2] onActivityResult(REQUEST_CODE_SYSTEM_ACCOUNT_PICKER) | " +
                    "resultCode=$resultCode (${resultCodeToString(resultCode)}), " +
                    "hasData=${data != null}, " +
                    "extraKeys=${data?.extras?.keySet()?.joinToString()}"
            )
            val callback = pendingAccountPickResult
            pendingAccountPickResult = null
            if (callback == null) {
                Log.w(TAG, "[Stage 2] pendingAccountPickResult was null on activity result!")
                return true
            }

            if (resultCode == Activity.RESULT_OK && data != null) {
                val accountName =
                    data.getStringExtra(AccountManager.KEY_ACCOUNT_NAME)?.trim().orEmpty()
                val accountType = data.getStringExtra(AccountManager.KEY_ACCOUNT_TYPE)
                Log.d(
                    TAG,
                    "[Stage 2] System AccountPicker result OK | " +
                        "hasEmail=${accountName.isNotEmpty()}, " +
                        "emailLength=${accountName.length}, " +
                        "accountType=$accountType"
                )
                if (accountName.isNotEmpty()) {
                    sendResultToFlutter(
                        stage = "Stage 6 - pickGoogleAccount (system_account_picker_success)",
                        result = callback,
                        payload = mapOf(
                            "status" to "selected",
                            "email" to accountName,
                            "selectionSource" to "system_account_picker"
                        )
                    )
                } else {
                    Log.w(TAG, "[Stage 2] System AccountPicker returned empty KEY_ACCOUNT_NAME")
                    sendResultToFlutter(
                        stage = "Stage 6 - pickGoogleAccount (empty_account_name)",
                        result = callback,
                        payload = mapOf(
                            "status" to "no_accounts",
                            "errorCode" to "empty_account_name",
                            "errorMessage" to "لم يتم العثور على بريد Google للحساب المختار."
                        )
                    )
                }
            } else {
                Log.w(
                    TAG,
                    "[Stage 2] System AccountPicker cancelled or failed | " +
                        "resultCode=$resultCode (${resultCodeToString(resultCode)})"
                )
                sendResultToFlutter(
                    stage = "Stage 6 - pickGoogleAccount (system_account_picker_cancelled)",
                    result = callback,
                    payload = mapOf(
                        "status" to "cancelled",
                        "errorCode" to "user_cancelled",
                        "errorMessage" to "تم إلغاء اختيار حساب Google."
                    )
                )
            }
            return true
        }

        if (requestCode == REQUEST_CODE_YOUTUBE_AUTHORIZATION) {
            Log.d(
                TAG,
                "[Stage 4] onActivityResult(REQUEST_CODE_YOUTUBE_AUTHORIZATION) | " +
                    "resultCode=$resultCode (${resultCodeToString(resultCode)}), " +
                    "hasData=${data != null}, " +
                    "extraKeys=${data?.extras?.keySet()?.joinToString()}"
            )
            inspectIntentExtrasDiagnostic("Stage 4 - REQUEST_CODE_YOUTUBE_AUTHORIZATION", data)

            val callback = pendingAuthorizeResult
            val accountEmail = pendingRequestedAccountEmail.orEmpty()
            pendingAuthorizeResult = null
            pendingRequestedAccountEmail = null
            if (callback == null) {
                Log.w(TAG, "[Stage 4] pendingAuthorizeResult was null on activity result!")
                return true
            }

            if (data == null || resultCode != Activity.RESULT_OK) {
                Log.w(
                    TAG,
                    "[Stage 4] Resolution returned non-OK or null intent | " +
                        "resultCode=$resultCode (${resultCodeToString(resultCode)}), " +
                        "hasData=${data != null}"
                )
                // Diagnostic-only inspection: if Play Services returned an Intent with
                // RESULT_CANCELED, calling getAuthorizationResultFromIntent(data) extracts
                // the underlying ApiException (e.g., DEVELOPER_ERROR 10, CANCELED 16, etc.)
                // so we can log the exact root cause without altering control flow.
                if (data != null) {
                    try {
                        val diagnosticAuthResult = Identity.getAuthorizationClient(activity)
                            .getAuthorizationResultFromIntent(data)
                        Log.d(
                            TAG,
                            "[Stage 4 - Diagnostic] getAuthorizationResultFromIntent on non-OK result succeeded unexpectedly | " +
                                "hasAccessToken=${!diagnosticAuthResult.accessToken.isNullOrEmpty()}, " +
                                "hasServerAuthCode=${!diagnosticAuthResult.serverAuthCode.isNullOrEmpty()}, " +
                                "grantedScopes=${diagnosticAuthResult.grantedScopes.joinToString()}"
                        )
                    } catch (e: Exception) {
                        logExceptionDetails(
                            "Stage 5 - getAuthorizationResultFromIntent (on non-OK resultCode=$resultCode)",
                            e
                        )
                    }
                }

                sendResultToFlutter(
                    stage = "Stage 6 - authorizeYouTubeScopes (consent_cancelled_or_denied)",
                    result = callback,
                    payload = mapOf(
                        "status" to "cancelled",
                        "selectedAccountEmail" to accountEmail,
                        "errorCode" to "consent_cancelled_or_denied",
                        "errorMessage" to "تم إلغاء أو رفض الموافقة على صلاحيات YouTube."
                    )
                )
                return true
            }

            try {
                val authResult = Identity.getAuthorizationClient(activity)
                    .getAuthorizationResultFromIntent(data)
                Log.d(
                    TAG,
                    "[Stage 4] getAuthorizationResultFromIntent SUCCESS | " +
                        "hasAccessToken=${!authResult.accessToken.isNullOrEmpty()}, " +
                        "hasServerAuthCode=${!authResult.serverAuthCode.isNullOrEmpty()}, " +
                        "grantedScopesCount=${authResult.grantedScopes.size}, " +
                        "grantedScopes=${authResult.grantedScopes.joinToString()}"
                )
                completeWithAuthorizationResult(
                    result = callback,
                    accountEmail = accountEmail,
                    authResult = authResult
                )
            } catch (e: ApiException) {
                logExceptionDetails("Stage 5 - getAuthorizationResultFromIntent (ApiException)", e)
                val isCancelled = e.statusCode == CommonStatusCodes.CANCELED
                sendResultToFlutter(
                    stage = "Stage 6 - authorizeYouTubeScopes (api_exception_${e.statusCode})",
                    result = callback,
                    payload = mapOf(
                        "status" to if (isCancelled) "cancelled" else "denied",
                        "selectedAccountEmail" to accountEmail,
                        "errorCode" to "api_exception_${e.statusCode}",
                        "errorMessage" to (e.localizedMessage
                            ?: "تم رفض منح صلاحيات الوصول إلى قناة YouTube.")
                    )
                )
            } catch (e: Exception) {
                logExceptionDetails("Stage 5 - getAuthorizationResultFromIntent (Exception)", e)
                sendResultToFlutter(
                    stage = "Stage 6 - authorizeYouTubeScopes (authorization_result_error)",
                    result = callback,
                    payload = mapOf(
                        "status" to "error",
                        "selectedAccountEmail" to accountEmail,
                        "errorCode" to "authorization_result_error",
                        "errorMessage" to (e.localizedMessage
                            ?: "تعذر قراءة نتيجة تفويض صلاحيات YouTube.")
                    )
                )
            }
            return true
        }

        return false
    }

    private fun completeWithAuthorizationResult(
        result: MethodChannel.Result,
        accountEmail: String,
        authResult: AuthorizationResult
    ) {
        val accessToken = authResult.accessToken?.trim().orEmpty()
        val serverAuthCode = authResult.serverAuthCode?.trim()
        val grantedScopes = authResult.grantedScopes
            .mapNotNull { it?.toString()?.trim() }
            .filter { it.isNotEmpty() }

        Log.d(
            TAG,
            "[Stage 4] completeWithAuthorizationResult | " +
                "hasAccessToken=${accessToken.isNotEmpty()}, " +
                "accessTokenLength=${accessToken.length}, " +
                "hasServerAuthCode=${!serverAuthCode.isNullOrEmpty()}, " +
                "grantedScopesCount=${grantedScopes.size}, " +
                "grantedScopes=${grantedScopes.joinToString()}"
        )

        if (accessToken.isEmpty()) {
            Log.e(TAG, "[Stage 5] completeWithAuthorizationResult failed: empty_access_token")
            sendResultToFlutter(
                stage = "Stage 6 - authorizeYouTubeScopes (empty_access_token)",
                result = result,
                payload = mapOf(
                    "status" to "denied",
                    "selectedAccountEmail" to accountEmail,
                    "errorCode" to "empty_access_token",
                    "errorMessage" to "لم يتم إصدار رمز وصول صالح لصلاحيات YouTube."
                )
            )
            return
        }

        sendResultToFlutter(
            stage = "Stage 6 - authorizeYouTubeScopes (authorized)",
            result = result,
            payload = mapOf(
                "status" to "authorized",
                "selectedAccountEmail" to accountEmail,
                "accessToken" to accessToken,
                "serverAuthCode" to serverAuthCode,
                "grantedScopes" to grantedScopes,
                "expiresAtEpochMs" to (System.currentTimeMillis() + 55L * 60L * 1000L)
            )
        )
    }

    /**
     * Logs sanitized payload details (never logging emails, tokens, or auth codes)
     * before returning the map over MethodChannel to Flutter.
     */
    private fun sendResultToFlutter(
        stage: String,
        result: MethodChannel.Result,
        payload: Map<String, Any?>
    ) {
        val sanitizedLogMap = mapOf(
            "status" to payload["status"],
            "errorCode" to payload["errorCode"],
            "errorMessage" to payload["errorMessage"],
            "selectionSource" to payload["selectionSource"],
            "hasEmail" to !(payload["email"] as? String).isNullOrEmpty(),
            "hasSelectedAccountEmail" to !(payload["selectedAccountEmail"] as? String).isNullOrEmpty(),
            "hasIdToken" to !(payload["idToken"] as? String).isNullOrEmpty(),
            "hasAccessToken" to !(payload["accessToken"] as? String).isNullOrEmpty(),
            "hasServerAuthCode" to !(payload["serverAuthCode"] as? String).isNullOrEmpty(),
            "grantedScopes" to payload["grantedScopes"],
            "expiresAtEpochMs" to payload["expiresAtEpochMs"]
        )
        Log.d(TAG, "[$stage] Returning payload to Flutter via MethodChannel: $sanitizedLogMap")
        result.success(payload)
    }

    /**
     * Logs comprehensive exception diagnostics (class, status code, API error code,
     * message, and full stack trace) without exposing any PII or tokens.
     */
    private fun logExceptionDetails(stage: String, e: Throwable) {
        val apiException = e as? ApiException
        val statusCode = apiException?.statusCode
        val statusString = statusCode?.let { CommonStatusCodes.getStatusCodeString(it) } ?: "N/A"
        val statusMessage = apiException?.status?.statusMessage ?: "N/A"
        val statusHasResolution = apiException?.status?.hasResolution() ?: false

        val credentialExceptionType = when (e) {
            is GetCredentialException -> e.type
            is ClearCredentialException -> e.type
            else -> "N/A"
        }

        Log.e(
            TAG,
            "[Stage 5 - FAILURE] stage=$stage | " +
                "exceptionClass=${e.javaClass.name} | " +
                "statusCode=${statusCode ?: "N/A"} ($statusString) | " +
                "statusMessage=$statusMessage | " +
                "statusHasResolution=$statusHasResolution | " +
                "apiErrorCode=$credentialExceptionType | " +
                "errorMessage=${e.message ?: e.localizedMessage ?: "null"}",
            e
        )
    }

    /**
     * Logs non-sensitive metadata about extras inside an ActivityResult Intent
     * (keys and value types/status codes, never logging token or email values).
     */
    private fun inspectIntentExtrasDiagnostic(stage: String, data: Intent?) {
        val extras = data?.extras ?: return
        val keysSummary = extras.keySet().map { key ->
            val rawVal = extras.get(key)
            val valType = rawVal?.javaClass?.name ?: "null"
            // Safe to log Google Play Services Status objects (contains statusCode & statusMessage)
            val safeValueSummary = if (key.contains("status", ignoreCase = true) ||
                key.contains("error", ignoreCase = true)
            ) {
                rawVal.toString()
            } else {
                "<redacted:$valType>"
            }
            "$key=$safeValueSummary"
        }
        Log.d(TAG, "[$stage] Intent extras diagnostic: ${keysSummary.joinToString(", ")}")
    }

    private fun resultCodeToString(resultCode: Int): String {
        return when (resultCode) {
            Activity.RESULT_OK -> "RESULT_OK (-1)"
            Activity.RESULT_CANCELED -> "RESULT_CANCELED (0)"
            Activity.RESULT_FIRST_USER -> "RESULT_FIRST_USER (1)"
            else -> "UNKNOWN ($resultCode)"
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        mainScope.cancel()
    }
}
