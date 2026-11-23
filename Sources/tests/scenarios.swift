import Cocoa
import CoreGraphics

// Only the environment boundary is stubbed: no real files, processes, keyboard
// state, speech commands, settings, network calls, or status items are accessed.
struct TestState {
    var softwareMuted = false
    var capsLocked = false
    var paused = false
    var commands: [String] = []
    var logLines: [String] = []
    var changes: [(Bool, String)] = []
}
var state = TestState()
func capsOn() -> Bool { state.capsLocked }
func clickMuted() -> Bool { state.softwareMuted }
func isMuted() -> Bool { capsOn() || clickMuted() }
func isPaused() -> Bool { state.paused }
func setClickMuted(_ on: Bool, via: String) {
    state.softwareMuted = on
    state.changes.append((on, via))
}
func speakCtl(_ command: String) { state.commands.append(command) }
func log(_ line: String) { state.logLines.append(line) }

final class Controller: NSObject {
    // EXTRACTED_PROPERTIES
    var refreshCount = 0
    func refresh() { refreshCount += 1 }
    // EXTRACTED_METHODS
}

var assertions = 0
var failures: [String] = []
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !condition() { failures.append(message); print("FAIL: \(message)") }
}
func pump(_ seconds: TimeInterval = 0.52) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}
var controllers: [Controller] = []
func fresh(muted: Bool = false, caps: Bool = false, paused: Bool = false) -> Controller {
    for controller in controllers { controller.pendingResume?.cancel() }
    controllers.removeAll()
    state = TestState(softwareMuted: muted, capsLocked: caps, paused: paused)
    let controller = Controller()
    controllers.append(controller)
    return controller
}

do {
    let c = fresh(muted: true)
    c.controlTapped(at: 100, heldMs: 120)
    expect(!clickMuted(), "Muted single Control tap immediately clears software mute")
    expect(state.commands.isEmpty, "Unmuting Control tap issues no pause/resume command")
    expect(c.pendingResume == nil, "Unmuting Control tap does not schedule a resume")
    expect(c.refreshCount > 0, "Unmuting Control tap refreshes visible state")
    pump()
    expect(state.commands.isEmpty, "Unmuting Control tap produces no delayed playback command")
}

do {
    let c = fresh(muted: true)
    c.togglePause(nil)
    expect(!clickMuted(), "Muted click/menu Pause-Resume immediately clears software mute")
    expect(state.commands.isEmpty, "Unmuting click/menu action issues no playback command")
    expect(c.pendingResume == nil, "Unmuting click/menu action leaves no pending resume")
    expect(c.refreshCount > 0, "Unmuting click/menu action refreshes visible state")
}

do {
    let c = fresh(muted: true)
    c.controlTapped(at: 100, heldMs: 100)
    c.controlTapped(at: 100.2, heldMs: 100)
    expect(!clickMuted(), "Double-tap starting muted remains unmuted")
    expect(state.commands.isEmpty, "Second half of unmuting double-tap does not pause playback")
    c.controlTapped(at: 101, heldMs: 100)
    expect(state.commands == ["pause"], "Control tap after unmute suppression window works normally")
}

do {
    let c = fresh()
    c.controlTapped(at: 100, heldMs: 100)
    expect(state.commands == ["pause"], "Single Control tap immediately pauses speech")
    c.controlTapped(at: 100.2, heldMs: 100)
    expect(clickMuted(), "Double-tap starting unmuted still enables mute")
    expect(state.commands == ["pause"], "Double-tap adds no resume command")
}

do {
    let c = fresh(paused: true)
    c.controlTapped(at: 100, heldMs: 100)
    expect(state.commands.isEmpty, "Paused single tap defers resume until double-tap window closes")
    expect(c.pendingResume != nil, "Paused single tap schedules resume")
    pump()
    expect(state.commands == ["resume"], "Paused single tap resumes exactly once after delay")
    expect(c.pendingResume == nil, "Completed delayed resume clears pending work")
}

