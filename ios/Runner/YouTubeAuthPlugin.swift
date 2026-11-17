import AuthenticationServices
import CryptoKit
import Flutter
import Foundation
import UIKit

final class YouTubeAuthPlugin: NSObject, FlutterPlugin, ASWebAuthenticationPresentationContextProviding {
  private static let channelName = "com.pasteleg.app/youtube_auth"
  private static let logTag = "[YouTubeOAuthDebug][iOS]"

  private var channel: FlutterMethodChannel?
  private var currentAuthSession: ASWebAuthenticationSession?
  private var lastSelectedEmail: String?
  private var cachedRefreshTokensByEmail: [String: String] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = YouTubeAuthPlugin()
    let methodChannel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    instance.channel = methodChannel
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    NSLog("\(logTag) Plugin registered with FlutterPluginRegistrar on channel \(channelName)")
  }

  static func register(with controller: FlutterViewController) {
    let instance = YouTubeAuthPlugin()
    let methodChannel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: controller.binaryMessenger
    )
    instance.channel = methodChannel
    methodChannel.setMethodCallHandler { [weak instance] call, result in
      instance?.handle(call, result: result)
    }
    objc_setAssociatedObject(
      controller,
      Unmanaged.passUnretained(instance).toOpaque(),
      instance,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickGoogleAccount":
      handlePickGoogleAccount(call: call, result: result)
    case "authorizeYouTubeScopes":
      handleAuthorizeYouTubeScopes(call: call, result: result)
    case "clearSelectedAccountSession":
      let args = call.arguments as? [String: Any] ?? [:]
      if let email = (args["accountEmail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
         !email.isEmpty {
        cachedRefreshTokensByEmail.removeValue(forKey: email)
      } else {
        cachedRefreshTokensByEmail.removeAll()
      }
      lastSelectedEmail = nil
      currentAuthSession?.cancel()
      currentAuthSession = nil
      NSLog("\(Self.logTag) Cleared selected Google account session.")
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Resolves the iOS OAuth 2.0 Client ID from Info.plist (`YouTubeIOSClientID`).
  /// Note: Google OAuth 2.0 requires an iOS client type (not a Web client type)
  /// when redirecting to a custom URL scheme (`com.googleusercontent.apps.<PREFIX>:/oauthredirect`).
  private func resolveIOSClientId() -> (clientId: String, callbackScheme: String)? {
    let info = Bundle.main.infoDictionary
    let configuredIOSClientId = (info?["YouTubeIOSClientID"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !configuredIOSClientId.isEmpty,
          !configuredIOSClientId.hasPrefix("YOUR_"),
          configuredIOSClientId.hasSuffix(".apps.googleusercontent.com") else {
      return nil
    }

    if let prefix = configuredIOSClientId.components(separatedBy: ".apps.googleusercontent.com").first,
       !prefix.isEmpty {
      return (
        clientId: configuredIOSClientId,
        callbackScheme: "com.googleusercontent.apps.\(prefix)"
      )
    }
    return nil
  }

  private func handlePickGoogleAccount(call: FlutterMethodCall, result: @escaping FlutterResult) {
    NSLog("\(Self.logTag) [Stage 1]Starting Google Account Picker (ASWebAuthenticationSession)")
    guard let oauthConfig = resolveIOSClientId() else {
      NSLog("\(Self.logTag) [Stage 1] Missing or invalid YouTubeIOSClientID in Info.plist")
      result([
        "status": "error",
        "errorCode": "missing_ios_client_id",
        "errorMessage": "لم يتم ضبط معرف عميل Google OAuth الخاص بنظام iOS (YouTubeIOSClientID) في ملف Info.plist."
      ])
      return
    }

    let verifier = Self.generateCodeVerifier()
    let challenge = Self.generateCodeChallenge(from: verifier)
    let redirectUri = "\(oauthConfig.callbackScheme):/oauthredirect"

    var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: oauthConfig.clientId),
      URLQueryItem(name: "redirect_uri", value: redirectUri),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: "openid email profile"),
      URLQueryItem(name: "prompt", value: "select_account"),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]

    guard let authUrl = components.url else {
      result([
        "status": "error",
        "errorCode": "invalid_auth_url",
        "errorMessage": "تعذر بناء رابط اختيار حسابات Google."
      ])
      return
    }

    let session = ASWebAuthenticationSession(
      url: authUrl,
      callbackURLScheme: oauthConfig.callbackScheme
    ) { [weak self] callbackURL, error in
      self?.currentAuthSession = nil

      if let nsError = error as NSError? {
        if nsError.domain == ASWebAuthenticationSessionErrorDomain,
           nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
          NSLog("\(Self.logTag) [Stage 2] Account picker cancelled by user.")
          result([
            "status": "cancelled",
            "errorCode": "user_cancelled",
            "errorMessage": "تم إلغاء اختيار حساب Google."
          ])
          return
        }
        NSLog("\(Self.logTag) [Stage 2] Account picker error: domain=\(nsError.domain), code=\(nsError.code)")
        result([
          "status": "error",
          "errorCode": "aswebauth_error_\(nsError.code)",
          "errorMessage": nsError.localizedDescription
        ])
        return
      }

      guard let callbackURL = callbackURL,
            let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems else {
        result([
          "status": "error",
          "errorCode": "invalid_callback_url",
          "errorMessage": "لم يتم استلام استجابة صالحة من نافذة اختيار حساب Google."
        ])
        return
      }

      if let oauthError = queryItems.first(where: { $0.name == "error" })?.value {
        let isCancelled = oauthError == "access_denied"
        NSLog("\(Self.logTag) [Stage 2] Account picker OAuth error: \(oauthError)")
        result([
          "status": isCancelled ? "cancelled" : "error",
          "errorCode": oauthError,
          "errorMessage": "تم إلغاء أو رفض اختيار حساب Google."
        ])
        return
      }

      guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
        result([
          "status": "error",
          "errorCode": "missing_auth_code",
          "errorMessage": "لم يتم استلام رمز التحقق من حساب Google."
        ])
        return
      }

      self?.exchangeCodeForAccountProfile(
        code: code,
        clientId: oauthConfig.clientId,
        redirectUri: redirectUri,
        codeVerifier: verifier,
        result: result
      )
    }

    session.presentationContextProvider = self
    session.prefersEphemeralWebBrowserSession = false
    currentAuthSession = session
    session.start()
  }

  private func handleAuthorizeYouTubeScopes(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let accountEmail = (args["accountEmail"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let scopes = (args["scopes"] as? [String]) ?? []
    let forceCodeForRefreshToken = (args["forceCodeForRefreshToken"] as? Bool) ?? true

    guard !accountEmail.isEmpty else {
      result([
        "status": "error",
        "errorCode": "missing_account_email",
        "errorMessage": "يرجى تحديد حساب Google أولاً."
      ])
      return
    }

    guard let oauthConfig = resolveIOSClientId() else {
      NSLog("\(Self.logTag) [Stage 3] Missing or invalid YouTubeIOSClientID in Info.plist")
      result([
        "status": "error",
        "selectedAccountEmail": accountEmail,
        "errorCode": "missing_ios_client_id",
        "errorMessage": "لم يتم ضبط معرف عميل Google OAuth الخاص بنظام iOS (YouTubeIOSClientID) في ملف Info.plist."
      ])
      return
    }

    let normalizedEmail = accountEmail.lowercased()
    if !forceCodeForRefreshToken,
       let cachedRefreshToken = cachedRefreshTokensByEmail[normalizedEmail],
       !cachedRefreshToken.isEmpty {
      NSLog("\(Self.logTag) [Stage 3] Performing silent access token refresh via cached refresh token")
      refreshYouTubeAccessToken(
        refreshToken: cachedRefreshToken,
        accountEmail: accountEmail,
        clientId: oauthConfig.clientId,
        requestedScopes: scopes,
        result: result
      )
      return
    }

    NSLog("\(Self.logTag) [Stage 3] Starting YouTube scope authorization | scopesCount=\(scopes.count), forceCodeForRefreshToken=\(forceCodeForRefreshToken)")

    let verifier = Self.generateCodeVerifier()
    let challenge = Self.generateCodeChallenge(from: verifier)
    let redirectUri = "\(oauthConfig.callbackScheme):/oauthredirect"
    let combinedScopes = (["openid", "email", "profile"] + scopes).joined(separator: " ")

    var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: oauthConfig.clientId),
      URLQueryItem(name: "redirect_uri", value: redirectUri),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: combinedScopes),
      URLQueryItem(name: "login_hint", value: accountEmail),
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "prompt", value: forceCodeForRefreshToken ? "consent" : "none"),
      URLQueryItem(name: "include_granted_scopes", value: "true"),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]

    guard let authUrl = components.url else {
      result([
        "status": "error",
        "selectedAccountEmail": accountEmail,
        "errorCode": "invalid_auth_url",
        "errorMessage": "تعذر بناء رابط تفويض صلاحيات YouTube."
      ])
      return
    }

    let session = ASWebAuthenticationSession(
      url: authUrl,
      callbackURLScheme: oauthConfig.callbackScheme
    ) { [weak self] callbackURL, error in
      self?.currentAuthSession = nil

      if let nsError = error as NSError? {
        if nsError.domain == ASWebAuthenticationSessionErrorDomain,
           nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
          NSLog("\(Self.logTag) [Stage 5] YouTube scope consent cancelled by user.")
          result([
            "status": "cancelled",
            "selectedAccountEmail": accountEmail,
            "errorCode": "user_cancelled",
            "errorMessage": "تم إلغاء الموافقة على صلاحيات YouTube."
          ])
          return
        }
        NSLog("\(Self.logTag) [Stage 5] YouTube scope consent error: domain=\(nsError.domain), code=\(nsError.code)")
        result([
          "status": "error",
          "selectedAccountEmail": accountEmail,
          "errorCode": "aswebauth_error_\(nsError.code)",
          "errorMessage": nsError.localizedDescription
        ])
        return
      }

      guard let callbackURL = callbackURL,
            let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems else {
        result([
          "status": "error",
          "selectedAccountEmail": accountEmail,
          "errorCode": "invalid_callback_url",
          "errorMessage": "لم يتم استلام استجابة صالحة من تفويض YouTube."
        ])
        return
      }

      if let oauthError = queryItems.first(where: { $0.name == "error" })?.value {
        NSLog("\(Self.logTag) [Stage 5] YouTube OAuth callback returned error=\(oauthError)")
        result([
          "status": oauthError == "access_denied" ? "denied" : "error",
          "selectedAccountEmail": accountEmail,
          "errorCode": oauthError,
          "errorMessage": "تم رفض منح صلاحيات الوصول إلى قناة YouTube."
        ])
        return
      }

      guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
        result([
          "status": "error",
          "selectedAccountEmail": accountEmail,
          "errorCode": "missing_auth_code",
          "errorMessage": "لم يتم استلام رمز التفويض لصلاحيات YouTube."
        ])
        return
      }

      self?.exchangeCodeForYouTubeTokens(
        code: code,
        accountEmail: accountEmail,
        clientId: oauthConfig.clientId,
        redirectUri: redirectUri,
        codeVerifier: verifier,
        requestedScopes: scopes,
        result: result
      )
    }

    session.presentationContextProvider = self
    session.prefersEphemeralWebBrowserSession = false
    currentAuthSession = session
    session.start()
  }

  private func exchangeCodeForAccountProfile(
    code: String,
    clientId: String,
    redirectUri: String,
    codeVerifier: String,
    result: @escaping FlutterResult
  ) {
    let tokenUrl = URL(string: "https://oauth2.googleapis.com/token")!
    var request = URLRequest(url: tokenUrl)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

    let bodyItems = [
      URLQueryItem(name: "client_id", value: clientId),
      URLQueryItem(name: "code", value: code),
      URLQueryItem(name: "code_verifier", value: codeVerifier),
      URLQueryItem(name: "grant_type", value: "authorization_code"),
      URLQueryItem(name: "redirect_uri", value: redirectUri),
    ]
    var bodyComponents = URLComponents()
    bodyComponents.queryItems = bodyItems
    request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

    URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
      DispatchQueue.main.async {
        if let error = error {
          NSLog("\(Self.logTag) [Stage 2] Account token exchange network error: \(error.localizedDescription)")
          result([
            "status": "error",
            "errorCode": "token_exchange_network_error",
            "errorMessage": error.localizedDescription
          ])
          return
        }

        guard let data = data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let idToken = json["id_token"] as? String else {
          NSLog("\(Self.logTag) [Stage 2] Account token exchange failed to return id_token")
          result([
            "status": "error",
            "errorCode": "token_exchange_failed",
            "errorMessage": "تعذر التحقق من بيانات حساب Google المختار على iOS."
          ])
          return
        }

        let claims = Self.decodeJWTClaims(idToken)
        let email = (claims["email"] as? String) ?? ""
        let name = claims["name"] as? String
        let picture = claims["picture"] as? String

        guard !email.isEmpty else {
          result([
            "status": "error",
            "errorCode": "missing_email_claim",
            "errorMessage": "لم يتم العثور على البريد الإلكتروني لحساب Google المختار."
          ])
          return
        }

        self?.lastSelectedEmail = email
        NSLog("\(Self.logTag) [Stage 2] Account selected successfully (hasIdToken=true)")
        result([
          "status": "selected",
          "email": email,
          "displayName": name as Any,
          "profilePictureUri": picture as Any,
          "idToken": idToken,
          "selectionSource": "ios_aswebauth_account_chooser"
        ])
      }
    }.resume()
  }

  private func exchangeCodeForYouTubeTokens(
    code: String,
    accountEmail: String,
    clientId: String,
    redirectUri: String,
    codeVerifier: String,
    requestedScopes: [String],
    result: @escaping FlutterResult
  ) {
    let tokenUrl = URL(string: "https://oauth2.googleapis.com/token")!
    var request = URLRequest(url: tokenUrl)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

    let bodyItems = [
      URLQueryItem(name: "client_id", value: clientId),
      URLQueryItem(name: "code", value: code),
      URLQueryItem(name: "code_verifier", value: codeVerifier),
      URLQueryItem(name: "grant_type", value: "authorization_code"),
      URLQueryItem(name: "redirect_uri", value: redirectUri),
    ]
    var bodyComponents = URLComponents()
    bodyComponents.queryItems = bodyItems
    request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

    URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
      DispatchQueue.main.async {
        if let error = error {
          NSLog("\(Self.logTag) [Stage 5] YouTube token exchange network error: \(error.localizedDescription)")
          result([
            "status": "error",
            "selectedAccountEmail": accountEmail,
            "errorCode": "youtube_token_network_error",
            "errorMessage": error.localizedDescription
          ])
          return
        }

        guard let data = data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
          let apiError = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["error"] as? String ?? "unknown"
          NSLog("\(Self.logTag) [Stage 5] YouTube token exchange failed: error=\(apiError)")
          result([
            "status": "error",
            "selectedAccountEmail": accountEmail,
            "errorCode": "youtube_token_exchange_failed",
            "errorMessage": "تعذر إصدار رمز الوصول لصلاحيات YouTube على iOS."
          ])
          return
        }

        let refreshToken = (json["refresh_token"] as? String) ?? ""
        let scopeStr = (json["scope"] as? String) ?? ""
        let grantedScopes = scopeStr
          .components(separatedBy: " ")
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
        let expiresIn = (json["expires_in"] as? Int) ?? 3500
        let expiresAtEpochMs = Int(Date().timeIntervalSince1970 * 1000) + (expiresIn * 1000)

        var verifiedEmail = accountEmail
        if let idToken = json["id_token"] as? String {
          let claims = Self.decodeJWTClaims(idToken)
          if let tokenEmail = claims["email"] as? String, !tokenEmail.isEmpty {
            verifiedEmail = tokenEmail
          }
        }

        if !refreshToken.isEmpty {
          self?.cachedRefreshTokensByEmail[verifiedEmail.lowercased()] = refreshToken
        }

        let isOfflineAccessGranted = !refreshToken.isEmpty
        NSLog("\(Self.logTag) [Stage 6] Returning authorized result to Flutter | hasAccessToken=true, hasRefreshToken=\(isOfflineAccessGranted), grantedScopesCount=\(grantedScopes.count)")

        result([
          "status": "authorized",
          "selectedAccountEmail": verifiedEmail,
          "accessToken": accessToken,
          "serverAuthCode": code,
          "isOfflineAccessGranted": isOfflineAccessGranted,
          "grantedScopes": grantedScopes.isEmpty ? requestedScopes : grantedScopes,
          "expiresAtEpochMs": expiresAtEpochMs
        ])
      }
    }.resume()
  }

  private func refreshYouTubeAccessToken(
    refreshToken: String,
    accountEmail: String,
    clientId: String,
    requestedScopes: [String],
    result: @escaping FlutterResult
  ) {
    let tokenUrl = URL(string: "https://oauth2.googleapis.com/token")!
    var request = URLRequest(url: tokenUrl)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

    let bodyItems = [
      URLQueryItem(name: "client_id", value: clientId),
      URLQueryItem(name: "refresh_token", value: refreshToken),
      URLQueryItem(name: "grant_type", value: "refresh_token"),
    ]
    var bodyComponents = URLComponents()
    bodyComponents.queryItems = bodyItems
    request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

    URLSession.shared.dataTask(with: request) { data, _, error in
      DispatchQueue.main.async {
        if let error = error {
          result([
            "status": "error",
            "selectedAccountEmail": accountEmail,
            "errorCode": "refresh_token_network_error",
            "errorMessage": error.localizedDescription
          ])
          return
        }

        guard let data = data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
          result([
            "status": "error",
            "selectedAccountEmail": accountEmail,
            "errorCode": "refresh_token_failed",
            "errorMessage": "انتهت صلاحية جلسة YouTube وتعذر تجديد رمز الوصول تلقائياً."
          ])
          return
        }

        let scopeStr = (json["scope"] as? String) ?? ""
        let grantedScopes = scopeStr
          .components(separatedBy: " ")
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
        let expiresIn = (json["expires_in"] as? Int) ?? 3500
        let expiresAtEpochMs = Int(Date().timeIntervalSince1970 * 1000) + (expiresIn * 1000)

        result([
          "status": "authorized",
          "selectedAccountEmail": accountEmail,
          "accessToken": accessToken,
          "isOfflineAccessGranted": true,
          "grantedScopes": grantedScopes.isEmpty ? requestedScopes : grantedScopes,
          "expiresAtEpochMs": expiresAtEpochMs
        ])
      }
    }.resume()
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      if let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) {
        return keyWindow
      }
    }
    return UIWindow()
  }

  private static func generateCodeVerifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func generateCodeChallenge(from verifier: String) -> String {
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return Data(digest).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func decodeJWTClaims(_ jwt: String) -> [String: Any] {
    let parts = jwt.components(separatedBy: ".")
    guard parts.count >= 2 else { return [:] }
    var payload = parts[1]
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let rem = payload.count % 4
    if rem > 0 {
      payload += String(repeating: "=", count: 4 - rem)
    }
    guard let data = Data(base64Encoded: payload),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return [:]
    }
    return obj
  }
}
