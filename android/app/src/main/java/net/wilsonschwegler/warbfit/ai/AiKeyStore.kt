package net.wilsonschwegler.warbfit.ai

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Secure, at-rest-encrypted storage for the user's AI Coach API key.
 *
 * Backed by Jetpack Security [EncryptedSharedPreferences] — values are encrypted with a
 * key held in the Android Keystore (hardware-backed where available). The plaintext API
 * key is never written to disk in the clear. This is the Android counterpart to storing
 * the key in the macOS Keychain.
 *
 * The selected provider/model are NOT secret and are stored as plain preferences here too
 * for convenience, but the key itself is the only sensitive value.
 */
object AiKeyStore {

    private const val FILE_NAME = "warbfit_ai_secure_prefs"
    private const val KEY_API = "api_key"
    private const val KEY_PROVIDER = "provider"
    private const val KEY_CONSENT = "data_consent"

    /** Per-provider model preference key, so each provider remembers its own last model. */
    private fun modelKey(provider: AiProvider) = "model_${provider.name}"

    /**
     * Open (or lazily create) the encrypted preferences file. The [MasterKey] uses the
     * AES256_GCM key scheme and lives in the Android Keystore.
     */
    private fun prefs(ctx: Context): SharedPreferences {
        val masterKey = MasterKey.Builder(ctx.applicationContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()

        return EncryptedSharedPreferences.create(
            ctx.applicationContext,
            FILE_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    /** Persist the API [key] (encrypted at rest). Blank keys are treated as a clear. */
    fun save(ctx: Context, key: String) {
        val trimmed = key.trim()
        if (trimmed.isEmpty()) {
            clear(ctx)
            return
        }
        prefs(ctx).edit().putString(KEY_API, trimmed).apply()
    }

    /** Read the stored API key, or null if none has been set. */
    fun read(ctx: Context): String? =
        prefs(ctx).getString(KEY_API, null)?.takeIf { it.isNotBlank() }

    /** Remove the stored API key. The provider/model preferences are left intact. */
    fun clear(ctx: Context) {
        prefs(ctx).edit().remove(KEY_API).apply()
    }

    /** True when a non-blank key is stored — the gate the UI uses to enable sending. */
    fun hasKey(ctx: Context): Boolean = read(ctx) != null

    // --- Non-secret selection helpers (provider + model). Convenience only. ---

    /** Persist the chosen provider (by enum name). */
    fun saveProvider(ctx: Context, provider: AiProvider) {
        prefs(ctx).edit().putString(KEY_PROVIDER, provider.name).apply()
    }

    /** Read the chosen provider, defaulting to OpenAI. */
    fun readProvider(ctx: Context): AiProvider =
        AiProvider.fromName(prefs(ctx).getString(KEY_PROVIDER, null))

    /**
     * Persist the chosen model id for [provider]. Any non-blank id is accepted (curated,
     * live-fetched, or a custom id the user typed) — the model list is no longer a fixed,
     * shipped set. A blank id is ignored.
     */
    fun saveModel(ctx: Context, provider: AiProvider, model: String) {
        val trimmed = model.trim()
        if (trimmed.isEmpty()) return
        prefs(ctx).edit().putString(modelKey(provider), trimmed).apply()
    }

    /**
     * Read the chosen model id for [provider], defaulting to that provider's default model
     * when nothing valid is stored. A previously-saved custom or live model id is preserved
     * even if it isn't in the curated [AiProvider.models] list.
     */
    fun readModel(ctx: Context, provider: AiProvider): String =
        prefs(ctx).getString(modelKey(provider), null)?.takeIf { it.isNotBlank() }
            ?: provider.defaultModel

    /** Persist the data-access consent flag. */
    fun saveConsent(ctx: Context, consent: Boolean) {
        prefs(ctx).edit().putBoolean(KEY_CONSENT, consent).apply()
    }

    /** Read the data-access consent flag (default false — privacy-safe; no metrics sent until on). */
    fun readConsent(ctx: Context): Boolean = prefs(ctx).getBoolean(KEY_CONSENT, false)
}
