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

    @Test("Chunk joining keeps punctuation tight")
    func joinsChunks() {
        #expect(TranscriptPostProcessor.join(["Hello", "world"]) == "Hello world")
        #expect(TranscriptPostProcessor.join(["Hello", ", again"]) == "Hello, again")
        #expect(TranscriptPostProcessor.join(["Hello", "", "  ", "world"]) == "Hello world")
        #expect(TranscriptPostProcessor.join([]) == "")
    }
}
