// USB Cable — что за USB-C кабель воткнут: паспорт из e-marker'а, реальная связь, питание.
//
// Источник — IORegistry, ветка IOPort (Apple Silicon): порт Port-USB-C@N, под ним
//   CC/SOP'          — Discover Identity кабеля (e-marker): VDO с током, вольтажом, скоростью;
//   CC/SOP           — то, что на другом конце (Mac, iPhone, зарядка…);
//   USB2/USB3/CIO    — реально поднятые линки;
//   Power In/USB-PD  — профили зарядки, если Mac сейчас потребитель.
// Скорость Thunderbolt/USB4 берётся из system_profiler (в IORegistry её не расшифровать).
//
// Главный сценарий — «петля»: оба конца кабеля в два порта Mac. Один порт становится
// источником, подаёт VCONN и читает e-marker; Thunderbolt поднимается сам с собой —
// это реальная проверка кабеля, а не того, что умеет устройство.
//
// Ограничения: e-marker читает только сторона-источник питания (если кабель от зарядки —
// метку читает зарядка, не Mac). Кабели без e-marker'а о себе ничего не сообщают.
//
// Режимы:
//   usb-cable            — иконка в строке меню
//   usb-cable --once     — отчёт в терминал (exit 1, если ничего не подключено)

import AppKit
import IOKit

typealias Props = [String: Any]

// MARK: - IORegistry

