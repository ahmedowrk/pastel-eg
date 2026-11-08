# TikTok Login Kit v2 (Official OpenSDK + PKCE) — Laravel Backend Contract

**Canonical Endpoint**: `POST /ar/mobile/social/tiktok/connect-token`  
**Target Host**: `https://pastel-eg.com`  
**Authentication**: Active Provider Session Cookie (`laravel_session` / `wedding-planner-session`) + `X-CSRF-TOKEN`

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

## 2. Exact Request Schema

### Headers
```http
POST /ar/mobile/social/tiktok/connect-token HTTP/1.1
Host: pastel-eg.com
Content-Type: application/json
Accept: application/json
X-Requested-With: XMLHttpRequest
X-CSRF-TOKEN: <csrf_token_from_meta_or_xsrf_cookie>
Cookie: <authenticated_webview_session_cookies>
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

## 3. Exact Success Response Schema (`200 OK`)

`TikTokBackendService.parseSuccessResponse` strictly validates all mandatory fields below and will reject any response missing `connection_id`, `connected_account.open_id`, or `connected_account.display_name`:

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

### Mandatory Fields Checked by Flutter:
- `status`: Must equal `"success"`.
- `provider`: Must equal `"tiktok"`.
- `connection_id`: Non-empty string identifier of the stored social connection record.
- `connected_account.open_id`: Non-empty string verified from TikTok `/v2/user/info/`.
- `connected_account.display_name`: Non-empty string verified from TikTok `/v2/user/info/`.
- `connected_account.avatar_url`: Optional string URL.

---

## 4. Exact Error Response Schema

Flutter inspects the explicit `code` field rather than assuming every `422` is a permission error:

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
| `401` / `403` | `UNAUTHENTICATED` | `authentication_failed` | Merchant session expired or invalid CSRF token |
| `422` | `INVALID_GRANT` | `authentication_failed` | Authorization `code` expired, already used, or `code_verifier` mismatch |
| `422` | `MISSING_PERMISSIONS` | `permission_denied` | Required scope (`user.info.basic`) was not granted |
| `409` | `ACCOUNT_ALREADY_LINKED` | `account_already_linked` | This TikTok `open_id` is already linked to another merchant account |
| `500` / `502` | `BACKEND_ERROR` | `backend_error` | Unexpected server or upstream TikTok API failure |

---

## 5. Server-to-Server TikTok API Exchange Steps

1. **Validate `redirect_uri`**: Must match `https://pastel-eg.com/social-connections/tiktok/callback`.
2. **Exchange Code + Verifier**:
   - `POST https://open.tiktokapis.com/v2/oauth/token/` (`application/x-www-form-urlencoded`)
   - Fields: `client_key`, `client_secret`, `code`, `grant_type=authorization_code`, `redirect_uri`, `code_verifier`.
3. **Verify Required Scopes**: Ensure `user.info.basic` is present in the token's granted `scope`; if missing, return `422` with `code: "MISSING_PERMISSIONS"`.
4. **Fetch Verified Account Identity**:
   - `GET https://open.tiktokapis.com/v2/user/info/?fields=open_id,union_id,avatar_url,display_name` with header `Authorization: Bearer {access_token}`.
5. **Persist & Return**: Store encrypted tokens linked to `auth()->id()` and return the Section 3 JSON response without ever returning `access_token` or `refresh_token`.
