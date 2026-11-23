import AVFoundation
import AppKit
import Foundation

// speak-play: audio player for the Claude Code speech hook that can really pause.
//
//   speak-play [--volume V] [--touch PATH] FILE          play an audio file (Kokoro mp3)
//   speak-play --say TEXT [--rate WPM] [--volume V] [--touch PATH]   speak text (fallback when Kokoro is down)
// Add --speed INITIAL and/or --speed-file PATH for live 0.5x-2.0x playback.
// Input audio must be rendered at 1x; only the literal SPEED setting is read.
//
// Signals:  SIGUSR1 = toggle pause/resume     SIGUSR2 = pause     SIGCONT = resume
//           SIGTERM / SIGINT = stop now (exit 0)
// While paused it creates ~/.claude/.speak-paused.d/<pid> (removed on resume/exit) so the
// menu bar app can show a pause badge, and touches --touch PATH every 30s if it exists, so
// the speak-response.sh queue lock is not mistaken for abandoned during a long pause.
// During active playback it creates ~/.claude/.speak-playing.d/<pid>. Both marker
// directories can be overridden with SPEAK_PAUSED_DIR / SPEAK_ACTIVITY_DIR for tests.
// Exit codes: 0 played/stopped, 2 could not start (caller may fall back to afplay/say).
//
// Why not SIGSTOP afplay: afplay hands the whole clip to the audio server up front, so a
// suspended afplay keeps playing (measured: 6s SIGSTOP on a 14s clip extended it <1s).

let pausedDir = NSString(string: ProcessInfo.processInfo.environment["SPEAK_PAUSED_DIR"]
    ?? "~/.claude/.speak-paused.d").expandingTildeInPath
let markerPath = pausedDir + "/" + String(getpid())
let activityDir = NSString(string: ProcessInfo.processInfo.environment["SPEAK_ACTIVITY_DIR"]
    ?? "~/.claude/.speak-playing.d").expandingTildeInPath
let activityMarkerPath = activityDir + "/" + String(getpid())

var volume: Float = 1.0
var rateWPM: Double = 200
var touchPath: String? = nil
var sayText: String? = nil
var filePath: String? = nil
var speedFile: String? = nil
var initialSpeed: Float = 1.0
var liveSpeed = false

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--volume", "-v": if !args.isEmpty, let v = Float(args.removeFirst()) { volume = v }
    case "--rate", "-r":   if !args.isEmpty, let r = Double(args.removeFirst()) { rateWPM = r }
    case "--touch":        if !args.isEmpty { touchPath = args.removeFirst() }
    case "--say":          if !args.isEmpty { sayText = args.removeFirst() }
    case "--speed-file":
        liveSpeed = true
        if !args.isEmpty { speedFile = NSString(string: args.removeFirst()).expandingTildeInPath }
    case "--speed":
        liveSpeed = true
        if !args.isEmpty, let value = Float(args.removeFirst()), value.isFinite { initialSpeed = value }
    case "-h", "--help":
        print("usage: speak-play [--volume V] [--touch PATH] [--speed INITIAL] [--speed-file PATH] FILE | --say TEXT [--rate WPM]"); exit(0)
    default:               filePath = a
    }
}
if sayText == nil && filePath == nil { fputs("speak-play: nothing to play\n", stderr); exit(2) }
if filePath == nil, let text = sayText, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    fputs("speak-play: nothing to say\n", stderr); exit(2)
}

