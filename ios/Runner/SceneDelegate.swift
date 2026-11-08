import Flutter
import UIKit
import TikTokOpenSDKCore

class SceneDelegate: FlutterSceneDelegate {

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
       let flutterVC = window?.rootViewController as? FlutterViewController {
      appDelegate.registerTikTokChannelIfNeeded(with: flutterVC)
    }

    // Handle any cold-start Universal Links or URL contexts
    for userActivity in connectionOptions.userActivities {
      if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
         let webpageURL = userActivity.webpageURL,
         TikTokURLHandler.handleOpenURL(webpageURL) {
        return
      }
    }
    for context in connectionOptions.urlContexts {
      if TikTokURLHandler.handleOpenURL(context.url) {
        return
      }
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      if TikTokURLHandler.handleOpenURL(context.url) {
        return
      }
    }
    super.scene(scene, openURLContexts: URLContexts)
  }

  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
       let webpageURL = userActivity.webpageURL,
       TikTokURLHandler.handleOpenURL(webpageURL) {
      return
    }
    super.scene(scene, continue: userActivity)
  }
}
