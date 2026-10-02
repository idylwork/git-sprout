//
//  GitSproutTests.swift
//  GitSproutTests
//

import AppKit
import Foundation
import PDFKit
import Testing
@testable import GitSprout

struct SelectionStepTests {
    @Test func movesWithinTheListAndClampsAtTheEnds() {
        let items = ["a", "b", "c"]
        #expect(SelectionStep.index(of: "b", in: items, delta: 1) == 2)
        #expect(SelectionStep.index(of: "b", in: items, delta: -1) == 0)
        #expect(SelectionStep.index(of: "a", in: items, delta: -1) == 0)
        #expect(SelectionStep.index(of: "c", in: items, delta: 1) == 2)
        #expect(SelectionStep.index(of: nil, in: items, delta: 1) == 0)
        #expect(SelectionStep.index(of: nil, in: items, delta: -1) == 2)
        #expect(SelectionStep.index(of: "missing", in: items, delta: 1) == 0)
        #expect(SelectionStep.index(of: "a", in: [String](), delta: 1) == nil)
        #expect(SelectionStep.index(of: "a", in: items, delta: 0) == nil)
    }
}

struct OpenDocumentEventTests {
    @Test func readsFileURLsFromAnOpenDocumentsEvent() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenDocuments),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        let list = NSAppleEventDescriptor.list()
        let folder = URL(fileURLWithPath: "/Users/kaol/Projects/git-sprout")
        list.insert(NSAppleEventDescriptor(fileURL: folder), at: 1)
        event.setParam(list, forKeyword: keyDirectObject)
        let urls = OpenDocumentEvent.urls(from: event)
        #expect(urls.map { $0.path(percentEncoded: false) } == [folder.path(percentEncoded: false)])
    }
}

struct RepositoryPathTests {
    @Test func containingDirectoryKeepsAFolderAndUsesAFileParent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitsprout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("a".utf8).write(to: file)
        let folder = root.path(percentEncoded: false)
        #expect(RepositoryPath.containingDirectory(for: folder) == folder)
        #expect(RepositoryPath.containingDirectory(for: file.path(percentEncoded: false)) == folder)
        let missing = root.appendingPathComponent("missing").path(percentEncoded: false)
        #expect(RepositoryPath.containingDirectory(for: missing) == missing)
    }

    @Test func menuTitleUsesTheFolderNameUntilNamesCollide() {
        let client = "/work/client/app"
        let server = "/work/server/app"
        #expect(RepositoryPath.menuTitle(for: client, among: [client]) == "app")
        #expect(RepositoryPath.menuTitle(for: client, among: [client, server]) == "app — client")
        #expect(RepositoryPath.menuTitle(for: server, among: [client, server]) == "app — server")
    }
}

struct RepoChangeTests {
    @Test func classifyKeepsWorktreePathsAndDropsObjectWrites() {
        let root = "/repo"
        let change = RepoChange.classify(
            absolutePaths: [
                "/repo/src/App.swift",
                "/repo/.git/objects/ab/cd",
                "/repo/.git/refs/heads/main",
                "/repo/.git/index.lock",
                "/repo/.git/HEAD",
                "/elsewhere/file.txt"
            ],
            root: root
        )
        #expect(change.refsChanged)
        #expect(change.worktreePaths == ["src/App.swift"])
        #expect(!change.worktreeOverflow)
    }
}

struct CommitMessagePromptTests {
    @Test func instructionsNameTheLanguage() {
        #expect(CommitMessagePrompt.instructions(for: .english).contains("English"))
        #expect(CommitMessagePrompt.instructions(for: .english).contains("what changed"))
        let japanese = CommitMessagePrompt.instructions(for: .japanese)
        #expect(japanese.contains("Japanese"))
        #expect(japanese.contains("what changed"))
        #expect(japanese.contains("past-tense verb"))
        let prompt = CommitMessagePrompt.prompt(for: "diff --git a/a b/a\n+one\n", language: .japanese)
        #expect(prompt?.contains("Japanese") == true)
        #expect(prompt?.contains("past-tense verb") == false)
        #expect(prompt?.contains("日本語") == false)
    }

    @Test func promptSkipsAnEmptyDiff() {
        #expect(CommitMessagePrompt.prompt(for: " \n") == nil)
    }

    @Test func diffExcerptCutsOnALineAndMarksTheCut() {
        let diff = String(repeating: "line\n", count: 40)
        let excerpt = CommitMessagePrompt.diffExcerpt(diff, limit: 50)
        #expect(excerpt.contains(CommitMessagePrompt.omittedNote))
        #expect(!excerpt.contains("line\nline\nline\nline\nline\nline\nline\nline\nline\nline\nline"))
        #expect(excerpt.split(separator: "\n", omittingEmptySubsequences: false).dropLast(2).allSatisfy { $0 == "line" })
    }

    @Test func cleanedMessageDropsFencesLabelsAndQuotes() {
        #expect(CommitMessagePrompt.cleanedMessage("```\nAdd parser\n```") == "Add parser")
        #expect(CommitMessagePrompt.cleanedMessage("```text\nAdd parser\n```") == "Add parser")
        #expect(CommitMessagePrompt.cleanedMessage("  \"Add parser\"  ") == "Add parser")
        #expect(CommitMessagePrompt.cleanedMessage("「パーサーを追加」") == "パーサーを追加")
        #expect(CommitMessagePrompt.cleanedMessage("Commit message:\nAdd parser") == "Add parser")
        #expect(CommitMessagePrompt.cleanedMessage("Add \"parser\"") == "Add \"parser\"")
        #expect(CommitMessagePrompt.cleanedMessage("   ") == nil)
    }

    @Test func messageDropsACopiedDiffAndKeepsASummary() {
        let diff = """
        diff --git a/App.swift b/App.swift
        @@ -1,3 +1,4 @@
         func run() {
        -    return
        +    start()
         }
        """
        let copied = """
        func run() {
            return
            start()
        }
        """
        #expect(CommitMessagePrompt.looksLikeDiff(diff))
        #expect(CommitMessagePrompt.message(subject: diff, body: "", diff: diff) == nil)
        #expect(CommitMessagePrompt.message(subject: copied, body: "", diff: diff) == nil)
        #expect(CommitMessagePrompt.message(subject: "Start the app", body: diff, diff: diff) == "Start the app")
        #expect(
            CommitMessagePrompt.message(subject: "Start the app", body: "Run when the window opens.", diff: diff)
                == "Start the app\n\nRun when the window opens."
        )
    }

    @Test func messageDropsABodyThatRestatesTheSubject() {
        let diff = "diff --git a/Settings.swift b/Settings.swift\n+language\n"
        let subject = "設定の言語設定とコミットメッセージの提案機能の追加"
        let restated = "コミットメッセージの言語設定と設定の言語設定の追加"
        #expect(CommitMessagePrompt.message(subject: subject, body: restated, diff: diff) == subject)
        #expect(
            CommitMessagePrompt.message(subject: subject, body: "設定画面から言語を選べるようにする。", diff: diff)
                == subject + "\n\n設定画面から言語を選べるようにする。"
        )
    }
}

struct DiffReviewPromptTests {
    private let sampleDiff = """
    Sources/Parser.swift | 2 ++
    1 file changed, 2 insertions(+)

    diff --git a/Sources/Parser.swift b/Sources/Parser.swift
    @@ -2,4 +2,6 @@
     struct Parser {
         func parse() {
    +        let first = 1
    +        let second = 2
             return
         }
    """

