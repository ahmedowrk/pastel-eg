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
        if (!handledByYouTube) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun onDestroy() {
        youtubeAuthPlugin?.dispose()
        youtubeAuthPlugin = null
        super.onDestroy()
    }
}
