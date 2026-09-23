import Foundation

public enum Heat: Int { case nominal, fair, serious, critical }
public struct MiningPolicy {
    public var idleThreshold: Double = 300
    public var activeDuty: Double = 0.05
    public var idleDuty: Double = 0.20
    public init() {}
    public func decision(enabled: Bool, paused: Bool, sleeping: Bool, battery: Bool,
                         allowBattery: Bool, heat: Heat, idleSeconds: Double) -> (duty: Double, reason: String) {
        if !enabled { return (0, "Set your Bitcoin address") }
        if paused { return (0, "Paused") }
        if sleeping { return (0, "Sleeping") }
        if battery && !allowBattery { return (0, "On battery") }
        if heat == .serious || heat == .critical { return (0, "Cooling down") }
        let idle = idleSeconds >= idleThreshold
        let duty = idle ? idleDuty : activeDuty
        return (heat == .fair ? min(duty, 0.025) : duty,
                heat == .fair ? "Reducing heat" : (idle ? "Away · mining gently" : "In use · mining lightly"))
    }
    public static func ramp(current: Double, target: Double) -> Double {
        target < current ? target : min(target, current + 0.01)
    }
    public static func batchSize(current: Int, gpuSeconds: Double) -> Int {
        guard gpuSeconds.isFinite, gpuSeconds > 0 else { return 256 }
        let ratio = min(2, max(0.25, 0.002 / gpuSeconds))
        return max(256, min(262_144, Int(Double(current) * ratio) / 256 * 256))
    }
}
