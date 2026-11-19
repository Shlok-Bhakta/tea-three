import Testing
@testable import TeaThreeKit

@Suite("Turn detection")
struct TurnDetectorTests {
    let detector = TurnDetector(pause: 2.0)

    @Test("a finished sentence sends after the normal pause")
    func finished() {
        #expect(detector.ending(of: "Log a burrito for lunch.") == .finished)
        #expect(detector.ending(of: "What's running on crabcake right now?") == .finished)
        #expect(detector.requiredSilence(for: "Log a burrito for lunch.") == 2.0)
    }

    @Test("trailing fillers and conjunctions hold the turn", arguments: [
        "So I ate a burrito and", "Check the build but", "I want you to um", "Log my lunch, uh",
        "Tell the food thread that", "Can you send the", "I think we should, you know", "Start a thread so",
        "I had a coffee,", "Wait so the thing is…", "Okay so",
    ])
    func unfinished(_ text: String) {
        #expect(detector.ending(of: text) == .unfinished)
        #expect(detector.requiredSilence(for: text) == 4.5)
    }

    @Test("a short fragment without punctuation is unfinished; a short sentence is not")
    func fragments() {
        #expect(detector.ending(of: "Log the") == .unfinished)
        #expect(detector.ending(of: "Okay.") == .finished)
    }

    @Test("no punctuation yet waits a little longer than a sentence")
    func uncertain() {
        #expect(detector.ending(of: "log a burrito for lunch today") == .uncertain)
        #expect(detector.requiredSilence(for: "log a burrito for lunch today") == 2.8)
    }

    @Test("wait and hold on keep the turn open much longer")
    func holding() {
        #expect(detector.ending(of: "Start a thread for, hold on") == .holding)
        #expect(detector.ending(of: "Wait.") == .holding)
        #expect(detector.requiredSilence(for: "let me think") == 8.0)
    }

    @Test("send it sends right away and is removed from the message")
    func sendNow() {
        #expect(detector.ending(of: "Log a burrito for lunch, send it.") == .sendNow)
        #expect(detector.requiredSilence(for: "log a burrito send it") == 0.6)
        #expect(TurnDetector.removingSendPhrase("Log a burrito for lunch, send it.") == "Log a burrito for lunch")
        #expect(TurnDetector.removingSendPhrase("Check the build over and out") == "Check the build")
        #expect(TurnDetector.removingSendPhrase("Log a burrito.") == "Log a burrito.")
    }

    @Test("the warning cue comes a second before sending, only when there's time")
    func warning() {
        #expect(detector.warningAt(for: "Log a burrito for lunch.") == 1.0)
        #expect(detector.warningAt(for: "So I ate a burrito and") == 3.5)
        #expect(detector.warningAt(for: "log it send it") == nil)
    }

    @Test("a hesitation after 'and' isn't sent at the old 1.6 s, or even at 3 s")
    func hesitationTimeline() {
        let said = "So I ate a burrito and"
        #expect(detector.decide(said, sinceText: 1.6, sinceSound: nil) == .listen)
        #expect(detector.decide(said, sinceText: 3.0, sinceSound: nil) == .listen)
        #expect(detector.decide(said, sinceText: 3.6, sinceSound: nil) == .warn)
        #expect(detector.decide(said, sinceText: 4.6, sinceSound: nil) == .send)
    }

    @Test("a finished sentence warns at 1 s and sends at 2 s")
    func finishedTimeline() {
        let said = "Log a burrito for lunch."
        #expect(detector.decide(said, sinceText: 0.5, sinceSound: nil) == .listen)
        #expect(detector.decide(said, sinceText: 1.2, sinceSound: nil) == .warn)
        #expect(detector.decide(said, sinceText: 2.1, sinceSound: nil) == .send)
    }

    @Test("an audible 'ummm' the recognizer dropped keeps the turn open")
    func soundHoldsTurn() {
        let said = "Log a burrito for lunch."
        #expect(detector.decide(said, sinceText: 3.0, sinceSound: 0.3) == .listen)
        // Sound right after a pause resets the cue too.
        #expect(detector.decide(said, sinceText: 1.5, sinceSound: 0.1) == .listen)
    }

    @Test("constant noise can't hold the turn more than 6 s past the last word")
    func noiseIsBounded() {
        let said = "Log a burrito for lunch."
        #expect(detector.decide(said, sinceText: 6.5, sinceSound: 0.1) == .listen)
        #expect(detector.decide(said, sinceText: 7.0, sinceSound: 0.1) == .warn)
        #expect(detector.decide(said, sinceText: 8.1, sinceSound: 0.1) == .send)
    }

    @Test("send it goes almost immediately")
    func sendItTimeline() {
        #expect(detector.decide("Log a burrito, send it", sinceText: 0.7, sinceSound: nil) == .send)
    }
}
