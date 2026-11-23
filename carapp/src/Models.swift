//
//  Models.swift
//  车辆状态解析（字段名对应 /ms-vehicle-status/api/v2.0/vehicle/status/latest）
//

import Foundation
import CoreLocation

struct VehicleStatus {
    var updateTime: Date = .distantPast

    // 位置
    var latitude: Double = 0
    var longitude: Double = 0
    var altitude: Double = 0
    var heading: Double = 0
    var posTrusted: Bool = false

    // 行驶
    var speed: Double = 0
    var engineRunning: Bool = false
    var odometer: Double = 0          // 总里程 km
    var tripMeter: Double = 0

    // 能源
    var chargeLevel: Double = 0       // 电量 %
    var distanceToEmpty: Double = 0   // 纯电续航 km（distanceToEmptyOnBatteryOnly）
    var fuelLevelPct: Double = 0      // 油量 %
    var fuelLevel: Double = 0         // 油量 L
    var chargeStatus: Int = 0
    var timeToFull: Int = 0           // 分钟
    var avgPowerConsumption: Double = 0
    var avgFuelConsumption: Double = 0
    var totalRange: Double = 0        // 综合续航（combinedDistanceToEmpty）
    var fuelRange: Double = 0         // 燃油续航（basic.distanceToEmpty）
    var voltage: Double = 0
    var odoEv: Double = 0             // 纯电里程
    var odoFuel: Double = 0           // 燃油里程
    var trip1: Double = 0
    var trip2: Double = 0
    var avgSpeed: Double = 0

    // 轮胎（kPa）
    var tyreFL: Double = 0
    var tyreFR: Double = 0
    var tyreRL: Double = 0
    var tyreRR: Double = 0
    var tyreTempFL: Double = 0
    var tyreTempFR: Double = 0
    var tyreTempRL: Double = 0
    var tyreTempRR: Double = 0

    // 门窗
    var doorLocked: Bool = false
    var doorOpenAny: Bool = false
    var trunkOpen: Bool = false
    var hoodOpen: Bool = false
    var windowClosed: Bool = true

    // 座舱
    var interiorTemp: Double = 0
    var exteriorTemp: Double = 0
    var preClimateActive: Bool = false
    var climateTarget: Double = 0
    var humidity: Double = 0

    // 门锁原始值
    var centralLockRaw: Int = -1

    init() {}