func boundedSpeed(_ value: Float) -> Float { min(max(value, 0.5), 2.0) }
func speechVoice(for text: String) -> AVSpeechSynthesisVoice? {
    if text.range(of: #"\p{Han}"#, options: .regularExpression) != nil,
       let voice = AVSpeechSynthesisVoice(language: "zh-CN") { return voice }
    // Keep the configured macOS voice for text without Chinese characters.
    return AVSpeechSynthesisVoice(identifier: NSSpeechSynthesizer.defaultVoice.rawValue)
}
var currentSpeed = boundedSpeed(initialSpeed)
var livePlayer: AVAudioPlayer? = nil
var renderedSpeechDirectory: URL? = nil

// Never source this private file, evaluate substitutions, or print its contents.
// A missing/invalid setting uses the initial speed at startup, then keeps the
// most recent valid value until a valid replacement arrives.
let speedAssignment = try! NSRegularExpression(pattern: #"(?m)^[\t ]*(?:export[\t ]+)?SPEED[\t ]*="#)
let literalSpeed = try! NSRegularExpression(pattern: #"(?m)^[\t ]*(?:export[\t ]+)?SPEED[\t ]*=[\t ]*(?:"([0-9]+(?:\.[0-9]+)?)"|'([0-9]+(?:\.[0-9]+)?)'|([0-9]+(?:\.[0-9]+)?))[\t ]*(?:#[^\r\n]*)?\r?$"#)
func readSpeedPreference() -> Float? {
    guard let path = speedFile, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let assignment = speedAssignment.matches(in: text, range: range).last,
          let match = literalSpeed.matches(in: text, range: range).last,
          match.range.location == assignment.range.location else { return nil }
    for index in 1...3 where match.range(at: index).location != NSNotFound {
        guard let value = Float((text as NSString).substring(with: match.range(at: index))),
              value.isFinite, value > 0 else { return nil }
        return boundedSpeed(value)
    }
    return nil
}
func updateSpeed() {
    guard liveSpeed else { return }
    if let value = readSpeedPreference() { currentSpeed = value }
    if let player = livePlayer, player.rate != currentSpeed { player.rate = currentSpeed }
}
updateSpeed()

func writeMarker() {
    try? FileManager.default.createDirectory(atPath: pausedDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: markerPath, contents: Data())
}
func removeMarker() { try? FileManager.default.removeItem(atPath: markerPath) }
func writeActivityMarker() {
    guard !paused else { return }
    try? FileManager.default.createDirectory(atPath: activityDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: activityMarkerPath, contents: Data())
}
func removeActivityMarker() { try? FileManager.default.removeItem(atPath: activityMarkerPath) }
func touchLock() {
    guard let p = touchPath, FileManager.default.fileExists(atPath: p) else { return }
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: p)
}

var paused = false
var keepalive: DispatchSourceTimer? = nil
var doPause: () -> Void = {}
var doResume: () -> Void = {}

func pause() {
    guard !paused else { return }
    paused = true
    doPause()
    removeActivityMarker()
    writeMarker(); touchLock()
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + 30, repeating: 30)
    t.setEventHandler { touchLock() }
    t.resume()
    keepalive = t
}
func resume() {
    guard paused else { return }
    paused = false
    keepalive?.cancel(); keepalive = nil
    removeMarker()
    doResume()
}
func finish(_ code: Int32) -> Never {
    keepalive?.cancel()
    removeMarker()
    removeActivityMarker()
    if let directory = renderedSpeechDirectory { try? FileManager.default.removeItem(at: directory) }
    exit(code)
}

// Clear a stale marker if a previous process using this PID was killed abruptly.
removeMarker()
removeActivityMarker()

var sources: [DispatchSourceSignal] = []
func on(_ sig: Int32, _ handler: @escaping () -> Void) {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler(handler: handler); s.resume(); sources.append(s)
}
on(SIGUSR1) { paused ? resume() : pause() }
on(SIGUSR2) { pause() }
on(SIGCONT) { resume() }
on(SIGTERM) { finish(0) }
on(SIGINT)  { finish(0) }
on(SIGHUP)  { finish(0) }

var keep: [AnyObject] = []   // keep player/synth/delegates alive
var isDone: () -> Bool = { false }      // backend says playback finished
var failSafeSec: Double = 600           // hard cap on un-paused wall time
var unpausedSec = 0.0

final class AudioDone: NSObject, AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) { finish(0) }
    func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        fputs("speak-play: decode error\n", stderr); finish(1)
    }
}

func startAudio(_ url: URL) {
    guard let player = try? AVAudioPlayer(contentsOf: url) else {
        fputs("speak-play: cannot open audio\n", stderr); finish(2)
    }
    let d = AudioDone()
    player.delegate = d
    player.volume = volume
    if liveSpeed {
        player.enableRate = true
        livePlayer = player
        updateSpeed()
        player.rate = currentSpeed
    }
    player.prepareToPlay()
    doPause = { player.pause() }
    doResume = {
        updateSpeed()
        guard player.play() else { finish(2) }
        if player.isPlaying { writeActivityMarker() }
    }
    isDone = { !player.isPlaying }
    // Wall-clock playback can double at the slowest supported rate. Paused time
    // remains excluded from this cap, including pauses made during rendering.
    failSafeSec = player.duration / (liveSpeed ? 0.5 : 1.0) + 15
    unpausedSec = 0
    keep = [player, d]
    if !paused {
        guard player.play() else { fputs("speak-play: play() failed\n", stderr); finish(2) }
        if player.isPlaying { writeActivityMarker() }
    }
}

