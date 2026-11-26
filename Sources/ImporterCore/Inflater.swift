/**
 * File: Inflater.swift
 * --------------------
 * Layer: Core
 * Description: A decoder of DEFLATE (RFC 1951), the compression of zip entries, written in Swift so that it runs the
 *              same on Apple platforms, Linux and WebAssembly. Compressed bytes go in piece by piece and come out
 *              decoded piece by piece, so a large attachment is never held whole.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 26/11/2026
 */

/// Why compressed bytes could not be decoded.
public enum InflaterError: Error, Equatable, Sendable {
    /// A block names the reserved block type 3.
    case reservedBlockType
    /// A stored block's length and its complement disagree.
    case storedLengthMismatch
    /// A block's code lengths do not describe a usable code.
    case invalidCodeLengths
    /// The bits read are no code of the block, or name a length or distance symbol that does not exist.
    case invalidSymbol
    /// A match reaches back before the start of the output.
    case distanceBeforeStart
    /// The compressed bytes ended before the last block did.
    case truncatedInput
}

/// A streaming DEFLATE decoder.
///
/// Give it compressed bytes with `append(_:)` and take decoded bytes with `inflate(isInputComplete:maximumOutputCount:)`
/// until `isFinished`. It decodes only while enough input is buffered to finish the step it starts (a block header or
/// one symbol), so it never has to undo a step when the input runs out. At the end of the input every remaining step is
/// decoded and running short is an error. It keeps the last 32 KB of output, the farthest a match reaches back.
public struct Inflater: Sendable {
    /// Whether the last block has been decoded.
    public private(set) var isFinished = false

    private var input: [UInt8] = []
    private var inputPosition = 0
    private var bitBuffer: UInt64 = 0
    private var bitCount = 0

    private static let windowSize = 32_768
    private var window = [UInt8](repeating: 0, count: Inflater.windowSize)
    private var windowPosition = 0
    private var totalOutputCount = 0

    private enum State: Sendable {
        case blockHeader
        case stored(remainingCount: Int)
        case compressed(literalsAndLengths: HuffmanCode, distances: HuffmanCode)
    }
    private var state = State.blockHeader
    private var isLastBlock = false

    // The input buffered before a block header is decoded: enough for the largest dynamic header (about 4,500 bits).
    private static let bitsNeededForHeader = 8_192
    // The input buffered before a symbol is decoded: a 15-bit length code, 5 extra bits, a 15-bit distance code and 13
    // extra bits.
    private static let bitsNeededForSymbol = 48

    public init() {}

    /// Adds compressed bytes to decode.
    public mutating func append(_ bytes: some Collection<UInt8>) {
        if inputPosition > 0, inputPosition >= input.count / 2 {
            input.removeFirst(inputPosition)
            inputPosition = 0
        }
        input.append(contentsOf: bytes)
    }

