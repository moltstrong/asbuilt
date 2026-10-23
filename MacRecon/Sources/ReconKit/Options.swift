import Foundation

/// Command-line options, kept free of RealityKit so they can be unit tested.
public enum Detail: String, CaseIterable, Sendable {
    case preview, reduced, medium, full, raw, custom
}

public enum TextureSize: String, CaseIterable, Sendable {
    case k1 = "1k", k2 = "2k", k4 = "4k", k8 = "8k", k16 = "16k"
    public var pixels: Int {
        switch self {
        case .k1: return 1024
        case .k2: return 2048
        case .k4: return 4096
        case .k8: return 8192
        case .k16: return 16384
        }
    }
}

public enum TextureMap: String, CaseIterable, Sendable {
    case diffuse, normal, roughness, displacement, ao
}

public enum Ordering: String, Sendable { case unordered, sequential }
public enum Sensitivity: String, Sendable { case normal, high }

public enum TextureFormatOption: Equatable, Sendable {
    case png
    case jpeg(quality: Float)
    public var summary: String {
        switch self {
        case .png: return "png"
        case .jpeg(let q): return "jpeg(q=\(q))"
        }
    }
}

public struct UsageError: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

public struct BuildOptions: Sendable {
    public var input: String = ""
    public var detail: Detail = .full
    public var detailExplicit = false
    public var outDir: String?
    public var obj = false
    public var texture: TextureSize?
    public var maxPolys: UInt?
    public var maps: [TextureMap]?
    public var textureFormat: TextureFormatOption?
    public var ordering: Ordering?
    public var sensitivity: Sensitivity?
    public var noMasking = false
    public var checkpoint: String?
    public var quads = false
    public var ignoreBoundingBox = false
    public var retry = true
    public var thumbnail = true
    public var keepTemp = false
    /// JSON live-status file (used by the server).
    public var statusFile: String?
    /// Human name for the capture, written into the log.
    public var title: String?
    // watch only
    public var interval: Double = 10
    public var once = false

    public init() {}

    /// The user pinned at least one alignment flag, so the automatic retry must not override it.
    public var userSetAlignmentFlags: Bool { ordering != nil || sensitivity != nil || noMasking }

    /// Retry once (sequential + high + no masking) unless disabled or the user chose those flags.
    public var shouldAutoRetry: Bool { retry && !userSetAlignmentFlags }

    public var usesCustomSpec: Bool { detail == .custom }

    public static let defaultCustomPolys: UInt = 250_000

