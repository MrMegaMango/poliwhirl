// Integrated local YouTube Music control. All speech settings and artwork follow below.


import Foundation

// Speech activity comes from Poliwhirl's existing playback markers. No audio
// capture or extra status item is needed for this bridge.
final class MusicPauseState {
    private let lock = NSLock()
    private let session = UUID().uuidString
    private let clock: () -> TimeInterval
    private var seq: UInt64 = 0
    private var enabled = false
    private var active = false
    private var lastSpeaking: TimeInterval?
    private let resumeDelay = 0.9

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if !enabled { active = false; lastSpeaking = nil }
        seq &+= 1
    }

    func update(isSpeaking: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        if isSpeaking {
            lastSpeaking = clock()
            if !active { active = true; seq &+= 1 }
        } else { expireLocked() }
    }

    private func expireLocked() {
        if active, let lastSpeaking, clock() - lastSpeaking >= resumeDelay {
            active = false
            seq &+= 1
        }
    }

    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        expireLocked()
        return ["session": session, "seq": seq, "active": active, "enabled": enabled,
                "updatedAt": Int64(Date().timeIntervalSince1970 * 1000), "sourceCount": enabled ? 1 : 0]
    }
}

final class MusicPauseBridge {
    private struct Configuration: Decodable {
        let token: String
        let port: UInt16
    }

    private let state = MusicPauseState()
    private var server: LocalStateServer?
    private let settingsURL: URL
    private let configurationURL: URL
    private(set) var enabled = false
    private(set) var available = false
    private(set) var status = "Music pause is starting"

    init() {
        let hooks = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/hooks", isDirectory: true)
        configurationURL = hooks.appendingPathComponent("music-pause.json")
        settingsURL = hooks.appendingPathComponent("music-pause-settings.json")
    }

    func start() {
        do {
            let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configurationURL))
            guard configuration.port == 49753,
                  configuration.token.utf8.count == 64,
                  configuration.token.allSatisfy({ $0.isHexDigit }) else {
                status = "Music pause configuration is invalid"
                return
            }
            if let data = try? Data(contentsOf: settingsURL),
               let preference = try? JSONDecoder().decode([String: Bool].self, from: data) {
                enabled = preference["enabled"] ?? true
            } else { enabled = true }
            let server = LocalStateServer(state: state, token: configuration.token, port: configuration.port)
            server.onStatus = { [weak self] message in
                guard let self else { return }
                if message.hasPrefix("Error:") {
                    self.available = false
                    self.state.setEnabled(false)
                    self.status = "Music connection unavailable; restart Poliwhirl to retry"
                } else {
                    self.available = true
                    self.state.setEnabled(self.enabled)
                    self.status = "Automatically pauses YouTube Music during spoken replies"
                }
            }
            try server.start()
            self.server = server
        } catch {
            available = false
            enabled = false
            state.setEnabled(false)
            status = "Music pause configuration could not be loaded"
        }
    }

    func update(isSpeaking: Bool) {
        guard available else { return }
        state.update(isSpeaking: isSpeaking)
    }

    func toggle() {
        guard available else { return }
        let next = !enabled
        do {
            let data = try JSONSerialization.data(withJSONObject: ["enabled": next])
            try data.write(to: settingsURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
            enabled = next
            state.setEnabled(next)
            status = "Automatically pauses YouTube Music during spoken replies"
        } catch {
            status = "Could not save the music-pause setting"
        }
    }

    func stop() {
        state.setEnabled(false)
        server?.stop()
        server = nil
        available = false
    }
}


import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let authorization: String?

    init?(_ data: Data) {
        guard data.count <= 8192, let text = String(data: data, encoding: .utf8),
              text.hasSuffix("\r\n\r\n") else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else { return nil }
        method = String(requestLine[0]); path = String(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).lowercased()
            guard headers[name] == nil else { return nil }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0" else { return nil }
        authorization = headers["authorization"]
    }
}

private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let lhs = Array(a.utf8), rhs = Array(b.utf8)
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for i in lhs.indices { difference |= lhs[i] ^ rhs[i] }
    return difference == 0
}

struct HTTPResponse {
    let status: Int
    let body: Data
    var wireData: Data {
        let phrase = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "Error"
        let head = "HTTP/1.1 \(status) \(phrase)\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

final class LocalStateServer {
    private let queue = DispatchQueue(label: "local.voice-music-pause.http")
    private let state: MusicPauseState
    private let token: String
    private let port: UInt16
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    var onStatus: ((String) -> Void)?

    init(state: MusicPauseState, token: String, port: UInt16) {
        self.state = state; self.token = token; self.port = port
    }

    func response(to data: Data) -> HTTPResponse {
        func error(_ code: Int, _ message: String) -> HTTPResponse {
            HTTPResponse(status: code, body: try! JSONSerialization.data(withJSONObject: ["error": message]))
        }
        guard let request = HTTPRequest(data) else { return error(400, "invalid_request") }
        guard request.method == "GET" else { return error(405, "get_only") }
        guard request.path == "/v1/state" else { return error(404, "not_found") }
        guard let auth = request.authorization, constantTimeEqual(auth, "Bearer \(token)") else { return error(401, "unauthorized") }
        return HTTPResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: state.snapshot(), options: [.sortedKeys]))
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let server = try NWListener(using: parameters)
        server.stateUpdateHandler = { [weak self] status in
            switch status {
            case .ready: self?.report("Local connection ready")
            case .failed(let error): self?.report("Error: Local connection failed: \(error.localizedDescription)")
            default: break
            }
        }
        server.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener = server
        server.start(queue: queue)
    }

