import Darwin
import Darwin.POSIX.fcntl
import Foundation

/// Best-effort raw file-descriptor writer for diagnostic output on MCP stdio
/// transports.
///
/// Foundation's `FileHandle.write(_:)` raises an Objective-C
/// `NSFileHandleOperationException` when the descriptor is closed or the pipe
/// is broken, and Swift `do/catch` cannot intercept that exception, so a
/// failed diagnostic write aborts the whole process. Transport diagnostics
/// must never be able to crash the MCP helper, so this writer uses
/// `Darwin.write` directly, loops on partial writes, and silently drops the
/// payload when the destination is unavailable (`EPIPE`, `EBADF`, `EINVAL`,
/// or any other write failure).
public enum BestEffortStderrWriter {
    /// Writes `data` to `descriptor`, returning `true` only when every byte
    /// was delivered. Never throws and never raises: any failure other than
    /// an interrupted write drops the remaining payload.
    @discardableResult
    public static func write(_ data: Data, to descriptor: Int32 = STDERR_FILENO) -> Bool {
        guard descriptor >= 0 else { return false }
        guard !data.isEmpty else { return true }
        // Suppress SIGPIPE on this descriptor so a peer-closed pipe surfaces
        // as EPIPE from write(2) instead of terminating the process. Failure
        // is acceptable: the write below still fails softly.
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(descriptor, baseAddress + offset, rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }
}
