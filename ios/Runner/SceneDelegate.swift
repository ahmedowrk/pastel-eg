import Flutter
import UIKit
import TikTokOpenSDKCore

class SceneDelegate: FlutterSceneDelegate {

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
