import Foundation
import Testing
@testable import Oh_My_Code

struct ProcessIOTests {
    private func shell(_ command: String) -> (Process, Pipe, Pipe) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        return (process, output, error)
    }

    @Test func readsBothStreamsAndTheStatus() throws {
        let (process, output, error) = shell("echo out; echo err >&2; exit 3")
        let result = try ProcessIO.run(process, output: output, error: error)
        #expect(result.output == Data("out\n".utf8) && result.error == Data("err\n".utf8) && result.status == 3)

        // More than a pipe holds, on both streams at once: neither blocks the other.
        let (big, bigOutput, bigError) = shell("head -c 300000 /dev/zero; head -c 300000 /dev/zero >&2")
        let large = try ProcessIO.run(big, output: bigOutput, error: bigError)
        #expect(large.output.count == 300_000 && large.error.count == 300_000 && large.status == 0)

        let (signalled, signalledOutput, _) = shell("kill -9 $$")
        #expect(try ProcessIO.run(signalled, output: signalledOutput, error: nil).status == 128 + 9)
    }

    @Test func endsWhenTheCommandExitsAndStopsSlowOnes() throws {
        // Something it started keeps the output open: the command's exit still ends it.
        let (daemon, daemonOutput, _) = shell("echo hi; sleep 20 & exit 0")
        var started = ContinuousClock.now
        let result = try ProcessIO.run(daemon, output: daemonOutput, error: nil)
        #expect(result.output == Data("hi\n".utf8) && ContinuousClock.now - started < .seconds(5))

        let (slow, slowOutput, _) = shell("sleep 30")
        started = ContinuousClock.now
        #expect(try ProcessIO.run(slow, output: slowOutput, error: nil, timeout: .milliseconds(300)).status == 128 + 9)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func manyCommandsAtOnceAllFinish() async throws {
        // Far more than there are threads: each waits on its own thread, needing no other.
        let statuses = await withTaskGroup(of: Int32.self) { group in
            for index in 0..<200 {
                group.addTask {
                    let (process, output, error) = shell("echo \(index); exit \(index % 3)")
                    return (try? ProcessIO.run(process, output: output, error: error).status) ?? -1
                }
            }
            return await group.reduce(into: [Int32]()) { $0.append($1) }
        }
        #expect(statuses.count == 200 && statuses.sorted() == (0..<200).map { Int32($0 % 3) }.sorted())
    }

    /// Commands given input (a blame of every open file at once) finish however many run at
    /// once: writing the input must not wait for a dispatch thread, as there may be none.
    @Test(.timeLimit(.minutes(1))) func manyCommandsWithInputAtOnceAllFinish() async {
        let folder = FileManager.default.temporaryDirectory
        let count = ProcessInfo.processInfo.activeProcessorCount * 4
        let outputs = await withTaskGroup(of: Data?.self) { group in
            for index in 0..<count {
                group.addTask(priority: .utility) {
                    Git.run(["hash-object", "--stdin"], in: folder, input: Data("text \(index)\n".utf8))
                }
            }
            return await group.reduce(into: [Data?]()) { $0.append($1) }
        }
        #expect(outputs.count == count && outputs.allSatisfy { $0?.count == 41 })
    }
}
