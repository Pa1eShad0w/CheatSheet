/// A shortcut chord must never become a hold gesture until Command is released.
public struct CommandHold: Sendable {
    public enum Event: Sendable {
        case modifiers(command: Bool, other: Bool)
        case keyDown
        case mouseDown
        case delayElapsed
        case reset
        case invalidate(command: Bool)
        case pin
        case unpin(command: Bool)
    }

    public enum Effect: Equatable, Sendable {
        case schedule
        case cancel
        case show
        case hide
    }

    private enum Phase: Sendable { case idle, waiting, visible, pinned, blocked }
    private var phase: Phase = .idle

    public init() {}

    public var isVisible: Bool { phase == .visible || phase == .pinned }
    public var isPinned: Bool { phase == .pinned }

    public mutating func handle(_ event: Event) -> [Effect] {
        if phase == .pinned {
            switch event {
            case .modifiers, .keyDown, .delayElapsed, .pin: return []
            default: break
            }
        }
        switch event {
        case .pin:
            guard phase == .visible else { return [] }
            phase = .pinned
            return []
        case .unpin(let command):
            guard phase == .pinned else { return [] }
            phase = command ? .visible : .idle
            return command ? [] : [.cancel, .hide]
        case .invalidate(let command):
            let effects = dismiss()
            phase = command ? .blocked : .idle
            return effects
        case .modifiers(command: false, other: _), .reset:
            let effects = dismiss()
            phase = .idle
            return effects
        case .modifiers(command: true, other: true), .keyDown, .mouseDown:
            guard phase != .idle else {
                if case .modifiers = event { phase = .blocked }
                return []
            }
            let effects = dismiss()
            phase = .blocked
            return effects
        case .modifiers(command: true, other: false):
            guard phase == .idle else { return [] }
            phase = .waiting
            return [.schedule]
        case .delayElapsed:
            guard phase == .waiting else { return [] }
            phase = .visible
            return [.show]
        }
    }

    private func dismiss() -> [Effect] {
        switch phase {
        case .waiting: [.cancel]
        case .visible, .pinned: [.cancel, .hide]
        case .idle, .blocked: []
        }
    }
}
