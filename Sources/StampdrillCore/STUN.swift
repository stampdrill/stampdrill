#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// STUN messages (RFC 8489) with the TURN additions (RFC 8656) that a
/// reachability check needs.
public struct STUNMessage: Equatable, Sendable {
    public enum Method: UInt16, Sendable {
        case binding = 0x001
        case allocate = 0x003
        case refresh = 0x004
    }

    public enum Class: UInt16, Sendable {
        case request = 0x000
        case indication = 0x010
        case success = 0x100
        case error = 0x110
    }

    public enum AttributeType: UInt16, Sendable {
        case mappedAddress = 0x0001
        case username = 0x0006
        case messageIntegrity = 0x0008
        case errorCode = 0x0009
        case lifetime = 0x000D
        case xorPeerAddress = 0x0012
        case realm = 0x0014
        case nonce = 0x0015
        case xorRelayedAddress = 0x0016
        case requestedTransport = 0x0019
        case xorMappedAddress = 0x0020
        case software = 0x8022
        case fingerprint = 0x8028
        case responseOrigin = 0x802B
    }

    public struct Attribute: Equatable, Sendable {
        public var type: UInt16
        public var value: Data

        public init(_ type: AttributeType, _ value: Data) {
            self.type = type.rawValue
            self.value = value
        }

        init(rawType: UInt16, value: Data) {
            type = rawType
            self.value = value
        }
    }

    public struct Address: Equatable, Sendable {
        public var ip: String
        public var port: UInt16
        public var isIPv6: Bool

        public var description: String { isIPv6 ? "[\(ip)]:\(port)" : "\(ip):\(port)" }
    }

    static let magicCookie: UInt32 = 0x2112_A442

    public var method: Method
    public var messageClass: Class
    public var transactionID: Data
    public var attributes: [Attribute]

    public init(method: Method, class messageClass: Class, transactionID: Data = STUNMessage.newTransactionID(), attributes: [Attribute] = []) {
        self.method = method
        self.messageClass = messageClass
        self.transactionID = transactionID
        self.attributes = attributes
    }

    public static func newTransactionID() -> Data {
        Data((0..<12).map { _ in UInt8.random(in: 0...255) })
    }

    // MARK: Encoding

