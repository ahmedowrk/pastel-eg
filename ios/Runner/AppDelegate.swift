import Flutter
import UIKit
import TikTokOpenSDKCore
import TikTokOpenAuthSDK

@main
@objc class AppDelegate: FlutterAppDelegate {

  private static let channelName = "com.pasteleg.app/tiktok_sdk"
  private static let defaultRedirectUri = "https://pastel-eg.com/social-connections/tiktok/callback"

  // Strong reference to active TikTokAuthRequest as required by TikTokOpenAuthSDK
  private var currentTikTokAuthRequest: TikTokAuthRequest?
  private var pendingFlutterResult: FlutterResult?
  private var pendingState: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: AppDelegate.channelName,
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] (call, result) in
        guard let self = self else { return }
        switch call.method {
        case "isTikTokInstalled":
          result(self.checkTikTokInstalled())
        case "authorize":
          self.handleAuthorize(call: call, result: result)
        case "cancel":
          self.clearPendingSession()
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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

  private func handleAuthorize(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if pendingFlutterResult != nil {
      result(FlutterError(
        code: "DUPLICATE_REQUEST",
        message: "A TikTok authorization request is already in progress.",
        details: nil
      ))
      return
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

    // Official TikTokOpenAuthSDK request initialization
    // Note: TikTokAuthRequest automatically initializes authRequest.pkce (TTKSDKCodeVerifier)
    // with a 43-char cryptographic codeVerifier and hex-encoded SHA-256 codeChallenge.
    let authRequest = TikTokAuthRequest(scopes: scopes, redirectURI: redirectUri)
    authRequest.state = state
    authRequest.isWebAuth = !preferNative

    self.currentTikTokAuthRequest = authRequest
    self.pendingFlutterResult = result
    self.pendingState = state

    let codeVerifier = authRequest.pkce.codeVerifier

    authRequest.send { [weak self] baseResponse in
      guard let self = self else { return }
      guard let activeResult = self.pendingFlutterResult else { return }
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
        if let expected = expectedState, !expected.isEmpty, authResponse.state != expected {
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
  }

  private func clearPendingSession() {
    self.currentTikTokAuthRequest = nil
    self.pendingFlutterResult = nil
    self.pendingState = nil
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
