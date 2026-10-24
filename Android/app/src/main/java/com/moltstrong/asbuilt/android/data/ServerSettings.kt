package com.moltstrong.asbuilt.android.data

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.moltstrong.asbuilt.android.BuildConfig
import com.moltstrong.asbuilt.core.recon.ReconConfig

/**
 * Server config: BuildConfig holds whatever the build was given (the public CI build has only the discovery
 * URL, never the API key); Settings pastes the key / URLs, stored with EncryptedSharedPreferences.
 * Values are never logged.
 */
class ServerSettings(context: Context) {
    private val prefs: SharedPreferences? = try {
        val key = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        EncryptedSharedPreferences.create(
            context, "recon-settings", key,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    } catch (e: Exception) {
        // Keystore broken (rare OEM bugs): run with the built-in config only, never crash.
        Log.w("AsBuilt", "encrypted settings unavailable: ${e.javaClass.simpleName}")
        null
    }

    val encryptedStorageAvailable: Boolean get() = prefs != null

    var overrideBaseUrl: String
        get() = prefs?.getString("baseUrl", "") ?: ""
        set(v) {
            prefs?.edit()?.putString("baseUrl", v.trim())?.apply()
        }

    var overrideApiKey: String
        get() = prefs?.getString("apiKey", "") ?: ""
        set(v) {
            prefs?.edit()?.putString("apiKey", v.trim())?.apply()
        }

    var overrideDiscoveryUrl: String
        get() = prefs?.getString("discoveryUrl", "") ?: ""
        set(v) {
            prefs?.edit()?.putString("discoveryUrl", v.trim())?.apply()
        }

    /** Texture size embedded in model.glb: 4096 default (3 x 8K is ~1 GB of GPU memory on a phone). */
    var glbTextureSize: Int
        get() = prefs?.getInt("glbTextureSize", DEFAULT_TEXTURE) ?: DEFAULT_TEXTURE
        set(v) {
            prefs?.edit()?.putInt("glbTextureSize", v)?.apply()
        }

    val builtInConfigured: Boolean
        get() = BuildConfig.RECON_API_KEY.isNotBlank() && (BuildConfig.RECON_BASE_URL.isNotBlank() || BuildConfig.RECON_DISCOVERY_URL.isNotBlank())

    val hasOverride: Boolean get() = overrideApiKey.isNotBlank() || overrideBaseUrl.isNotBlank() || overrideDiscoveryUrl.isNotBlank()

    fun clearOverride() {
        prefs?.edit()?.remove("baseUrl")?.remove("apiKey")?.remove("discoveryUrl")?.apply()
    }

    /** Effective config: override fields win individually; otherwise the built-in CI values. */
    fun config(): ReconConfig {
        val key = overrideApiKey.ifBlank { BuildConfig.RECON_API_KEY }
        // A key-only override (public CI build) keeps the built-in base / discovery URLs.
        val base = overrideBaseUrl.ifBlank { if (overrideDiscoveryUrl.isNotBlank()) "" else BuildConfig.RECON_BASE_URL }
        val disc = overrideDiscoveryUrl.ifBlank { if (overrideBaseUrl.isNotBlank()) "" else BuildConfig.RECON_DISCOVERY_URL }
        return ReconConfig(base.ifBlank { null }, disc.ifBlank { null }, key)
    }

    val isConfigured: Boolean get() = config().isUsable

    companion object {
        const val DEFAULT_TEXTURE = 4096
        val TEXTURE_CHOICES = listOf(2048, 4096, 8192)
    }
}
