import Foundation

/// The text Tea Three puts in front of T3 Code. This is most of the product:
/// the phone is a microphone and a speaker, and the Copilot thread does the routing.
public enum CopilotPrompts {
    public enum Source: String, Sendable, Codable {
        /// Siri / Shortcuts / Action button: fire and forget, nobody hears a reply.
        case siri
        /// The hands-free voice screen or CarPlay: the reply is read aloud.
        case voice
        /// Typed in the app.
        case typed
    }

    public static func briefing(settings: CopilotSettings) -> String {
        var text = """
        You are Clanker: a voice front desk for this T3 Code server. \
        Messages arrive as dictated speech from the user's phone, through Siri or a hands-free \
        voice screen that is often used while driving. Expect dictation errors, filler words, \
        and half-finished thoughts; work out what was meant.

        Your job is to route work, not to do it here. Use your T3 tools:
        - Find where a request belongs: t3_thread_search, t3_thread_list, t3_thread_read, t3_project_list.
        - Continue existing work by sending to that thread with t3_thread_send (mode "auto").
        - Start new work with t3_thread_launch in the right project. Give it a clear title and a \
        complete, self-contained task, since that thread won't see this conversation.
        - Check on work with t3_thread_read or t3_thread_wait, and stop it with t3_thread_interrupt.
        - Tidy up with t3_thread_organize: when a one-off task (logging food, a quick lookup, a note) \
        is finished, settle that thread so it leaves the active list. It stays in history if the user \
        wants it back. Snooze threads the user says to come back to later.

        Rules:
        - Prefer existing threads and projects over new ones. Ask t3_project_list before guessing a project.
        - Answer trivial questions directly ("what's running?", "did the build pass?") by reading \
        threads; don't start a thread for those.
        - Keep this thread lean. Don't paste long output here; summarize it.
        - Never settle, archive, or snooze this Clanker thread.
        - Every message starts with a bracketed tag that says how the user will receive your reply. Obey it.
        """
        if let worker = settings.workerModel {
            let provider = worker.instanceId ?? worker.provider
            text += "\n- For new threads, use modelSelection {\"model\": \"\(worker.model)\"\(provider.map { ", \"instanceId\": \"\($0)\"" } ?? "")} unless the user names another model."
        }
        if let runtimeMode = settings.runtimeMode {
            text += "\n- Launch new threads with runtimeMode \"\(runtimeMode.rawValue)\"."
        }
        let extra = settings.extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            text += "\n\nNotes from the user:\n\(extra)"
        }
        text += "\n\nReply with one short sentence saying you're ready."
        return text
    }

    /// Prefixes a dictated request with how its answer will be consumed.
    public static func envelope(_ text: String, source: Source, attachmentCount: Int = 0, date: Date = Date()) -> String {
        let stamp = Self.timestamp(date)
        let tag: String
        switch source {
        case .siri:
            tag = "[Clanker · Siri · \(stamp) · fire-and-forget: the user is gone and won't hear a reply. " +
                "Don't ask questions; make your best judgment and get it done. End with a one-line log of what you did.]"
        case .voice:
            tag = "[Clanker · voice · \(stamp) · your reply is read aloud, possibly while driving: " +
                "1 to 3 short spoken sentences, no markdown, lists, links, ids, or code. " +
                "Ask at most one short question, only if you truly can't proceed.]"
        case .typed:
            tag = "[Clanker · typed · \(stamp) · keep the reply brief.]"
        }
        let photos = switch attachmentCount {
        case 0: ""
        case 1: "\n[1 photo attached. Look at it; if work goes to another thread, describe what's in it there, since attachments don't carry over.]"
        default: "\n[\(attachmentCount) photos attached. Look at them; if work goes to another thread, describe what's in them there, since attachments don't carry over.]"
        }
        let body = text.isEmpty && attachmentCount > 0 ? "(no words, just the photo)" : text
        return "\(tag)\(photos)\n\(body)"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm zzz"
        return formatter.string(from: date)
    }
}
