import UIKit

/// Lange drücken (Finger) auf einen Körper im Viewport: kleines Kontextmenü mit „Löschen“ (Kai, Punkt 11).
/// Nur im Modellmodus mit dem Werkzeug „Auswählen“ und ohne offenen Befehl – Skizze, Stift und Ziehgriffe
/// bleiben unberührt. Liegt der Körper nicht in der Auswahl, wird er zuerst allein gewählt; sonst gilt die ganze
/// Auswahl. Gelöscht wird über ModelStore.deleteBodies (BodyDelete.swift), ein Rückgängig-Schritt.
/// Als UIInteraction gebaut, damit die Ansicht sie hält (addInteraction) und Viewport.swift nur eine Zeile braucht.
final class BodyContextMenuInteraction: NSObject, UIInteraction, UIEditMenuInteractionDelegate,
                                        UIGestureRecognizerDelegate {
    private(set) weak var view: UIView?
    private var longPress: UILongPressGestureRecognizer?
    private var editMenu: UIEditMenuInteraction?
    /// Körper, für die das gerade gezeigte Menü gilt
    private var targets: [Int] = []

    func willMove(to view: UIView?) {
        guard let old = self.view else { return }
        if let longPress { old.removeGestureRecognizer(longPress) }
        if let editMenu { old.removeInteraction(editMenu) }
        longPress = nil
        editMenu = nil
    }

    func didMove(to view: UIView?) {
        self.view = view
        guard let view else { return }
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.5
        press.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        // Andere Gesten und touchesBegan/-Ended der Ansicht laufen ungestört weiter
        press.cancelsTouchesInView = false
        press.delaysTouchesEnded = false
        press.delegate = self
        view.addGestureRecognizer(press)
        longPress = press
        let menu = UIEditMenuInteraction(delegate: self)
        view.addInteraction(menu)
        editMenu = menu
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let viewport = view as? ViewportView,
              let workspace = viewport.workspace,
              let renderer = viewport.renderer else { return }
        let sketch = workspace.sketch
        guard !sketch.isActive, workspace.command == nil, workspace.tool == .select,
              workspace.canvasCalibration == nil,
              !(workspace.boxSelects && workspace.acceptsBoxSelection) else { return }
        let location = gesture.location(in: viewport)
        guard let ray = renderer.camera.ray(through: location, viewSize: viewport.bounds.size) else { return }
        let model = workspace.model
        guard let hit = model.pick(origin: ray.origin, direction: ray.direction),
              model.bodies.indices.contains(hit.face.body) else { return }
        let body = hit.face.body
        if !model.deletableBodies.contains(body) {
            model.toggleBody(body, exclusive: true)
        }
        targets = model.deletableBodies
        guard !targets.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: location))
    }

    // MARK: UIEditMenuInteractionDelegate

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard !targets.isEmpty else { return nil }
        let chosen = targets
        let delete = UIAction(title: ModelStore.deleteTitle(count: chosen.count), image: UIImage(systemName: "trash"),
                              attributes: .destructive) { [weak self] _ in
            guard let viewport = self?.view as? ViewportView, let workspace = viewport.workspace else { return }
            workspace.model.deleteBodies(chosen)
            self?.targets = []
        }
        return UIMenu(children: [delete])
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// Maßfelder und Ziffernfeld behalten ihre Berührungen
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let touched = touch.view, let view else { return true }
        return touched === view
    }
}
