package net.wilsonschwegler.warbfit.ui

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import net.wilsonschwegler.warbfit.ai.AiCoach
import net.wilsonschwegler.warbfit.ai.AiKeyStore
import net.wilsonschwegler.warbfit.ai.AiProvider
import net.wilsonschwegler.warbfit.ai.ChatMsg
import net.wilsonschwegler.warbfit.data.TrackerDatabase
import net.wilsonschwegler.warbfit.data.TrackerRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * View model for the AI Coach screen.
 *
 * Holds the [AiCoach] engine (built over the same Room-backed [TrackerRepository] the rest of
 * the app uses) and the chat state. The API key and the chosen provider/model are persisted
 * by [AiKeyStore] — the key encrypted at rest in the Android Keystore, the provider/model as
 * plain (non-secret) preferences.
 *
 * Privacy posture mirrors the engine: nothing is sent until the user has saved a key and asked
 * a question, and only a compact text summary of their own metrics plus their question leaves
 * the device. Errors never crash — they surface in [error].
 */
class CoachViewModel(app: Application) : AndroidViewModel(app) {

    // The networked coach, over the local store. No key is held here; the engine reads it from
    // the encrypted store at call time.
    private val aiCoach = AiCoach(
        TrackerRepository(TrackerDatabase.get(app.applicationContext).trackerDao())
    )

    // MARK: - Transcript

    private val _messages = MutableStateFlow<List<ChatMsg>>(emptyList())
    /** The conversation so far (user/assistant turns), oldest first. */
    val messages: StateFlow<List<ChatMsg>> = _messages.asStateFlow()

    private val _sending = MutableStateFlow(false)
    /** True while a request is in flight — the UI disables Send and shows a thinking state. */
    val sending: StateFlow<Boolean> = _sending.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    /** Non-null when the last send failed; the UI shows it in red. Cleared on the next send. */
    val error: StateFlow<String?> = _error.asStateFlow()

    // MARK: - Provider / model selection (persisted via AiKeyStore)

    private val _provider = MutableStateFlow(AiKeyStore.readProvider(app.applicationContext))
    /** The currently selected provider. Persisted across launches. */
    val provider: StateFlow<AiProvider> = _provider.asStateFlow()

    private val _model = MutableStateFlow(
        AiKeyStore.readModel(app.applicationContext, _provider.value)
    )
    /** The currently selected model id. Persisted per provider. May be a custom/live id. */
    val model: StateFlow<String> = _model.asStateFlow()

    private val _availableModels = MutableStateFlow(seedModels(_provider.value, _model.value))
    /**
     * The models offered in the picker for the current provider: the provider's curated list,
     * plus any live-fetched ids merged in, plus the currently-selected id if it's a custom one.
     * Re-seeded whenever the provider changes; extended by [refreshModels].
     */
    val availableModels: StateFlow<List<String>> = _availableModels.asStateFlow()

    private val _refreshingModels = MutableStateFlow(false)
    /** True while a live model-list fetch is in flight; the UI disables the Refresh action. */
    val refreshingModels: StateFlow<Boolean> = _refreshingModels.asStateFlow()

    private val _consent = MutableStateFlow(AiKeyStore.readConsent(app.applicationContext))
    /** Explicit permission for the coach to read & send the user's data. Off by default. */
    val consent: StateFlow<Boolean> = _consent.asStateFlow()

    /** Grant or revoke data access; persisted. */
    fun setConsent(ctx: Context, value: Boolean) {
        _consent.value = value
        AiKeyStore.saveConsent(ctx, value)
    }

    // Bumped whenever the stored key changes so the UI recomposes its setup/chat gate.
    private val _keyVersion = MutableStateFlow(0)
    /** Increments when the key is saved or cleared; observe to re-read [hasKey]. */
    val keyVersion: StateFlow<Int> = _keyVersion.asStateFlow()

    // MARK: - Key gate

    /** True when a non-blank API key is stored. The UI shows the chat only when this is true. */
    fun hasKey(ctx: Context): Boolean = AiKeyStore.hasKey(ctx)

