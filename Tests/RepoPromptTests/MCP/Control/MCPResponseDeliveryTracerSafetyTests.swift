import Darwin
import Foundation
import RepoPromptShared
import XCTest

/// Regression coverage for repoprompt-ce#157: diagnostic and progress stderr
/// writes during transport failure handling must never abort the MCP helper,
/// even when the host has already closed the pipe.
final class MCPResponseDeliveryTracerSafetyTests: XCTestCase {
    func testWriterDeliversAllBytesAcrossPartialWrites() throws {
        let pipe = try makePipe()
        // Larger than the kernel pipe buffer (64 KiB) so write(2) must return
        // short counts and the writer has to loop.
        let payload = Data(repeating: UInt8(ascii: "x"), count: 256 * 1024)

        let readQueue = DispatchQueue(label: "tracer-safety-test-reader")
        let readDone = expectation(description: "reader drained pipe")
        nonisolated(unsafe) var received = Data()
        readQueue.async {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while received.count < payload.count {
                let count = read(pipe.readFD, &buffer, buffer.count)
                guard count > 0 else { break }
                received.append(contentsOf: buffer[0 ..< count])
            }
            readDone.fulfill()
        }

        XCTAssertTrue(BestEffortStderrWriter.write(payload, to: pipe.writeFD))
        wait(for: [readDone], timeout: 10)
        close(pipe.readFD)
        close(pipe.writeFD)
        XCTAssertEqual(received, payload)
    }

    func testWriterDropsDataOnBrokenPipeWithoutRaising() throws {
        let writeFD = try makeBrokenPipeWriteEnd()
        defer { close(writeFD) }
        XCTAssertFalse(BestEffortStderrWriter.write(Data("dropped\n".utf8), to: writeFD))
    }

    func testWriterDropsDataOnClosedDescriptorWithoutRaising() throws {
        let pipe = try makePipe()
        close(pipe.readFD)
        close(pipe.writeFD)
        XCTAssertFalse(BestEffortStderrWriter.write(Data("dropped\n".utf8), to: pipe.writeFD))
    }

    func testTerminalEmitWithBrokenStderrSinkDoesNotAbort() throws {
        let writeFD = try makeBrokenPipeWriteEnd()
        defer { close(writeFD) }
        // Terminal events bypass the success-tracing gate, so this is the
        // exact release-build path that previously crashed in
        // FileHandle.writeData on a host disconnect.
        MCPResponseDeliveryTracer.emit(
            MCPResponseDeliveryTraceEvent(
                layer: "proxy_ledger",
                phase: "connection_terminal",
                terminalReason: "host_disconnected"
            ),
            to: writeFD
        )
    }

    func testRecordConnectionFailureWithFailingTraceOutputReturnsCleanly() async throws {
        let writeFD = try makeBrokenPipeWriteEnd()
        defer { close(writeFD) }

        let ledger = JSONRPCBridgeLedger(traceSink: { event in
            MCPResponseDeliveryTracer.emit(event, to: writeFD)
        })
        _ = try await ledger.beginConnection()
        let prepared = try await ledger.prepare(
            frame: line(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#),
            direction: .clientToServer
        )
        try await ledger.commit(prepared)

        // Protocol-active connection failure emits a terminal trace event;
        // with a broken sink it must return instead of crashing the process.
        let isTerminal = await ledger.recordConnectionFailure("host_disconnected")
        XCTAssertTrue(isTerminal)
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.terminalReason, "host_disconnected")
    }

    func testProgressWriteFailureDoesNotBypassLedgerAccounting() async throws {
        let writeFD = try makeBrokenPipeWriteEnd()
        defer { close(writeFD) }

        let ledger = JSONRPCBridgeLedger()
        _ = try await ledger.beginConnection()
        let progressFrame =
            line(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"t","progress":1}}"#)

        // Mirrors the BootstrapSocketProxy progress branch: the stderr write
        // fails best-effort and the writer returns normally, so forward(...)
        // must still commit the frame instead of aborting the transaction.
        let prepared = try await JSONRPCBridgeDelivery.forward(
            frame: progressFrame,
            direction: .serverToClient,
            ledger: ledger
        ) { framed in
            XCTAssertFalse(BestEffortStderrWriter.write(framed, to: writeFD))
        }
        XCTAssertEqual(prepared.messages.map(\.kind), [.notification])

        let snapshot = await ledger.snapshot()
        XCTAssertNil(snapshot.terminalReason)
        XCTAssertEqual(snapshot.pendingTransactionCount, 0)
        XCTAssertEqual(snapshot.activeRequestCount, 0)
        XCTAssertTrue(snapshot.hasForwardedProtocolFrame)
    }
}

private extension MCPResponseDeliveryTracerSafetyTests {
    func makePipe() throws -> (readFD: Int32, writeFD: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            throw XCTSkip("pipe(2) failed with errno \(errno)")
        }
        return (fds[0], fds[1])
    }

    func makeBrokenPipeWriteEnd() throws -> Int32 {
        let pipe = try makePipe()
        close(pipe.readFD)
        return pipe.writeFD
    }

    func line(_ string: String) -> Data {
        Data((string + "\n").utf8)
    }
}
