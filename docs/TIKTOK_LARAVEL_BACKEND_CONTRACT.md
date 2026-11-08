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

## 2. OAuth `state`, PKCE, and Security Responsibilities (Threat Model & Boundaries)

Because the current Flutter flow initiates the native TikTok OpenSDK directly on the device without a prior backend round-trip to mint a server-issued `state`, it is essential to distinguish clearly between the four security layers below:

### A. Client / Native Callback `state` Validation (Implemented in Flutter + Native SDK Layer)
- **Mechanism**: `TikTokAuthService` generates a 24-byte cryptographically random `state` (`Random.secure()`) before invoking the native OpenSDK. Both the native layer (`MainActivity.kt` / `AppDelegate.swift`) and Dart (`TikTokAuthService._parseNativeResponse`) verify that the `state` returned by TikTok in the callback Intent/URL matches the in-flight request's `state`, then immediately wipe the pending session.
- **What it protects against**: Forged or unsolicited local deep-link / App Link / Universal Link callbacks injected into the mobile app by another app or external link on the device.
- **What it does NOT prove to Laravel**: Because `state` was generated on the client, submitting `state` in the `POST` body to Laravel does not by itself prove to the server that Laravel issued that `state`.

### B. PKCE Protection (`code` ↔ `code_verifier`, Implemented End-to-End)
- **Mechanism**: Native OpenSDK generates a cryptographically random `code_verifier` (`PKCEUtils.generateCodeVerifier()` on Android, `TTKSDKCodeVerifier` on iOS) and sends `code_challenge = HEX(SHA256(code_verifier))` to TikTok during authorization. Laravel forwards `code` and `code_verifier` to `https://open.tiktokapis.com/v2/oauth/token/`.
- **What it protects against**: Authorization code interception on the mobile device (e.g., if a malicious app intercepts the redirect `code`, it cannot exchange it without the in-memory `code_verifier`).
- **What it does NOT prevent**: If an attacker compromises their own device or initiates an OAuth flow on their own device to obtain a valid `(code, code_verifier)` pair for their own TikTok account, PKCE binds `code` to `code_verifier`, not to a specific Laravel user session.

### C. Server-Side Replay Protection via `Cache::add` (Implemented in `TikTokConnectController`)
- **Mechanism**: `Cache::add('tiktok_oauth_state_' . hash('sha256', $validated['state']), $user->id, now()->addMinutes(15))`.
- **What threat it actually prevents**: Duplicate or replayed submission of the **exact same** `state` string within the 15-minute window (e.g., network/proxy replay of a captured `/connect-token` request).
- **What it does NOT do**:
  1. It does **not** prove that `state` was originally issued by Laravel for `auth()->user()`.
  2. An caller who possesses a valid `(code, code_verifier)` pair could submit any fresh, unused random `state` string and pass `Cache::add`.
  3. Primary protection against cross-user request forgery on `POST /ar/mobile/social/tiktok/connect-token` therefore relies on **Laravel session authentication + CSRF verification (`X-CSRF-TOKEN` / `X-XSRF-TOKEN`)**, combined with `social_accounts` uniqueness (`provider_id` cannot be linked to another `user_id`).

### D. True Server-Issued Session-Bound OAuth `state` (Optional Backend Hardening)
- **Current status**: Not currently active because the web page invokes `PastelSocialBridge.postMessage({ action: 'connect', provider: 'tiktok' })` without a server-minted `state`, and Flutter does not call a pre-auth backend endpoint.
- **Smallest optional backend upgrade (if strict server-bound `state` is desired later)**:
  1. When rendering the Social Connections Blade/Inertia page (or via a lightweight endpoint before calling the JS bridge), Laravel generates `$state = Str::random(40)` and stores it in the authenticated user's session (`session()->put('tiktok_oauth_state', ['value' => $state, 'expires_at' => now()->addMinutes(10)->timestamp])`).
  2. In `TikTokConnectController::connectToken`, replace or supplement `Cache::add` with `session()->pull('tiktok_oauth_state')` and assert `hash_equals($expectedState, $validated['state'])`.
  *(Note: Until the web frontend passes a server-issued `state` into the bridge call and Flutter forwards it, Laravel should use the `Cache::add` replay lock + CSRF middleware shown in the controller below so existing mobile builds work out of the box).*

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
