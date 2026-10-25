import CoreLocation
import Darwin
import Foundation
import MapKit

// MARK: - Coordinates, Landmarks & GCJ-02 / WGS-84 Calibration

enum CoordinateReferenceSystem: String, Codable, Equatable, Sendable {
    case gcj02
    case wgs84
    case auto
}

struct GeoBoundingBox: Codable, Equatable, Sendable {
    var minLatitude: Double
    var maxLatitude: Double
    var minLongitude: Double
    var maxLongitude: Double

    func contains(latitude: Double, longitude: Double) -> Bool {
        latitude >= minLatitude && latitude <= maxLatitude &&
        longitude >= minLongitude && longitude <= maxLongitude
    }

    static let mainlandChina = GeoBoundingBox(
        minLatitude: 18.15,
        maxLatitude: 53.55,
        minLongitude: 73.66,
        maxLongitude: 135.05
    )
}

struct GeoCoordinate: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var name: String
    var subtitle: String
    var coordinateSystem: CoordinateReferenceSystem

    init(
        latitude: Double,
        longitude: Double,
        name: String = "自定义选点",
        subtitle: String = "地图拾取坐标",
        coordinateSystem: CoordinateReferenceSystem = .auto
    ) {
        self.latitude = max(-85.0, min(85.0, latitude))
        self.longitude = max(-180.0, min(180.0, longitude))
        self.name = name
        self.subtitle = subtitle
        self.coordinateSystem = coordinateSystem
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var formattedLatLon: String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }
}

struct LocationLandmarkItem: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(name)-\(String(format: "%.5f-%.5f", latitude, longitude))" }
    let name: String
    let subtitle: String
    let city: String
    let latitude: Double
    let longitude: Double
    var coordinateSystem: CoordinateReferenceSystem?

    init(
        name: String,
        subtitle: String,
        city: String,
        latitude: Double,
        longitude: Double,
        coordinateSystem: CoordinateReferenceSystem? = .gcj02
    ) {
        self.name = name
        self.subtitle = subtitle
        self.city = city
        self.latitude = latitude
        self.longitude = longitude
        self.coordinateSystem = coordinateSystem
    }

    var coordinate: GeoCoordinate {
        GeoCoordinate(
            latitude: latitude,
            longitude: longitude,
            name: name,
            subtitle: "\(city) · \(subtitle)",
            coordinateSystem: coordinateSystem ?? .auto
        )
    }
}

struct DeveloperLocationBundleConfig: Codable, Equatable, Sendable {
    var defaultLatitude: Double
    var defaultLongitude: Double
    var defaultLabel: String
    var defaultCoordinateSystem: CoordinateReferenceSystem
    var driftEnabledByDefault: Bool
    var coordinateCalibrationByDefault: Bool
    var driftIntervalMs: Int
    var driftJitterMs: Int
    var driftMinRadiusMeters: Double
    var driftMaxRadiusMeters: Double
    var altitudeMeters: Double
    var horizontalAccuracyMeters: Double
    var gcj02Bounds: GeoBoundingBox

    static let fallback = DeveloperLocationBundleConfig(
        defaultLatitude: 31.230416,
        defaultLongitude: 121.473701,
        defaultLabel: "示例位置",
        defaultCoordinateSystem: .gcj02,
        driftEnabledByDefault: true,
        coordinateCalibrationByDefault: true,
        driftIntervalMs: 100,
        driftJitterMs: 10,
        driftMinRadiusMeters: 1.5,
        driftMaxRadiusMeters: 10.0,
        altitudeMeters: 15.0,
        horizontalAccuracyMeters: 3.2,
        gcj02Bounds: .mainlandChina
    )
}

enum CoordinateTransform {
    private static let a = 6378245.0
    private static let ee = 0.00669342162296594323
    private static let earthRadiusMeters = 6_371_008.8

    static func isInsideMainlandChina(
        latitude: Double,
        longitude: Double,
        bounds: GeoBoundingBox = .mainlandChina
    ) -> Bool {
        bounds.contains(latitude: latitude, longitude: longitude)
    }

    static func wgs84ToGCJ02(
        latitude: Double,
        longitude: Double,
        bounds: GeoBoundingBox = .mainlandChina
    ) -> (latitude: Double, longitude: Double) {
        guard isInsideMainlandChina(latitude: latitude, longitude: longitude, bounds: bounds) else {
            return (latitude, longitude)
        }
        let (dLat, dLon) = delta(latitude: latitude, longitude: longitude)
        return (latitude + dLat, longitude + dLon)
    }

    /// High-precision fixed-point inverse converting GCJ-02 coordinates
    /// back to raw WGS-84 satellite coordinates for hardware GNSS injection.
    static func gcj02ToWGS84(
        latitude: Double,
        longitude: Double,
        bounds: GeoBoundingBox = .mainlandChina
    ) -> (latitude: Double, longitude: Double) {
        guard isInsideMainlandChina(latitude: latitude, longitude: longitude, bounds: bounds) else {
            return (latitude, longitude)
        }
        var wgsLat = latitude
        var wgsLon = longitude
        for _ in 0..<4 {
            let (dLat, dLon) = delta(latitude: wgsLat, longitude: wgsLon)
            let mappedLat = wgsLat + dLat
            let mappedLon = wgsLon + dLon
            wgsLat -= (mappedLat - latitude)
            wgsLon -= (mappedLon - longitude)
        }
        return (wgsLat, wgsLon)
    }

