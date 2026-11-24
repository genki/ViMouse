import Foundation

@main
struct LocalConversionAvailabilityTests {
    static func main() {
        for (silicon, major, resources, available) in [
            (false, 13, true, false), (false, 26, true, false),
            (true, 13, true, false), (true, 14, false, false),
            (true, 14, true, true), (true, 26, true, true)
        ] {
            precondition((SelfConversionSettings.localUnavailableReason(
                appleSilicon: silicon, majorVersion: major, resourcesPresent: resources) == nil) == available)
        }
        print("local availability: Intel/macOS13/SDK欠損/対応環境 6条件PASS")
    }
}
