import Foundation
import Network

extension LoopbackMediaServer {

    /// The schedule a dripped body is written on: byte `n` is due at
    /// `started + pausedSeconds + n / bytesPerSecond`, where `pausedSeconds` sums the burst pauses
    /// already taken. Anchored rather than relative, so a slice that went out late does not push
    /// every later one back.
    struct Pacing {
        let bytesPerSecond: Int?
        let burst: BurstPattern?
        let started: Date
        var pausedSeconds: TimeInterval
    }

    /// One drip slice per call, then the next scheduled on the server queue when it is due. Stops
    /// quietly when a write fails (the client went away, or ``stop()`` cancelled the connection).
    func drip(_ body: Data, offset: Int, on connection: NWConnection, pacing: Pacing, finish: @escaping () -> Void) {
        guard offset < body.count else {
            finish()
            return
        }
        // ~20 ms of the rate per slice, at least 1 KiB; the whole remainder when unpaced.
        var sliceBytes = pacing.bytesPerSecond.map { max($0 / 50, 1024) } ?? body.count
        var nextPaused = pacing.pausedSeconds
        if let burst = pacing.burst, burst.burstBytes > 0 {
            // Never write across a burst boundary; the pause is taken after the slice that ends it.
            let intoBurst = offset % burst.burstBytes
            sliceBytes = min(sliceBytes, burst.burstBytes - intoBurst)
            if intoBurst + sliceBytes == burst.burstBytes { nextPaused += burst.pauseSeconds }
        }
        let end = min(offset + sliceBytes, body.count)
        let chunk = body.subdata(in: offset..<end)
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { return }
            self.lock.lock(); self._servedBytes += Int64(chunk.count); self.lock.unlock()
            var next = pacing
            next.pausedSeconds = nextPaused
            let paced = pacing.bytesPerSecond.map { Double(end) / Double($0) } ?? 0
            let due = pacing.started.addingTimeInterval(paced + nextPaused)
            let wait = max(due.timeIntervalSinceNow, 0)
            self.queue.asyncAfter(deadline: .now() + wait) {
                self.drip(body, offset: end, on: connection, pacing: next, finish: finish)
            }
        })
    }

    /// `body` as `Transfer-Encoding: chunked`, in 4 KiB chunks.
    static func chunked(_ body: Data) -> Data {
        var out = Data()
        var index = body.startIndex
        while index < body.endIndex {
            let end = body.index(index, offsetBy: 4096, limitedBy: body.endIndex) ?? body.endIndex
            out.append(Data("\(String(end - index, radix: 16))\r\n".utf8))
            out.append(body[index..<end])
            out.append(Data("\r\n".utf8))
            index = end
        }
        out.append(Data("0\r\n\r\n".utf8))
        return out
    }

    /// `data` as a gzip stream of stored (uncompressed) deflate blocks: valid to any inflater,
    /// larger than its input, and needing no compressor.
    public static func gzip(_ data: Data) -> Data {
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
        var offset = 0
        repeat {
            let count = min(0xffff, data.count - offset)
            let last: UInt8 = offset + count >= data.count ? 1 : 0
            out.append(contentsOf: [last, UInt8(count & 0xff), UInt8(count >> 8), UInt8(~count & 0xff), UInt8((~count >> 8) & 0xff)])
            out.append(data[data.startIndex + offset ..< data.startIndex + offset + count])
            offset += count
        } while offset < data.count
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        crc = ~crc
        for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((crc >> UInt32(shift)) & 0xff)) }
        let size = UInt32(truncatingIfNeeded: data.count)
        for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((size >> UInt32(shift)) & 0xff)) }
        return out
    }
}
