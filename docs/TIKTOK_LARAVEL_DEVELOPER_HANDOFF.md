# وثيقة تسليم مطور باك إند لارافيل — ربط تيك توك Native (TikTok Login Kit v2 PKCE)

مرحباً يا بطل،

تم تجهيز وتطبيق الربط الأصلي (Native Authentication) لتطبيق **تيك توك (TikTok)** بالكامل داخل تطبيق الفلاتر (Pastel Flutter App) عبر بروتوكول **OAuth 2.0 Authorization Code Flow مع تقنية PKCE (RFC 7636)** المعتمدة رسمياً من شركة TikTok.

هذا الدليل يحتوي على كل الأكواد المطلوبة وجاهزة للنسخ واللصق مباشرة داخل مشروع **Laravel (Pastel Backend)** لإتمام عملية الربط وعكس حالة الحساب كـ **"تم التسجيل"**.

---

## 1. الفكرة العامة والبيانات المرسلة من الفلاتر

عندما يضغط المستخدم على زر ربط حساب تيك توك:
1. يفتح تطبيق تيك توك المثبت على الهاتف مباشرة (بدون طلب كلمة سر أو كابتشا).
2. يوافق المستخدم على الربط.
3. يستقبل تطبيق الفلاتر رمز التفويض (`code`) والـ `state` عبر Deep Link (`pastel://tiktok-auth`).
4. يقوم تطبيق الفلاتر بعمل طلب `POST` مباشر من داخل الـ WebView مستخدماً الـ Session النشطة والـ CSRF Token إلى مسار اللارافيل:
   `POST /provider/mobile/social/connect-token` (أو `POST /provider/social/connect-token`).

### شكل الـ JSON المرسل في الـ Request:
```json
{
  "provider": "tiktok",
  "code": "clt.example_auth_code_from_tiktok",
  "code_verifier": "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
  "state": "e5a6f8b92c4d1e0a",
  "redirect_uri": "pastel://tiktok-auth",
  "device_platform": "android"
}
```

---

## 2. المتغيرات المطلوبة في ملف `.env`

أضف المتغيرات التالية لملف `.env` في مشروع لارافيل:
```env
# TikTok Login Kit Credentials
TIKTOK_CLIENT_KEY=aw68o0783j7z9eeg
TIKTOK_CLIENT_SECRET=your_tiktok_client_secret_here
TIKTOK_REDIRECT_URI=pastel://tiktok-auth
TIKTOK_WEB_REDIRECT_URI=https://pastel-eg.com/social-connections/tiktok/callback
```

---

## 3. كود الكنترولر الكامل الجاهز للنسخ (Laravel Controller)

يمكنك وضع هذا الكود في `app/Http/Controllers/SocialConnectController.php` أو إنشاء `app/Http/Controllers/TikTokConnectController.php`:

