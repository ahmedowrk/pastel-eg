package com.pasteleg.app

import android.content.Intent
import android.util.Log
import com.pasteleg.app.youtube.YouTubeAuthPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "YouTubeOAuthDebug"
    }

    private var youtubeAuthPlugin: YouTubeAuthPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        youtubeAuthPlugin?.dispose()
        youtubeAuthPlugin = YouTubeAuthPlugin(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // Always invoke super.onActivityResult so FlutterActivity's internal lifecycle
        // and registered plugins (e.g. flutter_facebook_auth, image_picker) receive
        // their activity results normally.
        super.onActivityResult(requestCode, resultCode, data)

        Log.d(
            TAG,
            "[MainActivity] onActivityResult received | " +
                "requestCode=$requestCode, resultCode=$resultCode, hasData=${data != null}"
        )
        val handledByYouTube =
            youtubeAuthPlugin?.onActivityResult(requestCode, resultCode, data) ?: false
        Log.d(
            TAG,
            "[MainActivity] onActivityResult routing | " +
                "requestCode=$requestCode, handledByYouTube=$handledByYouTube"
        )
    }

    override fun onDestroy() {
        youtubeAuthPlugin?.dispose()
        youtubeAuthPlugin = null
        super.onDestroy()
    }
}