    /// The message on the wire. With a key, MESSAGE-INTEGRITY is appended.
    public func encoded(integrityKey: Data? = nil) -> Data {
        var body = Data()
        for attribute in attributes { body.append(Self.encode(attribute)) }

        let type = method.rawValue | messageClass.rawValue
        if let integrityKey {
            let header = Self.header(type: type, length: body.count + 24, transactionID: transactionID)
            let mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: header + body, using: SymmetricKey(data: integrityKey)))
            body.append(Self.encode(Attribute(.messageIntegrity, mac)))
        }
        return Self.header(type: type, length: body.count, transactionID: transactionID) + body
    }

    private static func header(type: UInt16, length: Int, transactionID: Data) -> Data {
        var data = Data()
        data.appendBigEndian(type)
        data.appendBigEndian(UInt16(length))
        data.appendBigEndian(magicCookie)
        data.append(transactionID)
        return data
    }

    private static func encode(_ attribute: Attribute) -> Data {
        var data = Data()
        data.appendBigEndian(attribute.type)
        data.appendBigEndian(UInt16(attribute.value.count))
        data.append(attribute.value)
        let padding = (4 - attribute.value.count % 4) % 4
        data.append(Data(repeating: 0, count: padding))
        return data
    }

    // MARK: Decoding

    public enum DecodingError: Error, Equatable {
        case notSTUN
        case truncated
    }

    /// The length of the message starting at `data`, once its header is there.
    public static func length(ofMessageIn data: Data) -> Int? {
        guard data.count >= 20 else { return nil }
        return 20 + Int(data.bigEndianUInt16(at: 2))
    }

    public init(decoding data: Data) throws(DecodingError) {
        guard data.count >= 20, data.first.map({ $0 & 0xC0 == 0 }) == true, data.bigEndianUInt32(at: 4) == Self.magicCookie else {
            throw .notSTUN
        }
        let type = data.bigEndianUInt16(at: 0)
        let length = Int(data.bigEndianUInt16(at: 2))
        guard data.count >= 20 + length else { throw .truncated }
        guard let method = Method(rawValue: type & ~0x0110), let messageClass = Class(rawValue: type & 0x0110) else { throw .notSTUN }
        self.method = method
        self.messageClass = messageClass
        transactionID = data.subdata(in: data.startIndex + 8 ..< data.startIndex + 20)

        var attributes: [Attribute] = []
        var offset = 20
        while offset + 4 <= 20 + length {
            let attributeType = data.bigEndianUInt16(at: offset)
            let attributeLength = Int(data.bigEndianUInt16(at: offset + 2))
            guard offset + 4 + attributeLength <= 20 + length else { throw .truncated }
            let start = data.startIndex + offset + 4
            attributes.append(Attribute(rawType: attributeType, value: data.subdata(in: start ..< start + attributeLength)))
            offset += 4 + attributeLength + (4 - attributeLength % 4) % 4
        }
        self.attributes = attributes
    }

    // MARK: Reading attributes

    public func attribute(_ type: AttributeType) -> Data? {
        attributes.first { $0.type == type.rawValue }?.value
    }

    public func string(_ type: AttributeType) -> String? {
        attribute(type).map { String(decoding: $0, as: UTF8.self) }
    }

    public var errorCode: (code: Int, reason: String)? {
        guard let value = attribute(.errorCode), value.count >= 4 else { return nil }
        let code = Int(value[value.startIndex + 2] & 0x07) * 100 + Int(value[value.startIndex + 3])
        return (code, String(decoding: value.dropFirst(4), as: UTF8.self))
    }

    public var lifetime: UInt32? {
        guard let value = attribute(.lifetime), value.count == 4 else { return nil }
        return value.bigEndianUInt32(at: 0)
    }

    public var mappedAddress: Address? {
        address(.xorMappedAddress, xor: true) ?? address(.mappedAddress, xor: false)
    }

    public var relayedAddress: Address? {
        address(.xorRelayedAddress, xor: true)
    }

    public var responseOrigin: Address? {
        address(.responseOrigin, xor: false)
    }

    private func address(_ type: AttributeType, xor: Bool) -> Address? {
        guard let value = attribute(type), value.count >= 8 else { return nil }
        let family = value[value.startIndex + 1]
        var port = value.bigEndianUInt16(at: 2)
        var bytes = [UInt8](value.dropFirst(4))
        if xor {
            port ^= UInt16(Self.magicCookie >> 16)
            var mask = withUnsafeBytes(of: Self.magicCookie.bigEndian, Array.init)
            if family == 0x02 { mask += transactionID }
            for index in bytes.indices where index < mask.count { bytes[index] ^= mask[index] }
        }
        switch (family, bytes.count) {
        case (0x01, 4):
            return Address(ip: bytes.map(String.init).joined(separator: "."), port: port, isIPv6: false)
        case (0x02, 16):
            let groups = stride(from: 0, to: 16, by: 2).map { String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16) }
            return Address(ip: Self.compress(groups), port: port, isIPv6: true)
        default:
            return nil
        }
    }

    /// `2001:db8:0:0:0:0:0:1` → `2001:db8::1`.
    private static func compress(_ groups: [String]) -> String {
        var best: Range<Int>?
        var index = 0
        while index < groups.count {
            guard groups[index] == "0" else { index += 1; continue }
            let start = index
            while index < groups.count, groups[index] == "0" { index += 1 }
            if index - start > 1, (best?.count ?? 0) < index - start { best = start ..< index }
        }
        guard let best else { return groups.joined(separator: ":") }
        return groups[..<best.lowerBound].joined(separator: ":") + "::" + groups[best.upperBound...].joined(separator: ":")
    }

    // MARK: Building attributes

    public static func address(_ type: AttributeType, ip: String, port: UInt16, transactionID: Data) -> Attribute {
        var value = Data([0])
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        value.append(0x01)
        value.appendBigEndian(port ^ UInt16(magicCookie >> 16))
        let mask = withUnsafeBytes(of: magicCookie.bigEndian, Array.init)
        value.append(contentsOf: parts.enumerated().map { $0.element ^ mask[$0.offset] })
        return Attribute(type, value)
    }

    public static func text(_ type: AttributeType, _ text: String) -> Attribute {
        Attribute(type, Data(text.utf8))
    }

    public static func errorCode(_ code: Int, _ reason: String) -> Attribute {
        Attribute(.errorCode, Data([0, 0, UInt8(code / 100), UInt8(code % 100)]) + Data(reason.utf8))
    }

    public static func uint32(_ type: AttributeType, _ number: UInt32) -> Attribute {
        var data = Data()
        data.appendBigEndian(number)
        return Attribute(type, data)
    }

    /// The long-term credential key: MD5 of `username:realm:password`.
    public static func longTermKey(username: String, realm: String, password: String) -> Data {
        Data(Insecure.MD5.hash(data: Data("\(username):\(realm):\(password)".utf8)))
    }

    /// Checks MESSAGE-INTEGRITY against the raw bytes the message was decoded from.
    public static func hasValidIntegrity(_ raw: Data, key: Data) -> Bool {
        guard let message = try? STUNMessage(decoding: raw) else { return false }
        var offset = 20
        for attribute in message.attributes {
            if attribute.type == AttributeType.messageIntegrity.rawValue {
                var header = raw.prefix(20)
                let length = UInt16(offset - 20 + 24)
                header[header.startIndex + 2] = UInt8(length >> 8)
                header[header.startIndex + 3] = UInt8(length & 0xFF)
                let signed = header + raw[raw.startIndex + 20 ..< raw.startIndex + offset]
                let mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: signed, using: SymmetricKey(data: key)))
                return mac == attribute.value
            }
            offset += 4 + attribute.value.count + (4 - attribute.value.count % 4) % 4
        }
        return false
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func bigEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) << 8 | UInt16(self[startIndex + offset + 1])
    }

    func bigEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(bigEndianUInt16(at: offset)) << 16 | UInt32(bigEndianUInt16(at: offset + 2))
    }
}