    private let echoedSummary = "新しい構造を作成しました。総評は差分の内容とコミットの準備状況について2〜3文で記述します。未完成のハンクがあるため、すべての指摘を含めています。"

    @Test func instructionsNameTheLanguage() {
        #expect(DiffReviewPrompt.instructions(for: .english).contains("English"))
        #expect(DiffReviewPrompt.instructions(for: .japanese).contains("Japanese"))
        #expect(DiffReviewPrompt.instructions(for: .english).contains("risk"))
        #expect(DiffReviewPrompt.instructions(for: .english).contains("Do not name files"))
        #expect(!DiffReviewPrompt.instructions(for: .english).contains("check disappears"))
        #expect(!DiffReviewPrompt.instructions(for: .english).contains("one or two sentences"))
        let prompt = DiffReviewPrompt.prompt(for: sampleDiff, language: .japanese)
        #expect(prompt?.contains("Japanese") == true)
        #expect(prompt?.contains("日本語") == false)
        #expect(prompt?.contains("let first") == true)
        #expect(prompt?.contains("1 file changed") == true)
        #expect(prompt?.contains("Sources/Parser.swift") == false)
        #expect(prompt?.contains("diff --git ") == false)
    }

    @Test func promptSkipsAnEmptyDiff() {
        #expect(DiffReviewPrompt.prompt(for: " \n") == nil)
        #expect(DiffReviewPrompt.parseHunks(" \n").isEmpty)
    }

    @Test func parseHunksKeepsContextAroundAddedLines() {
        let hunks = DiffReviewPrompt.parseHunks(sampleDiff)
        #expect(hunks.count == 1)
        #expect(hunks[0].changedLines.map(\.text) == ["        let first = 1", "        let second = 2"])
        #expect(hunks[0].changedLines.map(\.newNumber) == [4, 5])
        #expect(hunks[0].lines.count == 6)
    }

    @Test func reviewShowsTheTargetLinesWithOneLineOfContext() {
        let hunks = DiffReviewPrompt.parseHunks(sampleDiff)
        let review = DiffReviewPrompt.review(
            summary: "Parser.swift sets first and second.",
            comments: [
                (hunk: 1, line: 4, comment: "This line adds the first marker."),
                (hunk: 1, line: 5, comment: "This line adds the second marker."),
                (hunk: 9, line: 4, comment: "This hunk is not in the diff."),
                (hunk: 1, line: 4, comment: "This line adds the first marker.")
            ],
            hunks: hunks
        )
        #expect(review?.summary?.contains("first") == true)
        #expect(review?.findings.count == 1)
        #expect(review?.findings[0].path == "Sources/Parser.swift")
        #expect(review?.findings[0].lines.map(\.kind) == [.context, .addition, .addition, .context])
        #expect(review?.findings[0].lines.map(\.newNumber) == [3, 4, 5, 6])
        #expect(review?.findings[0].lines.map(\.text) == ["    func parse() {", "        let first = 1", "        let second = 2", "        return"])
        #expect(review?.findings[0].comment.contains("first marker") == true)
        #expect(review?.findings[0].comment.contains("second marker") == true)

        let oneLine = DiffReviewPrompt.review(
            summary: "Parser.swift sets first.",
            comments: [(hunk: 1, line: 4, comment: "This line adds the first marker.")],
            hunks: hunks
        )
        #expect(oneLine?.findings[0].lines.map(\.newNumber) == [3, 4, 5])
        #expect(oneLine?.findings[0].lines.map(\.kind) == [.context, .addition, .addition])

        let echoed = DiffReviewPrompt.review(
            summary: echoedSummary,
            comments: [(hunk: 1, line: 4, comment: "The first value is now assigned.")],
            hunks: hunks
        )
        #expect(echoed?.summary == nil)
        #expect(echoed?.findings[0].lines.contains { $0.text.contains("first") } == true)
        #expect(DiffReviewPrompt.review(summary: echoedSummary, comments: [], hunks: hunks) == nil)
        let copiedInstructions = """
        The summary is one or two sentences about what the changed lines do. A finding cites one changed line only when the same hunk also removes or replaces a line.

        Words from this line and from the line it replaces, in Japanese.
        """
        #expect(DiffReviewPrompt.review(summary: copiedInstructions, comments: [], hunks: hunks) == nil)
        #expect(
            DiffReviewPrompt.review(summary: "パーサーに代入を追加した。", comments: [], hunks: hunks)?.summary
                == "パーサーに代入を追加した。"
        )
        #expect(
            DiffReviewPrompt.review(summary: "パーサーに代入を追加した。", risk: "なし", comments: [], hunks: hunks)?.risk
                == nil
        )
        #expect(
            DiffReviewPrompt.review(
                summary: "パーサーに代入を追加した。",
                risk: "初期値が固定されたままになる。",
                comments: [],
                hunks: hunks
            )?.risk == "初期値が固定されたままになる。"
        )
        #expect(
            DiffReviewPrompt.review(
                summary: "パーサーに代入を追加した。",
                risk: "初期値が固定されたままになる。」}<ctrl46>}",
                comments: [],
                hunks: hunks
            )?.risk == "初期値が固定されたままになる。"
        )
        let loopedRisk = String(repeating: "変更の説明が同じ文で繰り返され、新しい内容は増えていない。", count: 2)
        #expect(
            DiffReviewPrompt.review(summary: "パーサーに代入を追加した。", risk: loopedRisk, comments: [], hunks: hunks)?.risk
                == nil
        )
        #expect(DiffReviewPrompt.review(summary: "Do not name files or quote code.", comments: [], hunks: hunks) == nil)
        #expect(
            DiffReviewPrompt.review(
                summary: "Parser.swift は新しいチェックが削除され、既存の条件のデフォルトが変更されました。",
                comments: [],
                hunks: hunks
            ) == nil
        )
        #expect(
            DiffReviewPrompt.review(summary: "Parser.swift sets first.", comments: [(hunk: 1, line: 4, comment: "        let first = 1")], hunks: hunks)?
                .findings.isEmpty == true
        )
    }

    @Test func reviewCapsFindings() {
        let diff = (1...8).map { index in
            """
            diff --git a/File\(index).swift b/File\(index).swift
            @@ -1 +1,2 @@
             stay
            +added\(index)
            """
        }.joined(separator: "\n")
        let hunks = DiffReviewPrompt.parseHunks(diff)
        #expect(hunks.count == 8)
        #expect(hunks[0].changedLines.map(\.newNumber) == [2])
        let comments = hunks.map { (hunk: $0.index, line: 2, comment: "File\($0.index) still has added\($0.index).") }
        let review = DiffReviewPrompt.review(summary: "File1.swift adds added1.", comments: comments, hunks: hunks)
        #expect(review?.findings.count == DiffReviewPrompt.findingLimit)
        #expect(review?.findings[0].lines.map(\.text) == ["stay", "added1"])
        #expect(review?.findings[0].lines.map(\.kind) == [.context, .addition])
    }
}