    /// Decodes what the buffered input allows, up to about `maximumOutputCount` bytes (a match may add up to 257
    /// more). When `isInputComplete` is true, all the input has been given and running short of it is an error.
    public mutating func inflate(isInputComplete: Bool, maximumOutputCount: Int = 65_536) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(min(maximumOutputCount, 65_536))
        decoding: while !isFinished, output.count < maximumOutputCount {
            switch state {
            case .blockHeader:
                if isLastBlock {
                    isFinished = true
                    break decoding
                }
                guard isInputComplete || availableBitCount >= Inflater.bitsNeededForHeader else { break decoding }
                try readBlockHeader()
            case .stored(let remainingCount):
                if remainingCount == 0 {
                    state = .blockHeader
                    continue
                }
                let copied = try copyStoredBytes(upTo: min(remainingCount, maximumOutputCount - output.count),
                                                 into: &output, isInputComplete: isInputComplete)
                if copied == 0 { break decoding }
                state = .stored(remainingCount: remainingCount - copied)
            case .compressed(let literalsAndLengths, let distances):
                while output.count < maximumOutputCount {
                    guard isInputComplete || availableBitCount >= Inflater.bitsNeededForSymbol else { break decoding }
                    let symbol = try decodeSymbol(with: literalsAndLengths)
                    if symbol < 256 {
                        emit(UInt8(symbol), into: &output)
                    } else if symbol == 256 {
                        state = .blockHeader
                        continue decoding
                    } else {
                        try copyMatch(lengthSymbol: symbol, distances: distances, into: &output)
                    }
                }
            }
        }
        if isInputComplete, !isFinished, output.isEmpty {
            throw InflaterError.truncatedInput
        }
        return output
    }

    // MARK: Bits

    private var availableBitCount: Int {
        bitCount + 8 * (input.count - inputPosition)
    }

    private mutating func refill() {
        while bitCount <= 56, inputPosition < input.count {
            bitBuffer |= UInt64(input[inputPosition]) << UInt64(bitCount)
            inputPosition += 1
            bitCount += 8
        }
    }

    private mutating func readBits(_ count: Int) throws -> Int {
        if count == 0 { return 0 }
        if bitCount < count { refill() }
        guard bitCount >= count else { throw InflaterError.truncatedInput }
        let value = Int(bitBuffer & ((1 << UInt64(count)) - 1))
        bitBuffer >>= UInt64(count)
        bitCount -= count
        return value
    }

    private mutating func decodeSymbol(with code: HuffmanCode) throws -> Int {
        if bitCount < code.maximumLength { refill() }
        let entry = code.table[Int(bitBuffer & ((1 << UInt64(code.maximumLength)) - 1))]
        let length = Int(entry & 0xF)
        guard length > 0 else { throw InflaterError.invalidSymbol }
        guard length <= bitCount else { throw InflaterError.truncatedInput }
        bitBuffer >>= UInt64(length)
        bitCount -= length
        return Int(entry >> 4)
    }

    // MARK: Blocks

    private mutating func readBlockHeader() throws {
        isLastBlock = try readBits(1) == 1
        switch try readBits(2) {
        case 0:
            // A stored block starts at the next byte boundary.
            _ = try readBits(bitCount % 8)
            let length = try readBits(16)
            let complement = try readBits(16)
            guard length == (~complement & 0xFFFF) else { throw InflaterError.storedLengthMismatch }
            state = .stored(remainingCount: length)
        case 1:
            state = .compressed(literalsAndLengths: HuffmanCode.fixedLiteralsAndLengths, distances: HuffmanCode.fixedDistances)
        case 2:
            try readDynamicCodes()
        default:
            throw InflaterError.reservedBlockType
        }
    }

    private mutating func readDynamicCodes() throws {
        let literalAndLengthCount = try readBits(5) + 257
        let distanceCount = try readBits(5) + 1
        let codeLengthCount = try readBits(4) + 4
        guard literalAndLengthCount <= 286, distanceCount <= 30 else { throw InflaterError.invalidCodeLengths }
        var codeLengthLengths = [UInt8](repeating: 0, count: 19)
        for index in 0..<codeLengthCount {
            codeLengthLengths[Inflater.codeLengthOrder[index]] = UInt8(try readBits(3))
        }
        let codeLengthCode = try HuffmanCode(lengths: codeLengthLengths)
        var lengths: [UInt8] = []
        lengths.reserveCapacity(literalAndLengthCount + distanceCount)
        while lengths.count < literalAndLengthCount + distanceCount {
            let symbol = try decodeSymbol(with: codeLengthCode)
            switch symbol {
            case 0..<16:
                lengths.append(UInt8(symbol))
            case 16:
                guard let previous = lengths.last else { throw InflaterError.invalidCodeLengths }
                lengths.append(contentsOf: repeatElement(previous, count: 3 + (try readBits(2))))
            case 17:
                lengths.append(contentsOf: repeatElement(0, count: 3 + (try readBits(3))))
            default:
                lengths.append(contentsOf: repeatElement(0, count: 11 + (try readBits(7))))
            }
        }
        guard lengths.count == literalAndLengthCount + distanceCount, lengths[256] != 0 else {
            throw InflaterError.invalidCodeLengths
        }
        state = .compressed(literalsAndLengths: try HuffmanCode(lengths: Array(lengths[0..<literalAndLengthCount])),
                            distances: try HuffmanCode(lengths: Array(lengths[literalAndLengthCount...])))
    }

    private mutating func copyStoredBytes(upTo count: Int, into output: inout [UInt8], isInputComplete: Bool) throws -> Int {
        var copied = 0
        // Whole bytes left in the bit buffer come first: the header was read past the byte boundary.
        while copied < count, bitCount >= 8 {
            emit(UInt8(bitBuffer & 0xFF), into: &output)
            bitBuffer >>= 8
            bitCount -= 8
            copied += 1
        }
        let fromInput = min(count - copied, input.count - inputPosition)
        for byte in input[inputPosition..<(inputPosition + fromInput)] {
            emit(byte, into: &output)
        }
        inputPosition += fromInput
        copied += fromInput
        if copied == 0, isInputComplete { throw InflaterError.truncatedInput }
        return copied
    }

    private mutating func copyMatch(lengthSymbol: Int, distances: HuffmanCode, into output: inout [UInt8]) throws {
        let lengthIndex = lengthSymbol - 257
        guard lengthIndex < Inflater.lengthBases.count else { throw InflaterError.invalidSymbol }
        let length = Inflater.lengthBases[lengthIndex] + (try readBits(Inflater.lengthExtraBits[lengthIndex]))
        let distanceSymbol = try decodeSymbol(with: distances)
        guard distanceSymbol < Inflater.distanceBases.count else { throw InflaterError.invalidSymbol }
        let distance = Inflater.distanceBases[distanceSymbol] + (try readBits(Inflater.distanceExtraBits[distanceSymbol]))
        guard distance <= totalOutputCount else { throw InflaterError.distanceBeforeStart }
        let mask = Inflater.windowSize - 1
        for _ in 0..<length {
            emit(window[(windowPosition - distance) & mask], into: &output)
        }
    }

    private mutating func emit(_ byte: UInt8, into output: inout [UInt8]) {
        output.append(byte)
        window[windowPosition] = byte
        windowPosition = (windowPosition + 1) & (Inflater.windowSize - 1)
        totalOutputCount += 1
    }

    // MARK: Tables of RFC 1951

    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    private static let lengthBases = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99,
                                      115, 131, 163, 195, 227, 258]
    private static let lengthExtraBits = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5,
                                          5, 0]
    private static let distanceBases = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
                                        1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtraBits = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11,
                                            11, 12, 12, 13, 13]
}

