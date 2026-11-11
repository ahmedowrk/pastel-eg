package com.pasteleg.app.youtube

import android.accounts.Account
import android.accounts.AccountManager
import android.app.Activity
import android.content.Intent
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
        when (call.method) {
            "pickGoogleAccount" -> handlePickGoogleAccount(call, result)
            "authorizeYouTubeScopes" -> handleAuthorizeYouTubeScopes(call, result)
            "clearSelectedAccountSession" -> handleClearSelectedAccountSession(result)
            else -> result.notImplemented()
        }
    }

    private fun handlePickGoogleAccount(call: MethodCall, result: MethodChannel.Result) {
        if (pendingAccountPickResult != null) {
            result.success(
                mapOf(
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

        mainScope.launch {
            if (forceAccountSelection) {
                try {
                    credentialManager.clearCredentialState(ClearCredentialStateRequest())
                } catch (_: ClearCredentialException) {
                } catch (_: Exception) {
                }
            }

            if (serverClientId.isEmpty()) {
                launchSystemAccountPickerFallback(result)
                return@launch
            }

            try {
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
                if (credential is CustomCredential &&
                    credential.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL
                ) {
                    val googleIdCredential = GoogleIdTokenCredential.createFrom(credential.data)
                    result.success(
                        mapOf(
                            "status" to "selected",
                            "email" to googleIdCredential.id,
                            "displayName" to googleIdCredential.displayName,
                            "profilePictureUri" to googleIdCredential.profilePictureUri?.toString(),
                            "idToken" to googleIdCredential.idToken,
                            "selectionSource" to "credential_manager"
                        )
                    )
                } else {
                    launchSystemAccountPickerFallback(result)
                }
            } catch (e: GetCredentialCancellationException) {
                result.success(
                    mapOf(
                        "status" to "cancelled",
                        "errorCode" to "user_cancelled",
                        "errorMessage" to "تم إلغاء اختيار حساب Google."
                    )
                )
            } catch (e: NoCredentialException) {
                launchSystemAccountPickerFallback(result)
            } catch (e: GetCredentialException) {
                launchSystemAccountPickerFallback(result)
            } catch (e: Exception) {
                launchSystemAccountPickerFallback(result)
            }
        }
    }

    private fun launchSystemAccountPickerFallback(result: MethodChannel.Result) {
        try {
            val options = AccountPicker.AccountChooserOptions.Builder()
                .setAllowableAccountsTypes(listOf(GOOGLE_ACCOUNT_TYPE))
                .setAlwaysShowAccountPicker(true)
                .build()
            val intent = AccountPicker.newChooseAccountIntent(options)
            pendingAccountPickResult = result
            activity.startActivityForResult(intent, REQUEST_CODE_SYSTEM_ACCOUNT_PICKER)
        } catch (e: Exception) {
            pendingAccountPickResult = null
            result.success(
                mapOf(
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
            result.success(
                mapOf(
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

        if (accountEmail.isEmpty()) {
            result.success(
                mapOf(
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
            result.success(
                mapOf(
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

            Identity.getAuthorizationClient(activity)
                .authorize(authorizationRequest)
                .addOnSuccessListener { authorizationResult ->
                    if (authorizationResult.hasResolution()) {
                        val pendingIntent = authorizationResult.pendingIntent
                        if (pendingIntent != null) {
                            try {
                                pendingAuthorizeResult = result
                                pendingRequestedAccountEmail = accountEmail
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
                                result.success(
                                    mapOf(
                                        "status" to "error",
                                        "selectedAccountEmail" to accountEmail,
                                        "errorCode" to "resolution_launch_failed",
                                        "errorMessage" to (e.localizedMessage
                                            ?: "تعذر فتح شاشة الموافقة على صلاحيات YouTube.")
                                    )
                                )
                            }
                        } else {
                            result.success(
                                mapOf(
                                    "status" to "error",
                                    "selectedAccountEmail" to accountEmail,
                                    "errorCode" to "missing_resolution_intent",
                                    "errorMessage" to "تعذر بدء شاشة موافقة Google لصلاحيات YouTube."
                                )
                            )
                        }
                    } else {
                        completeWithAuthorizationResult(
                            result = result,
                            accountEmail = accountEmail,
                            authResult = authorizationResult
                        )
                    }
                }
                .addOnFailureListener { e ->
                    val statusCode = (e as? ApiException)?.statusCode
                    val isCancelled = statusCode == CommonStatusCodes.CANCELED
                    result.success(
                        mapOf(
                            "status" to if (isCancelled) "cancelled" else "error",
                            "selectedAccountEmail" to accountEmail,
                            "errorCode" to (statusCode?.toString() ?: "authorize_failed"),
                            "errorMessage" to (e.localizedMessage
                                ?: "تعذر تفويض صلاحيات YouTube عبر Google Play Services.")
                        )
                    )
                }
        } catch (e: Exception) {
            result.success(
                mapOf(
                    "status" to "error",
                    "selectedAccountEmail" to accountEmail,
                    "errorCode" to "authorize_exception",
                    "errorMessage" to (e.localizedMessage ?: "حدث خطأ غير متوقع أثناء تفويض YouTube.")
                )
            )
        }
    }

    private fun handleClearSelectedAccountSession(result: MethodChannel.Result) {
        mainScope.launch {
            try {
                credentialManager.clearCredentialState(ClearCredentialStateRequest())
            } catch (_: Exception) {
            }
            result.success(null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == REQUEST_CODE_SYSTEM_ACCOUNT_PICKER) {
            val callback = pendingAccountPickResult
            pendingAccountPickResult = null
            if (callback == null) return true

            if (resultCode == Activity.RESULT_OK && data != null) {
                val accountName =
                    data.getStringExtra(AccountManager.KEY_ACCOUNT_NAME)?.trim().orEmpty()
                if (accountName.isNotEmpty()) {
                    callback.success(
                        mapOf(
                            "status" to "selected",
                            "email" to accountName,
                            "selectionSource" to "system_account_picker"
                        )
                    )
                } else {
                    callback.success(
                        mapOf(
                            "status" to "no_accounts",
                            "errorCode" to "empty_account_name",
                            "errorMessage" to "لم يتم العثور على بريد Google للحساب المختار."
                        )
                    )
                }
            } else {
                callback.success(
                    mapOf(
                        "status" to "cancelled",
                        "errorCode" to "user_cancelled",
                        "errorMessage" to "تم إلغاء اختيار حساب Google."
                    )
                )
            }
            return true
        }

        if (requestCode == REQUEST_CODE_YOUTUBE_AUTHORIZATION) {
            val callback = pendingAuthorizeResult
            val accountEmail = pendingRequestedAccountEmail.orEmpty()
            pendingAuthorizeResult = null
            pendingRequestedAccountEmail = null
            if (callback == null) return true

            if (data == null || resultCode != Activity.RESULT_OK) {
                callback.success(
                    mapOf(
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
                completeWithAuthorizationResult(
                    result = callback,
                    accountEmail = accountEmail,
                    authResult = authResult
                )
            } catch (e: ApiException) {
                val isCancelled = e.statusCode == CommonStatusCodes.CANCELED
                callback.success(
                    mapOf(
                        "status" to if (isCancelled) "cancelled" else "denied",
                        "selectedAccountEmail" to accountEmail,
                        "errorCode" to "api_exception_${e.statusCode}",
                        "errorMessage" to (e.localizedMessage
                            ?: "تم رفض منح صلاحيات الوصول إلى قناة YouTube.")
                    )
                )
            } catch (e: Exception) {
                callback.success(
                    mapOf(
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

        if (accessToken.isEmpty()) {
            result.success(
                mapOf(
                    "status" to "denied",
                    "selectedAccountEmail" to accountEmail,
                    "errorCode" to "empty_access_token",
                    "errorMessage" to "لم يتم إصدار رمز وصول صالح لصلاحيات YouTube."
                )
            )
            return
        }

        result.success(
            mapOf(
                "status" to "authorized",
                "selectedAccountEmail" to accountEmail,
                "accessToken" to accessToken,
                "serverAuthCode" to serverAuthCode,
                "grantedScopes" to grantedScopes,
                "expiresAtEpochMs" to (System.currentTimeMillis() + 55L * 60L * 1000L)
            )
        )
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        mainScope.cancel()
    }
}
