# وثيقة تسليم مطور باك إند لارافيل — ربط تيك توك الرسمي (TikTok OpenSDK v2 + PKCE)

مرحباً يا هندسة،

تم توحيد مسار وعقد الربط لحسابات **تيك توك (TikTok OpenSDK v2 + PKCE)** ليطابق هيكلية الربط المعتمدة لفيسبوك وإنستغرام في التطبيق (`POST /ar/mobile/social/tiktok/connect-token`).

---

## 1. المسار الرسمي الموحد (Canonical Endpoint)

```text
POST /ar/mobile/social/tiktok/connect-token
```

### المتغيرات المطلوبة في `.env`:
```env
TIKTOK_CLIENT_KEY=aw68o0783j7z9eeg
TIKTOK_CLIENT_SECRET=ضع_هنا_السيكرت_الخاص_بتيك_توك
TIKTOK_REDIRECT_URI=https://pastel-eg.com/social-connections/tiktok/callback
```

---

## 2. كود الكنترولر المتوافق مع عقد الاستجابة الصارم (`app/Http/Controllers/TikTokConnectController.php`)

```php
<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\DB;

class TikTokConnectController extends Controller
{
    private const ALLOWED_REDIRECT_URIS = [
        'https://pastel-eg.com/social-connections/tiktok/callback',
    ];

    public function connectToken(Request $request)
    {
        $validated = $request->validate([
            'provider'        => 'required|in:tiktok',
            'code'            => 'required|string|min:8',
            'code_verifier'   => 'required|string|min:20|max:128',
            'redirect_uri'    => 'required|url',
            'state'           => 'required|string|min:8|max:128',
            'granted_scopes'  => 'nullable|array',
            'device_platform' => 'required|string|in:android,ios',
        ]);

        $user = auth()->user();
        if (!$user) {
            return response()->json([
                'status'  => 'error',
                'code'    => 'UNAUTHENTICATED',
                'message' => 'يجب تسجيل الدخول لإتمام عملية الربط.',
            ], 401);
        }

        if (!in_array($validated['redirect_uri'], self::ALLOWED_REDIRECT_URIS, true)) {
            return response()->json([
                'status'  => 'error',
                'code'    => 'INVALID_GRANT',
                'message' => 'رابط إعادة التوجيه (redirect_uri) غير معتمد.',
            ], 422);
        }

        // حماية ضد إعادة إرسال نفس الطلب (Server-side Replay Protection)
        $stateLockKey = 'tiktok_oauth_state_' . hash('sha256', $validated['state']);
        if (!Cache::add($stateLockKey, $user->id, now()->addMinutes(15))) {
            return response()->json([
                'status'  => 'error',
                'code'    => 'INVALID_GRANT',
                'message' => 'تم استخدام رمز التحقق (state) مسبقاً.',
            ], 422);
        }

        $clientKey    = config('services.tiktok.client_key') ?? env('TIKTOK_CLIENT_KEY');
        $clientSecret = config('services.tiktok.client_secret') ?? env('TIKTOK_CLIENT_SECRET');

        try {
            // 1. تبديل رمز التفويض (code) مع مفتاح التحقق (code_verifier) لدى TikTok
            $tokenResponse = Http::asForm()
                ->timeout(15)
                ->post('https://open.tiktokapis.com/v2/oauth/token/', [
                    'client_key'    => $clientKey,
                    'client_secret' => $clientSecret,
                    'code'          => $validated['code'],
                    'grant_type'    => 'authorization_code',
                    'redirect_uri'  => $validated['redirect_uri'],
                    'code_verifier' => $validated['code_verifier'],
                ]);

            $tokenPayload = $tokenResponse->json() ?? [];
            $accessToken  = data_get($tokenPayload, 'access_token') ?? data_get($tokenPayload, 'data.access_token');
            $openId       = data_get($tokenPayload, 'open_id') ?? data_get($tokenPayload, 'data.open_id');
            $refreshToken = data_get($tokenPayload, 'refresh_token') ?? data_get($tokenPayload, 'data.refresh_token');
            $scopeStr     = (string) (data_get($tokenPayload, 'scope') ?? data_get($tokenPayload, 'data.scope', ''));
            $expiresIn    = (int) (data_get($tokenPayload, 'expires_in') ?? data_get($tokenPayload, 'data.expires_in', 86400));

            if (!$tokenResponse->successful() || empty($accessToken) || empty($openId)) {
                Log::warning('TikTok Token Exchange Rejected', [
                    'user_id' => $user->id,
                    'status'  => $tokenResponse->status(),
                    'error'   => data_get($tokenPayload, 'error') ?? data_get($tokenPayload, 'error.code'),
                ]);

                return response()->json([
                    'status'  => 'error',
                    'code'    => 'INVALID_GRANT',
                    'message' => 'فشل التحقق من رمز تفويض تيك توك أو انتهت صلاحيته.',
                ], 422);
            }

            // 2. التحقق من منح الصلاحية الأساسية user.info.basic من استجابة TikTok مباشرة
            $grantedScopes = array_values(array_filter(array_map('trim', explode(',', $scopeStr))));
            if (!in_array('user.info.basic', $grantedScopes, true)) {
                return response()->json([
                    'status'  => 'error',
                    'code'    => 'MISSING_PERMISSIONS',
                    'message' => 'يرجى الموافقة على صلاحيات الملف الشخصي الأساسية لإتمام الربط.',
                ], 422);
            }

            // 3. جلب هوية الحساب الموثقة مباشرة من خوادم TikTok
            $userResponse = Http::withToken($accessToken)
                ->timeout(15)
                ->get('https://open.tiktokapis.com/v2/user/info/', [
                    'fields' => 'open_id,union_id,avatar_url,display_name',
                ]);

            $userPayload    = $userResponse->json() ?? [];
            $verifiedOpenId = (string) (data_get($userPayload, 'data.user.open_id') ?? $openId);
            $displayName    = (string) (data_get($userPayload, 'data.user.display_name') ?? '');
            $avatarUrl      = data_get($userPayload, 'data.user.avatar_url');

            if (empty($verifiedOpenId) || empty($displayName)) {
                return response()->json([
                    'status'  => 'error',
                    'code'    => 'BACKEND_ERROR',
                    'message' => 'تعذر جلب بيانات الملف الشخصي الموثقة من تيك توك.',
                ], 502);
            }

            // 4. منع ربط نفس حساب تيك توك بأكثر من مزود خدمة
            $alreadyLinked = DB::table('social_accounts')
                ->where('provider', 'tiktok')
                ->where('provider_id', $verifiedOpenId)
                ->where('user_id', '!=', $user->id)
                ->exists();

            if ($alreadyLinked) {
                return response()->json([
                    'status'  => 'error',
                    'code'    => 'ACCOUNT_ALREADY_LINKED',
                    'message' => 'حساب تيك توك هذا مرتبط بالفعل بحساب مستخدم آخر.',
                ], 409);
            }

            // 5. حفظ أو تحديث السجل وإرجاع معرّف الربط الحقيقي connection_id
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

            $record = DB::table('social_accounts')
                ->where('user_id', $user->id)
                ->where('provider', 'tiktok')
                ->first();

            $connectionId = $record && isset($record->id)
                ? 'tiktok_conn_' . $record->id
                : 'tiktok_conn_' . $user->id;

            return response()->json([
                'status'            => 'success',
                'connection_id'     => (string) $connectionId,
                'provider'          => 'tiktok',
                'connected_account' => [
                    'open_id'      => $verifiedOpenId,
                    'display_name' => $displayName,
                    'avatar_url'  => $avatarUrl,
                ],
                'granted_scopes'    => $grantedScopes,
                'message'           => 'تم ربط حساب تيك توك بنجاح',
            ], 200);

        } catch (\Throwable $e) {
            Log::error('TikTok Connect Exception: ' . $e->getMessage());
            return response()->json([
                'status'  => 'error',
                'code'    => 'BACKEND_ERROR',
                'message' => 'حدث خطأ غير متوقع أثناء ربط حساب تيك توك.',
            ], 500);
        }
    }
}
```
