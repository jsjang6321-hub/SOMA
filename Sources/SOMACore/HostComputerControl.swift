import Foundation

public enum HostComputerIPCOperation: String, Codable, Equatable, Sendable {
    case observeScreen = "observe_screen"
    case performInput = "perform_input"
}

public enum HostComputerInputKind: String, Codable, CaseIterable, Sendable {
    case movePointer = "move_pointer"
    case click
    case doubleClick = "double_click"
    case scroll
    case typeText = "type_text"
    case pressKey = "press_key"
}

public enum HostComputerPointerButton: String, Codable, CaseIterable, Sendable {
    case left
    case right
}

public enum HostComputerKey: String, Codable, CaseIterable, Sendable {
    case returnKey = "return"
    case escape
    case tab
    case space
    case delete
    case forwardDelete = "forward_delete"
    case leftArrow = "left_arrow"
    case rightArrow = "right_arrow"
    case upArrow = "up_arrow"
    case downArrow = "down_arrow"
    case home
    case end
    case pageUp = "page_up"
    case pageDown = "page_down"
}

public enum HostComputerKeyModifier: String, Codable, CaseIterable, Sendable {
    case command
    case shift
    case option
    case control
    case function
}

public struct HostComputerInputAction: Codable, Equatable, Sendable {
    public let kind: HostComputerInputKind
    /// Main-display coordinates normalized to 0...1 from top-left.
    public let x: Double?
    public let y: Double?
    public let button: HostComputerPointerButton?
    public let deltaX: Int?
    public let deltaY: Int?
    public let text: String?
    public let key: HostComputerKey?
    public let modifiers: [HostComputerKeyModifier]

    public init(
        kind: HostComputerInputKind,
        x: Double? = nil,
        y: Double? = nil,
        button: HostComputerPointerButton? = nil,
        deltaX: Int? = nil,
        deltaY: Int? = nil,
        text: String? = nil,
        key: HostComputerKey? = nil,
        modifiers: [HostComputerKeyModifier] = []
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.text = text.map { String($0.prefix(1_024)) }
        self.key = key
        self.modifiers = Array(modifiers.uniqued().prefix(5))
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case x
        case y
        case button
        case deltaX
        case deltaY
        case text
        case key
        case modifiers
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try values.decode(HostComputerInputKind.self, forKey: .kind),
            x: try values.decodeIfPresent(Double.self, forKey: .x),
            y: try values.decodeIfPresent(Double.self, forKey: .y),
            button: try values.decodeIfPresent(HostComputerPointerButton.self, forKey: .button),
            deltaX: try values.decodeIfPresent(Int.self, forKey: .deltaX),
            deltaY: try values.decodeIfPresent(Int.self, forKey: .deltaY),
            text: try values.decodeIfPresent(String.self, forKey: .text),
            key: try values.decodeIfPresent(HostComputerKey.self, forKey: .key),
            modifiers: try values.decodeIfPresent(
                [HostComputerKeyModifier].self,
                forKey: .modifiers
            ) ?? []
        )
    }

    public func validate() throws {
        switch kind {
        case .movePointer, .click, .doubleClick:
            guard let x, let y, x.isFinite, y.isFinite,
                  (0...1).contains(x), (0...1).contains(y) else {
                throw HostComputerControlError.normalizedPointRequired
            }
            guard deltaX == nil, deltaY == nil, text == nil, key == nil else {
                throw HostComputerControlError.unexpectedInputFields
            }
            if kind == .movePointer, button != nil || !modifiers.isEmpty {
                throw HostComputerControlError.unexpectedInputFields
            }
        case .scroll:
            let horizontal = deltaX ?? 0
            guard x == nil, y == nil, button == nil, text == nil, key == nil,
                  let deltaY, (-2_000...2_000).contains(deltaY),
                  (-2_000...2_000).contains(horizontal), modifiers.isEmpty,
                  horizontal != 0 || deltaY != 0 else {
                throw HostComputerControlError.scrollDeltaRequired
            }
        case .typeText:
            guard x == nil, y == nil, button == nil, deltaX == nil, deltaY == nil,
                  key == nil, modifiers.isEmpty,
                  let text, !text.isEmpty else {
                throw HostComputerControlError.textRequired
            }
        case .pressKey:
            guard x == nil, y == nil, button == nil, deltaX == nil, deltaY == nil,
                  text == nil, key != nil else {
                throw HostComputerControlError.keyRequired
            }
        }
    }
}

public enum HostComputerControlError: Error, Equatable, LocalizedError {
    case normalizedPointRequired
    case scrollDeltaRequired
    case textRequired
    case keyRequired
    case unexpectedInputFields

    public var errorDescription: String? {
        switch self {
        case .normalizedPointRequired:
            "Pointer input requires finite x and y coordinates from 0 through 1"
        case .scrollDeltaRequired:
            "Scroll input requires a non-zero bounded delta_x or delta_y"
        case .textRequired:
            "Text input requires non-empty text and no unrelated fields"
        case .keyRequired:
            "Key input requires one supported key and no unrelated fields"
        case .unexpectedInputFields:
            "The host input action contains fields that do not belong to its kind"
        }
    }
}

public struct HostComputerIPCRequest: Codable, Equatable, Sendable {
    public let operation: HostComputerIPCOperation
    public let input: HostComputerInputAction?

    public init(operation: HostComputerIPCOperation, input: HostComputerInputAction? = nil) {
        self.operation = operation
        self.input = input
    }

    public func validate() throws {
        switch operation {
        case .observeScreen:
            guard input == nil else { throw HostComputerControlError.unexpectedInputFields }
        case .performInput:
            guard let input else { throw HostComputerControlError.unexpectedInputFields }
            try input.validate()
        }
    }
}

public struct HostScreenResource: Codable, Equatable, Sendable {
    public let imagePath: String
    public let mimeType: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let coordinateWidth: Double
    public let coordinateHeight: Double
    public let capturedAtNS: UInt64
    public let resourceExpiresAtNS: UInt64

    public init(
        imagePath: String,
        mimeType: String = "image/jpeg",
        pixelWidth: Int,
        pixelHeight: Int,
        coordinateWidth: Double,
        coordinateHeight: Double,
        capturedAtNS: UInt64,
        resourceExpiresAtNS: UInt64
    ) {
        self.imagePath = imagePath
        self.mimeType = mimeType
        self.pixelWidth = max(1, pixelWidth)
        self.pixelHeight = max(1, pixelHeight)
        self.coordinateWidth = max(1, coordinateWidth)
        self.coordinateHeight = max(1, coordinateHeight)
        self.capturedAtNS = capturedAtNS
        self.resourceExpiresAtNS = resourceExpiresAtNS
    }
}

public struct HostComputerActionReceipt: Codable, Equatable, Sendable {
    public let kind: HostComputerInputKind
    public let performedAtNS: UInt64
    public let textCharacterCount: Int?

    public init(kind: HostComputerInputKind, performedAtNS: UInt64, textCharacterCount: Int? = nil) {
        self.kind = kind
        self.performedAtNS = performedAtNS
        self.textCharacterCount = textCharacterCount.map { max(0, $0) }
    }
}

public struct HostComputerIPCResult: Codable, Equatable, Sendable {
    public let screen: HostScreenResource?
    public let action: HostComputerActionReceipt?

    public init(screen: HostScreenResource? = nil, action: HostComputerActionReceipt? = nil) {
        self.screen = screen
        self.action = action
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
