# TikTok OAuth 2.0 PKCE Backend Contract — Pastel Mobile & Web

## 1. Overview & Architecture

Pastel mobile application (`com.pasteleg.app`) implements **Native TikTok Authentication** using the official **TikTok Login Kit v2** via standard **OAuth 2.0 Authorization Code Flow with PKCE (RFC 7636)**.

### Why PKCE?
- **Zero Secret Exposure**: The TikTok `client_secret` is NEVER stored in the Flutter mobile application, ensuring maximum security.
- **CSRF & Interception Protection**: Every authorization request uses a cryptographically secure `code_verifier` (high-entropy cryptographic random string) and its SHA-256 hashed `code_challenge`, along with a unique anti-CSRF `state`.
- **Seamless User Experience**: If the TikTok app is installed on the user's device, it opens natively without requiring password input or CAPTCHAs.

---

## 2. Authentication Flow Sequence

```text
┌─────────────────┐       ┌─────────────────┐       ┌──────────────────────┐       ┌──────────────────────┐
│  Pastel Flutter │       │  TikTok App /   │       │    Pastel Laravel    │       │     TikTok API       │
│     (Client)    │       │     Browser     │       │       (Backend)      │       │     (Server v2)      │
└────────┬────────┘       └────────┬────────┘       └──────────┬───────────┘       └──────────┬───────────┘
         │                         │                           │                              │
         │ 1. Generate PKCE        │                           │                              │
         │    (verifier+challenge) │                           │                              │
         │ 2. Launch Auth URL      │                           │                              │
         │────────────────────────>│                           │                              │
         │                         │                           │                              │
         │                         │ 3. User approves in       │                              │
         │                         │    TikTok Native App      │                              │
         │ 4. Redirect Callback    │                           │                              │
         │    (code + state)       │                           │                              │
         │<────────────────────────│                           │                              │
         │                         │                           │                              │
         │ 5. POST Connect Token   │                           │                              │
         │    {code, verifier, ...}│                           │                              │
         │────────────────────────────────────────────────────>│                              │
         │                         │                           │ 6. Exchange Token with PKCE  │
         │                         │                           │    POST /v2/oauth/token/     │
         │                         │                           │─────────────────────────────>│
         │                         │                           │ 7. Return Access Token & OpenID
         │                         │                           │<─────────────────────────────│
         │                         │                           │                              │
         │                         │                           │ 8. Fetch User Profile Info   │
         │                         │                           │    GET /v2/user/info/        │
         │                         │                           │─────────────────────────────>│
         │                         │                           │ 9. Return Profile Data       │
         │                         │                           │<─────────────────────────────│
         │                         │                           │                              │
         │                         │                           │ 10. Store in DB & Link to    │
         │                         │                           │     auth()->user()           │
         │ 11. Return JSON Success │                           │                              │
         │<────────────────────────────────────────────────────│                              │
         │                         │                           │                              │
         │ 12. Reload WebView      │                           │                              │
         │     Shows: "تم التسجيل" │                           │                              │
```

---

## 3. Mobile Connect API Specification

### Endpoint
`POST /provider/mobile/social/connect-token`  
*(Fallback: `POST /provider/social/connect-token`)*

### Headers
| Header | Value | Description |
|---|---|---|
| `Accept` | `application/json` | Expects JSON response |
| `Content-Type` | `application/json` | Payload format |
| `X-CSRF-TOKEN` | `{{ csrf_token }}` | Provided by WebView bridge |
| `X-Requested-With` | `XMLHttpRequest` | Identifies AJAX request |
| `Cookie` | `wedding-planner-session=...` | Authenticated session cookie |

### Request Payload
```json
{
  "provider": "tiktok",
  "code": "clt.example_auth_code_from_tiktok_callback_12345",
  "code_verifier": "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
  "state": "e5a6f8b92c4d1e0a",
  "redirect_uri": "pastel://tiktok-auth",
  "device_platform": "android"
}
```

#### Field Descriptions:
- **`provider`** (*string*, required): Must be exactly `"tiktok"`.
- **`code`** (*string*, required): Authorization code received from TikTok callback query parameter (`code`).
- **`code_verifier`** (*string*, required): The original high-entropy random string generated by the client before hashing with SHA-256. TikTok will hash this value on the server and match it against the `code_challenge` provided during authorization.
- **`state`** (*string*, required): Anti-CSRF verification state.
- **`redirect_uri`** (*string*, required): Must match EXACTLY the `redirect_uri` sent in the authorization request (`pastel://tiktok-auth` for native app callback, or `https://pastel-eg.com/social-connections/tiktok/callback` for web fallback).
- **`device_platform`** (*string*, optional): `"android"` or `"ios"`.

---