    func stop() {
        listener?.cancel(); listener = nil
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
        }
    }

    private func report(_ message: String) { DispatchQueue.main.async { [weak self] in self?.onStatus?(message) } }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 32 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.connections.removeValue(forKey: id)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { [weak connection] in connection?.cancel() }
        receive(connection, data: Data())
    }

    private func receive(_ connection: NWConnection, data previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8193) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var data = previous
            if let chunk { data.append(chunk) }
            if data.count > 8192 || data.range(of: Data("\r\n\r\n".utf8)) != nil {
                let payload = self.response(to: data).wireData
                connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil {
                connection.cancel()
            } else { self.receive(connection, data: data) }
        }
    }
}


import Cocoa
import CoreGraphics

// Menu bar indicator + live mute / pause control for AI speech.
//   ready    -> miniature Poliwhirl, with its blue body and spiral belly
//   speaking -> open mouth + gentle bounce during actual playback
//   paused   -> yellow closed mouth + yellow star; muted -> red zipped mouth + red ×
// Native color artwork has a light outline for dark menu bars.
// PAUSE  = left-click the icon to pause / resume immediately, or use a bare tap of
//          Control (down + up within 0.5s, nothing else pressed). For Control taps:
//          speaking -> pauses at once; paused -> resumes after the double-tap window
//          (0.45s) so a double tap can still become "mute" without a blip of audio.
//          When software-muted, either action unmutes immediately. A second Control
//          tap in that same gesture is consumed so it cannot turn mute back on.
//          Pause also works between replies, holding upcoming speech until resume.
// MUTE   = a quick DOUBLE tap of Control (two bare taps < 0.45s apart) toggles the mute
//          flag file, same as the Mute / Unmute menu item; Caps Lock also mutes. Flipping into
//          muted runs `speak-pause.sh kill` to cut off speech already playing (paused or not).
//          Muted = Caps Lock on OR flag file present; the menu says which.
// Right-click / ctrl-click the icon for a menu. Ctrl+C-style shortcuts and ctrl-clicks never
// count as taps. Modifier state is polled 50x/sec via CGEventSource.flagsState (no Accessibility
// permission); the app opts out of App Nap (a napped background app has its timers throttled to
// ~1/s, which silently misses a 100ms tap) and uses a strict dispatch timer. Tap decisions go to
// ~/.claude/hooks/caps-mute-menubar.log (tail it if a tap "did nothing"), plus a warning whenever
// the measured poll rate drops below 30/s.
// Runs as a login agent (~/Library/LaunchAgents/com.zwang.capsmute.plist).

let clickFlag   = ("~/.claude/.muted-click" as NSString).expandingTildeInPath
let pauseFlag   = ("~/.claude/.speech-paused" as NSString).expandingTildeInPath
let pausedDir   = ("~/.claude/.speak-paused.d" as NSString).expandingTildeInPath
let playingDir  = ("~/.claude/.speak-playing.d" as NSString).expandingTildeInPath
let pauseScript = ("~/.claude/hooks/speak-pause.sh" as NSString).expandingTildeInPath
let logPath     = ("~/.claude/hooks/caps-mute-menubar.log" as NSString).expandingTildeInPath