    static func distanceMeters(
        fromLat lat1: Double,
        fromLon lon1: Double,
        toLat lat2: Double,
        toLon lon2: Double
    ) -> Double {
        let phi1 = lat1 * .pi / 180.0
        let phi2 = lat2 * .pi / 180.0
        let dPhi = (lat2 - lat1) * .pi / 180.0
        let dLambda = (lon2 - lon1) * .pi / 180.0
        let sinDPhi = sin(dPhi / 2.0)
        let sinDLambda = sin(dLambda / 2.0)
        let aVal = sinDPhi * sinDPhi + cos(phi1) * cos(phi2) * sinDLambda * sinDLambda
        let cVal = 2.0 * atan2(sqrt(max(0.0, aVal)), sqrt(max(0.0, 1.0 - aVal)))
        return earthRadiusMeters * cVal
    }

    static func bearingDegrees(
        fromLat lat1: Double,
        fromLon lon1: Double,
        toLat lat2: Double,
        toLon lon2: Double
    ) -> Double {
        let phi1 = lat1 * .pi / 180.0
        let phi2 = lat2 * .pi / 180.0
        let dLambda = (lon2 - lon1) * .pi / 180.0
        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        let deg = atan2(y, x) * 180.0 / .pi
        return (deg + 360.0).truncatingRemainder(dividingBy: 360.0)
    }

    static func offsetCoordinate(
        baseLatitude: Double,
        baseLongitude: Double,
        northMeters: Double,
        eastMeters: Double
    ) -> (latitude: Double, longitude: Double) {
        let metersPerDegLat = earthRadiusMeters * .pi / 180.0
        let cosLat = max(0.05, cos(baseLatitude * .pi / 180.0))
        let metersPerDegLon = metersPerDegLat * cosLat
        let dLat = northMeters / metersPerDegLat
        let dLon = eastMeters / metersPerDegLon
        return (baseLatitude + dLat, baseLongitude + dLon)
    }

    private static func delta(latitude: Double, longitude: Double) -> (Double, Double) {
        var dLat = transformLat(x: longitude - 105.0, y: latitude - 35.0)
        var dLon = transformLon(x: longitude - 105.0, y: latitude - 35.0)
        let radLat = latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1.0 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1.0 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return (dLat, dLon)
    }

    private static func transformLat(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }
}

// MARK: - 100ms / 10m Hardware GNSS Drift Engine

struct HardwareLocationFixSample: Equatable, Sendable {
    let baseCoordinate: GeoCoordinate
    let driftedMapLatitude: Double
    let driftedMapLongitude: Double
    let hardwareWGS84Latitude: Double
    let hardwareWGS84Longitude: Double
    let altitudeMeters: Double
    let driftDistanceMeters: Double
    let bearingDegrees: Double
    let velocityKnots: Double
    let satellites: Int

    var qemuGeoFixCommand: String {
        String(
            format: "geo fix %.7f %.7f %.1f %d %.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            hardwareWGS84Longitude,
            hardwareWGS84Latitude,
            altitudeMeters,
            satellites,
            velocityKnots
        )
    }
}

struct HardwareLocationDriftEngine: Sendable {
    private(set) var currentNorthMeters: Double = 0.0
    private(set) var currentEastMeters: Double = 0.0

    mutating func reset() {
        currentNorthMeters = 0.0
        currentEastMeters = 0.0
    }

