import Foundation

public struct MuxyDaemonRingBuffer: Sendable {
    public private(set) var capacity: Int
    private var storage: [UInt8]
    private var head: Int
    private var count: Int

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
        storage = [UInt8](repeating: 0, count: max(capacity, 1))
        head = 0
        count = 0
    }

    public var isEmpty: Bool {
        count == 0
    }

    public var length: Int {
        count
    }

    public mutating func append(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            storage[(head + count) % capacity] = byte
            if count < capacity {
                count += 1
            } else {
                head = (head + 1) % capacity
            }
        }
    }

    public func contents() -> Data {
        var data = Data(capacity: count)
        for index in 0 ..< count {
            data.append(storage[(head + index) % capacity])
        }
        return data
    }
}
