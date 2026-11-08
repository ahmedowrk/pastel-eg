# TikTok Login Kit v2 (Official OpenSDK + PKCE) — Laravel Backend Contract

**Canonical Endpoint**: `POST /ar/mobile/social/tiktok/connect-token`  
**Target Host**: `https://pastel-eg.com`  
**Authentication**: Active Provider Session Cookie (`laravel_session` / `wedding-planner-session`) + `X-CSRF-TOKEN` / `X-XSRF-TOKEN`

---

## 1. Canonical Endpoint & Transport Rules

1. **Single Canonical Endpoint**:
   `POST /ar/mobile/social/tiktok/connect-token`
   *(Matches the existing Meta canonical endpoint `POST /ar/mobile/social/meta/connect-token` in `PASTEL_SOCIAL_AUTH_BACKEND_CONTRACT.md`).*
2. **Single-Use Authorization Code**:
   Because an OAuth 2.0 `code` is strictly single-use, Flutter sends **exactly one** `POST` request per authorization flow using native cookie store credentials (`CookieManager` on Android, `WKHTTPCookieStore` on iOS). No fallback endpoint looping or automatic retries are performed.
3. **HTTPS Redirect URI**:
   `https://pastel-eg.com/social-connections/tiktok/callback`

---

## 2. OAuth `state`, PKCE, and Security Responsibilities

### A. Client-Generated `state` vs Server-Side Replay Protection
Because the mobile app launches the native TikTok OpenSDK directly on the device (without an initial server round-trip to pre-register `state` in the Laravel session):
1. **Mobile Client (`TikTokAuthService` + Native OpenSDK)**:
   - Generates a 24-byte cryptographically random `state` (`Random.secure()`) before invoking the native SDK.
   - Verifies that the callback `state` returned by TikTok equals the pending request's `state` at both the native layer (`MainActivity.kt` / `AppDelegate.swift`) and the Dart layer (`TikTokAuthService._parseNativeResponse`), then immediately wipes the pending state to prevent client-side replay.
2. **Laravel Backend (`TikTokConnectController`)**:
   - Does **not** compare `state` against a pre-stored session value (since the flow was initiated natively on the client).
   - Instead, Laravel enforces:
     1. Non-empty format validation on `state` (`required|string|min:8|max:128`).
     2. **Atomic Server-Side Replay Lock**: Uses `Cache::add('tiktok_oauth_state_' . hash('sha256', $validated['state']), $user->id, now()->addMinutes(15))` so that the same `state` value can never be submitted more than once.
     3. **Cryptographic Request-to-Token Binding via PKCE**: Forwards `code` and `code_verifier` to TikTok's `https://open.tiktokapis.com/v2/oauth/token/` endpoint, which verifies `SHA256_HEX(code_verifier) == code_challenge`.
     4. **Server-Verified Account Identity & Scopes**: Ignores client-provided `granted_scopes` for authorization decisions; verifies granted scopes from TikTok's `/v2/oauth/token/` response (`scope`) and fetches account identity (`open_id`, `display_name`, `avatar_url`) directly from `https://open.tiktokapis.com/v2/user/info/`.

---

## 3. Exact Request Schema

### Headers
```http
POST /ar/mobile/social/tiktok/connect-token HTTP/1.1
Host: pastel-eg.com
Content-Type: application/json
Accept: application/json
X-Requested-With: XMLHttpRequest
X-CSRF-TOKEN: <plain_text_csrf_token_from_meta_tag_if_present>
X-XSRF-TOKEN: <url_decoded_encrypted_xsrf_token_cookie_if_present>
Cookie: <authenticated_webview_session_cookies_including_HttpOnly>
```

### Request JSON Body
```json
{
  "provider": "tiktok",
  "code": "clt.example_authorization_code_from_tiktok_opensdk",
  "code_verifier": "aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY",
  "redirect_uri": "https://pastel-eg.com/social-connections/tiktok/callback",
  "state": "x8Km2p9Lq4Rv7Wz1Yj5Bn3Ct6D8F0G2H",
  "granted_scopes": [
    "user.info.basic"
  ],
  "device_platform": "android"
}
```

---

## 4. Exact Success Response Schema (`200 OK`)

`TikTokBackendService.parseSuccessResponse` strictly validates all mandatory fields below and rejects any response missing `connection_id`, `connected_account.open_id`, or `connected_account.display_name`:

```json
{
  "status": "success",
  "connection_id": "tiktok_conn_98231",
  "provider": "tiktok",
  "connected_account": {
    "open_id": "_000example_user_open_id",
    "display_name": "Pastel Studio",
    "avatar_url": "https://p16-va.tiktokcdn.com/tos-maliva-avt-0068/sample.jpeg"
  },
  "granted_scopes": [
    "user.info.basic"
  ],
  "message": "تم ربط حساب تيك توك بنجاح"
}
```

---

## 5. Exact Error Response Schema

```json
{
  "status": "error",
  "code": "INVALID_GRANT",
  "message": "فشل التحقق من رمز تفويض تيك توك أو انتهت صلاحيته."
}
```

### Standard Error Codes (`code`):
| HTTP Status | `code` | Mapped Flutter Bridge Status | Meaning |
|---|---|---|---|
| `401` / `403` / `419` | `UNAUTHENTICATED` | `authentication_failed` | Merchant session expired or invalid CSRF token |
| `422` | `INVALID_GRANT` | `authentication_failed` | Authorization `code` expired, replayed `state`, or `code_verifier` mismatch |
| `422` | `MISSING_PERMISSIONS` | `permission_denied` | Required scope (`user.info.basic`) was not granted |
| `409` | `ACCOUNT_ALREADY_LINKED` | `account_already_linked` | This TikTok `open_id` is already linked to another merchant account |
| `500` / `502` | `BACKEND_ERROR` | `backend_error` | Unexpected server or upstream TikTok API failure |
