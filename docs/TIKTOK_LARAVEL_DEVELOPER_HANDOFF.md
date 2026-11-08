# وثيقة تسليم مطور باك إند لارافيل — ربط تيك توك الرسمي (TikTok OpenSDK v2 + PKCE)

مرحباً يا هندسة،

تم دمج **حزمة تيك توك الرسمية (Official TikTok OpenSDK v2.4.0 للأندرويد و TikTokOpenAuthSDK v2.5.0 للـ iOS)** داخل تطبيق الفلاتر (**Pastel** - `com.pasteleg.app`).

تعتمد الحزمة الرسمية على:
1. فتح تطبيق تيك توك المثبت على هاتف المستخدم مباشرة (`AuthMethod.TikTokApp`) مع التحقق من التوقيع الرقمي لتطبيق تيك توك، والتحول التلقائي إلى `AuthMethod.ChromeTab` / `ASWebAuthenticationSession` في حال عدم تثبيت تطبيق تيك توك.
2. توليد مفتاح الأمان **PKCE (`code_verifier` و `code_challenge`)** عبر مكتبة تيك توك الأصلية (`PKCEUtils` على أندرويد و `TTKSDKCodeVerifier` على iOS).
3. استخدام رابط إعادة توجيه رسمي آمن عبر **HTTPS App Links / Universal Links**:
   `https://pastel-eg.com/social-connections/tiktok/callback`
   *(حيث أن Login Kit v2 لا يقبل الروابط المخصصة مثل `pastel://` ويشترط روابط `https://`)*.

---

## 1. المتغيرات المطلوبة في ملف `.env`

```env
TIKTOK_CLIENT_KEY=aw68o0783j7z9eeg
TIKTOK_CLIENT_SECRET=ضع_هنا_السيكرت_الخاص_بتيك_توك
TIKTOK_REDIRECT_URI=https://pastel-eg.com/social-connections/tiktok/callback
```

---

## 2. البيانات التي يرسلها تطبيق الموبايل إلى السيرفر

يرسل التطبيق طلب `POST` موثق بالجلسة الحالية (`wedding-planner-session`) والـ `X-CSRF-TOKEN` إلى المسار:
`POST /provider/mobile/social/connect-token`

### شكل الـ Request JSON:
```json
{
  "provider": "tiktok",
  "code": "clt.example_auth_code_from_tiktok_sdk",
  "code_verifier": "aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY",
  "state": "x8Km2p9Lq4Rv7Wz1Yj5Bn3Ct6D8F0G2H",
  "redirect_uri": "https://pastel-eg.com/social-connections/tiktok/callback",
  "granted_scopes": ["user.info.basic"],
  "device_platform": "android"
}
```

---

## 3. كود الكنترولر الكامل الجاهز للنسخ (`app/Http/Controllers/TikTokConnectController.php`)

هذا الكود يتبع كافة معايير الأمان:
- يتحقق من أن `redirect_uri` ضمن القائمة البيضاء المسموحة (`Allowed Redirect URIs`).
- لا يثق بأي بيانات هوية قادمة من العميل، بل يستخرج `open_id` والاسم والصورة مباشرة من خوادم TikTok بعد تبديل الـ `code` والـ `code_verifier`.
- لا يُعيد أي `access_token` أو `refresh_token` إلى الواجهة الأمامية.

