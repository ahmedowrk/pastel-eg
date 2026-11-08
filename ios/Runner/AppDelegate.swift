import Flutter
import UIKit
import WebKit
import TikTokOpenSDKCore
import TikTokOpenAuthSDK

@main
@objc class AppDelegate: FlutterAppDelegate {
  private static let channelName = "com.pasteleg.app/tiktok_sdk"
  private static let defaultRedirectUri = "https://pastel-eg.com/social-connections/tiktok/callback"
  private static let activeAuthTimeout: TimeInterval = 120

  // Strong reference to active TikTokAuthRequest as required by TikTokOpenAuthSDK.
  // Never cleared on applicationWillResignActive/applicationDidBecomeActive because
  // TikTokAuthRequest.deinit removes the request ID from TikTokAPI.
  private var currentTikTokAuthRequest: TikTokAuthRequest?
  private var pendingFlutterResult: FlutterResult?
  private var pendingState: String?
  private var pendingStartedAt: Date?
  private var registeredChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    registerTikTokChannelIfNeeded(with: window?.rootViewController as? FlutterViewController)
    return launched
  }

  func registerTikTokChannelIfNeeded(with controller: FlutterViewController?) {
    guard registeredChannel == nil, let flutterController = controller else { return }
    let channel = FlutterMethodChannel(
      name: AppDelegate.channelName,
      binaryMessenger: flutterController.binaryMessenger
    )

    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }
      switch call.method {
      case "isTikTokInstalled":
        result(self.checkTikTokInstalled())
      case "getCookiesForUrl":
        let args = call.arguments as? [String: Any]
        let urlStr = (args?["url"] as? String) ?? "https://pastel-eg.com"
        self.getCookiesForUrl(urlStr: urlStr, result: result)
      case "authorize":
        self.handleAuthorize(call: call, result: result)
      case "cancel":
        self.cancelActivePendingSession()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    registeredChannel = channel
  }

  private func getCookiesForUrl(urlStr: String, result: @escaping FlutterResult) {
    guard let parsedUrl = URL(string: urlStr),
          let host = parsedUrl.host?.lowercased() else {
      result("")
      return
    }
    let isSecureUrl = parsedUrl.scheme?.lowercased() == "https"
    let now = Date()

    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
      let matching = cookies.filter { cookie in
        if let expires = cookie.expiresDate, expires < now {
          return false
        }
        if cookie.isSecure && !isSecureUrl {
          return false
        }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == domain || host.hasSuffix("." + domain)
      }
      let header = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      result(header)
    }
  }

  private func checkTikTokInstalled() -> Bool {
    let schemes = ["snssdk1233", "snssdk1180", "tiktokopensdk"]
    for scheme in schemes {
      if let url = URL(string: "\(scheme)://"), UIApplication.shared.canOpenURL(url) {
        return true
      }
    }
    return false
  }

  private func isPendingSessionExpired() -> Bool {
    guard let startedAt = pendingStartedAt else { return true }
    return Date().timeIntervalSince(startedAt) > AppDelegate.activeAuthTimeout
  }

  private func handleAuthorize(call: FlutterMethodCall, result: @escaping FlutterResult) {
    // Active-request protection:
    // Never cancel or overwrite an active, non-expired authorization session.
    // Only recover if a prior session genuinely exceeded activeAuthTimeout (2 minutes).
    if pendingFlutterResult != nil || currentTikTokAuthRequest != nil {
      if !isPendingSessionExpired() {
        result(
          FlutterError(
            code: "DUPLICATE_REQUEST",
            message: "A TikTok authorization request is already in progress.",
            details: nil
          )
        )
        return
      }
      cancelActivePendingSession()
    }

    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "INVALID_ARGS", message: "Missing arguments", details: nil))
      return
    }

    let scopeStr = (args["scope"] as? String) ?? "user.info.basic"
    let scopes = Set(
      scopeStr
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    )
    let redirectUri = (args["redirectUri"] as? String) ?? AppDelegate.defaultRedirectUri
    let state = (args["state"] as? String)
    let preferNative = (args["preferNative"] as? Bool) ?? true
    let isNativeInstalled = checkTikTokInstalled()

    // Official TikTokOpenAuthSDK request initialization.
    // TikTokAuthRequest automatically initializes authRequest.pkce (TTKSDKCodeVerifier)
    // with a 43-char cryptographic codeVerifier and hex-encoded SHA-256 codeChallenge.
    let authRequest = TikTokAuthRequest(scopes: scopes, redirectURI: redirectUri)
    authRequest.state = state
    authRequest.isWebAuth = !preferNative || !isNativeInstalled

    let requestId = authRequest.requestID
    let codeVerifier = authRequest.pkce.codeVerifier

    self.currentTikTokAuthRequest = authRequest
    self.pendingFlutterResult = result
    self.pendingState = state
    self.pendingStartedAt = Date()

    let sent = authRequest.send { [weak self] baseResponse in
      guard let self = self else { return }
      // Ensure this callback belongs to the currently active request and has not already completed
      guard self.currentTikTokAuthRequest?.requestID == requestId,
            let activeResult = self.pendingFlutterResult else {
        return
      }
      let expectedState = self.pendingState
      self.clearPendingSession()

      guard let authResponse = baseResponse as? TikTokAuthResponse else {
        activeResult([
          "status": "failed",
          "errorMessage": "Invalid response from TikTokOpenAuthSDK",
          "usedNativeApp": isNativeInstalled && preferNative
        ])
        return
      }

      if authResponse.errorCode == .noError, let authCode = authResponse.authCode, !authCode.isEmpty {
        // Strict anti-CSRF state check
        if expectedState == nil || expectedState!.isEmpty || authResponse.state != expectedState {
          activeResult([
            "status": "failed",
            "errorCode": -1,
            "authError": "state_mismatch",
            "errorMessage": "فشل التحقق الأمني: عدم تطابق رمز الحماية (State Mismatch).",
            "usedNativeApp": isNativeInstalled && preferNative
          ])
          return
        }

        let granted = authResponse.grantedPermissions?.joined(separator: ",") ?? ""
        activeResult([
          "status": "success",
          "code": authCode,
          "codeVerifier": codeVerifier,
          "state": authResponse.state ?? expectedState ?? "",
          "redirectUri": redirectUri,
          "grantedPermissions": granted,
          "usedNativeApp": isNativeInstalled && preferNative
        ])
      } else {
        let status: String
        switch authResponse.errorCode {
        case .cancelled:
          status = "cancelled"
        case .denied:
          status = "denied"
        default:
          status = "failed"
        }

        activeResult([
          "status": status,
          "errorCode": authResponse.errorCode.rawValue,
          "authError": authResponse.error ?? "",
          "errorMessage": authResponse.errorDescription ?? "تم إلغاء أو رفض عملية المصادقة من تيك توك.",
          "usedNativeApp": isNativeInstalled && preferNative
        ])
      }
    }

    if !sent {
      guard self.currentTikTokAuthRequest?.requestID == requestId,
            let activeResult = self.pendingFlutterResult else {
        return
      }
      self.clearPendingSession()
      activeResult([
        "status": "unsupported",
        "errorMessage": "تعذر تشغيل مصادقة تيك توك (TikTokOpenAuthSDK).",
        "usedNativeApp": isNativeInstalled && preferNative
      ])
    }
  }

  private func cancelActivePendingSession() {
    guard let activeResult = self.pendingFlutterResult else {
      clearPendingSession()
      return
    }
    let isNativeInstalled = checkTikTokInstalled()
    clearPendingSession()
    activeResult([
      "status": "cancelled",
      "errorCode": TikTokAuthResponseErrorCode.cancelled.rawValue,
      "authError": "user_cancelled",
      "errorMessage": "تم إلغاء عملية تسجيل الدخول عبر تيك توك.",
      "usedNativeApp": isNativeInstalled
    ])
  }

  private func clearPendingSession() {
    self.currentTikTokAuthRequest = nil
    self.pendingFlutterResult = nil
    self.pendingState = nil
    self.pendingStartedAt = nil
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey : Any] = [:]
  ) -> Bool {
    if TikTokURLHandler.handleOpenURL(url) {
      return true
    }
    return super.application(app, open: url, options: options)
  }

  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
       let webpageURL = userActivity.webpageURL,
       TikTokURLHandler.handleOpenURL(webpageURL) {
      return true
    }
    return super.application(application, continue: userActivity, restorationHandler: restorationHandler)
  }
}
