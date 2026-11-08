# TikTok for Developers Dashboard Setup — Pastel Mobile App (Official OpenSDK v2)

This guide covers the exact configuration required in the **[TikTok Developer Portal](https://developers.tiktok.com/)** for **Pastel** (`com.pasteleg.app`) using the official **TikTok OpenSDK v2**.

---

## 1. App Credentials

- **Client Key**: `aw68o0783j7z9eeg`
  - Configured in Flutter (`lib/utils/constants.dart` -> `AppConstants.tiktokClientKey`).
  - Configured in iOS (`ios/Runner/Info.plist` -> `TikTokClientKey` & `CFBundleURLSchemes`).
- **Client Secret**: Confidential
  - Stored **ONLY** on the Laravel backend (`.env` -> `TIKTOK_CLIENT_SECRET`).
  - **NEVER** placed inside the Flutter application.

---

## 2. Login Kit v2 Redirect URI Configuration (HTTPS Only)

TikTok Login Kit v2 requires **HTTPS Redirect URIs** backed by Android App Links and iOS Universal Links (custom schemes like `pastel://` are not supported by Login Kit v2).

In the TikTok Developer Portal under **Products > Login Kit > Redirect URI**:
1. Add for **Android**, **iOS**, and **Web**:
   ```text
   https://pastel-eg.com/social-connections/tiktok/callback
   ```
2. Add secondary path (if used by web dashboard):
   ```text
   https://pastel-eg.com/provider/automation-settings/provider/social-connections/tiktok/callback
   ```

---

## 3. Android Platform Settings

Under **Login Kit > Android**:
- **Android Package Name**:
  ```text
  com.pasteleg.app
  ```
- **App Signing Certificate SHA-256 Fingerprint**:
  Extract the SHA-256 fingerprint from your release keystore (`key.properties` / Play App Signing) and debug keystore:
  ```bash
  keytool -list -v -keystore android/app/upload-keystore.jks
  ```
  *(Note: `com.tiktok.open.sdk:tiktok-open-sdk-auth:2.4.0` sends the caller app's SHA-256 signing certificate hash in both native `AwemeAuthorizedActivity` intents and `ChromeTab` fallback requests. If the SHA-256 fingerprint is missing in the TikTok Developer Portal, TikTok returns `errorCode: 10033`).*

---

## 4. iOS Platform Settings

Under **Login Kit > iOS**:
- **Bundle ID**:
  ```text
  com.pasteleg.app
  ```
- **Associated Domains (Universal Links)**:
  Configured in `ios/Runner/Runner.entitlements`:
  ```text
  applinks:pastel-eg.com
  ```
- **URL Scheme for Web Auth Fallback**:
  Configured in `ios/Runner/Info.plist`:
  ```text
  aw68o0783j7z9eeg
  ```

---

## 5. Required Scopes

Under **Scopes**:
- `user.info.basic` (Required — provides verified `open_id`, `union_id`, `display_name`, and `avatar_url`).
- `video.list` (Optional — only if displaying user portfolio videos).
