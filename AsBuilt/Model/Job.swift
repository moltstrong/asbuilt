import Foundation
import AsBuiltCore

enum CaptureKind: String, Codable, CaseIterable, Hashable, Sendable {
    case room
    case object
    /// ARKit LiDAR scene-reconstruction mesh (any space, object or MEP). Added in build 5.
    case mesh

    var displayName: String {
        switch self {
        case .room: return "Room scan"
        case .object: return "Object capture"
        case .mesh: return "LiDAR Mesh scan"
        }
    }

    var icon: String {
        switch self {
        case .room: return "square.split.bottomrightquarter"
        case .object: return "cube.transparent"
        case .mesh: return "point.3.filled.connected.trianglepath.dotted"
        }
    }

    /// Unknown values (written by a newer build) decode as `.object` so the job still loads.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CaptureKind(rawValue: raw) ?? .object
    }
}

enum CaptureOrigin: String, Codable, Hashable, Sendable {
    /// LiDAR room scan via RoomPlan.
    case roomPlan
    /// Guided photo capture via RealityKit Object Capture.
    case objectCapture
    /// Bundled sample data built from AsBuiltCore models.
    case sample
    /// ARKit scene reconstruction (LiDAR Mesh scan). Added in build 5.
    case lidarMesh
    /// Origin written by a newer build.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CaptureOrigin(rawValue: raw) ?? .unknown
    }
}

enum CaptureStatus: String, Codable, Hashable, Sendable {
    case complete
    /// Photos saved; on-device 3D reconstruction failed or is unavailable (retry, or reconstruct on a Mac).
    case imagesOnly
    case processing
    case failed

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CaptureStatus(rawValue: raw) ?? .failed
    }
}

struct Capture: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var kind: CaptureKind
    var origin: CaptureOrigin
    var title: String
    var createdAt: Date
    var notes: String
    var status: CaptureStatus
    var statusMessage: String?
    var imageCount: Int?
    /// LiDAR mesh scans: bounding box, triangle count and surface areas (also in scan-info.json).
    var measurements: MeshMeasurements?
    /// Object captures: on-device reconstruction attempts made so far (see reconstruction-log.txt).
    var reconstructionAttempts: Int?

    init(id: UUID = UUID(), kind: CaptureKind, origin: CaptureOrigin, title: String, createdAt: Date = Date(),
         notes: String = "", status: CaptureStatus = .complete, statusMessage: String? = nil, imageCount: Int? = nil,
         measurements: MeshMeasurements? = nil, reconstructionAttempts: Int? = nil) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.title = title
        self.createdAt = createdAt
        self.notes = notes
        self.status = status
        self.statusMessage = statusMessage
        self.imageCount = imageCount
        self.measurements = measurements
        self.reconstructionAttempts = reconstructionAttempts
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, origin, title, createdAt, notes, status, statusMessage, imageCount, measurements, reconstructionAttempts
    }

    /// Tolerant decoding: job.json files written by builds 1-4 (no `measurements` /
    /// `reconstructionAttempts`) and by future builds (unknown enum values) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decodeIfPresent(CaptureKind.self, forKey: .kind) ?? .object
        origin = try c.decodeIfPresent(CaptureOrigin.self, forKey: .origin) ?? .unknown
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Capture"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        status = try c.decodeIfPresent(CaptureStatus.self, forKey: .status) ?? .complete
        statusMessage = try c.decodeIfPresent(String.self, forKey: .statusMessage)
        imageCount = try c.decodeIfPresent(Int.self, forKey: .imageCount)
        measurements = try? c.decodeIfPresent(MeshMeasurements.self, forKey: .measurements)
        reconstructionAttempts = try c.decodeIfPresent(Int.self, forKey: .reconstructionAttempts)
    }
}

struct Job: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var address: String
    var client: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var isDemo: Bool
    var captures: [Capture]

    init(id: UUID = UUID(), name: String, address: String = "", client: String = "", notes: String = "",
         createdAt: Date = Date(), updatedAt: Date = Date(), isDemo: Bool = false, captures: [Capture] = []) {
        self.id = id
        self.name = name
        self.address = address
        self.client = client
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDemo = isDemo
        self.captures = captures
    }

    var roomCaptures: [Capture] { captures.filter { $0.kind == .room } }
    var objectCaptures: [Capture] { captures.filter { $0.kind == .object } }
    var meshCaptures: [Capture] { captures.filter { $0.kind == .mesh } }
}

/// Well-known file names inside `Documents/Jobs/<jobId>/<captureId>/`.
enum CaptureFile {
    static let roomUSDZ = "room.usdz"
    static let modelUSDZ = "model.usdz"
    static let roomJSON = "room.json"
    static let planJSON = "plan.json"
    static let dxf = "floorplan.dxf"
    static let svg = "floorplan.svg"
    static let pdf = "floorplan.pdf"
    static let csv = "takeoff.csv"
    static let images = "Images"
    static let checkpoint = "Checkpoint"
    static let reconstructionLog = "reconstruction-log.txt"
    static let meshOBJ = LiDARMeshExporter.objName
    static let meshMTL = LiDARMeshExporter.mtlName
    static let meshPLY = LiDARMeshExporter.plyName
    static let meshCSV = LiDARMeshExporter.csvName
    static let scanInfo = LiDARMeshExporter.infoName

    static func description(for name: String) -> String {
        switch name {
        case roomUSDZ: return "3D room model (RoomPlan, parametric USDZ). AR Quick Look, Reality Composer, Blender, SketchUp/Revit via USD import."
        case modelUSDZ: return "3D model (USDZ). Opens in AR Quick Look, Reality Composer, Blender, Cinema 4D."
        case roomJSON: return "Raw RoomPlan CapturedRoom JSON for re-processing."
        case planJSON: return "AsBuilt plan data (walls, openings, fixtures) in meters."
        case dxf: return "2D CAD floor plan, DXF R12 with layers. AutoCAD, Revit, SketchUp, BricsCAD."
        case svg: return "Vector floor plan for browsers and Illustrator."
        case pdf: return "Printable plan sheet with title block plus takeoff page."
        case csv: return "Quantity takeoff for Excel, Numbers or your estimating tool."
        case images: return "Source photos. Reconstruct at full detail on a Mac (Reality Composer Pro / PhotogrammetrySession)."
        case checkpoint: return "Reconstruction checkpoint data."
        case reconstructionLog: return "On-device 3D build log: settings, photo count, device, iOS version and Apple's error codes. Send it with a support request."
        case meshOBJ: return "LiDAR mesh, Wavefront OBJ (meters, Y-up, one group per surface type). Blender, SketchUp, Rhino, AutoCAD/Revit via import."
        case meshMTL: return "Colors for mesh.obj (keep it next to the OBJ)."
        case meshPLY: return "LiDAR mesh, binary PLY with vertex colors. MeshLab, CloudCompare, Recap."
        case meshCSV: return "Scan size (W x D x H) and scanned surface areas by type."
        case scanInfo: return "Scan measurements as JSON."
        default:
            if name.hasSuffix(".zip") { return "Everything in one archive." }
            return ""
        }
    }

    static func icon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "usdz": return "cube"
        case "dxf": return "ruler"
        case "pdf": return "doc.richtext"
        case "svg": return "square.on.square.dashed"
        case "csv": return "tablecells"
        case "json": return "curlybraces"
        case "zip": return "archivebox"
        case "obj", "ply": return "point.3.connected.trianglepath.dotted"
        case "mtl": return "paintpalette"
        case "txt": return "doc.text.magnifyingglass"
        default: return name == images ? "photo.stack" : "doc"
        }
    }
}
