// Prints the cases of a Swift enum compiled into a (private) framework, in runtime tag order, by
// reading the framework's Swift reflection metadata (__swift5_types / __swift5_fieldmd) in-process.
//
// The NSError code of a Swift error enum is its runtime tag: payload cases first (declaration
// order), then no-payload cases (declaration order). The field records are emitted in that same
// order, so record N is error code N.
//
// Usage: swiftc scripts/dump-swift-enum.swift -o dump-swift-enum
//        ./dump-swift-enum /System/Library/PrivateFrameworks/CoreOC.framework/CoreOC PhotogrammetrySession.Error
// With no arguments it dumps every enum named "Error" in CoreOC.
import Darwin
import MachO

let args = CommandLine.arguments
let frameworkPath = args.count > 1 ? args[1] : "/System/Library/PrivateFrameworks/CoreOC.framework/CoreOC"
let wanted = args.count > 2 ? args[2] : nil

guard dlopen(frameworkPath, RTLD_NOW) != nil else {
    print("dlopen failed: \(String(cString: dlerror()))")
    exit(2)
}
let imageName = frameworkPath.split(separator: "/").last.map(String.init) ?? frameworkPath

var header: UnsafePointer<mach_header_64>?
for i in 0..<_dyld_image_count() {
    guard let name = _dyld_get_image_name(i) else { continue }
    let path = String(cString: name)
    if path == frameworkPath || (path.hasSuffix("/" + imageName) && path.contains(imageName + ".framework")) {
        header = UnsafeRawPointer(_dyld_get_image_header(i)!).assumingMemoryBound(to: mach_header_64.self)
        print("image: \(path)")
        break
    }
}
guard let header else {
    print("image \(imageName) not found among loaded images")
    exit(3)
}

func section(_ name: String) -> UnsafeRawBufferPointer? {
    var size: UInt = 0
    guard let p = getsectiondata(header, "__TEXT", name, &size) else { return nil }
    return UnsafeRawBufferPointer(start: UnsafeRawPointer(p), count: Int(size))
}

func rel(_ p: UnsafeRawPointer) -> UnsafeRawPointer? {
    let offset = p.loadUnaligned(as: Int32.self)
    return offset == 0 ? nil : p + Int(offset)
}

/// Relative indirectable pointer (low bit set: points at a pointer).
func relIndirectable(_ p: UnsafeRawPointer) -> UnsafeRawPointer? {
    let raw = p.loadUnaligned(as: Int32.self)
    if raw == 0 { return nil }
    let target = p + Int(raw & ~1)
    if raw & 1 != 0 {
        guard let indirect = target.loadUnaligned(as: UnsafeRawPointer?.self) else { return nil }
        return indirect
    }
    return target
}

func cString(_ p: UnsafeRawPointer?) -> String {
    guard let p else { return "?" }
    return String(cString: p.assumingMemoryBound(to: CChar.self))
}

/// Context descriptor: Flags (u32), Parent (rel indirectable). Type descriptors add Name at +8.
func contextName(_ d: UnsafeRawPointer) -> String {
    let kind = d.loadUnaligned(as: UInt32.self) & 0x1F
    switch kind {
    case 0, 16, 17, 18: return cString(rel(d + 8)) // module, class, struct, enum
    case 1: return "<extension>"
    default: return "<ctx\(kind)>"
    }
}

func qualifiedName(_ d: UnsafeRawPointer) -> String {
    var parts: [String] = []
    var current: UnsafeRawPointer? = d
    var guardCount = 0
    while let c = current, guardCount < 16 {
        parts.append(contextName(c))
        current = relIndirectable(c + 4)
        guardCount += 1
    }
    return parts.reversed().joined(separator: ".")
}

guard let types = section("__swift5_types") else {
    print("no __swift5_types section")
    exit(4)
}

var found = 0
let count = types.count / 4
for i in 0..<count {
    let entry = types.baseAddress! + i * 4
    let raw = entry.loadUnaligned(as: Int32.self)
    let refKind = raw & 3
    var descriptor = entry + Int(raw & ~3)
    if refKind == 1 {
        guard let indirect = descriptor.loadUnaligned(as: UnsafeRawPointer?.self) else { continue }
        descriptor = indirect
    } else if refKind != 0 {
        continue
    }
    let flags = descriptor.loadUnaligned(as: UInt32.self)
    guard flags & 0x1F == 18 else { continue } // enums only
    let name = qualifiedName(descriptor)
    if let wanted {
        guard name.hasSuffix("." + wanted) || name == wanted else { continue }
    } else {
        guard name.hasSuffix(".Error") else { continue }
    }
    let payloadCases = Int(descriptor.loadUnaligned(fromByteOffset: 20, as: UInt32.self) & 0x00FF_FFFF)
    let emptyCases = Int(descriptor.loadUnaligned(fromByteOffset: 24, as: UInt32.self))
    print("\nenum \(name)   payload cases: \(payloadCases)   no-payload cases: \(emptyCases)")
    guard let fields = rel(descriptor + 16) else {
        print("  (no field descriptor)")
        continue
    }
    let recordSize = Int(fields.loadUnaligned(fromByteOffset: 10, as: UInt16.self))
    let numFields = Int(fields.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
    for f in 0..<numFields {
        let record = fields + 16 + f * recordSize
        let hasPayload = record.loadUnaligned(fromByteOffset: 4, as: Int32.self) != 0
        let fieldName = cString(rel(record + 8))
        let marker = hasPayload ? "payload" : "no payload"
        let order = (hasPayload == (f < payloadCases)) ? "" : "   <-- ORDER MISMATCH"
        print("  code \(f) = .\(fieldName)  (\(marker))\(order)")
    }
    found += 1
}
print("\nenums printed: \(found)")
exit(found > 0 ? 0 : 5)