struct LocalizationTests {
    @Test func japaneseOverridesTheEnglishSource() throws {
        let app = Bundle(for: AppModel.self)
        let japaneseURL = try #require(app.url(forResource: "ja", withExtension: "lproj"))
        let englishURL = try #require(app.url(forResource: "en", withExtension: "lproj"))
        let japanese = try #require(Bundle(url: japaneseURL))
        let english = try #require(Bundle(url: englishURL))
        #expect(japanese.localizedString(forKey: "Open", value: nil, table: nil) == "開く")
        #expect(english.localizedString(forKey: "Open", value: nil, table: nil) == "Open")
        #expect(japanese.localizedString(forKey: "%lld changes", value: nil, table: nil) == "%lld 件の変更")
        #expect(String(localized: "\(3) changes", bundle: japanese) == "3 件の変更")
    }
}

struct RemoteBrowserURLTests {
    @Test func opensWebPagesAndSkipsLocalPaths() {
        #expect(RemoteBrowserURL.page(from: "https://github.com/example/app.git")?.absoluteString == "https://github.com/example/app")
        #expect(RemoteBrowserURL.page(from: "http://gitlab.com/group/app/")?.absoluteString == "https://gitlab.com/group/app")
        #expect(RemoteBrowserURL.page(from: "git@github.com:example/app.git")?.absoluteString == "https://github.com/example/app")
        #expect(RemoteBrowserURL.page(from: "git@gitlab.com:group/sub/app.git")?.absoluteString == "https://gitlab.com/group/sub/app")
        #expect(RemoteBrowserURL.page(from: "ssh://git@github.com/example/app.git")?.absoluteString == "https://github.com/example/app")
        #expect(RemoteBrowserURL.page(from: "ssh://git@github.com:22/example/app.git")?.absoluteString == "https://github.com/example/app")
        #expect(RemoteBrowserURL.page(from: "git://github.com/example/app.git")?.absoluteString == "https://github.com/example/app")
        #expect(RemoteBrowserURL.page(from: "https://user:token@github.com/example/app.git")?.absoluteString == "https://github.com/example/app")
        #expect(RemoteBrowserURL.page(from: "/tmp/repo.git") == nil)
        #expect(RemoteBrowserURL.page(from: "file:///tmp/repo.git") == nil)
        #expect(RemoteBrowserURL.page(from: "  ") == nil)
    }
}

struct ParserTests {
    @Test func statusPorcelainKeepsPathsWithSpaces() {
        let raw = "1 MM N... 100644 100644 100644 78981922613b2afb6025042ff6bd878ac1994e85 422c2b7ab3b3c668038da977e4e93a5fc623169c file name.txt\0? new file.txt\0"
        let files = GitStatusParser.parse(Data(raw.utf8))
        #expect(files.count == 2)
        #expect(files[0].path == "file name.txt")
        #expect(files[0].staged == .modified)
        #expect(files[0].unstaged == .modified)
        #expect(files[1].path == "new file.txt")
        #expect(files[1].unstaged == .untracked)
    }

    @Test func statusRenameUsesTheNextNULPath() {
        let raw = "2 R. N... 100644 100644 100644 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb R100 new name.txt\0old name.txt\0"
        let files = GitStatusParser.parse(Data(raw.utf8))
        #expect(files.count == 1)
        #expect(files[0].path == "new name.txt")
        #expect(files[0].originalPath == "old name.txt")
        #expect(files[0].staged == .renamed)
        #expect(files[0].unstaged == .none)
    }

    @Test func logParserReadsDecorations() {
        let raw = "abc\u{1f}\u{1f}T\u{1f}t@example.com\u{1f}2026-09-29T17:54:24+09:00\u{1f} (HEAD -> refs/heads/main)\u{1f}init\u{1e}"
        let commits = GitLogParser.parse(Data(raw.utf8))
        #expect(commits.count == 1)
        #expect(commits[0].oid == "abc")
        #expect(commits[0].parents.isEmpty)
        #expect(commits[0].decoration == "main")
        #expect(commits[0].subject == "init")
        #expect(commits[0].body.isEmpty)
        #expect(commits[0].authoredAt != .distantPast)
    }

    @Test func logParserReadsTheBodyBelowTheSubject() {
        let raw = "abc\u{1f}parent\u{1f}T\u{1f}t@example.com\u{1f}2026-09-29T17:54:24+09:00\u{1f}\u{1f}init\u{1f}first line\u{1f}keeps separators\n\nthird\n\u{1e}"
        let commits = GitLogParser.parse(Data(raw.utf8))
        #expect(commits.count == 1)
        #expect(commits[0].subject == "init")
        #expect(commits[0].body == "first line\u{1f}keeps separators\n\nthird")
    }

    @Test func commitMessageGetsABlankSecondLine() {
        #expect(CommitMessageText.insertingBlankSecondLine("subject") == "subject")
        #expect(CommitMessageText.insertingBlankSecondLine("subject\n\nbody") == "subject\n\nbody")
        #expect(CommitMessageText.insertingBlankSecondLine("subject\nbody\nmore") == "subject\n\nbody\nmore")
        #expect(CommitMessageText.insertingBlankSecondLine("subject\r\nbody") == "subject\n\nbody")
        #expect(CommitMessageText.insertingBlankSecondLine("subject\n  \nbody") == "subject\n\nbody")
        #expect(CommitMessageText.insertingBlankSecondLine("") == "")
    }

    @Test func diffTextLinesStayOnTheGutterPitch() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let lineHeight = ceil(font.boundingRectForFont.height)
        let texts = ["alpha", "beta", "", "delta"]
        let view = DiffColumnTextView()
        view.frame = NSRect(x: 0, y: 0, width: 420, height: lineHeight * CGFloat(texts.count))
        view.apply(texts: texts, font: font, lineHeight: lineHeight, width: 420)
        let origins = view.lineFragmentOrigins()
        #expect(origins.count == texts.count)
        for (index, origin) in origins.enumerated() {
            #expect(abs(origin - CGFloat(index) * lineHeight) < 0.5)
        }
    }

    @Test func diffParserSplitsHunks() {
        let patch = """
        diff --git a/hello.txt b/hello.txt
        index 111..222 100644
        --- a/hello.txt
        +++ b/hello.txt
        @@ -1,2 +1,3 @@ heading
         line
        -old
        +new
        +extra
        """
        let document = GitDiffParser.parse(Data(patch.utf8))
        #expect(document.hunks.count == 1)
        #expect(document.hunks[0].lines.map(\.kind) == [.context, .deletion, .addition, .addition])
        #expect(document.hunks[0].patch.contains("@@ -1,2 +1,3 @@ heading"))
        #expect(document.hunks[0].heading == "heading")
        let selected = Set(document.hunks[0].lines.filter { $0.text == "old" || $0.text == "extra" }.map(\.id))
        let partial = DiffLinePatch.make(document: document, selectedIDs: selected)
        #expect(partial?.contains("@@ -1,2 +1,2 @@ heading") == true)
        #expect(partial?.contains("-old") == true)
        #expect(partial?.contains("+extra") == true)
        #expect(partial?.contains("+new") == false)
    }

    @Test func diffParserKeepsRenameAsOneChange() {
        let patch = """
        diff --git a/old.txt b/new.txt
        similarity index 100%
        rename from old.txt
        rename to new.txt
        """
        let document = GitDiffParser.parse(Data(patch.utf8))
        #expect(document.renameFrom == "old.txt")
        #expect(document.renameTo == "new.txt")
        #expect(document.hunks.isEmpty)
        #expect(!document.isEmpty)
    }

    @Test func diffParserMarksBinary() {
        let text = "diff --git a/a b/a\nBinary files a/a and b/a differ\n"
        let document = GitDiffParser.parse(Data(text.utf8))
        #expect(document.binary)
        #expect(document.hunks.isEmpty)
        #expect(document.renameFrom == nil)
    }

    @Test func diffParserKeepsRenameOnBinaryDiff() {
        let text = """
        diff --git a/old.png b/new.png
        similarity index 80%
        rename from old.png
        rename to new.png
        Binary files a/old.png and b/new.png differ

        """
        let document = GitDiffParser.parse(Data(text.utf8))
        #expect(document.binary)
        #expect(document.renameFrom == "old.png")
        #expect(document.renameTo == "new.png")
        #expect(!document.hasImageDiff)
    }

    @Test func branchAndStashParsers() {
        let branches = GitBranchParser.parse(Data("main\tabc\t*\nother\tdef\t \n".utf8))
        #expect(branches.map(\.name) == ["main", "other"])
        #expect(branches[0].isCurrent)
        #expect(!branches[1].isCurrent)
        #expect(branches[0].upstream == nil)
        let tracked = GitBranchParser.parse(Data("main\tabc\t*\torigin/main\torigin\n".utf8))
        #expect(tracked[0].upstream == "origin/main")
        #expect(tracked[0].remoteName == "origin")
        let stashes = GitStashParser.parse(Data("stash@{0}\u{1f}abc\u{1f}On main: demo\u{1e}".utf8))
        #expect(stashes.count == 1)
        #expect(stashes[0].ref == "stash@{0}")
        #expect(stashes[0].subject == "On main: demo")
    }

    @Test func grepLineAllowsColonsInThePath() {
        let hit = GitGrepParser.parseLine("dir/a:b.txt:12:hello")
        #expect(hit?.path == "dir/a:b.txt")
        #expect(hit?.line == 12)
        #expect(hit?.text == "hello")
    }
}

