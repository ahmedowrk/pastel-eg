# TikTok Login Kit v2 (Official OpenSDK + PKCE) — Laravel Backend Contract

## 1. Architecture Overview

The Pastel mobile application (`com.pasteleg.app`) integrates the **official native TikTok OpenSDK v2**:
- **Android**: `com.tiktok.open.sdk:tiktok-open-sdk-core:2.4.0` & `com.tiktok.open.sdk:tiktok-open-sdk-auth:2.4.0`
  - Uses `AuthApi(activity)` with `AuthApi.AuthMethod.TikTokApp` (which verifies the installed TikTok package `com.zhiliaoapp.musically` / `com.ss.android.ugc.trill` and its official APK signature via `TikTokAppCheckUtil`, launching `openauthorize.AwemeAuthorizedActivity` directly, and automatically falls back to `AuthApi.AuthMethod.ChromeTab` via `CustomTabsIntent` when the TikTok app is not installed).
- **iOS**: `TikTokOpenSDKCore` (`~> 2.5.0`) & `TikTokOpenAuthSDK` (`~> 2.5.0`)
  - Uses `TikTokAuthRequest` and `TikTokURLHandler` (which checks installed TikTok schemes `snssdk1233` / `snssdk1180` / `tiktokopensdk`, opens native Universal Link authorization, and falls back to `ASWebAuthenticationSession` when the TikTok app is not installed).

---

## 2. Redirect URI Architecture (HTTPS App Links & Universal Links)

TikTok Login Kit v2 **does not permit custom URL schemes** (such as `pastel://tiktok-auth`) as the `redirect_uri`. Both Android and iOS require a verified **HTTPS Redirect URI**:

- **Primary Redirect URI**:
  ```text
  https://pastel-eg.com/social-connections/tiktok/callback
  ```
- **Secondary Allowed Redirect URI**:
  ```text
  https://pastel-eg.com/provider/automation-settings/provider/social-connections/tiktok/callback
  ```

### Required Domain Verification Files on `https://pastel-eg.com`:
1. **Android App Links (`https://pastel-eg.com/.well-known/assetlinks.json`)**:
   ```json
   [
     {
       "relation": ["delegate_permission/common.handle_all_urls"],
       "target": {
         "namespace": "android_app",
         "package_name": "com.pasteleg.app",
         "sha256_cert_fingerprints": [
           "<RELEASE_KEYSTORE_SHA256_FINGERPRINT>"
         ]
       }
     }
   ]
   ```
2. **iOS Universal Links (`https://pastel-eg.com/.well-known/apple-app-site-association`)**:
   ```json
   {
     "applinks": {
       "apps": [],
       "details": [
         {
           "appID": "<APPLE_TEAM_ID>.com.pasteleg.app",
           "paths": [
             "/social-connections/tiktok/callback*",
             "/provider/automation-settings/provider/social-connections/tiktok/callback*"
           ]
         }
       ]
     }
   }
   ```

---

## 3. PKCE & State Responsibilities

### A. Native OpenSDK PKCE Implementation Details
Both official TikTok mobile OpenSDKs manage PKCE natively:
- **Android (`com.tiktok.open.sdk.auth.utils.PKCEUtils`)**:
  - `PKCEUtils.generateCodeVerifier()` generates a 32-character cryptographically random alphanumeric string using `java.security.SecureRandom`.
  - `PKCEUtils.generateCodeChallenge(codeVerifier)` computes the **lowercase hexadecimal SHA-256 digest** (`"%02x".format(byte)`).
- **iOS (`TikTokOpenAuthSDK.PKCE` / `TTKSDKCodeVerifier`)**:
  - `PKCE.generateCodeVerifier()` generates a 43-character random string from `[a-zA-Z0-9-._]`.
  - `pkce.codeChallenge` computes the **lowercase hexadecimal SHA-256 digest** (`"%02hhx"`).

### B. Security Boundaries & Responsibilities
| Responsibility | Mobile App (Flutter + Native OpenSDK) | Laravel Backend (`pastel-eg.com`) |
|---|---|---|
| **PKCE Generation** | Native SDK generates `code_verifier` and hex-SHA256 `code_challenge` per request. | Receives `code_verifier` and forwards it to TikTok's `/v2/oauth/token/` endpoint. |
| **CSRF `state` Validation** | Generates 24-byte `Random.secure()` state; validates callback `state == pendingState` on native & Dart layers; clears state immediately for single-use replay protection. | Logs/validates non-empty `state`. |
| **Client Secret** | **NEVER** stored on mobile client or exposed to WebView JS. | Stored exclusively in `.env` (`TIKTOK_CLIENT_SECRET`). |
| **Token Exchange** | **NEVER** calls TikTok token endpoint directly. | Exchanges `code` + `code_verifier` + `client_secret` server-to-server with TikTok. |
| **Account Identity Verification** | **NEVER** sends unverified user profile data as trusted identity. | Queries `https://open.tiktokapis.com/v2/user/info/` using the server-obtained `access_token` to obtain verified `open_id`, `union_id`, `display_name`, and `avatar_url`. |

