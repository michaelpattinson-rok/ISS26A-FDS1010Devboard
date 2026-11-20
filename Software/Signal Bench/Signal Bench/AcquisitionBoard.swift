import Foundation
import IOKit

nonisolated enum AcquisitionBoard: String, Codable, CaseIterable, Identifiable, Sendable {
    case picoW = "pico_w"
    case unoR4 = "uno_r4_minima"

    var id: Self { self }
    var title: String { self == .picoW ? "Pico W" : "UNO R4 Minima" }
    var bits: Int { self == .picoW ? 12 : 14 }
    var maxCode: UInt16 { UInt16(1 << bits) - 1 }
    var nominalReferenceMV: Int { self == .picoW ? 3300 : 5000 }
    var gpioMask: UInt32 { self == .picoW ? StreamWire.protectedPinMask : 0x1ffc }
    static let unoRates = 10_000...250_000
    var selectableRates: Set<Int> {
        self == .picoW ? Set(StreamWire.rates) : [10_000, 25_000, 50_000, 100_000, 125_000, 200_000, 250_000]
    }
    var liveRange: ClosedRange<Int> { self == .picoW ? StreamWire.customRates : Self.unoRates }
    func supportsSavedRate(_ rate: Int) -> Bool { liveRange.contains(rate) || (self == .unoR4 && rate == 500_000) }
    private func unoPeriod(_ rate: Int) -> UInt32 { UInt32((48_000_000 + rate / 2) / rate) }

    func analogPin(_ channel: Int) -> String { self == .picoW ? "GP\(26 + channel)" : "A\(channel)" }
    func digitalPin(_ pin: Int) -> String { self == .picoW ? "GP\(pin)" : "D\(pin)" }
    func rate(_ requested: Int) -> Double {
        guard self == .unoR4 else { return StreamWire.configuredRate(for: requested) }
        guard supportsSavedRate(requested) else { return Double(requested) }
        return 48_000_000 / Double(unoPeriod(requested))
    }
    func sampleCode(_ word: UInt16) -> UInt16 { word & maxCode }
    func accepts(_ clock: UInt32, _ counter: UInt32, rate: Int) -> Bool {
        guard clock == StreamWire.adcClock else { return false }
        if self == .picoW { return counter == StreamWire.divider(for: rate, clock: clock) }
        return supportsSavedRate(rate) && counter == unoPeriod(rate)
    }
    func measuredConfiguration(_ clock: UInt32, counter: UInt32) -> Double {
        self == .picoW ? StreamWire.configuredRate(clock: clock, divider: counter) : Double(clock) / Double(counter)
    }
}

nonisolated enum AcquisitionPorts {
    static func boardHints() -> [String: AcquisitionBoard] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOSerialBSDClient"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var result: [String: AcquisitionBoard] = [:]
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, "IOCalloutDevice" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  path.hasPrefix("/dev/cu.usbmodem") else { continue }
            func usbValue(_ key: String) -> Int? {
                let search = IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
                return (IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
                    kCFAllocatorDefault, search) as? NSNumber)?.intValue
            }
            switch (usbValue("idVendor"), usbValue("idProduct")) {
            case (0x2341, 0x0069): result[path] = .unoR4
            case (0x2e8a, 0x000a): result[path] = .picoW
            default: break
            }
        }
        return result
    }
}