    // MARK: - Selection mutators

    /**
     * Choose a provider; resets the model to that provider's stored/default model, re-seeds
     * the available-models list for the new provider, and persists.
     */
    fun selectProvider(ctx: Context, p: AiProvider) {
        if (p == _provider.value) return
        _provider.value = p
        AiKeyStore.saveProvider(ctx, p)
        val resolved = AiKeyStore.readModel(ctx, p)
        _model.value = resolved
        AiKeyStore.saveModel(ctx, p, resolved)
        // Reset the picker to the new provider's catalogue (plus the resolved id if custom).
        _availableModels.value = seedModels(p, resolved)
    }

    /**
     * Choose a model id and persist it for the current provider. Any non-blank id is accepted
     * (curated, live-fetched, or a custom id typed by the user); a brand-new custom id is also
     * merged into [availableModels] so it shows in the picker.
     */
    fun selectModel(ctx: Context, m: String) {
        val id = m.trim()
        if (id.isEmpty()) return
        _model.value = id
        AiKeyStore.saveModel(ctx, _provider.value, id)
        if (!_availableModels.value.contains(id)) {
            _availableModels.value = _availableModels.value + id
        }
    }

    /**
     * Best-effort: fetch the current provider's live model list using the saved key and merge
     * the returned ids into [availableModels] (curated ids first, then any new live ids). Never
     * throws and never changes the current selection; a failure simply leaves the list as-is.
     */
    fun refreshModels(ctx: Context) {
        if (_refreshingModels.value) return
        val appCtx = ctx.applicationContext
        val p = _provider.value
        _refreshingModels.value = true
        viewModelScope.launch {
            try {
                val live = aiCoach.fetchModels(appCtx, p)
                if (p == _provider.value) {
                    val merged = (_availableModels.value + live).distinct()
                    _availableModels.value = merged
                }
            } catch (_: Exception) {
                // Best-effort — keep whatever list we already have.
            } finally {
                _refreshingModels.value = false
            }
        }
    }

    // MARK: - Key management

    /** Save the user's API key (encrypted at rest). Blank input clears the key instead. */
    fun saveKey(ctx: Context, key: String) {
        AiKeyStore.save(ctx, key)
        _error.value = null
        _keyVersion.value += 1
        // Pull the user's ACTUAL current models from the provider so the picker is never stale.
        refreshModels(ctx)
    }

    /** Clear the stored key and reset the transcript back to the setup screen. */
    fun clearKey(ctx: Context) {
        AiKeyStore.clear(ctx)
        _messages.value = emptyList()
        _error.value = null
        _keyVersion.value += 1
    }

    // MARK: - Send

    /**
     * Send [text] as the next user turn: append it, call the coach, then append the reply.
     * No-ops on blank input or while a send is already in flight. All failures land in [error].
     */
    fun send(ctx: Context, text: String) {
        val question = text.trim()
        if (question.isEmpty() || _sending.value) return

        val appCtx = ctx.applicationContext
        _error.value = null
        _messages.value = _messages.value + ChatMsg(role = "user", text = question)
        _sending.value = true

        viewModelScope.launch {
            try {
                val reply = aiCoach.chat(
                    ctx = appCtx,
                    history = _messages.value,
                    provider = _provider.value,
                    model = _model.value,
                    consent = _consent.value,
                )
                _messages.value = _messages.value + ChatMsg(role = "assistant", text = reply)
            } catch (e: Exception) {
                _error.value = e.message ?: "Something went wrong. Please try again."
            } finally {
                _sending.value = false
            }
        }
    }

    /** Dismiss the current error (e.g. when the user edits the input again). */
    fun clearError() {
        _error.value = null
    }

    companion object {
        /**
         * Initial model list for [provider]: its curated ids, plus [selected] appended if it's a
         * custom id not already in that list (so a previously-saved custom model still shows).
         */
        private fun seedModels(provider: AiProvider, selected: String): List<String> =
            if (provider.models.contains(selected)) provider.models
            else provider.models + selected
    }
}