// Shared by the Claude and Codex speech hooks. Never execute or log this file:
// it also contains private credentials. Edit only the requested setting values.
struct SpeechSettingsStore {
    static let minimum = 0.5
    static let maximum = 2.0
    let url: URL
    private let assignment = try! NSRegularExpression(
        pattern: #"(?m)^[\t ]*(?:export[\t ]+)?SPEED[\t ]*=[\t ]*['"]?([0-9]+(?:\.[0-9]+)?)['"]?[\t ]*(?:#[^\r\n]*)?\r?$"#)
    private let anyAssignment = try! NSRegularExpression(
        pattern: #"(?m)^[\t ]*(?:export[\t ]+)?SPEED[\t ]*="#)

    enum StoreError: Error { case invalidSetting, changedDuringSave }

    static func normalized(_ speed: Double) -> Double {
        (min(max(speed, minimum), maximum) * 10).rounded() / 10
    }

    private func contents() throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func matches(in text: String) throws -> [NSTextCheckingResult] {
        let range = NSRange(text.startIndex..., in: text)
        let matches = assignment.matches(in: text, range: range)
        guard matches.count == anyAssignment.numberOfMatches(in: text, range: range) else {
            throw StoreError.invalidSetting
        }
        return matches
    }

    func read() throws -> Double {
        let text = try contents()
        guard let match = try matches(in: text).last,
              let value = Double((text as NSString).substring(with: match.range(at: 1))) else { return 1.0 }
        guard value.isFinite, value > 0 else { throw StoreError.invalidSetting }
        return value
    }

    func save(_ speed: Double) throws {
        guard speed.isFinite else { throw StoreError.invalidSetting }
        let original = try contents()
        let matches = try matches(in: original)
        let value = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Self.normalized(speed))
        let updated = NSMutableString(string: original)
        for match in matches.reversed() { updated.replaceCharacters(in: match.range(at: 1), with: value) }
        if matches.isEmpty {
            let newline = original.contains("\r\n") ? "\r\n" : "\n"
            let separator = original.isEmpty || original.hasSuffix("\n") || original.hasSuffix("\r\n") ? "" : newline
            updated.append(separator + "SPEED=\(value)" + newline)
        }
        try write(updated as String, replacing: original)
    }

    // This intentionally parses literal values only, without evaluating shell
    // substitutions. Editing one setting preserves all other content verbatim.
    private func choiceMatches(_ key: String, in text: String) throws -> [NSTextCheckingResult] {
        guard ["PHONON_VOICE", "SUMMARY_MODELS", "SUMMARY_MODEL", "SUMMARY_MODEL_FALLBACK", "SUMMARIZE"].contains(key) else {
            throw StoreError.invalidSetting
        }
        let prefix = #"(?m)^[\t ]*(?:export[\t ]+)?"# + key + #"[\t ]*=[\t ]*"#
        let literal = try NSRegularExpression(pattern: prefix + #"("[^"\r\n]*"|'[^'\r\n]*'|[^\s#'"\r\n]*)[\t ]*(?:#[^\r\n]*)?\r?$"#)
        let any = try NSRegularExpression(pattern: prefix)
        let range = NSRange(text.startIndex..., in: text)
        let matches = literal.matches(in: text, range: range)
        guard matches.count == any.numberOfMatches(in: text, range: range) else { throw StoreError.invalidSetting }
        return matches
    }

    func choice(_ key: String) throws -> String? {
        let text = try contents()
        guard let match = try choiceMatches(key, in: text).last else { return nil }
        var value = (text as NSString).substring(with: match.range(at: 1))
        if value.hasPrefix("\"") || value.hasPrefix("'") { value = String(value.dropFirst().dropLast()) }
        guard value.range(of: #"^[A-Za-z0-9_.:/+ -]*$"#, options: .regularExpression) != nil else {
            throw StoreError.invalidSetting
        }
        return value
    }

    func saveChoices(_ choices: [String: String]) throws {
        let original = try contents()
        var updated = original
        for key in choices.keys.sorted() {
            let value = choices[key]!
            guard value.range(of: #"^[A-Za-z0-9_.:/+ -]*$"#, options: .regularExpression) != nil else {
                throw StoreError.invalidSetting
            }
            let matches = try choiceMatches(key, in: updated)
            let edited = NSMutableString(string: updated)
            for match in matches.reversed() {
                edited.replaceCharacters(in: match.range(at: 1), with: "\"\(value)\"")
            }
            if matches.isEmpty {
                let newline = updated.contains("\r\n") ? "\r\n" : "\n"
                let separator = updated.isEmpty || updated.hasSuffix("\n") || updated.hasSuffix("\r\n") ? "" : newline
                edited.append(separator + "\(key)=\"\(value)\"" + newline)
            }
            updated = edited as String
        }
        try write(updated, replacing: original)
    }

    private func write(_ updated: String, replacing original: String) throws {
        guard updated != original else { return }

        // mkstemp creates a private 0600 file even if the parent process has a
        // permissive umask. Rename only after the complete replacement is ready.
        var template = Array(url.deletingLastPathComponent().appendingPathComponent(".voice-settings.XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(fd)
        let temporary = URL(fileURLWithPath: String(cString: template))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data(updated.utf8).write(to: temporary)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        guard try contents() == original else { throw StoreError.changedDuringSave }
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

struct SummaryModelOption {
    let title: String
    let shortTitle: String
    let models: String

    static let options = [
        SummaryModelOption(title: "Automatic — GPT-6 Astra, then Claude Opus 5", shortTitle: "Automatic",
                           models: "gpt-6-astra claude-opus-5"),
        SummaryModelOption(title: "GPT-6 Astra", shortTitle: "GPT-6 Astra", models: "gpt-6-astra"),
        SummaryModelOption(title: "Claude Opus 5", shortTitle: "Claude Opus 5", models: "claude-opus-5")
    ]
}

struct SpeechVoice {
    let id: String
    var title: String { id }
}

// Keep timers honest: no App Nap / timer coalescing for this process (system sleep still allowed).
let activityToken = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
    reason: "Control-tap pause detection polls the modifier state every 20 ms")

let logFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f }()
func log(_ msg: String) {
    let line = "\(logFmt.string(from: Date())) | \(msg)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

// --- icon artwork and playback animation ---
enum SpeechIconState: String {
    case ready = "Ready", speaking = "Speaking", paused = "Paused", muted = "Muted"
}

let glyph = NSSize(width: 24, height: 20)
let bounceFrameCount = 40
let bouncePeriod: TimeInterval = 0.85

func compose(state: SpeechIconState, bounce: CGFloat = 0) -> NSImage {
    let img = NSImage(size: glyph, flipped: false) { _ in
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: 0, yBy: bounce)
        transform.concat()

        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        let ink = color(0.09, 0.14, 0.22)
        let blue = color(0.19, 0.48, 0.87)
        let shadow = color(0.13, 0.35, 0.70)
        let white = color(0.97, 0.98, 0.96)
        let rim = color(0.70, 0.83, 0.94)
        let muteRed = color(0.95, 0.10, 0.16)
        let pauseYellow = color(1.0, 0.80, 0.08)

        func ellipse(_ rect: NSRect, fill: NSColor, outline: Bool = true) {
            let path = NSBezierPath(ovalIn: rect)
            if outline {
                rim.setStroke(); path.lineWidth = 1.05; path.stroke()
            }
            fill.setFill(); path.fill()
            if outline {
                ink.setStroke(); path.lineWidth = 0.45; path.stroke()
            }
        }

        // Poliwhirl's round blue body, raised eyes, little gloves, and large
        // spiral stay recognizable alongside its expressive little mouth.
        ellipse(NSRect(x: 3.4, y: 1.4, width: 5, height: 2.5), fill: shadow)
        ellipse(NSRect(x: 11, y: 1.4, width: 5, height: 2.5), fill: shadow)
        ellipse(NSRect(x: 1.4, y: 7.3, width: 4.6, height: 3), fill: blue)
        ellipse(NSRect(x: 13.4, y: 7.3, width: 4.6, height: 3), fill: blue)
        ellipse(NSRect(x: 3, y: 3, width: 13.4, height: 12), fill: blue)
        ellipse(NSRect(x: 4.2, y: 12.5, width: 4.5, height: 4.5), fill: blue)
        ellipse(NSRect(x: 10.7, y: 12.5, width: 4.5, height: 4.5), fill: blue)

        // Eye whites nest inside the blue bumps; sleeping eyelids mark pause.
        for x: CGFloat in [5.1, 11.6] {
            if state == .paused {
                let lid = NSBezierPath()
                lid.move(to: NSPoint(x: x, y: 14.5))
                lid.curve(to: NSPoint(x: x + 2.4, y: 14.5),
                          controlPoint1: NSPoint(x: x + 0.6, y: 14),
                          controlPoint2: NSPoint(x: x + 1.8, y: 14))
                ink.setStroke(); lid.lineWidth = 0.7; lid.lineCapStyle = .round; lid.stroke()
            } else {
                ellipse(NSRect(x: x, y: 13.35, width: 2.55, height: 3.05), fill: white, outline: false)
                ellipse(NSRect(x: x + 0.9, y: 13.55, width: 1, height: 2.4), fill: ink, outline: false)
            }
        }

        // Leave a blue strip above the belly for expressions, without covering
        // the spiral or putting separate controls beside the character.
        ellipse(NSRect(x: 4.05, y: 3.75, width: 11.3, height: 8), fill: white, outline: false)
        let spiral = NSBezierPath()
        for index in 0...160 {
            let progress = Double(index) / 160
            let angle = progress * 3.8 * Double.pi
            let radius = 0.2 + 3.8 * progress
            let point = NSPoint(x: 9.7 + CGFloat(cos(angle) * radius),
                                y: 7.8 + CGFloat(sin(angle) * radius * 0.72))
            if index == 0 { spiral.move(to: point) } else { spiral.line(to: point) }
        }
        ink.setStroke()
        spiral.lineWidth = 0.95
        spiral.lineCapStyle = .round
        spiral.lineJoinStyle = .round
        spiral.stroke()

        let mouth = NSBezierPath()
        mouth.lineWidth = 0.75
        mouth.lineCapStyle = .round
        ink.setStroke()
        switch state {
        case .ready:
            mouth.move(to: NSPoint(x: 8.1, y: 12.8))
            mouth.curve(to: NSPoint(x: 11.3, y: 12.8),
                        controlPoint1: NSPoint(x: 8.8, y: 11.8),
                        controlPoint2: NSPoint(x: 10.6, y: 11.8))
            mouth.stroke()
        case .speaking:
            ellipse(NSRect(x: 8.5, y: 11.9, width: 2.4, height: 1.9), fill: ink, outline: false)
            ellipse(NSRect(x: 9, y: 12.05, width: 1.4, height: 0.55),
                    fill: color(0.99, 0.58, 0.65), outline: false)
        case .paused:
            // A broad yellow closed mouth makes pause visible at menu-bar size.
            let restingMouth = NSBezierPath(
                roundedRect: NSRect(x: 6.5, y: 10.8, width: 6.4, height: 2.4),
                xRadius: 0.8, yRadius: 0.8)
            white.setStroke(); restingMouth.lineWidth = 0.6; restingMouth.stroke()
            pauseYellow.setFill(); restingMouth.fill()
            mouth.move(to: NSPoint(x: 7.5, y: 12))
            mouth.line(to: NSPoint(x: 11.9, y: 12))
            ink.setStroke(); mouth.lineWidth = 0.65
            mouth.stroke()
        case .muted:
            // A broad red mouth stays visible at menu-bar size; white zipper
            // teeth also distinguish mute from the paused expression by shape.
            let sealedMouth = NSBezierPath(
                roundedRect: NSRect(x: 6.5, y: 10.8, width: 6.4, height: 2.4),
                xRadius: 0.8, yRadius: 0.8)
            white.setStroke(); sealedMouth.lineWidth = 0.6; sealedMouth.stroke()
            muteRed.setFill(); sealedMouth.fill()
            mouth.move(to: NSPoint(x: 7.3, y: 12))
            mouth.line(to: NSPoint(x: 12.1, y: 12))
            white.setStroke(); mouth.lineWidth = 0.55
            for x: CGFloat in [8.1, 9.7, 11.3] {
                mouth.move(to: NSPoint(x: x, y: 11.55))
                mouth.line(to: NSPoint(x: x, y: 12.45))
            }
            mouth.stroke()
        }

        // The raised glove pose accompanies speech without changing its timing.
        let gloveLift: CGFloat = state == .speaking ? 0.6 : 0
        ellipse(NSRect(x: 0.75, y: 7.15 + gloveLift, width: 3.65, height: 4.15), fill: white)
        ellipse(NSRect(x: 15.15, y: 7.15 + gloveLift, width: 3.65, height: 4.15), fill: white)
        let thumbs = NSBezierPath()
        thumbs.move(to: NSPoint(x: 2.75, y: 9.6 + gloveLift))
        thumbs.line(to: NSPoint(x: 3.25, y: 8.8 + gloveLift))
        thumbs.move(to: NSPoint(x: 16.75, y: 9.6 + gloveLift))
        thumbs.line(to: NSPoint(x: 16.25, y: 8.8 + gloveLift))
        ink.setStroke(); thumbs.lineWidth = 0.45; thumbs.lineCapStyle = .round; thumbs.stroke()

        if state == .muted {
            // Replace the blue sparkle with a bold red cross for an extra cue
            // that remains legible without relying on the mouth's color alone.
            let muteMark = NSBezierPath()
            muteMark.move(to: NSPoint(x: 19.5, y: 7.35))
            muteMark.line(to: NSPoint(x: 22.7, y: 10.85))
            muteMark.move(to: NSPoint(x: 19.5, y: 10.85))
            muteMark.line(to: NSPoint(x: 22.7, y: 7.35))
            muteMark.lineCapStyle = .round
            white.setStroke(); muteMark.lineWidth = 2.4; muteMark.stroke()
            muteRed.setStroke(); muteMark.lineWidth = 1.6; muteMark.stroke()
        } else {
            let glint = NSBezierPath()
            glint.move(to: NSPoint(x: 21.25, y: 11.25))
            for point in [NSPoint(x: 21.9, y: 9.75), NSPoint(x: 23.4, y: 9.1),
                          NSPoint(x: 21.9, y: 8.45), NSPoint(x: 21.25, y: 6.95),
                          NSPoint(x: 20.6, y: 8.45), NSPoint(x: 19.1, y: 9.1),
                          NSPoint(x: 20.6, y: 9.75)] { glint.line(to: point) }
            glint.close()
            if state == .paused {
                // Match the yellow mouth while preserving Poliwhirl's star.
                glint.lineJoinStyle = .round
                white.setStroke(); glint.lineWidth = 1.1; glint.stroke()
                ink.setStroke(); glint.lineWidth = 0.65; glint.stroke()
                pauseYellow.setFill(); glint.fill()
            } else {
                rim.setStroke(); glint.lineWidth = 0.45; glint.stroke()
                color(0.44, 0.73, 0.98).setFill(); glint.fill()
            }
        }
        return true
    }
    img.isTemplate = false
    return img
}


let readyImg = compose(state: .ready)
let pausedImg = compose(state: .paused)
let mutedImg = compose(state: .muted)
let speakingFrames = (0..<bounceFrameCount).map { index in
    let phase = Double(index) / Double(bounceFrameCount)
    let lift = 2 * pow(sin(.pi * phase), 2)
    return compose(state: .speaking, bounce: CGFloat(lift))
}

// --- state ---
func capsOn() -> Bool { CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift) }
func clickMuted() -> Bool { FileManager.default.fileExists(atPath: clickFlag) }
func isMuted() -> Bool { capsOn() || clickMuted() }

// The flag file's content records which gesture set it ("click" / "Control double-tap").
func setClickMuted(_ on: Bool, via: String) {
    if on { FileManager.default.createFile(atPath: clickFlag, contents: via.data(using: .utf8)) }
    else  { try? FileManager.default.removeItem(atPath: clickFlag) }
}
func flagVia() -> String {
    guard let d = FileManager.default.contents(atPath: clickFlag),
          let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !s.isEmpty else { return "click" }
    return s
}

func hasLiveMarker(in directory: String) -> Bool {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return false }
    var any = false
    for name in names {
        guard let pid = Int32(name), pid > 0 else { continue }
        if kill(pid, 0) == 0 { any = true }
        else if errno == ESRCH { try? FileManager.default.removeItem(atPath: directory + "/" + name) }
    }
    return any
}
func isPaused() -> Bool {
    FileManager.default.fileExists(atPath: pauseFlag) || hasLiveMarker(in: pausedDir)
}
func isPlaying() -> Bool { hasLiveMarker(in: playingDir) }

// speak-pause.sh <cmd>; `kill` keeps a raw killall as a safety net if the script is gone.
func speakCtl(_ cmd: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    let fallback = (cmd == "kill") ? " || killall speak-play say afplay 2>/dev/null" : ""
    p.arguments = ["-c", "\"\(pauseScript)\" \(cmd) >/dev/null 2>&1\(fallback)"]
    try? p.run()
}

// --- controller ---
final class Controller: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let info = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let musicPause = MusicPauseBridge()
    let musicPauseItem = NSMenuItem(title: "Pause music while speaking", action: nil, keyEquivalent: "")
    let speedStore = SpeechSettingsStore(url: URL(fileURLWithPath:
        ("~/.claude/hooks/voice.env" as NSString).expandingTildeInPath))
    let speedSlider = NSSlider(value: 1.1, minValue: SpeechSettingsStore.minimum,
                               maxValue: SpeechSettingsStore.maximum, target: nil, action: nil)
    let speedValue = NSTextField(labelWithString: "1.1×")
    let speedHint = NSTextField(labelWithString: "Changes playing audio immediately")
    let voiceItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
    let voiceMenu = NSMenu()
    let summaryItem = NSMenuItem(title: "Summarizer model", action: nil, keyEquivalent: "")
    let summaryMenu = NSMenu()
    let modelStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var voices: [SpeechVoice] = []
    var wasMuted = false
    var iconState: SpeechIconState = .ready
    var speakingStartedAt = ProcessInfo.processInfo.systemUptime
    var lastIconFrame = -1
    var reduceMotion = false
    var ticks = 0
    var timer: DispatchSourceTimer?
    var windowTicks = 0
    var windowStart = Date().timeIntervalSinceReferenceDate

    // Control-tap detector state
    var ctrlDown = false
    var ctrlDownAt: TimeInterval = 0
    var comboSeen = false
    let otherMods: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn]
    let maxTap: TimeInterval = 0.5
    // single vs double tap
    var lastTapAt: TimeInterval = 0
    var lastTapWasUnmute = false
    var pendingResume: DispatchWorkItem?
    let doubleTapWindow: TimeInterval = 0.45

