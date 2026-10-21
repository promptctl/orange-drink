import Foundation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The deadline is the bound: a silent peer and a trickling peer both end as a typed timeout.
// Plain sockets only; the TLS callbacks run the same clock check on every return.
@Suite(.serialized) struct TimedSocketDeadline {
    static func pair() throws -> (TimedSocket, Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw IPhoneReadError.socket(errno: errno) }
        return (try TimedSocket(fd: fds[0]), fds[1])
    }

    @Test(.timeLimit(.minutes(1)))
    func silentPeerEndsAsATimeout() throws {
        let (socket, peer) = try Self.pair()
        defer { close(peer) }
        #expect(throws: IPhoneReadError.timeout) {
            try socket.readExact(4, until: Deadline(after: .milliseconds(1500)))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func peerTricklingBytesCannotExtendThePastTheDeadline() throws {
        let (socket, peer) = try Self.pair()
        let stop = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let trickle = Thread {
            // Writes until the test asks it to stop, then signals it is done, so the peer fd is never reused under it.
            while stop.wait(timeout: .now() + 0.4) == .timedOut {
                if write(peer, [0x41], 1) != 1 { break }
            }
            finished.signal()
        }
        trickle.start()
        defer {
            stop.signal()
            finished.wait()
            close(peer)
        }
        #expect(throws: IPhoneReadError.timeout) {
            try socket.readExact(100, until: Deadline(after: .milliseconds(2000)))
        }
    }
}
