import UIKit

// Pfeile eines offenen Modellbefehls im Viewport (ModelCommand.swift): eigener Text am Pfeil (Winkel, Gesamtabstand),
// Rasten mit Haptik beim Ziehen (Apple Pencil Pro ab iPadOS 17.5) und Antippen des Werts fokussiert das Wertfeld im
// Eigenschaften-Panel. Viewport.swift ruft diese drei Haken nur auf.

extension ViewportView {
    /// Text am Pfeil (nil = Länge wie bisher)
    func commandValueText(_ handle: DragHandle) -> String? {
        guard case .command = handle.kind, let workspace, let command = workspace.command,
              let driver = workspace.commandDriver else { return nil }
        return driver.valueText(handle: handle.kind, value: handle.value, command)
    }

    /// Nach jedem gerasteten Wert beim Ziehen: kurzer Ruck je Rastschritt.
    func commandDragTick(_ handle: DragHandle, value: Double, at location: CGPoint) {
        guard case .command(let key) = handle.kind else { return }
        let previous = CommandDragHaptics.last
        CommandDragHaptics.last = (key, value)
        guard let previous, previous.key == key, previous.value != value else { return }
        if #available(iOS 17.5, *) {
            let generator: UICanvasFeedbackGenerator
            if let existing = CommandDragHaptics.canvas as? UICanvasFeedbackGenerator, CommandDragHaptics.canvasView === self {
                generator = existing
            } else {
                generator = UICanvasFeedbackGenerator(view: self)
                CommandDragHaptics.canvas = generator
                CommandDragHaptics.canvasView = self
            }
            generator.alignmentOccurred(at: location)
        } else {
            CommandDragHaptics.selection.selectionChanged()
        }
    }

    /// Wert am Pfeil angetippt: Wertfeld im Panel bekommt den Fokus (true = erledigt).
    func commandValueLabelTapped(at location: CGPoint, label: UIView) -> Bool {
        guard !label.isHidden, label.frame.insetBy(dx: -12, dy: -12).contains(location),
              let workspace, let command = workspace.command, let driver = workspace.commandDriver,
              let key = driver.primaryValueKey(command) else { return false }
        command.focusKey = key
        return true
    }
}

@MainActor
private enum CommandDragHaptics {
    static var last: (key: String, value: Double)?
    static var canvas: UIFeedbackGenerator?
    static weak var canvasView: UIView?
    static let selection = UISelectionFeedbackGenerator()
}