    mutating func nextSample(
        base: GeoCoordinate,
        altitudeMeters: Double,
        driftEnabled: Bool,
        maxRadiusMeters: Double = 10.0,
        calibrateGCJ02ToWGS84: Bool = true,
        gcj02Bounds: GeoBoundingBox = .mainlandChina,
        randomUnit: () -> Double = { Double.random(in: 0.0...1.0) }
    ) -> HardwareLocationFixSample {
        let clampedMaxRadius = max(0.5, min(50.0, maxRadiusMeters))
        let prevNorth = currentNorthMeters
        let prevEast = currentEastMeters
        let north: Double
        let east: Double
        let speedKnots: Double

        if driftEnabled {
            let uRadius = max(0.0, min(1.0, randomUnit()))
            let uAngle = max(0.0, min(1.0, randomUnit()))
            let targetRadius = clampedMaxRadius * sqrt(uRadius)
            let theta = uAngle * 2.0 * .pi
            let targetNorth = targetRadius * cos(theta)
            let targetEast = targetRadius * sin(theta)

            var candidateNorth = currentNorthMeters * 0.45 + targetNorth * 0.55
            var candidateEast = currentEastMeters * 0.45 + targetEast * 0.55
            let radial = hypot(candidateNorth, candidateEast)
            if radial > clampedMaxRadius {
                let scale = (clampedMaxRadius * 0.98) / radial
                candidateNorth *= scale
                candidateEast *= scale
            } else if radial < 0.15 {
                let nudge = min(1.2, clampedMaxRadius * 0.25)
                candidateNorth = nudge * cos(theta)
                candidateEast = nudge * sin(theta)
            }
            currentNorthMeters = candidateNorth
            currentEastMeters = candidateEast
            north = candidateNorth
            east = candidateEast
            let stepMeters = hypot(north - prevNorth, east - prevEast)
            speedKnots = min(2.5, max(0.2, stepMeters * 0.35))
        } else {
            currentNorthMeters = 0.0
            currentEastMeters = 0.0
            north = 0.0
            east = 0.0
            speedKnots = 0.0
        }

        var (driftedMapLat, driftedMapLon) = CoordinateTransform.offsetCoordinate(
            baseLatitude: base.latitude,
            baseLongitude: base.longitude,
            northMeters: north,
            eastMeters: east
        )

        var rawDistance = CoordinateTransform.distanceMeters(
            fromLat: base.latitude,
            fromLon: base.longitude,
            toLat: driftedMapLat,
            toLon: driftedMapLon
        )
        if rawDistance > clampedMaxRadius && rawDistance > 0.0 {
            let ratio = (clampedMaxRadius * 0.995) / rawDistance
            currentNorthMeters *= ratio
            currentEastMeters *= ratio
            (driftedMapLat, driftedMapLon) = CoordinateTransform.offsetCoordinate(
                baseLatitude: base.latitude,
                baseLongitude: base.longitude,
                northMeters: currentNorthMeters,
                eastMeters: currentEastMeters
            )
            rawDistance = CoordinateTransform.distanceMeters(
                fromLat: base.latitude,
                fromLon: base.longitude,
                toLat: driftedMapLat,
                toLon: driftedMapLon
            )
        }
        let measuredDistance = min(clampedMaxRadius, rawDistance)
        let stepNorth = north - prevNorth
        let stepEast = east - prevEast
        let bearing = driftEnabled
            ? (
                hypot(stepNorth, stepEast) > 0.001
                    ? ((atan2(stepEast, stepNorth) * 180.0 / .pi) + 360.0).truncatingRemainder(dividingBy: 360.0)
                    : CoordinateTransform.bearingDegrees(
                        fromLat: base.latitude,
                        fromLon: base.longitude,
                        toLat: driftedMapLat,
                        toLon: driftedMapLon
                    )
            )
            : 0.0

        let shouldConvertGCJ02: Bool = {
            guard calibrateGCJ02ToWGS84 else { return false }
            switch base.coordinateSystem {
            case .wgs84:
                return false
            case .gcj02:
                return CoordinateTransform.isInsideMainlandChina(
                    latitude: driftedMapLat,
                    longitude: driftedMapLon,
                    bounds: gcj02Bounds
                )
            case .auto:
                return CoordinateTransform.isInsideMainlandChina(
                    latitude: driftedMapLat,
                    longitude: driftedMapLon,
                    bounds: gcj02Bounds
                )
            }
        }()

        let (hwLat, hwLon): (Double, Double)
        if shouldConvertGCJ02 {
            (hwLat, hwLon) = CoordinateTransform.gcj02ToWGS84(
                latitude: driftedMapLat,
                longitude: driftedMapLon,
                bounds: gcj02Bounds
            )
        } else {
            (hwLat, hwLon) = (driftedMapLat, driftedMapLon)
        }

        let altJitter = driftEnabled ? ((randomUnit() - 0.5) * 0.8) : 0.0
        let satChoices = [10, 11, 12, 9, 11]
        let satIdx = Int(abs(north * 13.0 + east * 7.0)) % satChoices.count

        return HardwareLocationFixSample(
            baseCoordinate: base,
            driftedMapLatitude: driftedMapLat,
            driftedMapLongitude: driftedMapLon,
            hardwareWGS84Latitude: hwLat,
            hardwareWGS84Longitude: hwLon,
            altitudeMeters: max(1.0, altitudeMeters + altJitter),
            driftDistanceMeters: driftEnabled ? measuredDistance : 0.0,
            bearingDegrees: bearing,
            velocityKnots: speedKnots,
            satellites: satChoices[satIdx]
        )
    }
}

// MARK: - Low-Latency Framed QEMU Emulator Console Transport

protocol LocationConsoleTransport: Sendable {
    func sendGeoFix(
        sample: HardwareLocationFixSample,
        port: UInt16,
        authTokenURLs: [URL]
    ) async -> Bool
    func disconnect() async
}

actor SocketEmulatorConsoleTransport: LocationConsoleTransport {
    private var socketFD: Int32 = -1
    private var connectedPort: UInt16 = 0
    private var authenticated: Bool = false

    func sendGeoFix(
        sample: HardwareLocationFixSample,
        port: UInt16,
        authTokenURLs: [URL]
    ) async -> Bool {
        let cmd = sample.qemuGeoFixCommand + "\r\n"
        if ensureConnectedAndAuthenticated(port: port, authTokenURLs: authTokenURLs) {
            if writeAll(cmd), readFramedCommandReply(timeoutMs: 180) {
                return true
            }
            closeSocket()
            if ensureConnectedAndAuthenticated(port: port, authTokenURLs: authTokenURLs),
               writeAll(cmd),
               readFramedCommandReply(timeoutMs: 180) {
                return true
            }
            closeSocket()
        }
        return false
    }

    func disconnect() async {
        closeSocket()
    }

    private func ensureConnectedAndAuthenticated(port: UInt16, authTokenURLs: [URL]) -> Bool {
        if socketFD >= 0 && connectedPort == port && authenticated {
            return true
        }
        closeSocket()

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            Darwin.close(fd)
            return false
        }

        socketFD = fd
        connectedPort = port

        guard let banner = readUntilCompleteFrame(timeoutMs: 220) else {
            closeSocket()
            return false
        }
        let requiresAuth = banner.contains("Authentication required")
        let tokens = Self.readAuthTokens(from: authTokenURLs)
        if requiresAuth || !tokens.isEmpty {
            var authSucceeded = false
            for token in tokens {
                guard writeAll("auth \(token)\r\n") else { continue }
                if readFramedCommandReply(timeoutMs: 220) {
                    authSucceeded = true
                    break
                }
            }
            if requiresAuth && !authSucceeded {
                closeSocket()
                return false
            }
        }
        authenticated = true
        return true
    }

    private static func readAuthTokens(from urls: [URL]) -> [String] {
        var results: [String] = []
        for url in urls {
            if let raw = try? String(contentsOf: url, encoding: .utf8) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !results.contains(trimmed) {
                    results.append(trimmed)
                }
            }
        }
        let fallbackHome = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".emulator_console_auth_token")
        if let raw = try? String(contentsOf: fallbackHome, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !results.contains(trimmed) {
                results.append(trimmed)
            }
        }
        return results
    }

    private func writeAll(_ text: String) -> Bool {
        guard socketFD >= 0 else { return false }
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.send(socketFD, base.advanced(by: sent), bytes.count - sent, 0)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    private func readUntilCompleteFrame(timeoutMs: Int32) -> String? {
        guard socketFD >= 0 else { return nil }
        let deadline = ContinuousClock.now + .milliseconds(Int(timeoutMs))
        var collected = ""
        var buffer = [UInt8](repeating: 0, count: 512)

        while ContinuousClock.now < deadline {
            var pfd = pollfd(fd: socketFD, events: Int16(POLLIN | POLLERR | POLLHUP), revents: 0)
            let ready = Darwin.poll(&pfd, 1, 25)
            if ready < 0 {
                return nil
            }
            if (pfd.revents & Int16(POLLERR | POLLHUP)) != 0 && (pfd.revents & Int16(POLLIN)) == 0 {
                return nil
            }
            if ready > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                let n = Darwin.recv(socketFD, &buffer, buffer.count, 0)
                if n <= 0 {
                    return nil
                }
                collected += String(decoding: buffer.prefix(n), as: UTF8.self)
                let lines = collected
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .split(separator: "\n", omittingEmptySubsequences: false)
                if lines.count >= 2 {
                    for line in lines.dropLast() {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed == "OK" || trimmed.hasPrefix("OK:") || trimmed.hasPrefix("KO:") {
                            return collected
                        }
                    }
                }
            }
        }
        return nil
    }

    private func readFramedCommandReply(timeoutMs: Int32) -> Bool {
        guard let frame = readUntilCompleteFrame(timeoutMs: timeoutMs) else {
            return false
        }
        let lines = frame
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.hasPrefix("KO:") }) {
            return false
        }
        return lines.contains(where: { $0 == "OK" || $0.hasPrefix("OK:") })
    }

    private func closeSocket() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        connectedPort = 0
        authenticated = false
    }
}

