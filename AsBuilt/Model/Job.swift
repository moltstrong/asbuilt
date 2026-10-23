import Foundation
import AsBuiltCore

enum CaptureKind: String, Codable, CaseIterable, Hashable, Sendable {
    case room
    case object

    var displayName: String {
        switch self {
        case .room: return "Room scan"
        case .object: return "Object capture"
        }
    }

    var icon: String {
        switch self {
        case .room: return "square.split.bottomrightquarter"
        case .object: return "cube.transparent"
        }
    }
}

enum CaptureOrigin: String, Codable, Hashable, Sendable {
    /// LiDAR room scan via RoomPlan.
    case roomPlan
    /// Guided photo capture via RealityKit Object Capture.
    case objectCapture
    /// Bundled sample data built from AsBuiltCore models.
    case sample
}

enum CaptureStatus: String, Codable, Hashable, Sendable {
    case complete
    /// Photos saved; 3D reconstruction not done on device (reconstruct on a Mac).
    case imagesOnly
    case processing
    case failed
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

    init(id: UUID = UUID(), kind: CaptureKind, origin: CaptureOrigin, title: String, createdAt: Date = Date(),
         notes: String = "", status: CaptureStatus = .complete, statusMessage: String? = nil, imageCount: Int? = nil) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.title = title
        self.createdAt = createdAt
        self.notes = notes
        self.status = status
        self.statusMessage = statusMessage
        self.imageCount = imageCount
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
        default: return name == images ? "photo.stack" : "doc"
        }
    }
}
