import Foundation

/// Runs `wakil-connect --list --connection <name>` for an organisation, the way a session's
/// connection is started (`WAKIL_ORG`), and reads its one line. Cancelling the check ends the
/// process (Rule 4).
public struct WakilConnectLister: Sendable {
    let executable: URL

    public init(executable: URL) { self.executable = executable }

    public func list(org: String, name: String) async -> ConnectionListing {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--list", "--connection", name]
        var env = ProcessInfo.processInfo.environment
        env["WAKIL_ORG"] = org
        // The check asks nobody: no socket to ask.
        env.removeValue(forKey: "WAKIL_APPROVAL_SOCKET")
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let box = ProcessBox(process)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (k: CheckedContinuation<ConnectionListing, Never>) in
                Thread.detachNewThread {
                    do { try process.run() } catch {
                        k.resume(returning: .error("\(wakilConnectBinaryName): \(error.localizedDescription)"))
                        return
                    }
                    // Both pipes drained at once (`WakilCLICredentialsLookup` says why).
                    let errData = readConcurrently(err.fileHandleForReading)
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    let errBody = errData.wait()
                    process.waitUntilExit()
                    let listing = parseConnectionListing(data, exitCode: process.terminationStatus)
                    if case .error(let e) = listing, data.isEmpty {
                        let said = String(decoding: errBody, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        k.resume(returning: .error(said.isEmpty ? e : said))
                        return
                    }
                    k.resume(returning: listing)
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

/// The running check's process, so a cancel from another thread can end it.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}