// MARK: - Developer Location Configuration, Search Status & Live Telemetry

enum LocationSearchOutcome: Equatable, Sendable {
    case results([GeoCoordinate])
    case empty(query: String)
    case failed(query: String, reason: String)
}

struct DeveloperLocationConfiguration: Codable, Equatable, Sendable {
    var selectedCoordinate: GeoCoordinate
    var altitudeMeters: Double
    var driftEnabled: Bool
    var driftIntervalMs: Int
    var driftRadiusMeters: Double
    var calibrateGCJ02ToWGS84: Bool

    init(
        selectedCoordinate: GeoCoordinate,
        altitudeMeters: Double = 15.0,
        driftEnabled: Bool = true,
        driftIntervalMs: Int = 100,
        driftRadiusMeters: Double = 10.0,
        calibrateGCJ02ToWGS84: Bool = true
    ) {
        self.selectedCoordinate = selectedCoordinate
        self.altitudeMeters = altitudeMeters
        self.driftEnabled = driftEnabled
        self.driftIntervalMs = max(50, min(1000, driftIntervalMs))
        self.driftRadiusMeters = max(1.0, min(50.0, driftRadiusMeters))
        self.calibrateGCJ02ToWGS84 = calibrateGCJ02ToWGS84
    }

    static func fromBundleConfig(_ config: DeveloperLocationBundleConfig, firstLandmark: LocationLandmarkItem?) -> DeveloperLocationConfiguration {
        let initialCoord = firstLandmark?.coordinate ?? GeoCoordinate(
            latitude: config.defaultLatitude,
            longitude: config.defaultLongitude,
            name: config.defaultLabel,
            subtitle: "插件默认坐标",
            coordinateSystem: config.defaultCoordinateSystem
        )
        return DeveloperLocationConfiguration(
            selectedCoordinate: initialCoord,
            altitudeMeters: config.altitudeMeters,
            driftEnabled: config.driftEnabledByDefault,
            driftIntervalMs: config.driftIntervalMs,
            driftRadiusMeters: config.driftMaxRadiusMeters,
            calibrateGCJ02ToWGS84: config.coordinateCalibrationByDefault
        )
    }
}

struct DeveloperLocationTelemetry: Equatable, Sendable {
    var pluginID: String
    var isPluginInstalled: Bool
    var isPluginEnabled: Bool
    var healthState: SystemPluginHealthState
    var driftEnabled: Bool
    var driftIntervalMs: Int
    var driftRadiusMeters: Double
    var calibrateGCJ02ToWGS84: Bool
    var baseCoordinate: GeoCoordinate
    var currentMapLatitude: Double
    var currentMapLongitude: Double
    var hardwareWGS84Latitude: Double
    var hardwareWGS84Longitude: Double
    var altitudeMeters: Double
    var currentDriftDistanceMeters: Double
    var currentBearingDegrees: Double
    var currentVelocityKnots: Double
    var satellites: Int
    var injectedFrameCount: UInt64
    var lastGeoFixCommand: String
}

// MARK: - Bundle-Driven Developer Location Plugin Instance

@MainActor
final class DeveloperLocationPlugin: HotPluggableSystemPlugin {
    let manifest: SystemPluginManifest
    let bundleDirectoryURL: URL
    private(set) var bundleConfig: DeveloperLocationBundleConfig
    private(set) var landmarks: [LocationLandmarkItem]
    private(set) var isEnabled: Bool = false
    private(set) var healthState: SystemPluginHealthState = .inactive
    private(set) var lastSample: HardwareLocationFixSample?
    private(set) var injectedFrameCount: UInt64 = 0
    private(set) var lastSearchOutcome: LocationSearchOutcome?

    weak var hostBridge: SystemPluginHostBridge?
    var onTelemetryChanged: ((DeveloperLocationTelemetry) -> Void)?

    private let defaults: UserDefaults
    private let consoleTransport: any LocationConsoleTransport
    private let configDefaultsKey: String
    private var driftEngine = HardwareLocationDriftEngine()
    private var loopTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var configurationRevision: UInt64 = 0
    private var needsDeferredRuntimeSetup: Bool = false
    private var setupGeneration: UInt64?
    private var nextSetupRetry: ContinuousClock.Instant?
    private var pendingSetupHooks: [String] = []
    private var isDeleted = false
    private let activity = SystemPluginActivity()

