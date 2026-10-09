import Foundation
import Testing
@testable import Desk

@Test func readOnlyProgramsNeverAsk() {
    let commands = [
        "ls -la",
        "cat file",
        "head -n 5 file",
        "tail -n 5 file",
        "grep -n foo file",
        "egrep foo file",
        "rg foo",
        "wc -l file",
        "pwd",
        "cd /tmp && pwd",
        "echo hi",
        "printf hi",
        "file notes.md",
        "stat notes.md",
        "du -sh .",
        "df -h",
        "which git",
        "type git",
        "whoami",
        "date",
        "tree",
        "sort file",
        "uniq file",
        "cut -d, -f1 file",
        "tr a b",
        "basename /a/b",
        "dirname /a/b",
        "realpath .",
        "jq . file",
        "diff a b",
        "cmp a b",
        "ls && cat file | head",
        "/usr/bin/ls -la",
    ]
    for command in commands {
        #expect(ReadOnlyShell.isEntirelyReadOnly(command), "\(command)")
    }
}

@Test func findAndGitReadOnlyEdges() {
    let allowed = [
        "find . -name '*.swift'",
        "find . -type f -print",
        "find . -printf '%p\n'",
        "git",
        "git status",
        "git status -sb",
        "git log -1 --oneline",
        "git diff --stat",
        "git show HEAD",
        "git show HEAD:README.md",
        "git branch",
        "git branch -vv",
        "git branch -a",
        "git branch -av",
        "git branch --show-current",
        "git branch --contains HEAD",
        "git rev-parse HEAD",
        "git rev-parse --abbrev-ref HEAD",
        "git ls-files",
        "git ls-files --others",
        "git blame file",
        "git blame -L 1,10 file",
        "git remote",
        "git remote -v",
        "git remote --verbose",
        "git status && git diff",
        "ls && git status",
    ]
    for command in allowed {
        #expect(ReadOnlyShell.isEntirelyReadOnly(command), "\(command)")
    }

    let ask = [
        "find . -delete",
        "find . -exec rm {} \\;",
        "find . -execdir rm {} +",
        "find . -ok rm {} \\;",
        "find . -okdir rm {} \\;",
        "find . -fprint out",
        "find . -fprint0 out",
        "find . -fprintf out %p",
        "find . -fls out",
        "find . -name x -delete",
        "git commit -m x",
        "git push",
        "git branch -d foo",
        "git branch -D foo",
        "git branch feature",
        "git branch -m old new",
        "git branch --set-upstream-to=origin/main",
        "git branch -ad",
        "git remote add origin url",
        "git remote show origin",
        "git diff --output=out.patch",
        "git diff --output out.patch",
        "git show --output=out.patch",
        "git status && git commit",
        "ls && find . -delete",
        "ls && git commit",
    ]
    for command in ask {
        #expect(!ReadOnlyShell.isEntirelyReadOnly(command), "\(command)")
    }
}

@Test func writesAndWrappersStillAsk() {
    let ask = [
        "sed -i '' file",
        "sed 's/a/b/' file",
        "rm file",
        "tee file",
        "xargs rm",
        "env ls",
        "sh -c ls",
        "bash -c ls",
        "ls > file",
        "ls > /tmp/x",
        "ls >> file",
        "ls >>/dev/null",
        "ls 3>/dev/null",
        "ls >/dev/nullify",
        "echo $(date)",
        "echo `date`",
        "cat <(ls)",
        "ls && rm file",
        "ls2>/dev/null",
    ]
    for command in ask {
        #expect(!ReadOnlyShell.isEntirelyReadOnly(command), "\(command)")
        #expect(command.contains(">") || command.contains("$(") || command.contains("`") || command.contains("<(") || ApprovalRule.shellPrograms(command) != nil)
    }
}

@Test func harmlessRedirectionsStillNameThePrograms() {
    let forms = [
        "2>&1",
        "1>&2",
        ">&2",
        "2>/dev/null",
        ">/dev/null",
        "&>/dev/null",
        "1>/dev/null",
        "2> /dev/null",
        "> /dev/null",
        "&> /dev/null",
        "1> /dev/null",
    ]
    for form in forms {
        #expect(ApprovalRule.shellPrograms("ls \(form)") == ["ls"], "\(form)")
        #expect(ReadOnlyShell.isEntirelyReadOnly("ls \(form)"), "\(form)")
    }
    #expect(ApprovalRule.shellPrograms("ls>/dev/null") == ["ls"])
    #expect(ReadOnlyShell.isEntirelyReadOnly("ls>/dev/null"))
    #expect(ReadOnlyShell.isEntirelyReadOnly("echo hello2>/dev/null"))
    #expect(ApprovalRule.shellPrograms("npm test 2>&1") == ["npm"])
    #expect(ApprovalRule.shellPrograms("npm test > out.txt") == nil)
    #expect(ApprovalRule.shellPrograms("ls > file") == nil)
    #expect(ApprovalRule.shellPrograms("ls >> file") == nil)
    #expect(ApprovalRule.shellPrograms("cat <(ls)") == nil)
    #expect(ApprovalRule.shellPrograms("echo $(date)") == nil)
    #expect(ApprovalRule.shellPrograms("echo `date`") == nil)
}

