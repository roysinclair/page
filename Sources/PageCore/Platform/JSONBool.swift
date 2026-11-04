import Foundation

extension NSNumber {
    /// True when this number is a JSON `true`/`false` (JSONSerialization
    /// boxes both numbers and booleans as NSNumber).
    ///
    /// macOS: the CFBoolean type id, as before the split. Linux (swift-corelibs
    /// Foundation): a boolean NSNumber reports the `c` (char) type encoding;
    /// JSONSerialization never produces 8-bit integers otherwise.
    var isJSONBool: Bool {
        #if canImport(Darwin)
        return CFGetTypeID(self) == CFBooleanGetTypeID()
        #else
        return String(cString: objCType) == "c"
        #endif
    }
}