    var configuration: DeveloperLocationConfiguration {
        didSet {
            persistConfiguration()
        }
    }

    var runtimeStatusSummary: String {
        guard isEnabled else {
            return "未启用"
        }
        let coord = configuration.selectedCoordinate
        switch healthState {
        case .inactive:
            return "未启用"
        case .waitingForRuntime:
            return "当前位置：\(coord.name) · 等待安卓容器就绪"
        case .degraded(let detail):
            return "当前位置：\(coord.name) · \(detail)"
        case .healthy:
            if configuration.driftEnabled {
                return "当前位置：\(coord.name) · \(Int(configuration.driftRadiusMeters))m 自动漂移中"
            }
            return "当前位置：\(coord.name) · 定点模式"
        }
    }

    init(
        manifest: SystemPluginManifest,
        bundleDirectoryURL: URL,
        defaults: UserDefaults = .standard,
        consoleTransport: (any LocationConsoleTransport)? = nil
    ) {
        self.manifest = manifest
        self.bundleDirectoryURL = bundleDirectoryURL.standardizedFileURL
        self.defaults = defaults
        self.consoleTransport = consoleTransport ?? SocketEmulatorConsoleTransport()
        self.configDefaultsKey = Self.configurationDefaultsKey(id: manifest.id)

        let loadedConfig = Self.loadBundleConfig(from: bundleDirectoryURL, manifest: manifest)
        let loadedLandmarks = Self.loadBundleLandmarks(from: bundleDirectoryURL, manifest: manifest, fallbackConfig: loadedConfig)
        self.bundleConfig = loadedConfig
        self.landmarks = loadedLandmarks

        if let data = defaults.data(forKey: self.configDefaultsKey),
           let decoded = try? JSONDecoder().decode(DeveloperLocationConfiguration.self, from: data) {
            self.configuration = decoded
        } else {
            self.configuration = DeveloperLocationConfiguration.fromBundleConfig(
                loadedConfig,
                firstLandmark: loadedLandmarks.first
            )
        }
    }

    private static func loadBundleConfig(from bundleURL: URL, manifest: SystemPluginManifest) -> DeveloperLocationBundleConfig {
        let rootPath = bundleURL.standardizedFileURL.path
        let rel = manifest.entrypoints.configFile ?? "resources/plugin-config.json"
        guard !rel.contains("..") else { return .fallback }
        let configURL = bundleURL.appendingPathComponent(rel).standardizedFileURL
        guard configURL.path.hasPrefix(rootPath + "/"),
              let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(DeveloperLocationBundleConfig.self, from: data) else {
            return .fallback
        }
        return decoded
    }

    private static func loadBundleLandmarks(
        from bundleURL: URL,
        manifest: SystemPluginManifest,
        fallbackConfig: DeveloperLocationBundleConfig
    ) -> [LocationLandmarkItem] {
        let rootPath = bundleURL.standardizedFileURL.path
        if let presetsRel = manifest.entrypoints.presetsFile, !presetsRel.contains("..") {
            let presetsURL = bundleURL.appendingPathComponent(presetsRel).standardizedFileURL
            if presetsURL.path.hasPrefix(rootPath + "/"),
               let data = try? Data(contentsOf: presetsURL),
               let loaded = try? JSONDecoder().decode([LocationLandmarkItem].self, from: data),
               !loaded.isEmpty {
                return loaded
            }
        }
        return [
            LocationLandmarkItem(
                name: fallbackConfig.defaultLabel,
                subtitle: "插件默认选点",
                city: "默认",
                latitude: fallbackConfig.defaultLatitude,
                longitude: fallbackConfig.defaultLongitude,
                coordinateSystem: fallbackConfig.defaultCoordinateSystem
            )
        ]
    }

    // MARK: - HotPluggableSystemPlugin Lifecycle

    func setEnabledWithoutBridge(_ enabled: Bool) async {
        guard !isDeleted else { return }
        lifecycleGeneration &+= 1
        setupGeneration = nil
        nextSetupRetry = nil
        isEnabled = enabled
        loopTask?.cancel()
        loopTask = nil
        if enabled {
            needsDeferredRuntimeSetup = true
            resetRuntimeSetupHooks()
            healthState = .waitingForRuntime
        } else {
            needsDeferredRuntimeSetup = false
            pendingSetupHooks.removeAll()
            await activity.waitUntilIdle()
            driftEngine.reset()
            healthState = .inactive
            await consoleTransport.disconnect()
        }
        emitTelemetry()
    }

    func activate(bridge: SystemPluginHostBridge) async {
        guard !isDeleted else { return }
        lifecycleGeneration &+= 1
        let capturedGen = lifecycleGeneration
        hostBridge = bridge
        isEnabled = true
        needsDeferredRuntimeSetup = true
        nextSetupRetry = nil
        resetRuntimeSetupHooks()
        driftEngine.reset()

        let state = bridge.currentRuntimeState
        guard state == .ready || state == .running else {
            healthState = .waitingForRuntime
            emitTelemetry()
            return
        }

        _ = await performRuntimeSetup(bridge: bridge)
        guard isEnabled, lifecycleGeneration == capturedGen else { return }

        _ = await injectSingleTick()
        guard isEnabled, lifecycleGeneration == capturedGen else { return }
        startInjectionLoop(capturedGeneration: capturedGen)
        emitTelemetry()
    }

