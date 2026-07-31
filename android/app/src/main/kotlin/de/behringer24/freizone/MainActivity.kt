package de.behringer24.freizone

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Bundle
import android.view.WindowManager
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.SecureRandom

class MainActivity : FlutterActivity() {
    // Lets Dart toggle FLAG_SECURE on the recovery-phrase backup screen, so
    // the seed can't be captured by a screenshot or screen recording (a
    // deliberate photo with another camera is still possible -- that's the
    // user's own choice). See lib/util/secure_screen.dart.
    private val secureScreenChannel = "freizone/secure_screen"

    // Hands a share received from another app over to Dart (APP-15). See
    // lib/util/share_intake.dart.
    private val shareIntakeChannel = "freizone/share_intake"

    // Publishes per-chat sharing shortcuts, so individual conversations show up
    // in the share sheet's direct-share row (APP-15 level 2). See
    // lib/util/share_shortcuts.dart.
    private val shareShortcutsChannel = "freizone/share_shortcuts"

    // Must match res/xml/shortcuts.xml's <category>, or the shortcuts get
    // published but are never offered as share targets.
    private val shareTargetCategory = "de.behringer24.freizone.category.SHARE_TARGET"

    /**
     * The share waiting to be collected, or null.
     *
     * Deliberately pull-based: Dart asks for this once its accounts are loaded
     * and it can actually show a target picker, rather than us pushing at a
     * moment when the Flutter side may not be ready -- a cold start straight
     * from the share sheet is exactly that moment. [shareChannel] only
     * *nudges* on a warm start; the payload always travels via
     * takePendingShare.
     */
    private var pendingShare: Map<String, Any?>? = null
    private var shareChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Read before Flutter is up: this is the cold-start case, where the
        // process exists only because the user picked us in the share sheet.
        capturePendingShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Warm start: the app was already running (launchMode singleTask), so
        // Dart is listening and can act at once.
        if (capturePendingShare(intent)) {
            shareChannel?.invokeMethod("shareReceived", null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, secureScreenChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enable" -> {
                        runOnUiThread {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    "disable" -> {
                        runOnUiThread {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        shareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            shareIntakeChannel,
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    // Returns the share and forgets it in the same step, so a
                    // rotation or a resume can never deliver it twice.
                    "takePendingShare" -> {
                        val share = pendingShare
                        pendingShare = null
                        result.success(share)
                    }
                    // Dart passes its own maxEdge/quality so those constants
                    // stay single-sourced there (see outgoing_attachment.dart),
                    // while the actual work stays native and fast.
                    "normalizeImage" -> {
                        val path = call.argument<String>("path")
                        val maxEdge = call.argument<Int>("maxEdge") ?: 1600
                        val quality = call.argument<Int>("quality") ?: 80
                        result.success(
                            if (path == null) null else normalizeImage(path, maxEdge, quality),
                        )
                    }
                    else -> result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareShortcutsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "publish" -> {
                        @Suppress("UNCHECKED_CAST")
                        val list = call.argument<List<Map<String, Any?>>>("shortcuts")
                            ?: emptyList()
                        publishShareShortcuts(list)
                        result.success(null)
                    }
                    "clear" -> {
                        // removeAllDynamicShortcuts alone would leave shortcuts
                        // the launcher has pinned; disabling them too is what
                        // makes "off" actually mean the names are gone.
                        val ids = ShortcutManagerCompat.getDynamicShortcuts(this).map { it.id }
                        ShortcutManagerCompat.removeAllDynamicShortcuts(this)
                        if (ids.isNotEmpty()) {
                            ShortcutManagerCompat.disableShortcuts(
                                this,
                                ids,
                                "Direct share was turned off in Freizone",
                            )
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Replaces the published set of per-chat share shortcuts.
     *
     * Each shortcut carries a [Person] and is marked long-lived, which is what
     * the platform requires before it will rank a shortcut in the direct-share
     * row. Its intent is a plain launch: the id already says which conversation
     * this is, and Dart reads that back from EXTRA_SHORTCUT_ID.
     */
    private fun publishShareShortcuts(list: List<Map<String, Any?>>) {
        // Cheaper than a diff, and correct: this is the whole set, in order.
        ShortcutManagerCompat.removeAllDynamicShortcuts(this)

        val max = ShortcutManagerCompat.getMaxShortcutCountPerActivity(this)
            .let { if (it <= 0) list.size else it }

        for (entry in list.take(max)) {
            val id = entry["id"] as? String ?: continue
            val label = entry["label"] as? String ?: continue
            val iconPng = entry["iconPng"] as? ByteArray

            val person = Person.Builder().setName(label).setKey(id).build()
            val icon = iconPng?.let {
                val bitmap = BitmapFactory.decodeByteArray(it, 0, it.size)
                if (bitmap == null) null else IconCompat.createWithAdaptiveBitmap(bitmap)
            }

            val intent = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
            }

            val builder = ShortcutInfoCompat.Builder(this, id)
                .setShortLabel(label)
                .setLongLabel(label)
                .setIntent(intent)
                .setLongLived(true)
                .setCategories(setOf(shareTargetCategory))
                .setPerson(person)
            if (icon != null) builder.setIcon(icon)

            try {
                ShortcutManagerCompat.pushDynamicShortcut(this, builder.build())
            } catch (e: Exception) {
                // A rejected shortcut (rate limiting, an over-large icon) must
                // not take the rest of the set down with it.
            }
        }
    }

    /**
     * Turns an ACTION_SEND intent into [pendingShare]. Returns whether
     * anything usable was found.
     */
    private fun capturePendingShare(intent: Intent?): Boolean {
        if (intent == null || intent.action != Intent.ACTION_SEND) return false

        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        @Suppress("DEPRECATION")
        val stream = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)

        val imagePath = stream?.let { copyToCache(it) }
        if (text == null && imagePath == null) return false

        pendingShare = mapOf(
            "text" to text,
            "imagePath" to imagePath,
            // Set when the share came in through one of our own sharing
            // shortcuts (APP-15 level 2), which already names the target --
            // Dart then skips the picker. Null for a plain share-sheet pick.
            "shortcutId" to intent.getStringExtra(Intent.EXTRA_SHORTCUT_ID),
        )
        return true
    }

    /**
     * Downscales and JPEG-re-encodes a shared image in place of the raw file,
     * returning the new path (or null if it could not be decoded).
     *
     * This exists because the two ways a picture enters the app must cost the
     * recipient the same: a gallery pick is downscaled and re-encoded by
     * image_picker before Dart ever sees it, so a *shared* picture has to get
     * the same treatment. Without this a shared photo would go out at full
     * camera resolution -- wasting the recipient's quota and bandwidth, and
     * running into the receiving server's max_blob_bytes where a gallery pick
     * never would.
     *
     * Done natively rather than in Dart because dart:ui can only encode PNG,
     * which for a photo is *larger* than the JPEG we started with.
     */
    private fun normalizeImage(path: String, maxEdge: Int, quality: Int): String? {
        return try {
            val source = File(path)

            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

            // inSampleSize only halves, so use it to get close cheaply (it
            // avoids ever holding the full-size bitmap in memory), then scale
            // the remainder exactly.
            val longest = maxOf(bounds.outWidth, bounds.outHeight)
            var sample = 1
            while (longest / (sample * 2) >= maxEdge) sample *= 2

            val decoded = BitmapFactory.decodeFile(
                path,
                BitmapFactory.Options().apply { inSampleSize = sample },
            ) ?: return null

            val decodedLongest = maxOf(decoded.width, decoded.height)
            val scaled = if (decodedLongest > maxEdge) {
                val ratio = maxEdge.toDouble() / decodedLongest
                Bitmap.createScaledBitmap(
                    decoded,
                    (decoded.width * ratio).toInt().coerceAtLeast(1),
                    (decoded.height * ratio).toInt().coerceAtLeast(1),
                    true,
                )
            } else {
                decoded
            }

            // BitmapFactory ignores EXIF orientation, so a portrait photo would
            // otherwise arrive on its side -- and the rotation has to happen
            // before we re-encode, since the new JPEG carries no EXIF of ours.
            val rotated = applyExifRotation(scaled, path)

            val target = File(source.parentFile, source.name + ".jpg")
            target.outputStream().use { out ->
                rotated.compress(Bitmap.CompressFormat.JPEG, quality, out)
            }

            if (rotated !== scaled) rotated.recycle()
            if (scaled !== decoded) scaled.recycle()
            decoded.recycle()
            // The full-size original has served its purpose; keeping it would
            // leave a copy of the user's photo sitting in our cache.
            source.delete()

            target.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    private fun applyExifRotation(bitmap: Bitmap, path: String): Bitmap {
        return try {
            val degrees = when (
                ExifInterface(path).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL,
                )
            ) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
            if (degrees == 0f) return bitmap
            val matrix = Matrix().apply { postRotate(degrees) }
            Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        } catch (e: Exception) {
            bitmap
        }
    }

    /**
     * Copies a shared content:// stream into our own cache and returns its
     * path.
     *
     * The bytes have to be taken now: the sending app grants a one-shot read
     * permission on that URI which does not reliably survive the trip through
     * a target picker. Copying is also the point at which the content stops
     * being the other app's to change underneath us.
     *
     * The claimed mime type is deliberately not consulted here. Dart decodes
     * the file to decide whether it really is an image
     * (OutgoingAttachment.prepare returns null when it is not), so a
     * mislabelled file is refused rather than uploaded.
     */
    private fun copyToCache(uri: Uri): String? {
        return try {
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            val raw = ByteArray(16)
            SecureRandom().nextBytes(raw)
            val target = File(dir, raw.joinToString("") { "%02x".format(it) })
            contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            target.absolutePath
        } catch (e: Exception) {
            // A share we cannot read is dropped rather than taking the launch
            // down with it -- the user simply sees nothing arrive.
            null
        }
    }
}