    /// Parses arguments after the subcommand. `positional` names the required positional argument.
    public static func parse(_ args: [String], positional: String = "input", allowWatchFlags: Bool = false) throws -> BuildOptions {
        var o = BuildOptions()
        var positionals: [String] = []
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw UsageError("\(flag) needs a value") }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--detail", "-d":
                let v = try value(a).lowercased()
                guard let d = Detail(rawValue: v) else {
                    throw UsageError("--detail must be one of \(Detail.allCases.map(\.rawValue).joined(separator: "|")), got '\(v)'")
                }
                o.detail = d
                o.detailExplicit = true
            case "--out", "-o": o.outDir = try value(a)
            case "--obj": o.obj = true
            case "--texture":
                let v = try value(a).lowercased()
                guard let t = TextureSize(rawValue: v) else {
                    throw UsageError("--texture must be one of \(TextureSize.allCases.map(\.rawValue).joined(separator: "|")), got '\(v)'")
                }
                o.texture = t
            case "--max-polys":
                let v = try value(a).replacingOccurrences(of: "_", with: "").replacingOccurrences(of: ",", with: "")
                guard let n = parseCount(v), n > 0 else { throw UsageError("--max-polys must be a positive number (e.g. 500000 or 2m), got '\(v)'") }
                o.maxPolys = n
            case "--maps":
                let v = try value(a).lowercased()
                if v == "all" {
                    o.maps = TextureMap.allCases
                } else {
                    var maps: [TextureMap] = []
                    for part in v.split(separator: ",") {
                        let p = part.trimmingCharacters(in: .whitespaces)
                        let name = p == "ambientocclusion" ? "ao" : (p == "color" || p == "diffusecolor" ? "diffuse" : p)
                        guard let m = TextureMap(rawValue: name) else {
                            throw UsageError("--maps takes all or a list of \(TextureMap.allCases.map(\.rawValue).joined(separator: ",")), got '\(p)'")
                        }
                        if !maps.contains(m) { maps.append(m) }
                    }
                    guard !maps.isEmpty else { throw UsageError("--maps is empty") }
                    o.maps = maps
                }
            case "--texture-format":
                let v = try value(a).lowercased()
                if v == "png" {
                    o.textureFormat = .png
                } else if v.hasPrefix("jpeg") || v.hasPrefix("jpg") {
                    var q: Float = 0.9
                    if let colon = v.firstIndex(of: ":") {
                        guard let qq = Float(v[v.index(after: colon)...]), qq > 0, qq <= 1 else {
                            throw UsageError("--texture-format jpeg:Q needs 0 < Q <= 1")
                        }
                        q = qq
                    }
                    o.textureFormat = .jpeg(quality: q)
                } else {
                    throw UsageError("--texture-format must be png or jpeg[:quality]")
                }
            case "--ordering":
                let v = try value(a).lowercased()
                guard let x = Ordering(rawValue: v) else { throw UsageError("--ordering must be unordered|sequential") }
                o.ordering = x
            case "--sensitivity":
                let v = try value(a).lowercased()
                guard let x = Sensitivity(rawValue: v) else { throw UsageError("--sensitivity must be normal|high") }
                o.sensitivity = x
            case "--no-masking": o.noMasking = true
            case "--checkpoint": o.checkpoint = try value(a)
            case "--quads": o.quads = true
            case "--ignore-bbox": o.ignoreBoundingBox = true
            case "--no-retry": o.retry = false
            case "--no-thumbnail": o.thumbnail = false
            case "--keep-temp": o.keepTemp = true
            case "--status-file": o.statusFile = try value(a)
            case "--title": o.title = try value(a)
            case "--interval" where allowWatchFlags:
                let v = try value(a)
                guard let s = Double(v), s >= 1 else { throw UsageError("--interval must be >= 1 second") }
                o.interval = s
            case "--once" where allowWatchFlags: o.once = true
            default:
                if a.hasPrefix("-") && a.count > 1 { throw UsageError("unknown option \(a)") }
                positionals.append(a)
            }
            i += 1
        }
        guard positionals.count == 1 else {
            throw UsageError(positionals.isEmpty ? "missing <\(positional)>" : "expected one <\(positional)>, got \(positionals.count): \(positionals.joined(separator: " "))")
        }
        o.input = positionals[0]

        // Custom-spec flags imply --detail custom; with an explicit non-custom detail they're a mistake.
        let customFlags = o.texture != nil || o.maxPolys != nil || o.maps != nil || o.textureFormat != nil
        if customFlags {
            if o.detailExplicit && o.detail != .custom {
                throw UsageError("--texture/--max-polys/--maps/--texture-format only apply to --detail custom (got --detail \(o.detail.rawValue))")
            }
            o.detail = .custom
        }
        return o
    }

    /// "2m" -> 2_000_000, "500k" -> 500_000, "1234" -> 1234.
    public static func parseCount(_ s: String) -> UInt? {
        let l = s.lowercased()
        if let last = l.last, last == "k" || last == "m" {
            guard let base = Double(l.dropLast()), base > 0 else { return nil }
            let v = base * (last == "k" ? 1_000 : 1_000_000)
            return v < Double(UInt.max) ? UInt(v.rounded()) : nil
        }
        return UInt(l)
    }

    /// Effective custom spec values (Apple's defaults where the user said nothing).
    public var effectiveTexture: TextureSize { texture ?? .k8 }
    public var effectiveMaxPolys: UInt { maxPolys ?? Self.defaultCustomPolys }
    public var effectiveMaps: [TextureMap] { maps ?? TextureMap.allCases }
    public var effectiveTextureFormat: TextureFormatOption { textureFormat ?? .png }

    public var summary: String {
        var parts = ["detail=\(detail.rawValue)"]
        if detail == .custom {
            parts.append("maxPolys=\(effectiveMaxPolys) texture=\(effectiveTexture.rawValue) maps=\(effectiveMaps.map(\.rawValue).joined(separator: ",")) format=\(effectiveTextureFormat.summary)")
        }
        parts.append("ordering=\((ordering ?? .unordered).rawValue)\(ordering == nil ? "(default)" : "")")
        parts.append("sensitivity=\((sensitivity ?? .normal).rawValue)\(sensitivity == nil ? "(default)" : "")")
        parts.append("masking=\(!noMasking)")
        if quads { parts.append("meshPrimitive=quad") }
        if ignoreBoundingBox { parts.append("ignoreBoundingBox=true") }
        if obj { parts.append("obj=true") }
        if let c = checkpoint { parts.append("checkpoint=\(c)") }
        parts.append("autoRetry=\(shouldAutoRetry)")
        return parts.joined(separator: " ")
    }
}

/// One reconstruction attempt's alignment settings.
public struct AttemptPlan: Equatable, Sendable {
    public var number: Int
    public var ordering: Ordering
    public var sensitivity: Sensitivity
    public var masking: Bool
    public var summary: String {
        "sampleOrdering=.\(ordering.rawValue) featureSensitivity=.\(sensitivity.rawValue) isObjectMaskingEnabled=\(masking)"
    }

    /// Attempt 1 uses the user's flags (or Apple's defaults). If that fails and the user didn't pin
    /// alignment flags, attempt 2 uses sequential ordering + high sensitivity + no masking.
    public static func plan(for o: BuildOptions) -> [AttemptPlan] {
        let first = AttemptPlan(number: 1, ordering: o.ordering ?? .unordered, sensitivity: o.sensitivity ?? .normal, masking: !o.noMasking)
        guard o.shouldAutoRetry else { return [first] }
        return [first, AttemptPlan(number: 2, ordering: .sequential, sensitivity: .high, masking: false)]
    }
}