    init(_ d: [String: Any]) {
        let basic = d["basic"] as? [String: Any] ?? [:]
        if let pos = basic["position"] as? [String: Any] {
            // ★ 真实字段名是 latitude / longitude（早期版本误读成 lat / lon，导致坐标恒为 0）
            latitude = num(pos["latitude"])
            longitude = num(pos["longitude"])
            altitude = num(pos["altitude"])
            heading = num(pos["direction"])
            posTrusted = bool(pos["posCanBeTrusted"])
        }
        speed = num(basic["speed"])
        engineRunning = num(basic["engineStatus"]) == 1
        totalRange = num(basic["combinedDistanceToEmpty"])   // 综合续航
        fuelRange = num(basic["distanceToEmpty"])            // 燃油续航
        if let u = d["updateTime"] as? Double { updateTime = Date(timeIntervalSince1970: u / 1000) }
        else if let u = d["updateTime"] as? Int { updateTime = Date(timeIntervalSince1970: Double(u) / 1000) }

        if let ev = d["electricVehicleStatus"] as? [String: Any] {
            chargeLevel = num(ev["chargeLevel"])
            distanceToEmpty = num(ev["distanceToEmptyOnBatteryOnly"])
            chargeStatus = Int(num(ev["chargeSts"]))
            timeToFull = Int(num(ev["timeToFullyCharged"]))
            avgPowerConsumption = num(ev["averPowerConsumption"])
            odoEv = num(ev["odometerOnBatteryOnly"])
        }
        if let run = d["runningStatus"] as? [String: Any] {
            fuelLevel = num(run["fuelLevel"])
            fuelLevelPct = num(run["fuelLevelPct"])
            tripMeter = num(run["tripMeter1"])
            avgFuelConsumption = num(run["aveTraFuelConsumption"])
            odoFuel = num(run["odometerOnFuelOnly"])
            trip1 = num(run["tripMeter1"])
            trip2 = num(run["tripMeter2"])
            avgSpeed = num(run["avgSpeed"])
        }
        if let m = d["additionalMaintenanceStatus"] as? [String: Any] {
            odometer = num(m["odometer"])
            tyreFL = num(m["tyreStatusDriver"])
            tyreFR = num(m["tyreStatusPassenger"])
            tyreRL = num(m["tyreStatusDriverRear"])
            tyreRR = num(m["tyreStatusPassengerRear"])
            tyreTempFL = num(m["tyreTempDriver"])
            tyreTempFR = num(m["tyreTempPassenger"])
            tyreTempRL = num(m["tyreTempDriverRear"])
            tyreTempRR = num(m["tyreTempPassengerRear"])
            voltage = num(m["voltage"])
        }
        if let cl = d["climateStatus"] as? [String: Any] {
            interiorTemp = num(cl["interiorTemp"])
            exteriorTemp = num(cl["exteriorTemp"])
            preClimateActive = bool(cl["preClimateActive"])
            if preClimateActive { climateTarget = 21.5 }
            let wins = ["winStatusDriver", "winStatusPassenger", "winStatusDriverRear", "winStatusPassengerRear"]
            windowClosed = wins.allSatisfy { num(cl[$0]) == 2 }
        }
        if let pol = d["pollutionStatus"] as? [String: Any] {
            humidity = num(pol["relHumSts"])
        }
        if let safe = d["drivingSafetyStatus"] as? [String: Any] {
            centralLockRaw = Int(num(safe["centralLockingStatus"]))
            doorLocked = num(safe["centralLockingStatus"]) == 1
            let doors = ["doorOpenStatusDriver", "doorOpenStatusPassenger",
                         "doorOpenStatusDriverRear", "doorOpenStatusPassengerRear"]
            doorOpenAny = doors.contains { num(safe[$0]) != 0 }
            trunkOpen = num(safe["trunkOpenStatus"]) != 0
            hoodOpen = num(safe["engineHoodOpenStatus"]) != 0
        }

        // 总续航直接用服务端给的 combinedDistanceToEmpty，不再本地折算。
        // 只有当服务端没给（0）时才回退成「电续航 + 油续航」。
        if totalRange <= 0 { totalRange = distanceToEmpty + fuelRange }
    }

    var batteryText: String { String(format: "%.0f%%", chargeLevel) }
    var rangeText: String { String(format: "%.0f km", totalRange) }
    var climateText: String {
        if preClimateActive { return String(format: "预设 %.1f°", climateTarget) }
        return String(format: "%.1f°", interiorTemp)
    }
    var lockText: String { doorLocked ? "已锁车" : "未锁车" }
    var location: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    var hasLocation: Bool { latitude != 0 && longitude != 0 }

    /// 数据新鲜度：「刚刚 / x 分钟前 / x 小时前 / x 天前」
    var updatedAgo: String {
        guard updateTime > Date(timeIntervalSince1970: 1_600_000_000) else { return "未知" }
        let s = Date().timeIntervalSince(updateTime)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        if s < 86400 { return "\(Int(s / 3600)) 小时前" }
        return "\(Int(s / 86400)) 天前"
    }

    /// 数据是否偏旧（超过 10 分钟）
    var isStale: Bool {
        guard updateTime > Date(timeIntervalSince1970: 1_600_000_000) else { return true }
        return Date().timeIntervalSince(updateTime) > 600
    }
}

// MARK: - 取值助手

func num(_ v: Any?) -> Double {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let s = v as? String { return Double(s) ?? 0 }
    if let n = v as? NSNumber { return n.doubleValue }
    return 0
}

func bool(_ v: Any?) -> Bool {
    if let b = v as? Bool { return b }
    if let i = v as? Int { return i != 0 }
    if let s = v as? String { return s == "true" || s == "1" }
    return false
}