    @discardableResult
    func deactivate(bridge: SystemPluginHostBridge) async -> Bool {
        lifecycleGeneration &+= 1
        let wasEnabled = isEnabled
        isEnabled = false
        needsDeferredRuntimeSetup = false
        setupGeneration = nil
        nextSetupRetry = nil
        pendingSetupHooks.removeAll()
        loopTask?.cancel()
        loopTask = nil
        driftEngine.reset()
        await activity.waitUntilIdle()
        await consoleTransport.disconnect()
        if (bridge.currentRuntimeState == .ready || bridge.currentRuntimeState == .running),
           let hook = manifest.entrypoints.onDisable {
            guard await runBundleGuestScript(relativePath: hook, bridge: bridge) else {
                isEnabled = wasEnabled
                needsDeferredRuntimeSetup = true
                resetRuntimeSetupHooks()
                nextSetupRetry = .now + .seconds(2)
                healthState = .degraded("停用失败，请重试")
                startInjectionLoop(capturedGeneration: lifecycleGeneration)
                emitTelemetry()
                return false
            }
        }
        healthState = .inactive
        emitTelemetry()
        return true
    }

    func deletePersistentData() {
        retire()
        Self.deleteStoredConfiguration(id: manifest.id, defaults: defaults)
    }

    func retire() {
        isDeleted = true
        isEnabled = false
        lifecycleGeneration &+= 1
        loopTask?.cancel()
        loopTask = nil
        pendingSetupHooks.removeAll()
        onTelemetryChanged = nil
    }

    static func deleteStoredConfiguration(id: String, defaults: UserDefaults) {
        defaults.removeObject(forKey: configurationDefaultsKey(id: id))
    }

    private static func configurationDefaultsKey(id: String) -> String {
        "AndroidUse.DeveloperLocationPlugin.configuration.\(id)"
    }

    func onRuntimeBecameReady(bridge: SystemPluginHostBridge) async {
        hostBridge = bridge
        guard isEnabled else { return }
        enqueueSetupHook(manifest.entrypoints.onRuntimeReady ?? manifest.entrypoints.onEnable)
        let capturedGen = lifecycleGeneration
        if setupGeneration != nil {
            // A user action may own setup before readiness arrives; keep retries and fixes scheduled.
            if loopTask == nil {
                startInjectionLoop(capturedGeneration: capturedGen)
            }
            return
        }
        _ = await performRuntimeSetup(bridge: bridge)
        guard isEnabled, lifecycleGeneration == capturedGen else { return }
        _ = await injectSingleTick()
        guard isEnabled, lifecycleGeneration == capturedGen else { return }
        startInjectionLoop(capturedGeneration: capturedGen)
        emitTelemetry()
    }

    func onAppLaunching(package: String, bridge: SystemPluginHostBridge) async {
        hostBridge = bridge
        guard isEnabled else { return }
        _ = await runBundleGuestScript(
            relativePath: manifest.entrypoints.onAppLaunch,
            bridge: bridge,
            extraEnv: ["ANDROID_USE_ACTIVE_PACKAGE": package]
        )
        _ = await injectSingleTick()
    }

    func onRuntimeStopping(bridge: SystemPluginHostBridge) async {
        lifecycleGeneration &+= 1
        setupGeneration = nil
        nextSetupRetry = nil
        if isEnabled { resetRuntimeSetupHooks() }
        loopTask?.cancel()
        loopTask = nil
        await activity.waitUntilIdle()
        await consoleTransport.disconnect()
        if isEnabled {
            needsDeferredRuntimeSetup = true
            healthState = .waitingForRuntime
        }
        emitTelemetry()
    }

    // MARK: - User Actions: Select Coordinate, Toggle Drift, Calibrate

    func selectLocation(_ coordinate: GeoCoordinate) {
        configurationRevision &+= 1
        var next = configuration
        next.selectedCoordinate = coordinate
        configuration = next
        driftEngine.reset()
        lastSample = nil
        emitTelemetry()
        if isEnabled {
            Task { @MainActor [weak self] in
                _ = await self?.injectSingleTick()
            }
        }
    }

    func setDriftEnabled(_ enabled: Bool) {
        configurationRevision &+= 1
        var next = configuration
        next.driftEnabled = enabled
        configuration = next
        if !enabled {
            driftEngine.reset()
            lastSample = nil
        }
        emitTelemetry()
        if isEnabled {
            Task { @MainActor [weak self] in
                _ = await self?.injectSingleTick()
            }
        }
    }

    func setCoordinateCalibrationEnabled(_ enabled: Bool) {
        configurationRevision &+= 1
        var next = configuration
        next.calibrateGCJ02ToWGS84 = enabled
        configuration = next
        lastSample = nil
        emitTelemetry()
        if isEnabled {
            Task { @MainActor [weak self] in
                _ = await self?.injectSingleTick()
            }
        }
    }

    func currentTelemetrySnapshot() -> DeveloperLocationTelemetry {
        let base = configuration.selectedCoordinate
        let sample = lastSample ?? {
            var previewEngine = HardwareLocationDriftEngine()
            return previewEngine.nextSample(
                base: base,
                altitudeMeters: configuration.altitudeMeters,
                driftEnabled: false,
                maxRadiusMeters: configuration.driftRadiusMeters,
                calibrateGCJ02ToWGS84: configuration.calibrateGCJ02ToWGS84,
                gcj02Bounds: bundleConfig.gcj02Bounds
            )
        }()
        return DeveloperLocationTelemetry(
            pluginID: manifest.id,
            isPluginInstalled: true,
            isPluginEnabled: isEnabled,
            healthState: healthState,
            driftEnabled: configuration.driftEnabled,
            driftIntervalMs: configuration.driftIntervalMs,
            driftRadiusMeters: configuration.driftRadiusMeters,
            calibrateGCJ02ToWGS84: configuration.calibrateGCJ02ToWGS84,
            baseCoordinate: base,
            currentMapLatitude: sample.driftedMapLatitude,
            currentMapLongitude: sample.driftedMapLongitude,
            hardwareWGS84Latitude: sample.hardwareWGS84Latitude,
            hardwareWGS84Longitude: sample.hardwareWGS84Longitude,
            altitudeMeters: sample.altitudeMeters,
            currentDriftDistanceMeters: sample.driftDistanceMeters,
            currentBearingDegrees: sample.bearingDegrees,
            currentVelocityKnots: sample.velocityKnots,
            satellites: sample.satellites,
            injectedFrameCount: injectedFrameCount,
            lastGeoFixCommand: sample.qemuGeoFixCommand
        )
    }

