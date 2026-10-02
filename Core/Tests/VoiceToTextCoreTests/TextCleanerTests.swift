import Testing
import VoiceToTextCore

@Suite struct TextCleanerTests {
    @Test(arguments: [
        "",
        "hello world",
        "Café naïve — 日本語テキスト 👋🏽",
        "first line\nsecond line\n\n  indented third\r\n",
        "   leading and trailing   ",
    ])
    func passthroughReturnsInputUnchanged(_ input: String) async {
        let outcome = await PassthroughCleaner().clean(input)
        #expect(outcome.text == input)
        #expect(outcome.source == .passthrough)
    }
}
