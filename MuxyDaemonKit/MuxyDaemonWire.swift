import Darwin
import Foundation

public enum DaemonWireError: Error, Equatable {
    case connectionClosed
    case frameTooLarge
    case writeFailed(String)
    case readFailed(String)
    case timeout
}

public struct DaemonFrame: Equatable, Sendable {
    public var type: DaemonFrameType
    public var payload: Data

    public init(type: DaemonFrameType, payload: Data) {
        self.type = type
        self.payload = payload
    }

    public static func control(_ message: DaemonControlMessage) throws -> DaemonFrame {
        let payload = try JSONEncoder.daemonWire.encode(message)
        return DaemonFrame(type: .control, payload: payload)
    }

    public func decodeControl() throws -> DaemonControlMessage {
        try JSONDecoder.daemonWire.decode(DaemonControlMessage.self, from: payload)
    }
}

public enum DaemonFrameCodec {
    public static let headerSize = 5

    public static func encode(_ frame: DaemonFrame) -> Data {
        var data = Data(capacity: headerSize + frame.payload.count)
        var length = UInt32(frame.payload.count).littleEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(frame.type.rawValue)
        data.append(frame.payload)
        return data
    }
}

public final class DaemonFrameReader {
    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) {
        buffer.append(data)
    }

    public func nextFrame() throws -> DaemonFrame? {
        guard buffer.count >= DaemonFrameCodec.headerSize else { return nil }
        let length = buffer.prefix(4).withUnsafeBytes { rawBuffer -> UInt32 in
            var value: UInt32 = 0
            withUnsafeMutableBytes(of: &value) { destination in
                destination.copyBytes(from: rawBuffer)
            }
            return UInt32(littleEndian: value)
        }
        guard length <= MuxyDaemonProtocol.maximumFramePayload else {
            throw DaemonWireError.frameTooLarge
        }
        let total = DaemonFrameCodec.headerSize + Int(length)
        guard buffer.count >= total else { return nil }
        let start = buffer.startIndex
        let typeByte = buffer[buffer.index(start, offsetBy: 4)]
        guard let type = DaemonFrameType(rawValue: typeByte) else {
            throw DaemonWireError.frameTooLarge
        }
        let payload = buffer.subdata(in: buffer.index(start, offsetBy: DaemonFrameCodec.headerSize) ..< buffer.index(
            start,
            offsetBy: total
        ))
        buffer.removeFirst(total)
        return DaemonFrame(type: type, payload: payload)
    }
}

extension JSONEncoder {
    static let daemonWire: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let daemonWire: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