/// A canonical Huffman code, decoded with one table lookup: the table is indexed by the next `maximumLength` bits of
/// input, least significant first, and holds the symbol and the length of its code.
struct HuffmanCode: Sendable {
    /// For each value of the next `maximumLength` bits: the symbol shifted left by 4, plus the code's length (0 for
    /// bits that start no code).
    let table: [UInt16]
    let maximumLength: Int

    /// The code giving each symbol the code length at its index (0 for a symbol with no code).
    init(lengths: [UInt8]) throws {
        let maximumLength = max(1, Int(lengths.max() ?? 0))
        guard maximumLength <= 15 else { throw InflaterError.invalidCodeLengths }
        var countOfLength = [Int](repeating: 0, count: 16)
        for length in lengths where length > 0 { countOfLength[Int(length)] += 1 }
        // A code may be incomplete (one distance code is allowed), never oversubscribed.
        var left = 1
        for length in 1...15 {
            left = left * 2 - countOfLength[length]
            guard left >= 0 else { throw InflaterError.invalidCodeLengths }
        }
        var nextCode = [Int](repeating: 0, count: 16)
        var code = 0
        for length in 1...15 {
            code = (code + countOfLength[length - 1]) << 1
            nextCode[length] = code
        }
        var table = [UInt16](repeating: 0, count: 1 << maximumLength)
        for (symbol, lengthByte) in lengths.enumerated() where lengthByte > 0 {
            let length = Int(lengthByte)
            let assigned = nextCode[length]
            nextCode[length] += 1
            var reversed = 0
            for bit in 0..<length where assigned & (1 << bit) != 0 {
                reversed |= 1 << (length - 1 - bit)
            }
            let entry = UInt16(symbol << 4 | length)
            var index = reversed
            while index < table.count {
                table[index] = entry
                index += 1 << length
            }
        }
        self.table = table
        self.maximumLength = maximumLength
    }

    static let fixedLiteralsAndLengths: HuffmanCode = {
        var lengths = [UInt8](repeating: 8, count: 288)
        for symbol in 144..<256 { lengths[symbol] = 9 }
        for symbol in 256..<280 { lengths[symbol] = 7 }
        // The fixed code is complete, so building it cannot fail.
        return try! HuffmanCode(lengths: lengths)
    }()

    static let fixedDistances: HuffmanCode = {
        // 30 distance codes of 5 bits (and the two unused ones of the fixed code, which no valid input names).
        try! HuffmanCode(lengths: [UInt8](repeating: 5, count: 30))
    }()
}
