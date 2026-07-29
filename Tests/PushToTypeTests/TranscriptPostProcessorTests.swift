import Testing

@testable import PTTWhisper

@Suite("Transcript post-processing")
struct TranscriptPostProcessorTests {

    @Test("Strips whisper's non-speech annotations")
    func stripsAnnotations() {
        let processor = TranscriptPostProcessor(
            capitalizeFirstLetter: false,
            appendTrailingSpace: false
        )
        #expect(processor.process(" [BLANK_AUDIO]") == "")
        #expect(processor.process("Hello (coughs) there") == "Hello there")
        #expect(processor.process("♪♪♪") == "")
    }

    @Test("Joins segments onto one line")
    func flattensSegments() {
        let processor = TranscriptPostProcessor(
            capitalizeFirstLetter: false,
            appendTrailingSpace: false
        )
        #expect(processor.process(" First segment.\n Second segment.") == "First segment. Second segment.")
    }

    @Test("Applies the formatting preferences")
    func appliesPreferences() {
        #expect(
            TranscriptPostProcessor(capitalizeFirstLetter: true, appendTrailingSpace: true)
                .process("hello world") == "Hello world "
        )
        #expect(
            TranscriptPostProcessor(capitalizeFirstLetter: false, appendTrailingSpace: false)
                .process("hello world") == "hello world"
        )
    }

    @Test("Leaves an already-capitalised sentence alone")
    func doesNotDoubleCapitalise() {
        let processor = TranscriptPostProcessor(appendTrailingSpace: false)
        #expect(processor.process("École is fine") == "École is fine")
    }

    @Test("Hesitation is removed, in both forms whisper emits")
    func removesHesitation() {
        let processor = TranscriptPostProcessor(
            capitalizeFirstLetter: false,
            appendTrailingSpace: false
        )
        #expect(processor.process("GSP, Gzowo...... i tak dalej") == "GSP, Gzowo i tak dalej")
        #expect(processor.process("GSP… Gzowo... i tak") == "GSP Gzowo i tak")
        // No space around the ellipsis: removing it outright would fuse two words into
        // one that was never spoken.
        #expect(processor.process("takimi…inno") == "takimi inno")
        // A single full stop is punctuation, not hesitation.
        #expect(processor.process("Koniec zdania. Nowe") == "Koniec zdania. Nowe")
    }

    @Test("Trailing hesitation is dropped")
    func dropsTrailingHesitation() {
        let processor = TranscriptPostProcessor(
            capitalizeFirstLetter: false,
            appendTrailingSpace: false
        )
        // Releasing the key during a pause should not leave the pause in the text.
        #expect(processor.process("i jak się zastanawiam......") == "i jak się zastanawiam")
        #expect(processor.process("i jak się zastanawiam…") == "i jak się zastanawiam")
        #expect(processor.process("coś tam,") == "coś tam")
        #expect(processor.process("zdanie.") == "zdanie.", "a real full stop survives")
    }

    @Test("Punctuation loses the space in front of it")
    func tightensPunctuation() {
        let processor = TranscriptPostProcessor(
            capitalizeFirstLetter: false,
            appendTrailingSpace: false
        )
        #expect(processor.process("tak , owszem ; no") == "tak, owszem; no")
        #expect(processor.process("raz, , dwa") == "raz, dwa")
    }

    @Test("Chunk joining keeps punctuation tight")
    func joinsChunks() {
        #expect(TranscriptPostProcessor.join(["Hello", "world"]) == "Hello world")
        #expect(TranscriptPostProcessor.join(["Hello", ", again"]) == "Hello, again")
        #expect(TranscriptPostProcessor.join(["Hello", "", "  ", "world"]) == "Hello world")
        #expect(TranscriptPostProcessor.join([]) == "")
    }
}