---

## 4. Mobile-to-Laravel Connect Endpoint Specification

### Endpoint
`POST /provider/mobile/social/connect-token`  
*(Fallbacks: `POST /provider/social/connect-token`, `POST /provider/automation-settings/provider/social-connections/tiktok/connect-token`)*

### Request Headers
| Header | Value | Description |
|---|---|---|
| `Accept` | `application/json` | Expects JSON response |
| `Content-Type` | `application/json` | JSON request payload |
| `X-CSRF-TOKEN` | `{{ csrf_token }}` | Extracted from active WebView page |
| `X-Requested-With` | `XMLHttpRequest` | Identifies AJAX request |
| `Cookie` | `wedding-planner-session=...` | Authenticated Laravel session cookie |

### Request Body Schema
```json
{
  "provider": "tiktok",
  "code": "clt.example_authorization_code_from_tiktok_opensdk",
  "code_verifier": "aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY",
  "state": "x8Km2p9Lq4Rv7Wz1Yj5Bn3Ct6D8F0G2H",
  "redirect_uri": "https://pastel-eg.com/social-connections/tiktok/callback",
  "granted_scopes": [
    "user.info.basic"
  ],
  "device_platform": "android"
}
```

---

## 5. Server-to-Server TikTok Open API v2 Exchange

### Step 1: Exchange Authorization Code + PKCE Verifier for Access Token
- **URL**: `POST https://open.tiktokapis.com/v2/oauth/token/`
- **Content-Type**: `application/x-www-form-urlencoded`
- **Form Fields**:
  - `client_key`: `config('services.tiktok.client_key')` (`aw68o0783j7z9eeg`)
  - `client_secret`: `config('services.tiktok.client_secret')`
  - `code`: `$request->input('code')`
  - `grant_type`: `"authorization_code"`
  - `redirect_uri`: `$request->input('redirect_uri')` (verified against server allowlist)
  - `code_verifier`: `$request->input('code_verifier')`

#### TikTok Token API Response (`200 OK`):
```json
{
  "access_token": "act.example_access_token_value",
  "expires_in": 86400,
  "open_id": "_000example_user_open_id",
  "refresh_expires_in": 31536000,
  "refresh_token": "rft.example_refresh_token_value",
  "scope": "user.info.basic",
  "token_type": "Bearer"
}
```
*(Note: Depending on TikTok API v2 endpoint revision, fields are returned either at the root object or inside `"data"`. The Laravel controller handles both `data_get($tokenData, 'access_token') ?? data_get($tokenData, 'data.access_token')`).*

### Step 2: Fetch Verified TikTok Account Identity
- **URL**: `GET https://open.tiktokapis.com/v2/user/info/?fields=open_id,union_id,avatar_url,display_name`
- **Headers**:
  - `Authorization: Bearer {access_token}`

#### TikTok User Info Response (`200 OK`):
```json
{
  "data": {
    "user": {
      "open_id": "_000example_user_open_id",
      "union_id": "_000example_user_union_id",
      "avatar_url": "https://p16-va.tiktokcdn.com/tos-maliva-avt-0068/sample.jpeg",
      "display_name": "Pastel Studio"
    }
  },
  "error": {
    "code": "ok",
    "message": "",
    "log_id": "202611081138100102003004006"
  }
}
```

---

## 6. Laravel Response Contract to Mobile App

### Success Response (`200 OK`)
*(Never includes `access_token`, `refresh_token`, or `client_secret`)*
```json
{
  "success": true,
  "status": "success",
  "message": "تم ربط حساب تيك توك بنجاح",
  "data": {
    "provider": "tiktok",
    "account_id": "_000example_user_open_id",
    "display_name": "Pastel Studio",
    "avatar_url": "https://p16-va.tiktokcdn.com/tos-maliva-avt-0068/sample.jpeg",
    "status": "connected"
  }
}
```

### Error Responses
- **`401 Unauthorized`**: User session expired or unauthenticated.
- **`422 Unprocessable Entity`**: Invalid/expired `code`, PKCE `code_verifier` mismatch, or invalid `redirect_uri`.
- **`409 Conflict`**: This TikTok `open_id` is already linked to a different Pastel user account.