struct GraphLayoutTests {
    private func commit(_ oid: String, _ parents: [String]) -> CommitRecord {
        CommitRecord(oid: oid, parents: parents, subject: oid)
    }

    @Test func linearHistoryStaysInOneLane() {
        let commits = (0..<5).reversed().map { index in
            commit("c\(index)", index == 0 ? [] : ["c\(index - 1)"])
        }
        let laid = GraphLayout.layout(commits: commits, cursor: .empty)
        #expect(laid.rows.map(\.commitLane) == [0, 0, 0, 0, 0])
        #expect(laid.cursor.lanes.isEmpty)
        #expect(laid.rows.allSatisfy { $0.commitColor == 0 })
    }

    @Test func mergeAndPaginationUseTheSameLanes() {
        let commits = [
            commit("D", ["B", "C"]),
            commit("C", ["A"]),
            commit("B", ["A"]),
            commit("A", [])
        ]
        let full = GraphLayout.layout(commits: commits, cursor: .empty)
        #expect(full.rows.map(\.commitLane) == [0, 1, 0, 0])
        #expect(full.rows.map { $0.outgoing.map(\.oid) } == [["B", "C"], ["B", "A"], ["A", "A"], []])
        #expect(full.rows[3].edges.contains { $0.joinsCommit && $0.fromLane == 1 && $0.toLane == 0 })

        let page1 = GraphLayout.layout(commits: Array(commits.prefix(2)), cursor: .empty)
        let page2 = GraphLayout.layout(commits: Array(commits.dropFirst(2)), cursor: page1.cursor)
        #expect(page1.rows.map(\.commitLane) + page2.rows.map(\.commitLane) == full.rows.map(\.commitLane))
        #expect(page2.cursor.lanes.map(\.oid) == full.cursor.lanes.map(\.oid))
        #expect(page1.rows[1].connectsUp)
        #expect(!page1.rows[0].connectsUp)
    }

    @Test func uncommittedFollowsTheCheckedOutTip() {
        let commits = [
            commit("tip", ["base"]),
            commit("base", [])
        ]
        let laid = GraphLayout.layout(commits: commits, cursor: .empty)
        let rows = GraphLayout.insertingUncommitted(laid.rows, aboveHead: "tip")
        #expect(rows.map(\.commit.oid) == [CommitRecord.uncommittedOID, "tip", "base"])
        #expect(rows[0].commit.parents == ["tip"])
        #expect(rows[0].commitLane == rows[1].commitLane)
        #expect(rows[1].connectsUp)
    }

    @Test func checkedOutCommitStaysInTheLeftLane() {
        let commits = [
            commit("newer", ["base"]),
            commit("head", ["base"]),
            commit("base", [])
        ]
        let laid = GraphLayout.layout(commits: commits, cursor: .empty, head: "head")
        #expect(laid.rows.first { $0.commit.oid == "head" }?.commitLane == 0)
        #expect(laid.rows.first { $0.commit.oid == "newer" }?.commitLane == 1)
        let untouched = GraphLayout.layout(commits: [commit("head", ["base"]), commit("base", [])], cursor: .empty, head: "head")
        #expect(untouched.rows.map(\.commitLane) == [0, 0])
        #expect(!untouched.rows[0].connectsUp)
    }

    @Test func reservedLaneSurvivesPagination() {
        let commits = [
            commit("newer", ["mid"]),
            commit("mid", ["head"]),
            commit("head", ["base"]),
            commit("base", [])
        ]
        let page1 = GraphLayout.layout(commits: Array(commits.prefix(2)), cursor: .empty, head: "head")
        let page2 = GraphLayout.layout(commits: Array(commits.dropFirst(2)), cursor: page1.cursor, head: "head")
        #expect(page1.cursor.lanes.map(\.oid) == ["head", "head"])
        #expect(page1.rows.map(\.commitLane) == [1, 1])
        #expect(page2.rows.map(\.commitLane) == [0, 0])
    }

    @Test func uncommittedStaysAtTheTopWhenAnotherBranchIsNewer() {
        let commits = [
            commit("newer", ["base"]),
            commit("head", ["base"]),
            commit("base", [])
        ]
        let laid = GraphLayout.layout(commits: commits, cursor: .empty, head: "head")
        let rows = GraphLayout.insertingUncommitted(laid.rows, aboveHead: "head")
        #expect(rows.map(\.commit.oid) == [CommitRecord.uncommittedOID, "newer", "head", "base"])
        #expect(rows[0].commit.parents == ["head"])
        #expect(rows[0].commitLane == 0)
        #expect(rows[2].commitLane == 0)
        #expect(rows[1].commitLane == 1)
        #expect(rows[2].connectsUp)
        #expect(!rows[1].connectsUp)
        #expect(rows[1].edges.contains { $0.fromLane == 0 && $0.toLane == 0 })
    }

    @Test func uncommittedStaysAtTheTopAboveAChildOfHead() {
        let commits = [
            commit("child", ["head"]),
            commit("head", ["base"]),
            commit("base", [])
        ]
        let laid = GraphLayout.layout(commits: commits, cursor: .empty, head: "head")
        let rows = GraphLayout.insertingUncommitted(laid.rows, aboveHead: "head")
        #expect(rows.map(\.commit.oid) == [CommitRecord.uncommittedOID, "child", "head", "base"])
        #expect(rows[0].commitLane == 0)
        #expect(rows[2].commitLane == 0)
        #expect(rows[1].commitLane == 1)
        #expect(rows[2].connectsUp)
        #expect(rows[1].edges.contains { $0.fromLane == 0 && $0.toLane == 0 })
    }

