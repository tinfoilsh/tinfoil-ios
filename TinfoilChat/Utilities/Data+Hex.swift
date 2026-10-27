import Foundation

extension Data {
    init?(lowercaseHex: String) {
        guard lowercaseHex.count.isMultiple(of: 2),
              lowercaseHex.unicodeScalars.allSatisfy({
                  (48...57).contains(Int($0.value)) || (97...102).contains(Int($0.value))
              })
        else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(lowercaseHex.count / 2)
        var index = lowercaseHex.startIndex
        while index < lowercaseHex.endIndex {
            let next = lowercaseHex.index(index, offsetBy: 2)
            guard let byte = UInt8(lowercaseHex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
