import XCTest
@testable import SwitchboardCore

final class MarkdownTests: XCTestCase {
    func testClaudeStyleReply() {
        let source = """
        The Mac app is a floating pill. Here's everything in it.

        ## What you see
        - **Pill:** always on screen and draggable
          anywhere.
        - **Expanded list:** each row shows:
          - project name and git branch
        1. first
        2. second

        ---
        ```sh
        ./build.sh --install
        ```
        | a | b |
        |---|---|
        """
        XCTAssertEqual(MarkdownBlock.parse(source), [
            .paragraph("The Mac app is a floating pill. Here's everything in it."),
            .heading(level: 2, text: "What you see"),
            .listItem(depth: 0, marker: "•", text: "**Pill:** always on screen and draggable anywhere."),
            .listItem(depth: 0, marker: "•", text: "**Expanded list:** each row shows:"),
            .listItem(depth: 1, marker: "•", text: "project name and git branch"),
            .listItem(depth: 0, marker: "1.", text: "first"),
            .listItem(depth: 0, marker: "2.", text: "second"),
            .rule,
            .code("./build.sh --install"),
            .code("| a | b |\n|---|---|"),
        ])
    }

    func testSoftWrappedParagraphsJoinAndUnclosedFenceStillShows() {
        XCTAssertEqual(MarkdownBlock.parse("one\ntwo\n\nthree\n```\ncode"),
                       [.paragraph("one two"), .paragraph("three"), .code("code")])
    }

    func testPlainTextForBanners() {
        XCTAssertEqual(Summarizer.plainText("## Done\n- **Fixed** the `parser`"), "Done\n• Fixed the parser")
    }
}
