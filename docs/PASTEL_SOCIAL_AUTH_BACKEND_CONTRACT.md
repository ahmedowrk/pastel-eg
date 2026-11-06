# PASTEL SOCIAL AUTHENTICATION — LARAVEL BACKEND API CONTRACT

**Document Version**: 1.0.0  
**Target Backend**: Laravel 10/11 Framework at `https://pastel-eg.com`  
**Authentication Standard**: Session Cookies (`laravel_session` + `X-CSRF-TOKEN`) / Bearer Token  
**Meta App ID**: `2184428119002213` (Pastel Studio)  

---

## 1. Security Architecture & Rules

1. **Zero Secret Storage in Client**: The Meta App Secret (`client_secret`) MUST NEVER be stored, referenced, or shipped inside the Flutter mobile application or JavaScript code.
2. **Zero Token Exposure to JavaScript**: Access tokens obtained by native SDKs or backend exchanges must NEVER be passed into WebView DOM or returned via `window.onSocialConnectionResult`.
3. **Transport Security**: All endpoints MUST use HTTPS exclusively.
4. **Session Binding**: Every social account connection request must be authenticated with the active merchant/provider session on `pastel-eg.com`.
5. **Replay & Concurrency Prevention**: Requests must include unique `request_id` or timestamp nonces to prevent replay attacks.

---

## 2. API Endpoints Specification

### 2.1 Connect Social Account via Native Token (Recommended Flow)
When the user completes native Facebook Login on Android or iOS, Flutter receives a short-lived User Access Token (`accessToken.token`). Flutter immediately forwards it to Laravel to exchange for a long-lived Page Access Token.

- **Endpoint**: `POST /ar/mobile/social/meta/connect-token`
- **Authentication**: Authenticated Provider Session (`laravel_session` + `X-CSRF-TOKEN` or `Authorization: Bearer <token>`)
- **Headers**:
  ```http
  Content-Type: application/json
  Accept: application/json
  X-CSRF-TOKEN: <csrf_token>
  X-Requested-With: XMLHttpRequest
  ```
- **Request Body**:
  ```json
  {
    "provider": "facebook",
    "access_token": "EAAfBh...user_access_token...",
    "granted_permissions": [
      "pages_show_list",
      "pages_read_engagement",
      "pages_manage_posts",
      "pages_messaging",
      "instagram_basic",
      "instagram_manage_messages"
    ],
    "device_platform": "android"
  }
  ```
- **Backend Processing Steps**:
  1. Validate incoming `access_token` against Graph API `GET https://graph.facebook.com/v26.0/me?access_token=...`.
  2. Exchange for long-lived User Token:
     `GET https://graph.facebook.com/v26.0/oauth/access_token?grant_type=fb_exchange_token&client_id=2184428119002213&client_secret={APP_SECRET}&fb_exchange_token={USER_TOKEN}`.
  3. Query associated Pages and Instagram Accounts:
     `GET https://graph.facebook.com/v26.0/me/accounts?fields=id,name,access_token,instagram_business_account{id,username,name}`.
  4. Automatically connect primary Page or store available pages for selection.
- **Success Response (`200 OK`)**:
  ```json
  {
    "status": "success",
    "connection_id": "meta_conn_98231",
    "provider": "facebook",
    "connected_page": {
      "id": "1319472027925479",
      "name": "Agentamrs",
      "instagram_account": {
        "id": "178414002345678",
        "username": "agentamrs_eg"
      }
    },
    "granted_scopes": [
      "pages_show_list",
      "pages_read_engagement",
      "pages_manage_posts"
    ],
    "message": "تم ربط صفحة Agentamrs وحساب انستجرام بنجاح"
  }
  ```
- **Error Responses**:
  - `401 Unauthorized`: Session expired or invalid CSRF token.
  - `422 Unprocessable Entity`: Missing or revoked permissions.
    ```json
    {
      "status": "error",
      "code": "MISSING_PERMISSIONS",
      "missing_scopes": ["pages_manage_posts", "pages_show_list"],
      "message": "يجب منح جميع الصلاحيات المطلوبة للتمكن من إدارة الصفحة."
    }
    ```
  - `400 Bad Request`: Invalid or expired Facebook token.

---

### 2.2 Get Social Connection Status
Allows the Flutter app and website to query the real-time connection state of Facebook and Instagram.

- **Endpoint**: `GET /ar/mobile/social/status`
- **Authentication**: Authenticated Provider Session
- **Query Parameters**: None
- **Response (`200 OK`)**:
  ```json
  {
    "status": "success",
    "connections": {
      "facebook": {
        "connected": true,
        "page_id": "1319472027925479",
        "page_name": "Agentamrs",
        "connected_at": "2026-11-06T11:45:00Z",
        "token_expires_at": "2026-05-06T11:45:00Z"
      },
      "instagram": {
        "connected": true,
        "account_id": "178414002345678",
        "username": "agentamrs_eg"
      },
      "tiktok": {
        "connected": false
      }
    }
  }
  ```

---

### 2.3 Disconnect Social Account
Allows disconnecting a Facebook Page or Instagram account and revoking server-stored tokens.

- **Endpoint**: `POST /ar/mobile/social/disconnect`
- **Authentication**: Authenticated Provider Session
- **Request Body**:
  ```json
  {
    "provider": "facebook",
    "revoke_meta_permissions": false
  }
  ```
- **Response (`200 OK`)**:
  ```json
  {
    "status": "success",
    "message": "تم إلغاء ربط حساب فيسبوك بنجاح"
  }
  ```

---

## 3. Account Switching & Force Re-authentication (`auth_type=reauthenticate`)
If the web-based OAuth fallback is used, Laravel must generate the OAuth redirect URL with Meta's official re-authentication flag:

```php
// In Laravel Controller or Socialite Provider setup:
$url = 'https://www.facebook.com/v26.0/dialog/oauth?' . http_build_query([
    'client_id' => config('services.facebook.client_id'), // 2184428119002213
    'redirect_uri' => route('meta.callback'),
    'state' => $state,
    'response_type' => 'code',
    'auth_type' => 'reauthenticate', // <-- Forces Facebook to present login dialog instead of "Continue as [Old User]"
    'scope' => implode(',', [
        'publish_video',
        'instagram_basic',
        'instagram_content_publish',
        'pages_messaging',
        'instagram_manage_messages',
        'pages_manage_posts',
        'pages_read_engagement',
        'pages_manage_metadata',
        'pages_show_list'
    ])
]);
return redirect($url);
```
