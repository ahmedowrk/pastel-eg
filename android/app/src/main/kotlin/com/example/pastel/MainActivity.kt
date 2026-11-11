package com.pasteleg.app

import android.content.Intent
import com.pasteleg.app.youtube.YouTubeAuthPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
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
        val handledByYouTube =
            youtubeAuthPlugin?.onActivityResult(requestCode, resultCode, data) ?: false
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