func properties(_ e: io_registry_entry_t) -> Props {
    var u: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(e, &u, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let d = u?.takeRetainedValue() as? Props else { return [:] }
    return d
}

func className(_ e: io_object_t) -> String {
    (IOObjectCopyClass(e)?.takeRetainedValue() as String?) ?? ""
}

struct Node { let cls: String; let p: Props }

func descendants(_ e: io_registry_entry_t) -> [Node] {
    var it: io_iterator_t = 0
    guard IORegistryEntryCreateIterator(e, kIOServicePlane,
                                        IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(it) }
    var out: [Node] = []
    while true {
        let c = IOIteratorNext(it)
        if c == 0 { break }
        out.append(Node(cls: className(c), p: properties(c)))
        IOObjectRelease(c)
    }
    return out
}

func ports() -> [(Props, [Node])] {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPort"), &it) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(it) }
    var out: [(Props, [Node])] = []
    while true {
        let s = IOIteratorNext(it)
        if s == 0 { break }
        let p = properties(s)
        let type = p["PortTypeDescription"] as? String ?? ""
        if type == "USB-C" || type.hasPrefix("MagSafe") { out.append((p, descendants(s))) }
        IOObjectRelease(s)
    }
    return out.sorted { ($0.0["PortNumber"] as? Int ?? 0, $0.0["PortTypeDescription"] as? String ?? "")
                      < ($1.0["PortNumber"] as? Int ?? 0, $1.0["PortTypeDescription"] as? String ?? "") }
}

func platformSerial() -> String? {
    let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    defer { IOObjectRelease(s) }
    return properties(s)["IOPlatformSerialNumber"] as? String
}

// MARK: - e-marker (USB PD 3.x, Discover Identity для SOP')

func vdo(_ any: Any?) -> UInt32? {
    guard let d = any as? Data, d.count == 4 else { return nil }
    return d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
}

func bits(_ v: UInt32, _ hi: Int, _ lo: Int) -> Int { Int((v >> UInt32(lo)) & ((1 << UInt32(hi - lo + 1)) - 1)) }

struct Cable {
    let vid: Int, pid: Int
    let kind: Int            // ID Header 29..27: 3 — пассивный, 4 — активный, 6 — VPD
    let speed: Int           // Cable VDO 2..0
    let current: Int         // 6..5
    let maxVolt: Int         // 10..9
    let epr: Bool            // 17
    let latency: Int         // 16..13
    let plug: Int            // 19..18
    let vdo2: UInt32?        // только у активных
    let raw: [UInt32]

    init?(_ meta: Props) {
        guard let list = meta["VDOs"] as? [Any] else { return nil }
        let v = list.compactMap(vdo)
        guard v.count >= 4 else { return nil }
        raw = v
        let id = v[0], c = v[3]
        vid = bits(id, 15, 0)
        pid = bits(v[2], 31, 16)
        kind = bits(id, 29, 27)
        speed = bits(c, 2, 0)
        current = bits(c, 6, 5)
        maxVolt = bits(c, 10, 9)
        epr = bits(c, 17, 17) == 1
        latency = bits(c, 16, 13)
        plug = bits(c, 19, 18)
        vdo2 = (kind == 4 && v.count >= 5) ? v[4] : nil
    }

    var kindText: String {
        switch kind {
        case 3: return "пассивный"
        case 4: return "активный"
        case 6: return "VCONN-устройство"
        default: return "тип \(kind)"
        }
    }
    var speedText: String {
        switch speed {
        case 0: return "USB 2.0 — 480 Мбит/с (скоростных пар нет)"
        case 1: return "USB 3.2 Gen 1 — 5 Гбит/с"
        case 2: return "USB 3.2 Gen 2 / USB4 Gen 2 — 10 Гбит/с (20 в USB4)"
        case 3: return "USB4 Gen 3 — 40 Гбит/с, Thunderbolt 4 (USB4 v2 гонит по нему 80)"
        case 4: return "USB4 Gen 4 — 80 Гбит/с, Thunderbolt 5"
        default: return "код \(speed)"
        }
    }
    var speedShort: String { ["USB2", "5G", "10G", "40G", "80G"][safe: speed] ?? "?" }
    var amps: Int { current == 2 ? 5 : 3 }
    var volts: Int { [20, 30, 40, 50][maxVolt] }
    // EPR — 48 В × 5 А = 240 Вт (50 В — допуск кабеля, не рабочее напряжение).
    var watts: Int { min(volts, 48) * amps }
    var powerText: String {
        var s = "\(amps) А · до \(volts) В → \(watts) Вт"
        if epr { s += " (EPR)" }
        if current == 0 { s += ", ток в метке не указан — считаем 3 А" }
        return s
    }
    var lengthText: String? {
        switch latency {
        case 1: return "~1 м (задержка < 10 нс)"
        case 2...7: return "~\(latency) м (задержка \(latency - 1)0–\(latency)0 нс)"
        case 8: return "> 7 м"
        case 9: return "оптика ~100 м"
        case 10: return "оптика ~200 м"
        case 11: return "оптика ~300 м"
        default: return nil
        }
    }
    var activeText: String? {
        guard let a = vdo2 else { return nil }
        var parts: [String] = []
        parts.append(bits(a, 10, 10) == 1 ? "оптический" : "медный")
        parts.append(bits(a, 9, 9) == 1 ? "ретаймер" : "редрайвер")
        if bits(a, 8, 8) == 0 { parts.append("USB4") }
        if bits(a, 4, 4) == 0 { parts.append("USB 3.2") }
        if bits(a, 5, 5) == 0 { parts.append("USB 2.0") }
        parts.append(bits(a, 3, 3) == 1 ? "2 линии" : "1 линия")
        return parts.joined(separator: ", ")
    }
    var vendorText: String {
        let known = [0x05AC: "Apple", 0x8087: "Intel", 0x04E8: "Samsung", 0x0BDA: "Realtek", 0x2109: "VIA Labs"]
        let hex = String(format: "0x%04X", vid)
        return known[vid].map { "\($0) (\(hex))" } ?? hex
    }
    var short: String { "\(speedShort) · \(watts)W" }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

// MARK: - Отчёт по порту

struct PortReport {
    let number: Int
    let type: String               // USB-C / MagSafe 3
    let connected: Bool
    let cable: Cable?
    let partnerPD: Bool            // на другом конце есть PD-устройство (ответило на SOP)
    let partnerName: String?
    let partnerSerial: String?
    let partnerPID: Int?
    let links: [String]
    let cio: Bool
    let pdOptions: [Props]         // профили зарядки (Mac — потребитель)
    let pdWinning: Props?

    var title: String { "\(type) \(number)" }
    var macIsSink: Bool { pdWinning != nil }

    init(_ p: Props, _ nodes: [Node]) {
        number = p["PortNumber"] as? Int ?? 0
        type = p["PortTypeDescription"] as? String ?? "?"
        connected = (p["ConnectionActive"] as? Bool) ?? false

        let sopp = nodes.first { $0.cls == "IOPortTransportComponentCCUSBPDSOPp" }
        cable = (sopp?.p["Metadata"] as? Props).flatMap(Cable.init)

        let sop = nodes.first { $0.cls == "IOPortTransportComponentCCUSBPDSOP" }
        let sopMeta = sop?.p["Metadata"] as? Props ?? [:]
        partnerPD = !sopMeta.isEmpty
        partnerPID = sopMeta["Product ID"] as? Int

        // Имя — из активного USB-линка, иначе из Apple UVDM, иначе VID:PID из PD.
        // SOPMfgString на самом порте не берём: он остаётся от прошлого подключения.
        var name: String? = nil, serial: String? = nil
        for n in nodes where n.cls.hasPrefix("IOPortTransportStateUSB") && (n.p["Active"] as? Bool ?? false) {
            if let m = n.p["Metadata"] as? Props, let pr = m["Product"] as? String {
                name = pr; serial = m["Serial Number"] as? String; break
            }
        }
        if name == nil, let u = nodes.first(where: { $0.cls == "IOPortTransportProtocolAppleUVDM" }) {
            name = u.p["Product"] as? String
        }
        if name == nil, let v = sopMeta["Vendor ID"] as? Int, let pid = sopMeta["Product ID"] as? Int {
            name = String(format: "PD-устройство %04X:%04X", v, pid)
        }
        partnerSerial = serial
        let pdSource = nodes.first { $0.cls == "IOPortFeaturePowerSource" && ($0.p["PowerSourceName"] as? String) == "USB-PD" }
        // Зарядка в SOP отдаёт VID:PID своего PD-контроллера (часто Cypress 04B4) — это не имя.
        if serial == nil, pdSource?.p["WinningPowerSourceOption"] != nil, let n = name, n.hasPrefix("PD-устройство") {
            name = n.replacingOccurrences(of: "PD-устройство", with: "зарядка USB-PD, контроллер")
        }
        partnerName = connected ? name : nil

        var l: [String] = []
        var hasCIO = false
        for n in nodes where n.cls.hasPrefix("IOPortTransportState") && (n.p["Active"] as? Bool ?? false) {
            switch n.p["TransportTypeDescription"] as? String {
            case "USB2":
                // Пока линк не поднялся, Active уже Yes, а скорость — «None».
                guard let r = n.p["DataRateDescription"] as? String, r != "None" else { continue }
                l.append("USB 2.0 · " + ru(r))
            case "USB3":
                let gen = n.p["SuperSpeedSignalingDescription"] as? String ?? ""
                l.append("USB 3.2 \(gen) · " + ru(n.p["DataRateDescription"] as? String ?? ""))
            case "CIO":
                hasCIO = true
            case "DisplayPort":
                l.append("DisplayPort")
            default: break
            }
        }
        links = l
        cio = hasCIO

        let pd = nodes.first { $0.cls == "IOPortFeaturePowerSource" && ($0.p["PowerSourceName"] as? String) == "USB-PD" }
        // PowerSourceOptions — OSSet (в ioreg в квадратных скобках), не массив.
        let rawOpts = pd?.p["PowerSourceOptions"]
        let opts = (rawOpts as? [Props]) ?? ((rawOpts as? NSSet)?.allObjects.compactMap { $0 as? Props }) ?? []
        pdOptions = opts
            .sorted { ($0["Voltage (mV)"] as? Int ?? $0["Max Voltage (mV)"] as? Int ?? 0)
                    < ($1["Voltage (mV)"] as? Int ?? $1["Max Voltage (mV)"] as? Int ?? 0) }
        pdWinning = pd?.p["WinningPowerSourceOption"] as? Props
    }
}

func ru(_ s: String) -> String {
    s.replacingOccurrences(of: "Gbps", with: "Гбит/с")
     .replacingOccurrences(of: "Mbps", with: "Мбит/с")
     .replacingOccurrences(of: " (High Speed)", with: "")
}

func volts(_ mv: Int) -> String {
    let v = Double(mv) / 1000
    return v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
}

func pdOptionText(_ o: Props) -> String {
    let a = volts(o["Max Current (mA)"] as? Int ?? 0)
    if let v = o["Voltage (mV)"] as? Int { return "\(volts(v)) В \(a) А" }
    // PPS/AVS — диапазон напряжений; ключи угадываем по аналогии с Fixed.
    let lo = o["Min Voltage (mV)"] as? Int, hi = o["Max Voltage (mV)"] as? Int
    if let lo, let hi { return "\(volts(lo))–\(volts(hi)) В \(a) А (PPS)" }
    return (o["Class"] as? String ?? "?").replacingOccurrences(of: "IOPortFeaturePowerSourceOption", with: "")
}

// Thunderbolt/USB4: номер разъёма → скорость линка («80 Gb/s»).
func thunderboltSpeeds() -> [Int: String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    p.arguments = ["-json", "-detailLevel", "mini", "SPThunderboltDataType"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [:] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let j = try? JSONSerialization.jsonObject(with: data) as? Props,
          let buses = j["SPThunderboltDataType"] as? [Props] else { return [:] }
    var out: [Int: String] = [:]
    for b in buses {
        guard let r = b["receptacle_1_tag"] as? Props,
              (r["receptacle_status_key"] as? String) == "receptacle_connected",
              let id = Int(r["receptacle_id_key"] as? String ?? ""),
              let s = r["current_speed_key"] as? String else { continue }
        out[id] = s.replacingOccurrences(of: "Gb/s", with: "Гбит/с")
    }
    return out
}

// MARK: - Сборка отчёта

struct Entry {
    let title: String
    let short: String          // для строки меню: «40G · 240W»
    let lines: [(String, String)]
}

// system_profiler — ~0.5–1 с; при открытии меню берём кэш, свежее — по событиям подключения.
var tbCache: [Int: String] = [:]
let tbLock = NSLock()

func buildEntries(freshTB: Bool = true) -> [Entry] {
    let reports = ports().map { PortReport($0.0, $0.1) }.filter(\.connected)
    let cioPorts = reports.filter(\.cio).map(\.number)
    tbLock.lock()
    var tb = tbCache
    tbLock.unlock()
    if !cioPorts.isEmpty && (freshTB || cioPorts.contains { tb[$0] == nil }) {
        tb = thunderboltSpeeds()
        tbLock.lock(); tbCache = tb; tbLock.unlock()
    }
    let own = platformSerial()

    // Петля: один порт видит на том конце этот же Mac (по серийнику), второй — парный.
    var used = Set<Int>()
    var entries: [Entry] = []
    for r in reports where !used.contains(r.number) {
        var group = [r]
        if r.type == "USB-C", let own, r.partnerSerial == own || reports.contains(where: { $0.partnerSerial == own && $0.number != r.number }) {
            if let mate = reports.first(where: { $0.number != r.number && $0.type == "USB-C" && !used.contains($0.number)
                                                 && $0.partnerPID != nil && $0.partnerPID == r.partnerPID }) {
                group.append(mate)
            }
        }
        group.forEach { used.insert($0.number) }
        entries.append(entry(group, tb: tb))
    }
    return entries
}

func entry(_ g: [PortReport], tb: [Int: String]) -> Entry {
    let loop = g.count == 2
    let title = loop
        ? "\(g[0].title) ↔ \(g[1].title) · петля (кабель обоими концами в Mac)"
        : "\(g[0].title)" + (g[0].partnerName.map { " · \($0)" } ?? "")
    var lines: [(String, String)] = []

    // Кабель
    let cable = g.compactMap(\.cable).first
    if let c = cable {
        lines.append(("Кабель", "\(c.kindText), e-marker \(c.vendorText)"))
        lines.append(("", "скорость: \(c.speedText)"))
        lines.append(("", "питание: \(c.powerText)"))
        if let len = c.lengthText { lines.append(("", "длина: \(len)")) }
        if let a = c.activeText { lines.append(("", a)) }
        if c.plug == 3 { lines.append(("", "кабель несъёмный (captive)")) }
    } else if g[0].type.hasPrefix("MagSafe") {
        lines.append(("Кабель", "MagSafe — метки нет, кабель штатный"))
    } else if g.allSatisfy(\.macIsSink) {
        // Метку читает тот, кто подаёт питание (VCONN). Здесь это зарядка.
        var s = "метку читает зарядка, не Mac — воткните кабель обоими концами в Mac"
        if g.flatMap(\.pdOptions).contains(where: { ($0["Max Current (mA)"] as? Int ?? 0) > 3000 }) {
            s += "; зарядка предлагает > 3 А — значит, она увидела 5-амперную метку"
        }
        if g.flatMap(\.pdOptions).contains(where: { ($0["Voltage (mV)"] as? Int ?? 0) > 20000 }) {
            s += "; есть профили выше 20 В (EPR) — кабель заявлен на 240 Вт"
        }
        lines.append(("Кабель", s))
    } else if g.contains(where: \.partnerPD) {
        // VDO дописываются через секунду-другую после подключения — «нет» не утверждаем.
        lines.append(("Кабель", "e-marker не прочитан — скорее всего, его нет: тогда не больше 3 А / 60 Вт, скорость смотрите по связи"))
    } else {
        lines.append(("Кабель", "метка не прочитана (на том конце не PD-устройство) — для проверки кабеля воткните его петлёй"))
    }

    // Связь
    var links: [String] = []
    for r in g where r.cio {
        links.append("Thunderbolt/USB4 · " + (tb[r.number] ?? "скорость не определена"))
    }
    links += g.flatMap(\.links)
    var seen = Set<String>()
    links = links.filter { seen.insert($0).inserted }
    let hasLinks = !links.isEmpty
    if !hasLinks { links = ["данных нет (только питание)"] }
    for (i, l) in links.enumerated() { lines.append((i == 0 ? "Связь" : "", l)) }
    if loop && hasLinks { lines.append(("", "↑ поднято через этот кабель — это его реальная скорость")) }
    else if hasLinks { lines.append(("", "↑ предел — слабейшее из кабеля и устройства")) }

    // Питание
    if let sink = g.first(where: \.macIsSink), let w = sink.pdWinning {
        let v = w["Voltage (mV)"] as? Int ?? 0, a = w["Max Current (mA)"] as? Int ?? 0
        let now = "\(volts(v)) В × \(volts(a)) А = \(v * a / 1_000_000) Вт"
        if loop {
            lines.append(("Питание", "Mac питает сам себя (\(now)) — безвредно, просто петля"))
        } else {
            lines.append(("Зарядка", "сейчас \(now)"))
            if !sink.pdOptions.isEmpty {
                lines.append(("", "профили: " + sink.pdOptions.map(pdOptionText).joined(separator: " · ")))
            }
        }
    }

    let short: String = {
        if let c = cable { return c.short }
        if let r = g.first(where: \.cio), let s = tb[r.number] { return s.replacingOccurrences(of: " Гбит/с", with: "G") }
        return "?"
    }()
    return Entry(title: title, short: short, lines: lines)
}

func render(_ entries: [Entry]) -> String {
    if entries.isEmpty { return "Ничего не подключено" }
    return entries.map { e in
        ([e.title] + e.lines.map { k, v in "  " + k.padding(toLength: 8, withPad: " ", startingAt: 0) + v })
            .joined(separator: "\n")
    }.joined(separator: "\n\n")
}

// MARK: - CLI

if CommandLine.arguments.contains("--once") || CommandLine.arguments.contains("-1") {
    var e = buildEntries()
    // Сразу после подключения метка может быть ещё не дочитана — одна перепроверка.
    if e.contains(where: { $0.lines.contains { $0.1.hasPrefix("e-marker не прочитан") || $0.1.hasPrefix("метка не прочитана") } }) {
        Thread.sleep(forTimeInterval: 3)
        e = buildEntries()
    }
    print(render(e))
    exit(e.isEmpty ? 1 : 0)
}

// MARK: - Строка меню

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var entries: [Entry] = []
    var notifyPort = IONotificationPortCreate(kIOMainPortDefault)
    var iterators: [io_iterator_t] = []
    var pending: DispatchWorkItem?
    var titleUntil = Date.distantPast
    let queue = DispatchQueue(label: "usb-cable.scan")

    static let agentLabel = "com.geforester.usb-cable"
    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        let img = NSImage(systemSymbolName: "cable.connector", accessibilityDescription: "USB-кабель")
        img?.isTemplate = true
        item.button?.image = img
        watch()
        refresh(announce: false)
    }

    // Подписка на появление/исчезновение узлов порта: SOP/SOP', транспорты, источники питания.
    func watch() {
        guard let np = notifyPort else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(np).takeUnretainedValue(), .defaultMode)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOServiceMatchingCallback = { ctx, it in
            while case let s = IOIteratorNext(it), s != 0 { IOObjectRelease(s) }
            Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue().changed()
        }
        for cls in ["IOPortTransportComponentCC", "IOPortTransportState", "IOPortFeaturePowerSource"] {
            for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var it: io_iterator_t = 0
                if IOServiceAddMatchingNotification(np, type, IOServiceMatching(cls), cb, me, &it) == KERN_SUCCESS {
                    while case let s = IOIteratorNext(it), s != 0 { IOObjectRelease(s) }
                    iterators.append(it)
                }
            }
        }
    }

    // Узлы появляются пачкой, а VDO и линки дописываются чуть позже — ждём, потом добираем ещё раз.
    func changed() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.refresh(announce: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self?.refresh(announce: false) }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    // Меню собираем синхронно ДО показа: если менять пункты в уже открытом меню,
    // AppKit не уменьшает его высоту — внизу остаётся пустота.
    var menuOpen = false
    func menuNeedsUpdate(_ menu: NSMenu) {
        entries = buildEntries(freshTB: false)
        renderButton()
        renderMenu()
    }
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    func refresh(announce: Bool) {
        queue.async {
            let e = buildEntries()
            DispatchQueue.main.async {
                let had = Set(self.entries.map(\.title))
                self.entries = e
                if announce && e.contains(where: { !had.contains($0.title) }) {
                    self.titleUntil = Date().addingTimeInterval(15)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15.1) { self.renderButton() }
                }
                self.renderButton()
                if !self.menuOpen { self.renderMenu() }
            }
        }
    }

    // Сводка по кабелю видна 15 с после подключения, дальше — только иконка.
    func renderButton() {
        guard let b = item.button else { return }
        let showing = Date() < titleUntil && !entries.isEmpty
        b.title = showing ? " " + entries.map(\.short).joined(separator: "  ") : ""
        b.toolTip = render(entries)
    }

    func renderMenu() {
        menu.removeAllItems()
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        if entries.isEmpty { menu.addItem(disabled("Ничего не подключено", bold: false)) }
        for (i, e) in entries.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            menu.addItem(disabled(e.title, bold: true))
            for (k, v) in e.lines {
                let mi = disabled("", bold: false)
                mi.attributedTitle = NSAttributedString(
                    string: k.padding(toLength: 8, withPad: " ", startingAt: 0) + v,
                    attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
                menu.addItem(mi)
            }
        }
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Скопировать отчёт", action: #selector(copyReport), keyEquivalent: "c")
        copy.target = self
        copy.isEnabled = !entries.isEmpty
        menu.addItem(copy)
        let login = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = FileManager.default.fileExists(atPath: App.agentURL.path) ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func disabled(_ title: String, bold: Bool) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        if bold {
            mi.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor])
        }
        return mi
    }

    @objc func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(render(entries), forType: .string)
    }

    // Автозапуск — обычный LaunchAgent, как у dualsense-battery.
    @objc func toggleLogin() {
        let fm = FileManager.default
        let url = App.agentURL
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        } else {
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let plist: [String: Any] = ["Label": App.agentLabel, "ProgramArguments": [exe],
                                        "RunAtLoad": true, "ProcessType": "Interactive"]
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? d.write(to: url)
            }
        }
        renderMenu()
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
