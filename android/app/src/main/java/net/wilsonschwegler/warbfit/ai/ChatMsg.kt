package net.wilsonschwegler.warbfit.ai

/**
 * One turn in the coach conversation.
 *
 * @param role "user" or "assistant" — the only two roles the UI history carries. The
 *   system prompt is supplied separately by [AiCoach] and is never stored here.
 * @param text plain-text message body.
 */
data class ChatMsg(
    val role: String, // "user" | "assistant"
    val text: String,
)