    override init() {
        super.init()
        menu.delegate = self
        info.isEnabled = false
        menu.addItem(info)
        let pauseItem = NSMenuItem(title: "Unmute / Pause / Resume speech   (click or tap Control)",
                                   action: #selector(togglePause(_:)), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        let muteItem = NSMenuItem(title: "Mute / Unmute   (double-tap Control or Caps Lock)",
                                  action: #selector(toggleMute(_:)), keyEquivalent: "")
        muteItem.target = self
        menu.addItem(muteItem)
        musicPauseItem.target = self
        musicPauseItem.action = #selector(toggleMusicPause(_:))
        menu.addItem(musicPauseItem)
        menu.addItem(.separator())
        addSpeedControl()
        addModelControls()
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit (back at next login)",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        musicPause.start()

        if let button = item.button {
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("AI speech: Ready")
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "AI speech · click or tap Control: unmute / pause / resume · double-tap Control: mute · right-click: settings"
        }
        refresh()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        log("started pid=\(getpid()) poll=20ms double-tap-window=\(Int(doubleTapWindow * 1000))ms")
    }

    func addSpeedControl() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 98))
        view.autoresizingMask = [.width]
        let title = NSTextField(labelWithString: "Speech speed")
        title.frame = NSRect(x: 18, y: 73, width: 240, height: 18)
        title.font = .menuFont(ofSize: 13)
        view.addSubview(title)

        speedValue.frame = NSRect(x: 326, y: 73, width: 56, height: 18)
        speedValue.alignment = .right
        speedValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        speedValue.autoresizingMask = [.minXMargin]
        view.addSubview(speedValue)

        speedSlider.frame = NSRect(x: 55, y: 42, width: 290, height: 24)
        speedSlider.autoresizingMask = [.width]
        speedSlider.isContinuous = true
        speedSlider.altIncrementValue = 0.1
        speedSlider.target = self
        speedSlider.action = #selector(speedChanged(_:))
        speedSlider.setAccessibilityLabel("Speech speed")
        speedSlider.setAccessibilityHelp("Adjusts playing audio and future responses from 0.5 to 2.0 times normal speed.")
        view.addSubview(speedSlider)

        for (text, x) in [("0.5×", CGFloat(18)), ("2.0×", CGFloat(350))] {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: x, y: 46, width: 34, height: 16)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            if x > 100 { label.autoresizingMask = [.minXMargin]; label.alignment = .right }
            view.addSubview(label)
        }
        speedHint.frame = NSRect(x: 18, y: 15, width: 364, height: 16)
        speedHint.font = .systemFont(ofSize: 11)
        speedHint.textColor = .secondaryLabelColor
        speedHint.autoresizingMask = [.width]
        view.addSubview(speedHint)
        let row = NSMenuItem()
        row.view = view
        menu.addItem(row)
        loadSpeed()
    }

    func showSpeed(_ speed: Double) {
        speedSlider.doubleValue = speed
        speedValue.stringValue = String(format: "%.1f×", speed)
        speedSlider.setAccessibilityValueDescription(String(format: "%.1f times normal speed", speed))
    }

    func loadSpeed() {
        do {
            showSpeed(try speedStore.read())
            speedSlider.isEnabled = true
            speedHint.stringValue = "Changes playing audio immediately"
            speedHint.textColor = .secondaryLabelColor
        } catch {
            speedSlider.isEnabled = false
            speedHint.stringValue = "Couldn’t read speech speed. Reopen this menu to retry."
            speedHint.textColor = .systemRed
        }
    }

    func addModelControls() {
        voiceMenu.autoenablesItems = false
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)
        summaryMenu.autoenablesItems = false
        summaryItem.submenu = summaryMenu
        for (index, option) in SummaryModelOption.options.enumerated() {
            let row = NSMenuItem(title: option.title, action: #selector(summaryChanged(_:)), keyEquivalent: "")
            row.target = self
            row.tag = index
            summaryMenu.addItem(row)
        }
        menu.addItem(summaryItem)
        modelStatus.isEnabled = false
        modelStatus.isHidden = true
        menu.addItem(modelStatus)
        loadVoices()
    }

    func selectedSummaryModels() throws -> String {
        if let models = try speedStore.choice("SUMMARY_MODELS"), !models.isEmpty {
            return models.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let configuredPrimary = try speedStore.choice("SUMMARY_MODEL") ?? ""
        let primary = configuredPrimary.isEmpty ? "gpt-6-astra" : configuredPrimary
        let fallback = try speedStore.choice("SUMMARY_MODEL_FALLBACK") ?? "claude-opus-5"
        return [primary, fallback].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func loadModels() {
        do {
            let selected = try selectedSummaryModels()
            let enabled = try (speedStore.choice("SUMMARIZE") ?? "1") == "1"
            let selectedOption = SummaryModelOption.options.first { $0.models == selected }
            summaryItem.title = "Summarizer model: \(enabled ? selectedOption?.shortTitle ?? "Custom" : "Off")"
            for row in summaryMenu.items {
                row.state = enabled && SummaryModelOption.options[row.tag].models == selected ? .on : .off
            }
            let configuredVoice = try speedStore.choice("PHONON_VOICE") ?? ""
            let selectedVoice = configuredVoice.isEmpty ? "Harper" : configuredVoice
            voiceItem.title = "English voice: \(selectedVoice)"
            voiceMenu.removeAllItems()
            for voice in voices.sorted(by: { $0.title < $1.title }) {
                let row = NSMenuItem(title: voice.title, action: #selector(voiceChanged(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = voice.id
                row.state = voice.id == selectedVoice ? .on : .off
                voiceMenu.addItem(row)
            }
            if !voices.contains(where: { $0.id == selectedVoice }) {
                if !voices.isEmpty { voiceMenu.addItem(.separator()) }
                let status = NSMenuItem(title: voices.isEmpty ? "No Phonon voices installed" : "Selected voice is not installed",
                                        action: nil, keyEquivalent: "")
                status.isEnabled = false
                voiceMenu.addItem(status)
            }
            modelStatus.isHidden = true
        } catch {
            modelStatus.title = "Couldn’t read model settings. Reopen this menu to retry."
            modelStatus.isHidden = false
        }
    }

    func loadVoices() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/hooks/phonon/model/voices", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        voices = files.compactMap { file in
            let name = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "safetensors",
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else { return nil }
            return SpeechVoice(id: name)
        }
        loadModels()
    }

    @objc func voiceChanged(_ sender: NSMenuItem) {
        guard let voice = sender.representedObject as? String else { return }
        saveModelChoices(["PHONON_VOICE": voice])
    }

    @objc func summaryChanged(_ sender: NSMenuItem) {
        guard SummaryModelOption.options.indices.contains(sender.tag) else { return }
        saveModelChoices(["SUMMARY_MODELS": SummaryModelOption.options[sender.tag].models, "SUMMARIZE": "1"])
    }

    func saveModelChoices(_ choices: [String: String]) {
        do {
            try speedStore.saveChoices(choices)
            loadModels()
        } catch {
            modelStatus.title = "Couldn’t save this selection. Try again."
            modelStatus.isHidden = false
            log("speech model selection save failed")
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMusicPause()
        loadSpeed()
        loadVoices()
    }

    func refreshMusicPause() {
        musicPauseItem.title = musicPause.available ? "Pause music while speaking"
            : "Pause music while speaking (unavailable)"
        musicPauseItem.state = musicPause.enabled ? .on : .off
        musicPauseItem.action = musicPause.available ? #selector(toggleMusicPause(_:)) : nil
        musicPauseItem.isEnabled = musicPause.available
        musicPauseItem.toolTip = musicPause.status
    }

    @objc func toggleMusicPause(_ sender: Any?) {
        musicPause.toggle()
        refreshMusicPause()
    }

    @objc func speedChanged(_ sender: NSSlider) {
        let value = SpeechSettingsStore.normalized(sender.doubleValue)
        do {
            try speedStore.save(value)
            showSpeed(value)
            speedHint.stringValue = "Changes playing audio immediately"
            speedHint.textColor = .secondaryLabelColor
        } catch {
            if let saved = try? speedStore.read() { showSpeed(saved) }
            speedHint.stringValue = "Couldn’t save speech speed. Try again."
            speedHint.textColor = .systemRed
            log("speech speed save failed")
        }
    }

    // 50x/sec: watch the Control key for a bare tap; every 5th tick refresh mute/pause UI.
    func tick() {
        let flags = CGEventSource.flagsState(.hidSystemState)
        let ctrl = flags.contains(.maskControl)
        let now = Date().timeIntervalSinceReferenceDate
        if ctrl {
            if !ctrlDown { ctrlDown = true; ctrlDownAt = now; comboSeen = false }
            if !flags.intersection(otherMods).isEmpty { comboSeen = true }
        } else if ctrlDown {
            ctrlDown = false
            let held = now - ctrlDownAt
            // Was anything else pressed while Control was down (Ctrl+C, ctrl-click, ctrl+scroll)?
            let sinceOther = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
                .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
                .min() ?? .infinity
            let heldMs = Int(held * 1000)
            if !comboSeen && held < maxTap && sinceOther > held + 0.05 {
                controlTapped(at: now, heldMs: heldMs)
            } else {
                let why = comboSeen ? "other modifier held" : held >= maxTap ? "held too long" : "another key/click during hold"
                log("control released, ignored: \(why) (held \(heldMs)ms)")
            }
        }
        ticks += 1
        if ticks % 5 == 0 { refresh() }
        updateIcon()
        // Poll-rate sanity check every 10s: if the system throttles us, say so in the log.
        windowTicks += 1
        if now - windowStart >= 10 {
            let rate = Double(windowTicks) / (now - windowStart)
            if rate < 30 { log(String(format: "WARNING poll rate %.1f/s (expected ~50/s); taps may be missed", rate)) }
            windowTicks = 0; windowStart = now
        }
    }

    func controlTapped(at now: TimeInterval, heldMs: Int) {
        // Second bare tap inside the window -> double tap -> mute toggle.
        if now - lastTapAt < doubleTapWindow {
            lastTapAt = 0
            pendingResume?.cancel(); pendingResume = nil
            if lastTapWasUnmute {
                lastTapWasUnmute = false
                log("control double-tap -> second tap consumed after unmute action")
                return
            }
            let on = !clickMuted()
            setClickMuted(on, via: "Control double-tap")
            log("control double-tap -> mute \(on ? "on" : "off")")
            refresh()                       // the off->on edge kills speech in progress
            return
        }
        lastTapAt = now
        lastTapWasUnmute = false
        if unmuteForPlayback(via: "control tap (held \(heldMs)ms)") {
            lastTapWasUnmute = true
            return
        }
        if isPaused() {
            // Resume is not time-critical: wait out the double-tap window first, so a
            // double tap becomes "mute" cleanly instead of resuming for a moment.
            let w = DispatchWorkItem { [weak self] in
                self?.pendingResume = nil
                speakCtl("resume")
                log("control tap -> resume")
                self?.refreshSoon()
            }
            pendingResume = w
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: w)
            log("control tap (held \(heldMs)ms) -> resume in \(Int(doubleTapWindow * 1000))ms unless double-tapped")
        } else {
            speakCtl("pause")               // also holds upcoming speech when idle
            log("control tap (held \(heldMs)ms) -> pause")
            refreshSoon()
        }
    }

    func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.refresh() }
    }

    // A normal playback action clears software mute instead of silently doing
    // nothing. Caps Lock remains an explicit hardware mute for the speech hooks.
    func unmuteForPlayback(via: String) -> Bool {
        guard isMuted() else { return false }
        if clickMuted() { setClickMuted(false, via: via) }
        if capsOn() {
            log("\(via) -> software mute off; turn off Caps Lock to unmute")
        } else {
            log("\(via) -> unmute")
        }
        refresh()
        return true
    }

    @objc func togglePause(_ sender: Any?) {
        // An explicit click or menu action supersedes a pending keyboard resume.
        pendingResume?.cancel(); pendingResume = nil
        lastTapAt = 0
        lastTapWasUnmute = false
        if unmuteForPlayback(via: "click / pause menu") { return }
        speakCtl("toggle")
        refreshSoon()
    }
    @objc func toggleMute(_ sender: Any?) {
        pendingResume?.cancel(); pendingResume = nil
        lastTapAt = 0
        lastTapWasUnmute = false
        setClickMuted(!clickMuted(), via: "menu")
        refresh()
    }

    @objc func clicked(_ sender: Any?) {
        let e = NSApp.currentEvent
        let rightish = (e?.type == .rightMouseUp) || (e?.modifierFlags.contains(.control) ?? false)
        if rightish {
            if let button = item.button {
                menu.popUp(positioning: nil,
                           at: NSPoint(x: 0, y: button.bounds.height + 5),
                           in: button)
            }
        } else {
            togglePause(sender)
        }
    }

    func updateIcon() {
        guard let button = item.button else { return }
        let frame: Int
        if iconState == .speaking && !reduceMotion {
            let elapsed = ProcessInfo.processInfo.systemUptime - speakingStartedAt
            frame = Int(elapsed.truncatingRemainder(dividingBy: bouncePeriod) / bouncePeriod * Double(bounceFrameCount))
        } else { frame = 0 }
        guard frame != lastIconFrame else { return }
        lastIconFrame = frame
        switch iconState {
        case .ready: button.image = readyImg
        case .speaking: button.image = speakingFrames[frame]
        case .paused: button.image = pausedImg
        case .muted: button.image = mutedImg
        }
        button.title = ""
    }

    func refresh() {
        guard let button = item.button else { return }
        let muted = isMuted()
        if muted && !wasMuted {
            // Mute replaces pause; unmuting must not reveal a second quiet state.
            try? FileManager.default.removeItem(atPath: pauseFlag)
            speakCtl("kill")
        }
        wasMuted = muted
        let paused = !muted && isPaused()
        let speaking = !muted && !paused && isPlaying()
        musicPause.update(isSpeaking: speaking)
        refreshMusicPause()
        let next: SpeechIconState = muted ? .muted : paused ? .paused : speaking ? .speaking : .ready
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if next != iconState {
            iconState = next
            lastIconFrame = -1
            if next == .speaking { speakingStartedAt = ProcessInfo.processInfo.systemUptime }
            button.setAccessibilityLabel("AI speech: \(next.rawValue)")
            log("speech state -> \(next.rawValue.lowercased())")
        }
        updateIcon()
        let via = (clickMuted() && capsOn()) ? "\(flagVia()) + Caps Lock"
                : clickMuted() ? flagVia()
                : capsOn() ? "Caps Lock" : ""
        info.title = muted ? "Muted (\(via)) · " + (capsOn() ? "turn off Caps Lock to unmute" : "click or tap Control to unmute")
                   : paused ? "Paused · click to resume · right-click for settings"
                   : speaking ? "Speaking · click to pause · right-click for settings"
                   : "Ready · click to pause · right-click for settings"
        button.toolTip = info.title + " · double-tap Control: mute / unmute"
    }

}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
let controller = Controller()
app.run()
