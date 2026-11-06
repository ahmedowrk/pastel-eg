# PASTEL NATIVE META AUTHENTICATION — PLATFORM SETUP GUIDE

**Meta App ID**: `2184428119002213`  
**Android Application ID**: `com.pasteleg.app`  
**iOS Bundle Identifier**: (Pastel Production Bundle ID)  

---

## 1. Flutter Dependencies (`pubspec.yaml`)

Add the official Meta authorization plugin and HTTP client to your Flutter dependencies:

```yaml
dependencies:
  flutter:
    sdk: flutter
  webview_flutter: ^4.10.0
  webview_flutter_android: ^4.1.0
  flutter_facebook_auth: ^6.1.0
  http: ^1.2.0
  image_picker: ^1.1.2
  url_launcher: ^6.3.1
  firebase_core: ^3.8.1
  firebase_messaging: ^15.1.6
  app_badge_plus: ^1.1.3
```

Run in terminal:
```bash
flutter pub get
```

---

## 2. Android Configuration

### 2.1 Strings Resource (`android/app/src/main/res/values/strings.xml`)
Create or update `android/app/src/main/res/values/strings.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">Pastel</string>
    <string name="facebook_app_id">2184428119002213</string>
    <string name="fb_login_protocol_scheme">fb2184428119002213</string>
    <!-- Replace with your Facebook Client Token from Meta Dashboard -> Settings -> Advanced -->
    <string name="facebook_client_token">PASTE_YOUR_META_CLIENT_TOKEN_HERE</string>
</resources>
```

### 2.2 Android Manifest (`android/app/src/main/AndroidManifest.xml`)
Inside `<application>` tag, add the Meta application ID metadata and activities:

```xml
<application
    android:label="Pastel"
    android:name="${applicationName}"
    android:icon="@mipmap/ic_launcher">

    <!-- Meta / Facebook SDK Configuration -->
    <meta-data
        android:name="com.facebook.sdk.ApplicationId"
        android:value="@string/facebook_app_id" />
    <meta-data
        android:name="com.facebook.sdk.ClientToken"
        android:value="@string/facebook_client_token" />

    <activity
        android:name="com.facebook.FacebookActivity"
        android:configChanges="keyboard|keyboardHidden|screenLayout|screenSize|orientation"
        android:label="@string/app_name" />

    <activity
        android:name="com.facebook.CustomTabActivity"
        android:exported="true">
        <intent-filter>
            <action android:name="android.intent.action.VIEW" />
            <category android:name="android.intent.category.DEFAULT" />
            <category android:name="android.intent.category.BROWSABLE" />
            <data android:scheme="@string/fb_login_protocol_scheme" />
        </intent-filter>
    </activity>

    <!-- Existing Main Activity & Firebase setup remains unchanged below -->
</application>
```

### 2.3 Android Key Hashes for Meta Dashboard
Generate the release and debug Key Hashes to register under Meta Developer Dashboard > Basic Settings > Android:

```bash
# Debug Key Hash
keytool -exportcert -alias androiddebugkey -keystore ~/.android/debug.keystore | openssl sha1 -binary | openssl base64

# Release Key Hash (using your release keystore)
keytool -exportcert -alias YOUR_KEY_ALIAS -keystore /path/to/release.keystore | openssl sha1 -binary | openssl base64
```

---

## 3. iOS Configuration

### 3.1 iOS Info.plist (`ios/Runner/Info.plist`)
Inside `<dict>` tag, add the URL schemes and queries:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>fb2184428119002213</string>
    </array>
  </dict>
</array>

<key>FacebookAppID</key>
<string>2184428119002213</string>
<key>FacebookClientToken</key>
<string>PASTE_YOUR_META_CLIENT_TOKEN_HERE</string>
<key>FacebookDisplayName</key>
<string>Pastel</string>

<key>LSApplicationQueriesSchemes</key>
<array>
  <string>fbapi</string>
  <string>fb-messenger-share-api</string>
</array>
```

---

## 4. Website-side JavaScript Usage (`https://pastel-eg.com`)

On the social media settings page (`/provider/social-media-and-data`), when rendered inside the mobile app:

```javascript
// 1. Verify that the Native Bridge is available
if (window.PastelNative && window.PastelNative.isAvailable) {
  // Listen for the connection result
  window.onSocialConnectionResult = function(result) {
    console.log('[Website] Received social connection result:', result);

    if (result.status === 'success') {
      alert('تم ربط صفحة ' + (result.pageName || 'فيسبوك') + ' بنجاح!');
      // Refresh the accounts table
      window.location.reload();
    } else if (result.status === 'cancelled') {
      console.log('تم إلغاء عملية الربط.');
    } else {
      alert('فشل الربط: ' + (result.errorMessage || result.status));
    }
  };

  // 2. Trigger native connection when the user clicks "ربط فيسبوك"
  document.getElementById('connectFbBtn').addEventListener('click', function(e) {
    e.preventDefault();
    window.PastelNative.connectSocialAccount('facebook');
  });
}
```