do {
    let c = fresh(paused: true)
    c.controlTapped(at: 100, heldMs: 100)
    let pending = c.pendingResume
    c.controlTapped(at: 100.2, heldMs: 100)
    expect(clickMuted(), "Paused double-tap enables mute")
    expect(pending?.isCancelled == true, "Double-tap cancels pending delayed resume")
    expect(c.pendingResume == nil, "Double-tap clears pending resume reference")
    pump()
    expect(state.commands.isEmpty, "Cancelled delayed resume never runs after double-tap mute")
}

do {
    let c = fresh(paused: true)
    c.controlTapped(at: 100, heldMs: 100)
    let pending = c.pendingResume
    c.togglePause(nil)
    expect(pending?.isCancelled == true, "Explicit click cancels pending keyboard resume")
    expect(c.pendingResume == nil, "Explicit click clears pending resume reference")
    expect(state.commands == ["toggle"], "Explicit click issues one toggle command")
    c.controlTapped(at: 100.2, heldMs: 100)
    expect(!clickMuted(), "Explicit click clears pending double-tap gesture")
    c.pendingResume?.cancel()
    pump()
    expect(state.commands == ["toggle"], "Cancelled keyboard resumes do not run after click")
}

do {
    let c = fresh(caps: true)
    c.controlTapped(at: 100, heldMs: 100)
    expect(isMuted(), "Single Control tap cannot override Caps Lock mute")
    expect(!clickMuted(), "Blocked Control tap does not create software mute latch")
    expect(state.commands.isEmpty, "Caps Lock blocks playback commands from Control")
    c.togglePause(nil)
    expect(isMuted(), "Click cannot override Caps Lock mute")
    expect(state.commands.isEmpty, "Caps Lock blocks playback commands from click")
}

do {
    let c = fresh(paused: true)
    c.controlTapped(at: 100, heldMs: 100)
    let pending = c.pendingResume
    c.toggleMute(nil)
    expect(clickMuted(), "Explicit mute menu action enables software mute")
    expect(pending?.isCancelled == true, "Mute menu action cancels pending keyboard resume")
    expect(c.pendingResume == nil, "Mute menu action clears pending resume reference")
    pump()
    expect(state.commands.isEmpty, "Cancelled resume does not run after explicit menu mute")
    c.controlTapped(at: 100.2, heldMs: 100)
    expect(!clickMuted(), "Control after explicit menu mute unmutes with a single tap")
}

do {
    let c = fresh(muted: true)
    c.controlTapped(at: 100, heldMs: 100)
    c.togglePause(nil)
    expect(state.commands == ["toggle"], "Click after unmute performs a normal playback toggle")
    c.controlTapped(at: 100.2, heldMs: 100)
    expect(state.commands == ["toggle", "pause"], "Click clears unmute double-tap suppression")
    expect(!clickMuted(), "Click and following Control tap do not unexpectedly remute")
}

do {
    let c = fresh(muted: true, caps: true)
    c.controlTapped(at: 100, heldMs: 100)
    expect(isMuted(), "Control cannot unmute speech while Caps Lock remains on")
    expect(!clickMuted(), "Control clears software mute even while Caps Lock remains on")
    expect(state.commands.isEmpty, "Combined software/hardware mute causes no playback command")
    state.capsLocked = false
    expect(!isMuted(), "Disabling Caps Lock after Control unmute restores speech readiness")
}

do {
    let c = fresh(muted: true, caps: true)
    c.togglePause(nil)
    expect(isMuted(), "Click cannot unmute speech while Caps Lock remains on")
    expect(!clickMuted(), "Click clears software mute even while Caps Lock remains on")
    expect(state.commands.isEmpty, "Click with combined mute causes no playback command")
    state.capsLocked = false
    expect(!isMuted(), "Disabling Caps Lock after click unmute restores speech readiness")
}

if failures.isEmpty {
    print("PASS: \(assertions) assertions across 12 gesture scenarios")
} else {
    print("FAILED: \(failures.count) of \(assertions) assertions")
    exit(1)
}