    @Test func uncommittedLinePassesThroughCommitsAboveHead() {
        let commits = [
            commit("newer", ["mid"]),
            commit("mid", ["head"]),
            commit("head", ["base"]),
            commit("base", [])
        ]
        let laid = GraphLayout.layout(commits: commits, cursor: .empty, head: "head")
        let rows = GraphLayout.insertingUncommitted(laid.rows, aboveHead: "head")
        #expect(rows.map(\.commit.oid) == [CommitRecord.uncommittedOID, "newer", "mid", "head", "base"])
        #expect(rows[0].commitLane == 0)
        #expect(rows[3].commitLane == 0)
        #expect(rows[1].edges.contains { $0.fromLane == 0 && $0.toLane == 0 })
        #expect(rows[2].edges.contains { $0.fromLane == 0 && $0.toLane == 0 })
        #expect(rows[3].connectsUp)
    }

    @Test func noUpwardLineFromHeadWhenNothingIsUncommitted() {
        let sibling = [
            commit("newer", ["base"]),
            commit("head", ["base"]),
            commit("base", [])
        ]
        let siblingRows = GraphLayout.omittingUnusedHeadLine(
            GraphLayout.layout(commits: sibling, cursor: .empty, head: "head").rows,
            head: "head"
        )
        #expect(siblingRows.first { $0.commit.oid == "head" }?.commitLane == 0)
        #expect(siblingRows.first { $0.commit.oid == "newer" }?.commitLane == 1)
        #expect(siblingRows.first { $0.commit.oid == "head" }?.connectsUp == false)
        #expect(!siblingRows[0].edges.contains { $0.fromLane == 0 && $0.toLane == 0 })
        #expect(siblingRows[0].edges.contains { $0.fromLane == 1 && $0.toLane == 1 })

        let child = [
            commit("child", ["head"]),
            commit("head", ["base"]),
            commit("base", [])
        ]
        let childRows = GraphLayout.omittingUnusedHeadLine(
            GraphLayout.layout(commits: child, cursor: .empty, head: "head").rows,
            head: "head"
        )
        #expect(childRows[1].connectsUp == false)
        #expect(!childRows[0].edges.contains { $0.fromLane == 0 && $0.toLane == 0 })
        #expect(childRows[0].edges.contains { $0.fromLane == 1 && $0.toLane == 1 })
        #expect(childRows[1].edges.contains { $0.joinsCommit && $0.fromLane == 1 && $0.toLane == 0 })

        let tip = GraphLayout.omittingUnusedHeadLine(
            GraphLayout.layout(commits: [commit("head", ["base"]), commit("base", [])], cursor: .empty, head: "head").rows,
            head: "head"
        )
        #expect(tip.map(\.commitLane) == [0, 0])
        #expect(!tip[0].connectsUp)
    }

    @Test func uncommittedStaysUnlinkedUntilHeadIsLoaded() {
        let laid = GraphLayout.layout(commits: [commit("newer", [])], cursor: .empty)
        let rows = GraphLayout.insertingUncommitted(laid.rows, aboveHead: "missing")
        #expect(rows.map(\.commit.oid) == [CommitRecord.uncommittedOID, "newer"])
        #expect(rows[0].edges.isEmpty)
        #expect(rows[0].commit.parents.isEmpty)
        #expect(!rows[1].connectsUp)
    }
}

struct GitClientTests {
    @Test func statusStageCommitLogDiffAndStash() async throws {
        let repo = try TemporaryRepo()
        let file = repo.root.appendingPathComponent("file name.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        try "other\n".write(to: repo.root.appendingPathComponent("new file.txt"), atomically: true, encoding: .utf8)
        let client = GitClient(workingDirectory: repo.root.path)

        let before = try await client.status()
        #expect(before.files.contains { $0.path == "file name.txt" && $0.unstaged == .untracked })

        try await client.stage(paths: ["file name.txt"])
        let staged = try await client.status()
        #expect(staged.files.contains { $0.path == "file name.txt" && $0.staged == .added })

        try await client.commit(message: "init")
        var lines = (1...20).map { "line \($0)" }
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        try await client.stage(paths: ["file name.txt"])
        try await client.commit(message: "base")
        lines[0] = "changed top"
        lines[19] = "changed bottom"
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let added = try await client.diff(path: "new file.txt", staged: false)
        #expect(added.hunks.contains { hunk in
            hunk.lines.contains { $0.kind == .addition && $0.text == "other" }
        })

        let diff = try await client.diff(path: "file name.txt", staged: false)
        #expect(diff.hunks.count >= 2)
        try await client.apply(patch: diff.hunks[0].patch, cached: true, reverse: false)
        let partial = try await client.status()
        let changed = try #require(partial.files.first { $0.path == "file name.txt" })
        #expect(changed.hasStaged)
        #expect(changed.hasUnstaged)

        try await client.commit(message: "partial")
        let page = try await client.log(skip: 0, limit: 1)
        #expect(page.commits.count == 1)
        #expect(page.hasMore)
        #expect(page.commits[0].subject == "partial")