```php
<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\DB;

class TikTokConnectController extends Controller
{
    /**
     * القائمة البيضاء لروابط إعادة التوجيه المعتمدة في TikTok Developer Portal
     */
    private const ALLOWED_REDIRECT_URIS = [
        'https://pastel-eg.com/social-connections/tiktok/callback',
        'https://pastel-eg.com/provider/automation-settings/provider/social-connections/tiktok/callback',
    ];

    /**
     * استقبال رمز تيك توك من تطبيق الموبايل وتبديله عبر PKCE وربطه بالمستخدم الحالي
     */
    public function connectToken(Request $request)
    {
        $validated = $request->validate([
            'provider'       => 'required|in:tiktok',
            'code'           => 'required|string|min:8',
            'code_verifier'  => 'required|string|min:20|max:128',
            'redirect_uri'   => 'required|url',
            'state'          => 'nullable|string|max:128',
            'granted_scopes' => 'nullable|array',
            'device_platform'=> 'nullable|string|in:android,ios',
        ]);

        $user = auth()->user();
        if (!$user) {
            return response()->json([
                'success' => false,
                'status'  => 'unauthorized',
                'message' => 'يجب تسجيل الدخول لإتمام عملية الربط.',
            ], 401);
        }

        $redirectUri = $validated['redirect_uri'];
        if (!in_array($redirectUri, self::ALLOWED_REDIRECT_URIS, true)) {
            return response()->json([
                'success' => false,
                'status'  => 'permission_denied',
                'message' => 'رابط إعادة التوجيه (redirect_uri) غير معتمد.',
            ], 422);
        }

        $clientKey    = config('services.tiktok.client_key') ?? env('TIKTOK_CLIENT_KEY');
        $clientSecret = config('services.tiktok.client_secret') ?? env('TIKTOK_CLIENT_SECRET');

        try {
            // 1. تبديل رمز التفويض (code) مع مفتاح التحقق (code_verifier) لدى خادم TikTok الرسمي
            $tokenResponse = Http::asForm()
                ->timeout(15)
                ->post('https://open.tiktokapis.com/v2/oauth/token/', [
                    'client_key'    => $clientKey,
                    'client_secret' => $clientSecret,
                    'code'          => $validated['code'],
                    'grant_type'    => 'authorization_code',
                    'redirect_uri'  => $redirectUri,
                    'code_verifier' => $validated['code_verifier'],
                ]);

            $tokenPayload = $tokenResponse->json() ?? [];

            // يدعم الاستجابة المباشرة أو المغلفة داخل data
            $accessToken      = data_get($tokenPayload, 'access_token') ?? data_get($tokenPayload, 'data.access_token');
            $openId           = data_get($tokenPayload, 'open_id') ?? data_get($tokenPayload, 'data.open_id');
            $refreshToken     = data_get($tokenPayload, 'refresh_token') ?? data_get($tokenPayload, 'data.refresh_token');
            $expiresIn        = (int) (data_get($tokenPayload, 'expires_in') ?? data_get($tokenPayload, 'data.expires_in', 86400));

            if (!$tokenResponse->successful() || empty($accessToken) || empty($openId)) {
                $errorDesc = data_get($tokenPayload, 'error_description')
                    ?? data_get($tokenPayload, 'error.message')
                    ?? data_get($tokenPayload, 'message')
                    ?? 'فشل تبديل رمز التفويض مع تيك توك.';

                Log::error('TikTok OpenSDK Token Exchange Failed', [
                    'user_id'  => $user->id,
                    'status'   => $tokenResponse->status(),
                    'response' => $tokenPayload,
                ]);

                return response()->json([
                    'success' => false,
                    'status'  => 'permission_denied',
                    'message' => 'فشل التحقق من رمز تفويض تيك توك: ' . $errorDesc,
                ], 422);
            }

            // 2. التحقق من هوية الحساب مباشرة من خوادم TikTok (عدم الوثوق بأي هوية من العميل)
            $userResponse = Http::withToken($accessToken)
                ->timeout(15)
                ->get('https://open.tiktokapis.com/v2/user/info/', [
                    'fields' => 'open_id,union_id,avatar_url,display_name',
                ]);

            $userPayload = $userResponse->json() ?? [];
            $verifiedOpenId = data_get($userPayload, 'data.user.open_id') ?? $openId;
            $displayName    = data_get($userPayload, 'data.user.display_name') ?? 'TikTok User';
            $avatarUrl      = data_get($userPayload, 'data.user.avatar_url');

            // 3. التأكد من عدم ارتباط حساب تيك توك هذا بمستخدم آخر في المنصة
            $existingOtherUser = DB::table('social_accounts')
                ->where('provider', 'tiktok')
                ->where('provider_id', $verifiedOpenId)
                ->where('user_id', '!=', $user->id)
                ->exists();

            if ($existingOtherUser) {
                return response()->json([
                    'success' => false,
                    'status'  => 'permission_denied',
                    'message' => 'حساب تيك توك هذا مرتبط بالفعل بحساب مزود خدمة آخر.',
                ], 409);
            }

            // 4. حفظ وتشفير التوكنات في قاعدة البيانات وربطها بالمستخدم الحالي
            DB::table('social_accounts')->updateOrInsert(
                [
                    'user_id'  => $user->id,
                    'provider' => 'tiktok',
                ],
                [
                    'provider_id'      => $verifiedOpenId,
                    'name'             => $displayName,
                    'nickname'         => $displayName,
                    'avatar'           => $avatarUrl,
                    'token'            => encrypt($accessToken),
                    'refresh_token'    => $refreshToken ? encrypt($refreshToken) : null,
                    'token_expires_at' => now()->addSeconds($expiresIn),
                    'updated_at'       => now(),
                ]
            );

            return response()->json([
                'success' => true,
                'status'  => 'success',
                'message' => 'تم ربط حساب تيك توك بنجاح',
                'data'    => [
                    'provider'     => 'tiktok',
                    'account_id'   => $verifiedOpenId,
                    'display_name' => $displayName,
                    'avatar_url'   => $avatarUrl,
                    'status'       => 'connected',
                ],
            ]);

        } catch (\Throwable $e) {
            Log::error('TikTok Connect Exception: ' . $e->getMessage(), [
                'user_id' => $user->id,
                'trace'   => $e->getTraceAsString(),
            ]);

            return response()->json([
                'success' => false,
                'status'  => 'backend_error',
                'message' => 'حدث خطأ غير متوقع أثناء ربط حساب تيك توك.',
            ], 500);
        }
    }
}
```