## 4. TikTok Open API v2 Integration (Backend to TikTok)

### Step 1: Exchange Authorization Code for Access Token
- **URL**: `https://open.tiktokapis.com/v2/oauth/token/`
- **Method**: `POST`
- **Content-Type**: `application/x-www-form-urlencoded`
- **Parameters**:
  - `client_key`: `env('TIKTOK_CLIENT_KEY')`
  - `client_secret`: `env('TIKTOK_CLIENT_SECRET')`
  - `code`: Value received from mobile request (`->input('code')`)
  - `grant_type`: `"authorization_code"`
  - `redirect_uri`: Value received from mobile request (`->input('redirect_uri')`)
  - `code_verifier`: Value received from mobile request (`->input('code_verifier')`)

#### Expected TikTok Token Response:
```json
{
  "data": {
    "access_token": "act.example_access_token_value_abc123",
    "expires_in": 86400,
    "open_id": "_000example_user_open_id_xyz",
    "refresh_expires_in": 31536000,
    "refresh_token": "rft.example_refresh_token_value_456def",
    "scope": "user.info.basic",
    "token_type": "Bearer"
  },
  "error": {
    "code": "ok",
    "message": "",
    "log_id": "202611081138000102003004005"
  }
}
```

---

### Step 2: Fetch TikTok User Profile
- **URL**: `https://open.tiktokapis.com/v2/user/info/?fields=open_id,union_id,avatar_url,display_name`
- **Method**: `GET`
- **Headers**:
  - `Authorization`: `Bearer {access_token}`

#### Expected TikTok Profile Response:
```json
{
  "data": {
    "user": {
      "avatar_url": "https://p16-va.tiktokcdn.com/tos-maliva-avt-0068/sample.jpeg",
      "display_name": "Pastel Studio",
      "open_id": "_000example_user_open_id_xyz",
      "union_id": "_000example_user_union_id_123"
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

## 5. Database Schema & Storage

Accounts are associated with the authenticated user (`auth()->user()`).

### Recommended Table: `connected_social_accounts` (or `social_accounts`)
| Column | Type | Attributes | Description |
|---|---|---|---|
| `id` | BIGINT UNSIGNED | AUTO_INCREMENT, PRIMARY | Primary Key |
| `user_id` | BIGINT UNSIGNED | INDEX, FOREIGN KEY | References `users.id` |
| `provider` | VARCHAR(32) | INDEX | Value: `"tiktok"` |
| `provider_id` | VARCHAR(128) | INDEX | TikTok `open_id` or `union_id` |
| `name` | VARCHAR(255) | NULLABLE | Display name (`display_name`) |
| `nickname` | VARCHAR(255) | NULLABLE | Username or handle |
| `avatar` | TEXT | NULLABLE | Avatar URL |
| `access_token` | TEXT | ENCRYPTED | Encrypted access token |
| `refresh_token`| TEXT | ENCRYPTED, NULLABLE | Encrypted refresh token |
| `token_expires_at` | TIMESTAMP | NULLABLE | Calculated: `now()->addSeconds()` |
| `created_at` | TIMESTAMP | | |
| `updated_at` | TIMESTAMP | | |

*Unique constraint recommended on `["user_id", "provider"]`, or allow multiple accounts per provider depending on business logic.*

---

## 6. Success & Error Response Contracts

### Success Response (`200 OK`)
```json
{
  "success": true,
  "message": "تم ربط حساب تيك توك بنجاح",
  "data": {
    "provider": "tiktok",
    "account_id": "_000example_user_open_id_xyz",
    "display_name": "Pastel Studio",
    "status": "connected"
  }
}
```

### Error Responses
#### Unauthorized (`401 Unauthorized`)
```json
{
  "success": false,
  "message": "يجب تسجيل الدخول أولاً لإتمام الربط"
}
```

#### Invalid Grant / Token Exchange Failed (`422 Unprocessable Entity`)
```json
{
  "success": false,
  "message": "فشل التحقق من رمز تفويض تيك توك. يرجى إعادة المحاولة.",
  "error_code": "TIKTOK_TOKEN_EXCHANGE_FAILED",
  "debug_message": "invalid_grant: code_verifier does not match"
}
```

#### Account Already Linked (`409 Conflict`)
```json
{
  "success": false,
  "message": "هذا الحساب مرتبط بالفعل بمستخدم آخر",
  "error_code": "ACCOUNT_ALREADY_LINKED"
}
```

---

## 7. Status & UI Reflection
When the connection succeeds, the Laravel backend marks the TikTok connection as active for the logged-in user.
When the Flutter WebView reloads or the user visits the Social Connections page, the status renders:
**"تم التسجيل"** (or **"متصل"** / Connected), matching the behavior of Facebook and Instagram.
