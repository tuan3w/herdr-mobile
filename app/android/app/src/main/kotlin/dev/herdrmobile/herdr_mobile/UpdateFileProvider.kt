package dev.herdrmobile.herdr_mobile

import androidx.core.content.FileProvider

/**
 * Shares the downloaded update APK with Android's installer (see
 * `res/xml/update_paths.xml`). A subclass of its own, not `FileProvider`
 * itself: the plugins that share files declare that class too, and the
 * manifest merger refuses two providers with the same name.
 */
class UpdateFileProvider : FileProvider()
