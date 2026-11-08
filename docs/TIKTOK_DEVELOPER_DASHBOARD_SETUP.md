# TikTok for Developers Dashboard Configuration Guide — Pastel Mobile App

This step-by-step checklist covers the exact setup required in the **TikTok Developer Portal** to activate native authentication for **Pastel** (`com.pasteleg.app`).

---

## 1. Portal Access & App Creation

1. Navigate to the official portal: **[https://developers.tiktok.com/](https://developers.tiktok.com/)**.
2. Sign in with the organization's TikTok account.
3. In the top navigation bar, click **Manage apps** > **Create an app**.
4. Set App Name to: `Pastel` (or `Pastel Studio`).
5. Upload the app icon (same logo used on the website and app store).
6. Set Category to: `Lifestyle` / `Business Services`.

---

## 2. Add Login Kit Product

1. In your app dashboard left sidebar, navigate to **Products** > **Add products**.
2. Locate **Login Kit** and click **Add**.
3. Under Login Kit Configuration, configure the following environments:

---

## 3. Platform Configurations & Redirect URIs

### A. Web / Server-Side Callbacks
In the **Redirect URI** section, enter both development and production callback URLs:
- Production Web Callback:
  ```text
  https://pastel-eg.com/social-connections/tiktok/callback
  ```
- Custom Scheme Native Deep Link Callback:
  ```text
  pastel://tiktok-auth
  ```
*(Both URIs must be added and saved).*

---

### B. Android Platform Configuration
Under **Platform** settings, enable **Android**:
- **Package Name**:
  ```text
  com.pasteleg.app
  ```
- **Android Signing Certificate SHA-256 Fingerprint**:
  - Run the following command locally on your release keystore to extract your SHA-256:
    ```bash
    keytool -list -v -keystore android/app/upload-keystore.jks
    ```
  - Copy the `SHA256: XX:XX:XX...` fingerprint and paste it into the TikTok portal.
  - *(Optional)* Add your debug keystore SHA-256 fingerprint for local testing:
    ```bash
    keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
    ```

---

### C. iOS Platform Configuration
Under **Platform** settings, enable **iOS**:
- **Bundle ID**:
  ```text
  com.pasteleg.app
  ```
- **URL Scheme**:
  ```text
  pastel
  ```
- **App Store ID**: (Leave blank if pending release or input existing Apple App Store ID).

---

## 4. Scopes & Permissions Configuration

In the **Permissions** tab under **Login Kit**:
1. **`user.info.basic`** (*Mandatory*):
   - Grants read access to user's public profile (avatar, username, display name, open_id).
2. **`video.list`** (*Optional*):
   - Grants read access to user's public video list if needed for portfolio display.

---

## 5. Client Credentials

Once your app is created, copy the credentials into your configuration:
- **Client Key** (Public): Set in Flutter `lib/utils/constants.dart` under `tiktokClientKey`.
- **Client Secret** (Confidential): Set ONLY in Laravel `.env` under `TIKTOK_CLIENT_SECRET`.
  *CRITICAL: Never put the Client Secret in Flutter or client-side code.*

---

## 6. Testing in Sandbox / Development Mode

Before submitting for App Review:
1. In the TikTok Developer Portal, go to **Roles** / **Test Accounts**.
2. Add your TikTok personal account handle as a **Tester**.
3. The tester will receive an invite notification on TikTok. Accept the invite.
4. Now you can test the native login and callback on your phone in Debug or Release mode without waiting for review approval.

---

## 7. App Review Submission Checklist

When ready for public production:
1. Ensure Privacy Policy URL is set to `https://pastel-eg.com/privacy-policy` (or equivalent).
2. Ensure Terms of Service URL is set to `https://pastel-eg.com/terms`.
3. Provide a brief video recording demonstrating:
   - User tapping "Connect TikTok" in Pastel app.
   - TikTok native app opening and requesting permission.
   - Returning to Pastel app showing **"تم التسجيل"** (Connected).
4. Click **Submit for Review**.