        try "stash me\n".write(to: file, atomically: true, encoding: .utf8)
        try await client.stashPush(message: "demo")
        let stashes = try await client.stashes()
        #expect(stashes.count == 1)
        let clean = try await client.status()
        #expect(!clean.files.contains { $0.path == "file name.txt" })
        try await client.stashPop(stashes[0].ref)
        let restored = try await client.status()
        #expect(restored.files.contains { $0.path == "file name.txt" })
    }

    @Test func rangeDiffStartsAtTheMergeBase() async throws {
        let repo = try TemporaryRepo()
        let hello = repo.root.appendingPathComponent("hello.txt")
        try "one\n".write(to: hello, atomically: true, encoding: .utf8)
        try repo.git(["add", "hello.txt"])
        try repo.git(["commit", "-m", "base"])
        try repo.git(["branch", "feature"])
        try "main\n".write(to: hello, atomically: true, encoding: .utf8)
        try "side\n".write(to: repo.root.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try repo.git(["add", "hello.txt", "other.txt"])
        try repo.git(["commit", "-m", "on main"])
        try repo.git(["switch", "feature"])
        try "feature\n".write(to: hello, atomically: true, encoding: .utf8)
        try "extra\n".write(to: repo.root.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        try repo.git(["add", "hello.txt", "extra.txt"])
        try repo.git(["commit", "-m", "on feature"])
        try "third\n".write(to: repo.root.appendingPathComponent("third.txt"), atomically: true, encoding: .utf8)
        try repo.git(["add", "third.txt"])
        try repo.git(["commit", "-m", "again"])

        let client = GitClient(workingDirectory: repo.root.path)
        let head = try await client.head()
        let page = try await client.log(skip: 0, limit: 10)
        let mainOID = try #require(page.commits.first { $0.subject == "on main" }?.oid)
        let tipFiles = try await client.files(in: head.oid)
        #expect(tipFiles.values.map(\.path) == ["third.txt"])

        let files = try await client.files(from: mainOID, to: head.oid)
        #expect(files.values.map(\.path).sorted() == ["extra.txt", "hello.txt", "third.txt"])
        let helloDiff = try await client.rangeFileDiff(base: mainOID, head: head.oid, path: "hello.txt")
        let lines = helloDiff.hunks.flatMap(\.lines).map(\.text)
        #expect(lines.contains("one"))
        #expect(lines.contains("feature"))
        #expect(!lines.contains("main"))
    }

    @Test func unchangedTrackedFileHasNoDiff() async throws {
        let repo = try TemporaryRepo()
        try "one\n".write(to: repo.root.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
        try repo.git(["add", "kept.txt"])
        try repo.git(["commit", "-m", "init"])
        let client = GitClient(workingDirectory: repo.root.path)
        let diff = try await client.diff(path: "kept.txt", staged: false)
        #expect(diff.isEmpty)
    }

    @Test func stashNamesEachChangedFile() async throws {
        let repo = try TemporaryRepo()
        let tracked = repo.root.appendingPathComponent("tracked.txt")
        try "one\n".write(to: tracked, atomically: true, encoding: .utf8)
        try repo.git(["add", "tracked.txt"])
        try repo.git(["commit", "-m", "init"])
        try "one\ntwo\n".write(to: tracked, atomically: true, encoding: .utf8)
        try "brand\n".write(to: repo.root.appendingPathComponent("brand new.txt"), atomically: true, encoding: .utf8)
        let client = GitClient(workingDirectory: repo.root.path)
        try await client.stashPush(message: "demo", includeUntracked: true)

        let ref = try #require(try await client.stashes().first?.ref)
        let files = try await client.stashFiles(ref)
        #expect(files.values.map(\.path).sorted() == ["brand new.txt", "tracked.txt"])

        let trackedDiff = try await client.stashFileDiff(ref: ref, path: "tracked.txt")
        #expect(trackedDiff.hunks.contains { hunk in
            hunk.lines.contains { $0.kind == .addition && $0.text == "two" }
        })
        let untrackedDiff = try await client.stashFileDiff(ref: ref, path: "brand new.txt")
        #expect(untrackedDiff.hunks.contains { hunk in
            hunk.lines.contains { $0.kind == .addition && $0.text == "brand" }
        })
    }

    @Test func checkIgnoreFollowsGitignoreAndKeepsTrackedFiles() async throws {
        let repo = try TemporaryRepo()
        try "secret.txt\n".write(to: repo.root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try repo.git(["add", ".gitignore"])
        try repo.git(["commit", "-m", "ignore"])
        let client = GitClient(workingDirectory: repo.root.path)
        let ignored = try await client.ignored(among: ["secret.txt", "keep.txt"])
        #expect(ignored.contains("secret.txt"))
        #expect(!ignored.contains("keep.txt"))

        try "tracked\n".write(to: repo.root.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try repo.git(["add", "-f", "secret.txt"])
        try repo.git(["commit", "-m", "force"])
        let tracked = try await client.ignored(among: ["secret.txt"])
        #expect(!tracked.contains("secret.txt"))
    }

    @Test func historyPagesBranchesCheckoutAndFileVersions() async throws {
        let repo = try TemporaryRepo()
        let file = repo.root.appendingPathComponent("hello.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        try repo.git(["add", "hello.txt"])
        try repo.git(["commit", "-m", "first"])
        try "two\n".write(to: file, atomically: true, encoding: .utf8)
        try repo.git(["add", "hello.txt"])
        try repo.git(["commit", "-m", "second"])
        try "three\n".write(to: file, atomically: true, encoding: .utf8)
        try repo.git(["add", "hello.txt"])
        try repo.git(["commit", "-m", "third"])
        try repo.git(["branch", "feature"])

        let client = GitClient(workingDirectory: repo.root.path)
        let firstPage = try await client.log(skip: 0, limit: 2)
        #expect(firstPage.commits.count == 2)
        #expect(firstPage.hasMore)
        let secondPage = try await client.log(skip: 2, limit: 2)
        #expect(secondPage.commits.count == 1)
        #expect(!secondPage.hasMore)
        #expect(secondPage.commits[0].subject == "first")

        let branches = try await client.branches()
        #expect(branches.contains { $0.name == "feature" && !$0.isCurrent })
        try await client.switchBranch("feature")
        let switched = try await client.head()
        #expect(switched.name == "feature")
        #expect(!switched.detached)

        let missing = await #expect(throws: GitFailure.self) {
            try await client.switchBranch("no-such-branch")
        }
        #expect(missing != nil)

        try await client.detach(oid: switched.oid)
        let detached = try await client.head()
        #expect(detached.detached)

        let history = try await client.fileLog(path: "hello.txt", skip: 0, limit: 10)
        let oldest = try #require(history.commits.last)
        let blob = try await client.file(at: oldest.oid, path: "hello.txt")
        #expect(blob.text.contains("one"))
        let parent = try await client.fileParentDiff(rev: history.commits[0].oid, path: "hello.txt")
        #expect(!parent.binary)
        try await client.stage(from: oldest.oid, paths: ["hello.txt"])
        let restored = try await client.status()
        #expect(restored.files.contains { $0.path == "hello.txt" && $0.hasStaged })

        let found = try await client.searchCommits(query: "second")
        #expect(found.values.contains { $0.subject == "second" })
        let paths = try await client.searchPaths(query: "hello")
        #expect(paths.values == ["hello.txt"])
        let hits = try await client.searchContent(query: "three")
        #expect(hits.values.contains { $0.path == "hello.txt" })
    }

    @Test func stageSelectedLinesWithinAHunk() async throws {
        let repo = try TemporaryRepo()
        let file = repo.root.appendingPathComponent("lines.txt")
        try "alpha\nbeta\ngamma\n".write(to: file, atomically: true, encoding: .utf8)
        try repo.git(["add", "lines.txt"])
        try repo.git(["commit", "-m", "base"])
        try "alpha\nBETA\nGAMMA\n".write(to: file, atomically: true, encoding: .utf8)

        let client = GitClient(workingDirectory: repo.root.path)
        let diff = try await client.diff(path: "lines.txt", staged: false)
        let hunk = try #require(diff.hunks.first)
        let selected = Set(hunk.lines.filter { $0.text == "beta" || $0.text == "BETA" }.map(\.id))
        let patch = try #require(DiffLinePatch.make(document: diff, selectedIDs: selected))
        try await client.apply(patch: patch, cached: true, reverse: false)

        let staged = try await client.diff(path: "lines.txt", staged: true)
        #expect(staged.hunks.contains { $0.lines.contains { $0.text == "BETA" } })
        #expect(!staged.hunks.contains { $0.lines.contains { $0.text == "GAMMA" } })
        let unstaged = try await client.diff(path: "lines.txt", staged: false)
        #expect(unstaged.hunks.contains { $0.lines.contains { $0.text == "GAMMA" } })

        let stagedLines = staged.hunks.flatMap(\.lines)
        let unstageIDs = Set(stagedLines.filter { $0.text == "BETA" || $0.text == "beta" }.map(\.id))
        let reverse = try #require(DiffLinePatch.make(document: staged, selectedIDs: unstageIDs))
        try await client.apply(patch: reverse, cached: true, reverse: true)
        let cleared = try await client.diff(path: "lines.txt", staged: true)
        #expect(!cleared.hunks.contains { $0.lines.contains { $0.text == "BETA" } })
    }

    @Test func renameDeleteRebaseAndMatchRemote() async throws {
        let repo = try TemporaryRepo()
        let file = repo.root.appendingPathComponent("hello.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        try repo.git(["add", "hello.txt"])
        try repo.git(["commit", "-m", "first"])

        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("gitsprout-remote-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: remote) }
        try repo.git(["init", "--bare", remote.path])
        try repo.git(["remote", "add", "origin", remote.path])
        try repo.git(["push", "-u", "origin", "main"])

        let other = try TemporaryRepo()
        try other.git(["remote", "add", "origin", remote.path])
        try other.git(["fetch", "origin"])
        try other.git(["checkout", "-B", "main", "origin/main"])
        try "remote\n".write(to: other.root.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
        try other.git(["add", "remote.txt"])
        try other.git(["commit", "-m", "from-remote"])
        try other.git(["push", "origin", "main"])

        let localFile = repo.root.appendingPathComponent("local.txt")
        try "local\n".write(to: localFile, atomically: true, encoding: .utf8)
        try repo.git(["add", "local.txt"])
        try repo.git(["commit", "-m", "from-local"])

        let client = GitClient(workingDirectory: repo.root.path)
        let main = try #require(try await client.branches().first { $0.name == "main" })
        #expect(main.isCurrent)
        #expect(main.upstream == "origin/main")
        #expect(main.remoteName == "origin")

        try await client.renameBranch("main", to: "trunk")
        #expect(try await client.head().name == "trunk")
        try await client.renameBranch("trunk", to: "main")

        try repo.git(["branch", "extra"])
        try await client.deleteBranch("extra")
        #expect(try await client.branches().contains { $0.name == "extra" } == false)
        await #expect(throws: GitFailure.self) {
            try await client.deleteBranch("main")
        }

        try await client.rebase(branch: "main", onto: "origin/main", remote: "origin")
        let rebased = try await client.log(skip: 0, limit: 3)
        #expect(Array(rebased.commits.prefix(2).map(\.subject)) == ["from-local", "from-remote"])

        try repo.git(["branch", "side"])
        try await client.matchRemote(branch: "side", upstream: "origin/main", remote: "origin", isCurrent: false)
        let side = try #require(try await client.branches().first { $0.name == "side" })
        let origin = try #require(try await client.branches().first { $0.name == "main" })
        #expect(side.oid != origin.oid)

        try "after\n".write(to: file, atomically: true, encoding: .utf8)
        try repo.git(["add", "hello.txt"])
        try repo.git(["commit", "-m", "after"])
        try await client.matchRemote(branch: "main", upstream: "origin/main", remote: "origin", isCurrent: true)
        let matched = try await client.log(skip: 0, limit: 1)
        #expect(matched.commits.first?.subject == "from-remote")
        #expect(try String(contentsOf: file, encoding: .utf8) == "one\n")
        #expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("remote.txt").path))
        #expect(!FileManager.default.fileExists(atPath: localFile.path))
        let resetSide = try #require(try await client.branches().first { $0.name == "side" })
        let resetMain = try #require(try await client.branches().first { $0.name == "main" })
        #expect(resetSide.oid == resetMain.oid)
    }

    @Test func amendAddsStagedChangesAndKeepsTheEditedMessage() async throws {
        let repo = try TemporaryRepo()
        let file = repo.root.appendingPathComponent("hello.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        try repo.git(["add", "hello.txt"])
        try repo.git(["commit", "-m", "subject", "-m", "body line"])

        let client = GitClient(workingDirectory: repo.root.path)
        #expect(try await client.headCommitMessage() == "subject\n\nbody line")
        let before = try await client.head()

        try "two\n".write(to: file, atomically: true, encoding: .utf8)
        try await client.stage(paths: ["hello.txt"])
        try await client.commit(message: "subject\n\nbody edited", amend: true)

        let after = try await client.head()
        #expect(after.oid != before.oid)
        #expect(try await client.headCommitMessage() == "subject\n\nbody edited")
        let page = try await client.log(skip: 0, limit: 5)
        #expect(page.commits.count == 1)
        #expect(page.commits[0].subject == "subject")
        #expect(page.commits[0].body == "body edited")
        #expect(page.commits[0].parents.isEmpty)
    }

    @Test func commitSeparatesTheSubjectFromTheBody() async throws {
        let repo = try TemporaryRepo()
        let file = repo.root.appendingPathComponent("hello.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        try repo.git(["add", "hello.txt"])
        let client = GitClient(workingDirectory: repo.root.path)
        try await client.commit(message: "subject\nbody line\nmore", amend: false)
        #expect(try await client.headCommitMessage() == "subject\n\nbody line\nmore")
        let page = try await client.log(skip: 0, limit: 1)
        #expect(page.commits[0].subject == "subject")
        #expect(page.commits[0].body == "body line\nmore")
    }

    @Test func stagedDiffTextIncludesOnlyTheIndex() async throws {
        let repo = try TemporaryRepo()
        let file = repo.root.appendingPathComponent("hello.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        try repo.git(["add", "hello.txt"])
        let client = GitClient(workingDirectory: repo.root.path)
        let staged = try await client.stagedDiffText()
        #expect(staged.contains("hello.txt"))
        #expect(staged.contains("+one"))

        try repo.git(["commit", "-m", "add"])
        try "two\n".write(to: file, atomically: true, encoding: .utf8)
        let unstaged = try await client.stagedDiffText()
        #expect(unstaged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        try repo.git(["add", "hello.txt"])
        let updated = try await client.stagedDiffText()
        #expect(updated.contains("+two"))
        #expect(!updated.contains("+one"))
    }

    @Test func pushSendsFastForwardAndOverwritesAfterAmend() async throws {
        let repo = try TemporaryRepo()
        let file = repo.root.appendingPathComponent("hello.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        try repo.git(["add", "hello.txt"])
        try repo.git(["commit", "-m", "first"])

        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("gitsprout-remote-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: remote) }
        try repo.git(["init", "--bare", remote.path])
        try repo.git(["remote", "add", "origin", remote.path])
        try repo.git(["push", "-u", "origin", "main"])

        try "two\n".write(to: file, atomically: true, encoding: .utf8)
        try repo.git(["add", "hello.txt"])
        try repo.git(["commit", "-m", "second"])

        let client = GitClient(workingDirectory: repo.root.path)
        #expect(try await client.pushDivergence(branch: "main", upstream: "origin/main") == .fastForward)
        try await client.push(remote: "origin", branch: "main", forceWithLease: false, setUpstream: false)

        try repo.git(["reset", "--hard", "HEAD~1"])
        #expect(try await client.pushDivergence(branch: "main", upstream: "origin/main") == .behind)
        try repo.git(["reset", "--hard", "origin/main"])
        try repo.git(["commit", "--amend", "-m", "second amended"])
        #expect(try await client.pushDivergence(branch: "main", upstream: "origin/main") == .diverged)
        await #expect(throws: GitFailure.self) {
            try await client.push(remote: "origin", branch: "main", forceWithLease: false, setUpstream: false)
        }
        try await client.push(remote: "origin", branch: "main", forceWithLease: true, setUpstream: false)
        let tip = try await client.log(skip: 0, limit: 1)
        #expect(tip.commits.first?.subject == "second amended")
        try repo.git(["fetch", "origin"])
        #expect(try await client.pushDivergence(branch: "main", upstream: "origin/main") == .upToDate)
    }

    @Test func remoteLinkPrefersTheBranchRemoteThenOrigin() async throws {
        let repo = try TemporaryRepo()
        try repo.git(["remote", "add", "origin", "https://github.com/example/app.git"])
        try repo.git(["remote", "add", "upstream", "git@gitlab.com:group/app.git"])
        let client = GitClient(workingDirectory: repo.root.path)
        let origin = try await client.remoteLink(preferredRemote: nil)
        #expect(origin?.name == "origin")
        #expect(origin?.browserURL?.absoluteString == "https://github.com/example/app")
        let upstream = try await client.remoteLink(preferredRemote: "upstream")
        #expect(upstream?.name == "upstream")
        #expect(upstream?.browserURL?.absoluteString == "https://gitlab.com/group/app")

        try repo.git(["remote", "set-url", "origin", repo.root.appendingPathComponent("missing.git").path])
        let local = try await client.remoteLink(preferredRemote: "origin")
        #expect(local?.name == "origin")
        #expect(local?.browserURL == nil)

        let empty = try TemporaryRepo()
        let none = try await GitClient(workingDirectory: empty.root.path).remoteLink(preferredRemote: nil)
        #expect(none == nil)
    }

    @Test func resolveRepositoryRejectsPlainFolders() async throws {
        let repo = try TemporaryRepo()
        let root = try await GitClient.resolveRepository(at: repo.root.path)
        #expect(URL(fileURLWithPath: root).resolvingSymlinksInPath().path == repo.root.resolvingSymlinksInPath().path)

        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("gitsprout-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        await #expect(throws: GitFailure.self) {
            try await GitClient.resolveRepository(at: plain.path)
        }
    }

    @Test func imageDiffLoadsBothVersions() async throws {
        let repo = try TemporaryRepo()
        let before = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        let after = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        let file = repo.root.appendingPathComponent("pixel.png")
        try before.write(to: file)
        try repo.git(["add", "pixel.png"])
        try repo.git(["commit", "-m", "add image"])

        try after.write(to: file)
        let client = GitClient(workingDirectory: repo.root.path)
        let unstaged = try await client.diff(path: "pixel.png", staged: false)
        #expect(unstaged.binary)
        #expect(unstaged.beforeImage == .data(before))
        #expect(unstaged.afterImage == .data(after))

        try await client.stage(paths: ["pixel.png"])
        let staged = try await client.diff(path: "pixel.png", staged: true)
        #expect(staged.beforeImage == .data(before))
        #expect(staged.afterImage == .data(after))

        try repo.git(["commit", "-m", "change image"])
        let tip = try #require(try await client.log(skip: 0, limit: 1).commits.first)
        let shown = try await client.showFileDiff(oid: tip.oid, path: "pixel.png")
        #expect(shown.beforeImage == .data(before))
        #expect(shown.afterImage == .data(after))
        let blob = try await client.file(at: tip.oid, path: "pixel.png")
        #expect(blob.image == after)

        try FileManager.default.removeItem(at: file)
        let deleted = try await client.diff(path: "pixel.png", staged: false)
        #expect(deleted.beforeImage == .data(after))
        #expect(deleted.afterImage == .absent)

        let extra = repo.root.appendingPathComponent("new.png")
        try before.write(to: extra)
        let untracked = try await client.diff(path: "new.png", staged: false)
        #expect(untracked.beforeImage == .absent)
        #expect(untracked.afterImage == .data(before))

        try Data([0x00, 0x01, 0x02]).write(to: repo.root.appendingPathComponent("blob.bin"))
        try repo.git(["add", "blob.bin"])
        try repo.git(["commit", "-m", "bin"])
        try Data([0x00, 0x01, 0x03]).write(to: repo.root.appendingPathComponent("blob.bin"))
        let binary = try await client.diff(path: "blob.bin", staged: false)
        #expect(binary.binary)
        #expect(!binary.hasImageDiff)
    }

    @Test func avifDiffIsShownAsAnImage() async throws {
        let repo = try TemporaryRepo()
        let avif = try #require(Data(base64Encoded: """
        AAAAIGZ0eXBhdmlmAAAAAGF2aWZtaWYxbWlhZk1BMUEAAAD2bWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAcGljdAAAAAAAAAAAAAAAAAAAAAAOcGl0bQAAAAAAAQAAAB5pbG9jAAAAAEQAAAEAAQAAAAEAAAEeAAAALQAAAChpaW5mAAAAAAABAAAAGmluZmUCAAAAAAEAAGF2MDFDb2xvcgAAAAB1aXBycAAAAFVpcGNvAAAAFGlzcGUAAAAAAAAAZAAAAGQAAAAQcGl4aQAAAAADCAgIAAAADGF2MUOBIAAAAAAAE2NvbHJuY2x4AAEAAgAAgAAAAApsc2Vs//8AAAAYaXBtYQAAAAAAAAABAAEFAQKDBIUAAAA1bWRhdBIACgk4GbHjYQECAJAyHhAAALRRs+wBOmIEokSqdl9WqdzBQ1Jjg0yEMYAwIA==
        """, options: .ignoreUnknownCharacters))
        try avif.write(to: repo.root.appendingPathComponent("pixel.avif"))
        let client = GitClient(workingDirectory: repo.root.path)
        let diff = try await client.diff(path: "pixel.avif", staged: false)
        #expect(diff.beforeImage == .absent)
        #expect(diff.afterImage == .data(avif))
        #expect(NSImage(data: avif) != nil)
    }

    @Test func pdfDiffShowsEveryPage() async throws {
        func makePDF(pages: Int) -> Data {
            let document = PDFDocument()
            for _ in 0..<pages {
                let image = NSImage(size: NSSize(width: 24, height: 16), flipped: false) { rect in
                    NSColor.white.setFill()
                    rect.fill()
                    return true
                }
                document.insert(PDFPage(image: image)!, at: document.pageCount)
            }
            return document.dataRepresentation()!
        }

        let first = makePDF(pages: 1)
        let second = makePDF(pages: 2)
        #expect(ImageDiffView.images(from: second).count == 2)
        #expect(ImagePaths.isImage("Notes.PDF"))
        #expect(ImagePaths.isImage("photo.psd"))
        #expect(ImagePaths.isImage("plate.exr"))
        #expect(!ImagePaths.isImage("notes.txt"))

        let repo = try TemporaryRepo()
        let file = repo.root.appendingPathComponent("notes.pdf")
        try first.write(to: file)
        try repo.git(["add", "notes.pdf"])
        try repo.git(["commit", "-m", "add pdf"])
        try second.write(to: file)
        let client = GitClient(workingDirectory: repo.root.path)
        let diff = try await client.diff(path: "notes.pdf", staged: false)
        #expect(diff.beforeImage == .data(first))
        #expect(diff.afterImage == .data(second))
    }
}

final class TemporaryRepo {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitsprout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "user.name", "Test User"])
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func git(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let group = DispatchGroup()
        var errData = Data()
        group.enter()
        DispatchQueue.global().async {
            _ = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        try process.run()
        process.waitUntilExit()
        group.wait()
        if process.terminationStatus != 0 {
            throw GitFailure(message: String(decoding: errData, as: UTF8.self))
        }
    }
}