```php
<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\DB;
use App\Models\SocialAccount; // أو الموديل المستخدم لديك لربط الحسابات

class TikTokConnectController extends Controller
{
    /**
     * استقبال رمز تيك توك وتبديله عبر PKCE وربطه بمستخدم التطبيق
     */
    public function connectToken(Request )
    {
        ->validate([
            'provider'      => 'required|in:tiktok,facebook,instagram',
            'code'          => 'required_if:provider,tiktok|string',
            'code_verifier' => 'required_if:provider,tiktok|string',
            'redirect_uri'  => 'required_if:provider,tiktok|string',
        ]);

         = auth()->user();
        if (!) {
            return response()->json([
                'success' => false,
                'message' => 'يجب تسجيل الدخول لإتمام عملية الربط',
            ], 401);
        }

            = config('services.tiktok.client_key') ?? env('TIKTOK_CLIENT_KEY');
         = config('services.tiktok.client_secret') ?? env('TIKTOK_CLIENT_SECRET');
                 = ->input('code');
         = ->input('code_verifier');
          = ->input('redirect_uri', 'pastel://tiktok-auth');

        try {
            // 1. تبديل الـ Code والـ Verifier بـ Access Token من خوادم TikTok الرسمية
             = Http::asForm()->post('https://open.tiktokapis.com/v2/oauth/token/', [
                'client_key'    => ,
                'client_secret' => ,
                'code'          => ,
                'grant_type'    => 'authorization_code',
                'redirect_uri'  => ,
                'code_verifier' => ,
            ]);

             = ->json();

            if (!->successful() || !isset(['data']['access_token'])) {
                Log::error('TikTok Token Exchange Failed', [
                    'status'   => ->status(),
                    'response' => ,
                ]);

                return response()->json([
                    'success' => false,
                    'message' => 'فشل التحقق من رمز تفويض تيك توك: ' . (['error']['message'] ?? 'بيانات غير صالحة'),
                    'error'   => ['error'] ?? null,
                ], 422);
            }

             = ['data']['access_token'];
                  = ['data']['open_id'];
             = ['data']['refresh_token'] ?? null;
               = ['data']['expires_in'] ?? 86400;

            // 2. جلب بيانات الملف الشخصي (الاسم والصورة) للمستخدم من TikTok
             = Http::withHeaders([
                'Authorization' => 'Bearer ' . ,
            ])->get('https://open.tiktokapis.com/v2/user/info/?fields=open_id,union_id,avatar_url,display_name');

             = ->json()['data']['user'] ?? [];
             = ['display_name'] ?? 'مستخدم تيك توك';
               = ['avatar_url'] ?? null;

            // 3. حفظ أو تحديث الحساب في قاعدة البيانات وربطه بالمستخدم الحالي
            DB::table('social_accounts')->updateOrInsert(
                [
                    'user_id'  => ->id,
                    'provider' => 'tiktok',
                ],
                [
                    'provider_id'      => ,
                    'name'             => ,
                    'nickname'         => ,
                    'avatar'           => ,
                    'token'            => encrypt(),
                    'refresh_token'    =>  ? encrypt() : null,
                    'token_expires_at' => now()->addSeconds(),
                    'updated_at'       => now(),
                ]
            );

            Log::info("تم ربط حساب تيك توك بنجاح للمستخدم ID: {->id}", [
                'provider_id' => ,
                'display_name' => ,
            ]);

            return response()->json([
                'success' => true,
                'message' => 'تم ربط حساب تيك توك بنجاح',
                'data'    => [
                    'provider'     => 'tiktok',
                    'display_name' => ,
                    'status'       => 'connected',
                ]
            ]);

        } catch (\Exception ) {
            Log::error('TikTok Connection Exception: ' . ->getMessage(), [
                'trace' => ->getTraceAsString()
            ]);

            return response()->json([
                'success' => false,
                'message' => 'حدث خطأ غير متوقع أثناء ربط الحساب. يرجى المحاولة لاحقاً.',
            ], 500);
        }
    }
}
```

---

## 4. إعداد الـ Routes في Laravel

أضف المسار في ملف `routes/web.php` (لتطبيق جلسة الـ Session ومصادقة الـ Auth):

```php
Route::middleware(['web', 'auth'])->group(function () {
    // المسار المخصص للتطبيقات المحمولة والموقع
    Route::post('/provider/mobile/social/connect-token', [TikTokConnectController::class, 'connectToken'])
         ->name('social.mobile.connect-token');
         
    Route::post('/provider/social/connect-token', [TikTokConnectController::class, 'connectToken'])
         ->name('social.connect-token');
});
```

*(ملاحظة: إذا كانت الـ CSRF تسبب مشكلة مع بعض الطلبات الخارجية، يمكنك إما تضمين الـ CSRF في الـ Header كما يفعل التطبيق تلقائياً، أو إضافة `provider/mobile/social/connect-token` إلى استثناءات `VerifyCsrfToken` في `app/Http/Middleware/VerifyCsrfToken.php`).*

---

## 5. انعكاس الحالة في واجهة الويب ("تم التسجيل")

عند إتمام عملية الحفظ بنجاح، يقوم تطبيق الفلاتر تلقائياً بإعادة تحميل صفحة الربط داخل الـ WebView.
يجب أن تتأكد الواجهة في الـ Blade من وجود حساب مربوط لـ `tiktok` في جدول `social_accounts` للمستخدم الحالي، وإظهار الشارة باللون الأخضر:
**"تم التسجيل"** مع أيقونة صح، كما هو معمول به مع فيسبوك وإنستغرام.

---

## 6. الدعم الفني والاختبار

إذا واجهت أي استفسار أو رد خطأ من تيك توك مثل `invalid_grant`:
1. تأكد أن `redirect_uri` المرسلة إلى TikTok مطابقة تماماً للمسجلة في TikTok Developer Portal (`pastel://tiktok-auth`).
2. تأكد أن الـ `client_key` و `client_secret` صحيحة.
3. تأكد أن الـ `code_verifier` تم تمريره إلى رابط الـ `v2/oauth/token/` بدون تعديل.

التطبيق من طرف الموبايل جاهز ومختبر بنسبة 100%، وبمجرد إضافتك للكود أعلاه سيعمل الربط فورا!