@Test func variableReferencesDoNotBlockAReadOnlyCommand() {
    #expect(ApprovalRule.shellPrograms(#"D=/some/path cat "$D/file""#) == ["cat"])
    #expect(ReadOnlyShell.isEntirelyReadOnly(#"D=/some/path cat "$D/file""#))
    #expect(ApprovalRule.shellPrograms("D=/tmp echo $D") == ["echo"])
    #expect(ReadOnlyShell.isEntirelyReadOnly("D=/tmp echo $D"))
    #expect(ReadOnlyShell.isEntirelyReadOnly(#"D=/tmp cat "$D/file" 2>&1"#))
    #expect(ApprovalRule.shellPrograms("echo ${D}") == ["echo"])
    #expect(!ReadOnlyShell.isEntirelyReadOnly(#"D=/tmp cat "$D/file" > out"#))
    #expect(ApprovalRule.shellPrograms(#"D=/tmp cat "$D/file" > out"#) == nil)
}

@Test func answeredAllowsLeaveTheTranscriptAndDenialsStay() {
    let user = Message(author: .user, body: "go")
    var once = Message(author: .notice, body: "Run cat file")
    once.approval = ApprovalRecord(agent: .claude, title: "Run cat file", detail: "cat file", rule: "Bash(cat:*)", decision: .allowOnce)
    var denied = Message(author: .notice, body: "Run rm file")
    denied.approval = ApprovalRecord(agent: .claude, title: "Run rm file", detail: "rm file", rule: "Bash(rm:*)", decision: .deny)
    var threadAllow = Message(author: .notice, body: "Run jq .")
    threadAllow.approval = ApprovalRecord(agent: .codex, title: "Run jq .", detail: "jq .", rule: "Bash(jq:*)", decision: .allowInThread)
    var always = Message(author: .notice, body: "Search the web")
    always.approval = ApprovalRecord(agent: .claude, title: "Search the web", detail: nil, rule: "WebSearch", decision: .allowAlways)
    var waiting = Message(author: .notice, body: "Run touch x")
    waiting.approval = ApprovalRecord(agent: .claude, title: "Run touch x", detail: "touch x", rule: "Bash(touch:*)", decision: nil)
    let reply = Message(author: .agent(.claude), body: "done", createdAt: .now)
    var stored = reply
    stored.steps = [WorkStep.approval(once.approval!, id: once.id, at: once.createdAt)]

    let fresh = TranscriptRows.rows(in: [user, once, denied, stored])
    #expect(fresh.map(\.message.id) == [user.id, denied.id, stored.id])
    #expect(fresh.last?.approvalSteps.isEmpty == true)
    #expect(fresh.last?.message.steps.map(\.title) == ["Allowed once: Run cat file"])
    #expect(fresh.last?.message.steps.first?.kind == .approval)
    #expect(fresh.last?.message.steps.first?.state == .done)

    let legacy = TranscriptRows.rows(in: [once, threadAllow, always, denied, waiting, reply])
    #expect(legacy.map(\.message.id) == [denied.id, waiting.id, reply.id])
    #expect(legacy.last?.approvalSteps.map(\.title) == [
        "Allowed once: Run cat file",
        "Allowed in this thread: Run jq .",
        "Always allowed: Search the web",
    ])

    let waitingAfter = TranscriptRows.rows(in: [reply, waiting])
    #expect(waitingAfter.map(\.message.id) == [reply.id, waiting.id])
    #expect(waitingAfter.allSatisfy { $0.approvalSteps.isEmpty })

    let orphan = TranscriptRows.rows(in: [once])
    #expect(orphan.map(\.message.id) == [once.id])
    #expect(orphan[0].approvalSteps.isEmpty)
}

@Test func readOnlyProgramsWithWritingOrRunningFlagsStillAsk() {
    #expect(!ReadOnlyShell.isEntirelyReadOnly("sort -o out.txt in.txt"))
    #expect(!ReadOnlyShell.isEntirelyReadOnly("sort --output=out.txt in.txt"))
    #expect(!ReadOnlyShell.isEntirelyReadOnly("tree -o listing.txt"))
    #expect(!ReadOnlyShell.isEntirelyReadOnly("rg --pre ./script.sh needle"))
    #expect(ReadOnlyShell.isEntirelyReadOnly("sort -n in.txt | uniq -c"))
    #expect(ReadOnlyShell.isEntirelyReadOnly("rg -n needle src"))
}

@Test func shellTricksThatHideWritesStillAsk() {
    #expect(ApprovalRule.shellPrograms("ls & rm file") == nil)
    #expect(ApprovalRule.shellPrograms("ls 2>&1 | head") == ["ls", "head"])
    #expect(!ReadOnlyShell.isEntirelyReadOnly("find . -d\\elete"))
    #expect(!ReadOnlyShell.isEntirelyReadOnly("FLAG=-delete; find . $FLAG"))
    #expect(!ReadOnlyShell.isEntirelyReadOnly("less '+!touch /tmp/probe' README.md"))
    #expect(!ReadOnlyShell.isEntirelyReadOnly("GIT_EXTERNAL_DIFF=/tmp/x git diff --ext-diff"))
    #expect(!ReadOnlyShell.isEntirelyReadOnly("git log -p --ext-diff"))
    #expect(!ReadOnlyShell.isEntirelyReadOnly("sort --compress-program=sh in.txt"))
    #expect(!ReadOnlyShell.isEntirelyReadOnly("file -C -m magic"))
    #expect(ReadOnlyShell.isEntirelyReadOnly("git diff HEAD~1 -- README.md"))
    #expect(!ReadOnlyShell.isEntirelyReadOnly("FOO=1 /usr/bin/git status"))
}