    // MARK: - Search Locations (Coordinate String + Landmarks + Apple MKLocalSearch)

    func searchLocationsWithStatus(query: String) async -> LocationSearchOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let defaults = landmarks.map(\.coordinate)
            let outcome = LocationSearchOutcome.results(defaults)
            lastSearchOutcome = outcome
            return outcome
        }

        var results: [GeoCoordinate] = []

        // 1. Direct coordinate string parser ("22.541664, 114.104519" or "114.104519 22.541664")
        if let parsed = Self.parseCoordinateQuery(trimmed) {
            results.append(parsed)
        }

        // 2. Bundle preset landmarks matching
        let qLower = trimmed.lowercased()
        for item in landmarks {
            if item.name.lowercased().contains(qLower)
                || item.subtitle.lowercased().contains(qLower)
                || item.city.lowercased().contains(qLower) {
                results.append(item.coordinate)
            }
        }

        // 3. MapKit MKLocalSearch for real-world addresses, buildings, and POIs
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        let center = configuration.selectedCoordinate.clCoordinate
        request.region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: 50_000,
            longitudinalMeters: 50_000
        )
        let search = MKLocalSearch(request: request)
        var remoteErrorReason: String?
        do {
            let response = try await search.start()
            for mapItem in response.mapItems.prefix(8) {
                let c = mapItem.placemark.coordinate
                guard CLLocationCoordinate2DIsValid(c) else { continue }
                let title = mapItem.name ?? trimmed
                let locality = [
                    mapItem.placemark.LocalityOrCity,
                    mapItem.placemark.subLocality,
                    mapItem.placemark.thoroughfare
                ].compactMap { $0 }.joined(separator: " ")
                let isInChina = CoordinateTransform.isInsideMainlandChina(
                    latitude: c.latitude,
                    longitude: c.longitude,
                    bounds: bundleConfig.gcj02Bounds
                )
                let candidate = GeoCoordinate(
                    latitude: c.latitude,
                    longitude: c.longitude,
                    name: title,
                    subtitle: locality.isEmpty ? "地图搜索结果" : locality,
                    coordinateSystem: isInChina ? .gcj02 : .wgs84
                )
                if !results.contains(where: {
                    abs($0.latitude - candidate.latitude) < 0.0001 && abs($0.longitude - candidate.longitude) < 0.0001
                }) {
                    results.append(candidate)
                }
            }
        } catch {
            remoteErrorReason = error.localizedDescription
        }

        let outcome: LocationSearchOutcome
        if !results.isEmpty {
            outcome = .results(results)
        } else if let remoteErrorReason {
            outcome = .failed(query: trimmed, reason: remoteErrorReason)
        } else {
            outcome = .empty(query: trimmed)
        }
        lastSearchOutcome = outcome
        return outcome
    }

    func searchLocations(query: String) async -> [GeoCoordinate] {
        switch await searchLocationsWithStatus(query: query) {
        case .results(let list):
            return list
        case .empty, .failed:
            return []
        }
    }

    static func parseCoordinateQuery(_ query: String) -> GeoCoordinate? {
        let parts = query
            .replacingOccurrences(of: "，", with: ",")
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        let a = parts[0]
        let b = parts[1]
        let lat: Double
        let lon: Double
        if abs(a) <= 90.0 && abs(b) <= 180.0 && abs(b) > 90.0 {
            lat = a
            lon = b
        } else if abs(b) <= 90.0 && abs(a) <= 180.0 && abs(a) > 90.0 {
            lat = b
            lon = a
        } else if abs(a) <= 90.0 && abs(b) <= 180.0 {
            lat = a
            lon = b
        } else {
            return nil
        }
        return GeoCoordinate(
            latitude: lat,
            longitude: lon,
            name: String(format: "坐标 (%.5f, %.5f)", lat, lon),
            subtitle: "手动输入经纬度",
            coordinateSystem: .auto
        )
    }

    // MARK: - 100ms Hardware Injection Loop (Monotonic Deadline Scheduled)

    @discardableResult
    func injectSingleTick() async -> HardwareLocationFixSample {
        let capturedGen = lifecycleGeneration
        let sample = driftEngine.nextSample(
            base: configuration.selectedCoordinate,
            altitudeMeters: configuration.altitudeMeters,
            driftEnabled: configuration.driftEnabled,
            maxRadiusMeters: configuration.driftRadiusMeters,
            calibrateGCJ02ToWGS84: configuration.calibrateGCJ02ToWGS84,
            gcj02Bounds: bundleConfig.gcj02Bounds
        )
        lastSample = sample

        guard isEnabled else {
            emitTelemetry()
            return sample
        }

        activity.begin()
        defer { activity.end() }
        if let bridge = hostBridge {
            let state = bridge.currentRuntimeState
            if state == .ready || state == .running {
                if needsDeferredRuntimeSetup {
                    guard setupGeneration == nil,
                          nextSetupRetry.map({ ContinuousClock.now >= $0 }) ?? true else {
                        emitTelemetry()
                        return sample
                    }
                    let configured = await performRuntimeSetup(bridge: bridge)
                    guard configured, isEnabled, lifecycleGeneration == capturedGen else {
                        emitTelemetry()
                        return sample
                    }
                }
                let port = bridge.emulatorConsolePort
                let tokenURLs = bridge.emulatorAuthTokenURLs
                let sentViaSocket = await consoleTransport.sendGeoFix(
                    sample: sample,
                    port: port,
                    authTokenURLs: tokenURLs
                )
                guard isEnabled, lifecycleGeneration == capturedGen else { return sample }
                if sentViaSocket {
                    injectedFrameCount &+= 1
                    healthState = .healthy
                } else if isEnabled,
                          lifecycleGeneration == capturedGen,
                          state == .ready || state == .running {
                    let sentFallback = await bridge.sendEmulatorGeoFix(
                        longitude: sample.hardwareWGS84Longitude,
                        latitude: sample.hardwareWGS84Latitude,
                        altitude: sample.altitudeMeters,
                        satellites: sample.satellites,
                        velocityKnots: sample.velocityKnots
                    )
                    guard isEnabled, lifecycleGeneration == capturedGen else { return sample }
                    if sentFallback {
                        injectedFrameCount &+= 1
                        healthState = .healthy
                    } else {
                        healthState = .degraded("GNSS 通道等待确认")
                    }
                } else {
                    healthState = (state == .starting) ? .waitingForRuntime : .degraded("GNSS 通道等待响应")
                }
            } else {
                healthState = .waitingForRuntime
            }
        } else {
            healthState = .waitingForRuntime
        }
        emitTelemetry()
        return sample
    }

    private func startInjectionLoop(capturedGeneration: UInt64) {
        loopTask?.cancel()
        loopTask = nil
        guard isEnabled, lifecycleGeneration == capturedGeneration else { return }

        loopTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var nextDeadline = clock.now
            while !Task.isCancelled {
                guard let self, self.isEnabled, self.lifecycleGeneration == capturedGeneration else { break }
                if let bridge = self.hostBridge {
                    let state = bridge.currentRuntimeState
                    if state != .ready && state != .running && state != .starting {
                        self.healthState = .waitingForRuntime
                        self.emitTelemetry()
                        break
                    }
                }
                let baseMs = self.configuration.driftEnabled ? self.configuration.driftIntervalMs : 1000
                let jitterRange = self.configuration.driftEnabled ? max(0, self.bundleConfig.driftJitterMs) : 0
                let jitterMs = jitterRange > 0 ? Int.random(in: -jitterRange...jitterRange) : 0
                let stepMs = max(45, baseMs + jitterMs)
                nextDeadline += .milliseconds(stepMs)
                let now = clock.now
                if nextDeadline > now {
                    try? await clock.sleep(until: nextDeadline, tolerance: .milliseconds(4))
                } else {
                    nextDeadline = now
                }
                guard !Task.isCancelled, self.isEnabled, self.lifecycleGeneration == capturedGeneration else { break }
                _ = await self.injectSingleTick()
            }
        }
    }

    private func resetRuntimeSetupHooks() {
        pendingSetupHooks.removeAll()
        enqueueSetupHook(manifest.entrypoints.onEnable)
        enqueueSetupHook(manifest.entrypoints.onRuntimeReady)
    }

    private func enqueueSetupHook(_ path: String?) {
        guard let path, !pendingSetupHooks.contains(path) else { return }
        pendingSetupHooks.append(path)
    }

    private func performRuntimeSetup(bridge: SystemPluginHostBridge) async -> Bool {
        guard setupGeneration == nil else { return false }
        let capturedGen = lifecycleGeneration
        setupGeneration = capturedGen
        defer {
            if setupGeneration == capturedGen { setupGeneration = nil }
        }
        needsDeferredRuntimeSetup = true
        while let hook = pendingSetupHooks.first {
            let success = await runBundleGuestScript(relativePath: hook, bridge: bridge)
            guard isEnabled, lifecycleGeneration == capturedGen else { return false }
            guard success else {
                nextSetupRetry = .now + .seconds(2)
                healthState = .degraded("定位配置未完成，将自动重试")
                return false
            }
            pendingSetupHooks.removeFirst()
        }
        guard isEnabled, lifecycleGeneration == capturedGen else { return false }
        needsDeferredRuntimeSetup = false
        nextSetupRetry = nil
        return true
    }

    @discardableResult
    private func runBundleGuestScript(
        relativePath: String?,
        bridge: SystemPluginHostBridge,
        extraEnv: [String: String] = [:]
    ) async -> Bool {
        guard let relativePath,
              !relativePath.contains(".."),
              !relativePath.hasPrefix("."),
              !relativePath.contains("/.") else {
            return false
        }
        let rootPath = bundleDirectoryURL.standardizedFileURL.path
        let scriptURL = bundleDirectoryURL.appendingPathComponent(relativePath).standardizedFileURL
        guard scriptURL.path.hasPrefix(rootPath + "/"),
              FileManager.default.isReadableFile(atPath: scriptURL.path),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            return false
        }
        var envPrefix = ""
        for (k, v) in extraEnv where k.range(of: #"^[A-Z0-9_]+$"#, options: .regularExpression) != nil {
            let clean = v.replacingOccurrences(of: "'", with: "")
            envPrefix += "export \(k)='\(clean)'\n"
        }
        activity.begin()
        defer { activity.end() }
        return await bridge.executeGuestShell(
            envPrefix + script,
            operation: "配置硬件级 GNSS 定位环境",
            timeout: 12
        )
    }

    private func persistConfiguration() {
        guard !isDeleted else { return }
        if let encoded = try? JSONEncoder().encode(configuration) {
            defaults.set(encoded, forKey: configDefaultsKey)
        }
    }

    private func emitTelemetry() {
        let snapshot = currentTelemetrySnapshot()
        onTelemetryChanged?(snapshot)
    }
}

private extension CLPlacemark {
    var LocalityOrCity: String? {
        locality ?? administrativeArea
    }
}
