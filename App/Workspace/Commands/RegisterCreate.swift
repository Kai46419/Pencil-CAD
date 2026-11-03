import Foundation

/// Treiber ERSTELLEN (Paket M1)
extension ModelCommands {
    static func registerCreate() {
        register(ExtrudeCommand.self)
        register(RevolveCommand.self)
        register(SweepCommand.self)
        register(LoftCommand.self)
        register(HoleCommand.self)
        register(ThreadCommand.self)
        register(BoxCommand.self)
        register(CylinderCommand.self)
        register(SphereCommand.self)
        register(TorusCommand.self)
        register(ConeCommand.self)
        register(HelixCommand.self)
        register(ThinExtrudeCommand.self)
    }
}
