# PASTEL NATIVE META AUTHENTICATION & WEBVIEW BRIDGE — REPOSITORY AUDIT

**Target Application**: Pastel Mobile (`com.pasteleg.app`)  
**Production Website**: `https://pastel-eg.com`  
**Firebase Project**: `pastel-e59a0`  
**Meta Application ID**: `2184428119002213` (Pastel Studio)  
**Audit Date**: 2026-11-06  
**Auditor**: Senior Flutter Engineer & Mobile Authentication Architect  

---

## 1. Executive Summary

Pastel is a production mobile application currently implemented as a Flutter WebView container with integrated Firebase Cloud Messaging (FCM) that wraps the Laravel-powered e-commerce & merchant platform at `https://pastel-eg.com`.

Merchants and providers configure their store settings and connect social media accounts (Facebook Pages, Instagram Professional Accounts) at `https://pastel-eg.com/provider/social-media-and-data`.

While the recent WebView stabilization resolved the Android WebAuthn/Passkey crash ("Something went wrong — Use your passkey again") and enabled authentication via mobile Safari User-Agent emulation with third-party cookie persistence, the client has requested **Native Social Authorization**. In this flow, tapping "Connect Facebook" or "Connect Instagram" on the website triggers the native Facebook SDK (or external secure system browser) without forcing users to re-enter credentials or navigate raw OAuth dialogs inside the embedded WebView.

---

## 2. Repository Architecture & Component Map

### 2.1 Flutter Components
- `lib/webview/webview_controller.dart`:
  - Controller initializing `WebViewController` with `_kPasskeyFreeSafariUserAgent`.
  - Injects `_kDisablePasskeyJs` on `onPageStarted` and `onPageFinished` to suppress broken WebAuthn credentials.
  - Registers JavaScript channels:
    - `FlutterFCMChannel`: Dispatches FCM device token, device name, and CSRF token to `POST /ar/fcm/device-token`.
    - `NotificationStateChannel`: Handles badge count synchronization via `NotificationStateService`.
  - Platform-specific Android setup: enables `setAcceptThirdPartyCookies(true)` and image picking via `ImagePicker`.
  - Navigation delegate rewrites `www.facebook.com/v26.0/dialog/oauth` to `m.facebook.com`.
  - Missing: Native Social Bridge JavaScript channel (`PastelNativeChannel`), native Facebook SDK bindings, and secure native-to-Laravel credential exchange.

- `lib/services/notification_service.dart` & `lib/services/notification_state_service.dart`:
  - Handles FCM push payloads, badge tracking with `AppBadgePlus`, and deep linking.
  - Must remain completely intact and undisturbed.

### 2.2 Android Configuration State
- **Application ID**: `com.pasteleg.app`
- **Current State**: Uses standard Android WebView with third-party cookies enabled.
- **Required Meta SDK Configuration**:
  - `FacebookAppID`: `2184428119002213`
  - `FacebookClientToken`: (Provided in Meta App Dashboard under Settings > Advanced > Client Token)
  - `com.facebook.FacebookActivity` and `com.facebook.CustomTabActivity` intent filters with `fb2184428119002213`.
  - Android Key Hash (Debug & Release SHA-1 converted to base64) registered in Meta Developer Dashboard.

### 2.3 iOS Configuration State
- **Bundle Identifier**: Matches production release profile for Pastel.
- **Required Meta SDK Configuration**:
  - `Info.plist`: `CFBundleURLTypes` with scheme `fb2184428119002213`.
  - `LSApplicationQueriesSchemes`: `fbapi`, `fb-messenger-share-api`.
  - `FacebookAppID`: `2184428119002213`
  - `FacebookDisplayName`: `Pastel` or `Pastel Studio`

### 2.4 Website & OAuth Inspection
Live inspection of `https://pastel-eg.com` revealed:
- **Connection Trigger**: Button on `/provider/social-media-and-data` initiates a `GET` request to `/provider/automation-settings/provider/social-connections/meta/connect`.
- **OAuth Parameters**:
  - `client_id`: `2184428119002213`
  - `redirect_uri`: `https://pastel-eg.com/provider/automation-settings/provider/social-connections/meta/callback`
  - `response_type`: `code`
  - `state`: Cryptographically generated per session and stored in Laravel session.
  - `scope`: `publish_video,instagram_basic,instagram_content_publish,pages_messaging,instagram_manage_messages,pages_manage_posts,pages_read_engagement,pages_manage_metadata,pages_show_list`
- **Post-Auth Flow**:
  - Facebook redirects to `/meta/callback?code=...&state=...`.
  - Laravel exchanges `code` for a User Access Token and redirects to `/select-page`.
  - User chooses the Facebook Page (`page_id`), which Laravel saves alongside long-lived Page Access Tokens.

---

## 3. Gap Analysis & Vulnerabilities

| Area | Current State | Risk / Gap | Required Native Architecture |
| :--- | :--- | :--- | :--- |
| **User Interaction** | WebView redirects full page to Facebook | Clunky UI, session cookie collisions, "Continue as previous user" lock-in | Native popup / Facebook App SSO |
| **Token Handling** | Cookie-based session in WebView | Web cookies may leak across WebView if compromised | Pure Native SDK / Secure Token Transfer to Laravel; zero tokens in JS |
| **Bridge Security** | Only FCM and Badge channels exist | No bridge for social login requests | `window.PastelNative` JS Channel with schema & origin validation |
| **Account Switching** | Locked into previously signed-in Facebook user | User cannot switch Facebook account without clearing all cookies | Native SDK `loginWithPermissions` + Laravel backend `reauthenticate` |

---

## 4. Dependencies & Prerequisites Matrix

1. **Meta Developer Dashboard**:
   - Add Android package `com.pasteleg.app` with release & debug Key Hashes.
   - Configure iOS Bundle ID with Single Sign On enabled.
   - Meta App ID `2184428119002213` verified and active.
2. **Laravel Backend**:
   - Provide an authenticated mobile API endpoint (`POST /ar/mobile/social/meta/connect-token` or `/meta/exchange-token`) that accepts `{ access_token: string }` or authorization code, retrieves pages, and saves credentials under the logged-in merchant.
3. **Flutter Dependencies**:
   - `flutter_facebook_auth: ^6.1.0` or official Facebook SDK wrapper.
