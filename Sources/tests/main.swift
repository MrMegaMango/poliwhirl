import Foundation

func testMusicPauseState() {
    var now: TimeInterval = 0
    let state = MusicPauseState(clock: { now })
    func active() -> Bool { state.snapshot()["active"] as! Bool }
    state.update(isSpeaking: true)
    precondition(!active(), "Disabled integration must not pause music")
    state.setEnabled(true)
    state.update(isSpeaking: true)
    precondition(active())
    now = 5; state.update(isSpeaking: true)
    precondition(active(), "Long utterances hold the pause")
    now = 5.5; state.update(isSpeaking: false)
    precondition(active(), "Short gaps should not restart music")
    now = 5.91
    precondition(!active(), "Silence must release without a main-loop tick")
    now = 6; state.update(isSpeaking: true)
    state.setEnabled(false)
    precondition(!active(), "Disabling must restore owned playback")
    precondition(state.snapshot()["sourceCount"] as? Int == 0)
    state.setEnabled(true)
    precondition(!active(), "Re-enabling must not reuse a previous speech pulse")
    precondition(state.snapshot()["sourceCount"] as? Int == 1)
    print("PASS: Poliwhirl speech activity, silence release, stalled-loop expiry, and disable/re-enable")
}

func testSpeechSettings() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phonon-menu-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = directory.appendingPathComponent("voice.env")
    let store = SpeechSettingsStore(url: settings)
    let original = "# fixture only\r\nVOICE=af_sky\r\nSPEED=1.4\r\nVOICE_API_KEY='fixture-secret-$()'\r\nSUMMARY_MODELS=\"gpt-6-astra\"\r\n"
    try original.write(to: settings, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
    try store.saveChoices(["PHONON_VOICE": "Harper"])
    let appended = try String(contentsOf: settings, encoding: .utf8)
    precondition(appended == original + "PHONON_VOICE=\"Harper\"\r\n", "Appending changed other settings")
    try store.saveChoices(["PHONON_VOICE": "Zoey"])
    let switched = try String(contentsOf: settings, encoding: .utf8)
    precondition(switched == original + "PHONON_VOICE=\"Zoey\"\r\n", "Switching changed other settings")
    let selectedVoice = try store.choice("PHONON_VOICE")
    precondition(selectedVoice == "Zoey")
    let selectedSpeed = try store.read()
    precondition(selectedSpeed == 1.4)
    let mode = try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as! NSNumber
    precondition(mode.intValue == 0o600, "Private permissions changed")
    do {
        try store.saveChoices(["PHONON_VOICE": "$(touch injected)"])
        fatalError("Executable setting accepted")
    } catch SpeechSettingsStore.StoreError.invalidSetting { }
    let afterRejection = try String(contentsOf: settings, encoding: .utf8)
    precondition(afterRejection == switched, "Rejected value changed settings")
    print("Phonon voice settings preserve unrelated fields, permissions, and literal-value restrictions.")
}

testMusicPauseState()
try testSpeechSettings()