---

## 4. تعريف المسارات في `routes/web.php`

```php
use App\Http\Controllers\TikTokConnectController;

Route::middleware(['web', 'auth'])->group(function () {
    Route::post('/provider/mobile/social/connect-token', [TikTokConnectController::class, 'connectToken'])
         ->name('social.mobile.connect-token');

    Route::post('/provider/social/connect-token', [TikTokConnectController::class, 'connectToken'])
         ->name('social.connect-token');

    Route::post('/provider/automation-settings/provider/social-connections/tiktok/connect-token', [TikTokConnectController::class, 'connectToken'])
         ->name('social.tiktok.connect-token');
});
```

---

## 5. ملفات التحقق من الـ App Links / Universal Links على السيرفر

لكي يفتح نظام أندرويد و iOS التطبيق مباشرة عند العودة من متصفح Chrome Custom Tab أو Safari إلى الرابط `https://pastel-eg.com/social-connections/tiktok/callback`، تأكد من وجود الملفين التاليين في مجلد `public/.well-known/` على السيرفر:

1. `public/.well-known/assetlinks.json` (للأندرويد - ضع بصمة SHA-256 لمفتاح التوقيع):
```json
[
  {
    "relation": ["delegate_permission/common.handle_all_urls"],
    "target": {
      "namespace": "android_app",
      "package_name": "com.pasteleg.app",
      "sha256_cert_fingerprints": [
        "PUT_YOUR_RELEASE_SHA256_FINGERPRINT_HERE"
      ]
    }
  }
]
```

2. `public/.well-known/apple-app-site-association` (للـ iOS):
```json
{
  "applinks": {
    "apps": [],
    "details": [
      {
        "appID": "TEAM_ID.com.pasteleg.app",
        "paths": [
          "/social-connections/tiktok/callback*",
          "/provider/automation-settings/provider/social-connections/tiktok/callback*"
        ]
      }
    ]
  }
}
```