// AVSpeechUtterance.rate is fixed once enqueued. Rendering live-speed fallback
// speech into private audio lets it use the same adjustable playback path.
final class SpeechRenderer {
    let synth = AVSpeechSynthesizer()
    let utterance: AVSpeechUtterance
    let outputURL: URL
    var output: AVAudioFile? = nil
    var completed = false
    let lock = NSLock()

    init(utterance: AVSpeechUtterance, outputURL: URL) {
        self.utterance = utterance
        self.outputURL = outputURL
    }

    func start() {
        synth.write(utterance) { [weak self] buffer in self?.receive(buffer) }
    }

    func receive(_ buffer: AVAudioBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else { fail(); return }
        if pcm.frameLength == 0 {
            completed = true
            let hasAudio = output != nil
            output = nil // Close the file before AVAudioPlayer opens it.
            DispatchQueue.main.async { [outputURL] in
                guard hasAudio else { finish(2) }
                startAudio(outputURL)
            }
            return
        }
        do {
            if output == nil {
                output = try AVAudioFile(forWriting: outputURL, settings: pcm.format.settings,
                                         commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
            }
            try output?.write(from: pcm)
        } catch { fail() }
    }

    func fail() {
        completed = true
        output = nil
        DispatchQueue.main.async { fputs("speak-play: speech rendering failed\n", stderr); finish(2) }
    }
}

if let path = filePath {
    startAudio(URL(fileURLWithPath: path))
} else if let text = sayText {
    final class Done: NSObject, AVSpeechSynthesizerDelegate {
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) { writeActivityMarker() }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didContinue u: AVSpeechUtterance) { writeActivityMarker() }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didPause u: AVSpeechUtterance) { removeActivityMarker() }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { finish(0) }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { finish(0) }
    }
    let utt = AVSpeechUtterance(string: text)
    utt.voice = speechVoice(for: text)
    // AVSpeech rate 0...1, default 0.5 ~ the normal speaking rate `say` uses at ~175-200 wpm.
    utt.rate = Float(min(max(AVSpeechUtteranceDefaultSpeechRate * Float(rateWPM / 190.0), AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate))
    failSafeSec = Double(text.count) / 6.0 + 30
    if liveSpeed {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speak-play-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700]) }
        catch { fputs("speak-play: cannot create speech audio\n", stderr); finish(2) }
        renderedSpeechDirectory = directory
        utt.volume = 1.0 // Playback applies the requested volume once.
        let renderer = SpeechRenderer(utterance: utt, outputURL: directory.appendingPathComponent("speech.caf"))
        keep = [renderer]
        renderer.start()
    } else {
        let synth = AVSpeechSynthesizer()
        let d = Done()
        synth.delegate = d
        utt.volume = volume
        synth.speak(utt)
        doPause = { synth.pauseSpeaking(at: .word) }
        doResume = { synth.continueSpeaking() }
        isDone = { !synth.isSpeaking }
        keep = [synth, d, utt]
    }
}

// Read the path anew so atomic preference-file replacements are observed too.
let speedPoll = DispatchSource.makeTimerSource(queue: .main)
if liveSpeed {
    speedPoll.schedule(deadline: .now() + 0.1, repeating: 0.1)
    speedPoll.setEventHandler { updateSpeed() }
    speedPoll.resume()
}

// Completion poll (every 0.25s, after a 1s start-up grace) + fail-safe.
let poll = DispatchSource.makeTimerSource(queue: .main)
poll.schedule(deadline: .now() + 1.0, repeating: 0.25)
poll.setEventHandler {
    if paused { return }
    unpausedSec += 0.25
    if isDone() { finish(0) }
    if unpausedSec > failSafeSec { fputs("speak-play: fail-safe timeout\n", stderr); finish(1) }
}
poll.resume()

RunLoop.main.run()    // services both the main GCD queue (signals, timers) and AVFoundation callbacks
