import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import SOMACore
import UniformTypeIdentifiers

private enum HostComputerRuntimeError: Error, LocalizedError {
    case screenRecordingPermissionRequired
    case accessibilityPermissionRequired
    case screenCaptureUnavailable
    case imageEncodingFailed
    case inputEventCreationFailed

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionRequired:
            "Screen Recording permission is required for SOMA Subconscious in System Settings > Privacy & Security"
        case .accessibilityPermissionRequired:
            "Accessibility permission is required for SOMA Subconscious in System Settings > Privacy & Security"
        case .screenCaptureUnavailable:
            "The main display could not be captured"
        case .imageEncodingFailed:
            "The current screen image could not be encoded"
        case .inputEventCreationFailed:
            "The requested macOS input event could not be created"
        }
    }
}

/// Executes administrator-authorized host observation and short input actions
/// inside the signed L0 owner. The MCP child never receives OS automation
/// authority directly; it receives only the bounded result projection.
final class HostComputerController: @unchecked Sendable {
    private let directoryURL: URL
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let cleanupQueue = DispatchQueue(label: "soma.host-computer.cleanup", qos: .utility)
    private let resourceTTLNS: UInt64 = 60_000_000_000
    private let maximumPixelWidth = 1_600
    private let maximumPixelHeight = 1_000

    init(directoryURL: URL) throws {
        self.directoryURL = directoryURL
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        for file in (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [] where file.pathExtension.lowercased() == "jpg" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func handle(_ request: HostComputerIPCRequest) -> Result<HostComputerIPCResult, Error> {
        do {
            try request.validate()
            switch request.operation {
            case .observeScreen:
                return .success(.init(screen: try captureMainDisplay()))
            case .performInput:
                guard let input = request.input else {
                    throw HostComputerControlError.unexpectedInputFields
                }
                return .success(.init(action: try perform(input)))
            }
        } catch {
            return .failure(error)
        }
    }

    private func captureMainDisplay() throws -> HostScreenResource {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw HostComputerRuntimeError.screenRecordingPermissionRequired
        }
        let displayID = CGMainDisplayID()
        guard let source = CGDisplayCreateImage(displayID) else {
            throw HostComputerRuntimeError.screenCaptureUnavailable
        }
        let scale = min(
            1,
            Double(maximumPixelWidth) / Double(source.width),
            Double(maximumPixelHeight) / Double(source.height)
        )
        let output: CGImage
        if scale < 1 {
            let transformed = CIImage(cgImage: source).transformed(
                by: CGAffineTransform(scaleX: scale, y: scale)
            )
            guard let scaled = imageContext.createCGImage(transformed, from: transformed.extent) else {
                throw HostComputerRuntimeError.imageEncodingFailed
            }
            output = scaled
        } else {
            output = source
        }

        let filename = "screen-\(UUID().uuidString.lowercased()).jpg"
        let imageURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
        guard let destination = CGImageDestinationCreateWithURL(
            imageURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw HostComputerRuntimeError.imageEncodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            output,
            [kCGImageDestinationLossyCompressionQuality: 0.74] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: imageURL)
            throw HostComputerRuntimeError.imageEncodingFailed
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)

        let capturedAtNS = DispatchTime.now().uptimeNanoseconds
        let expiresAtNS = capturedAtNS &+ resourceTTLNS
        cleanupQueue.asyncAfter(deadline: .now() + .seconds(60)) { [imageURL] in
            try? FileManager.default.removeItem(at: imageURL)
        }
        let bounds = CGDisplayBounds(displayID)
        return HostScreenResource(
            imagePath: imageURL.path,
            pixelWidth: output.width,
            pixelHeight: output.height,
            coordinateWidth: bounds.width,
            coordinateHeight: bounds.height,
            capturedAtNS: capturedAtNS,
            resourceExpiresAtNS: expiresAtNS
        )
    }

    private func perform(_ input: HostComputerInputAction) throws -> HostComputerActionReceipt {
        try input.validate()
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            throw HostComputerRuntimeError.accessibilityPermissionRequired
        }
        switch input.kind {
        case .movePointer:
            try postPointerMove(input)
        case .click:
            try postClick(input, count: 1)
        case .doubleClick:
            try postClick(input, count: 2)
        case .scroll:
            try postScroll(input)
        case .typeText:
            try postText(input.text ?? "")
        case .pressKey:
            try postKey(input)
        }
        return HostComputerActionReceipt(
            kind: input.kind,
            performedAtNS: DispatchTime.now().uptimeNanoseconds,
            textCharacterCount: input.kind == .typeText ? input.text?.count : nil
        )
    }

    private func normalizedPoint(_ input: HostComputerInputAction) throws -> CGPoint {
        guard let x = input.x, let y = input.y else {
            throw HostComputerControlError.normalizedPointRequired
        }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(
            x: bounds.minX + bounds.width * x,
            y: bounds.minY + bounds.height * y
        )
    }

    private func postPointerMove(_ input: HostComputerInputAction) throws {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: try normalizedPoint(input),
            mouseButton: .left
        ) else {
            throw HostComputerRuntimeError.inputEventCreationFailed
        }
        event.post(tap: .cghidEventTap)
    }

    private func postClick(_ input: HostComputerInputAction, count: Int) throws {
        let point = try normalizedPoint(input)
        let button = input.button ?? .left
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        let eventButton: CGMouseButton = button == .left ? .left : .right
        let flags = eventFlags(input.modifiers)
        for click in 1...count {
            guard let down = CGEvent(
                mouseEventSource: nil,
                mouseType: downType,
                mouseCursorPosition: point,
                mouseButton: eventButton
            ), let up = CGEvent(
                mouseEventSource: nil,
                mouseType: upType,
                mouseCursorPosition: point,
                mouseButton: eventButton
            ) else {
                throw HostComputerRuntimeError.inputEventCreationFailed
            }
            down.flags = flags
            up.flags = flags
            down.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func postScroll(_ input: HostComputerInputAction) throws {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(input.deltaY ?? 0),
            wheel2: Int32(input.deltaX ?? 0),
            wheel3: 0
        ) else {
            throw HostComputerRuntimeError.inputEventCreationFailed
        }
        event.post(tap: .cghidEventTap)
    }

    private func postText(_ text: String) throws {
        let characters = Array(text.utf16)
        guard !characters.isEmpty,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw HostComputerRuntimeError.inputEventCreationFailed
        }
        characters.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: baseAddress
            )
            up.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: baseAddress
            )
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postKey(_ input: HostComputerInputAction) throws {
        guard let key = input.key,
              let code = keyCode(key),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw HostComputerRuntimeError.inputEventCreationFailed
        }
        let flags = eventFlags(input.modifiers)
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func eventFlags(_ modifiers: [HostComputerKeyModifier]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { flags, modifier in
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            case .function: flags.insert(.maskSecondaryFn)
            }
        }
    }

    private func keyCode(_ key: HostComputerKey) -> CGKeyCode? {
        switch key {
        case .returnKey: 36
        case .tab: 48
        case .space: 49
        case .delete: 51
        case .escape: 53
        case .home: 115
        case .pageUp: 116
        case .forwardDelete: 117
        case .end: 119
        case .pageDown: 121
        case .leftArrow: 123
        case .rightArrow: 124
        case .downArrow: 125
        case .upArrow: 126
        }
    }
}
