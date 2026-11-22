// Ground truth for AirPlay tests with the Mac's own AirPlay 2 receiver
// (System Settings ▸ AirDrop & Handoff ▸ AirPlay Receiver, Current User):
// records what the receiver plays through a Core Audio process tap (macOS 14.2+)
// and writes the same log as pcm_monitor.py, one line per 100 ms of audio:
//   HH:MM:SS.mmm t=12.3s rms=-23.4dB
// The tap mutes what it records, so the Mac stays quiet. The first run asks
// for System Audio Recording permission for the terminal app.
//
//   swiftc -O tool/airplay/tap_monitor.swift -o /tmp/vpc_airplay/tap_monitor
//   tap_monitor list [seconds]            # processes playing audio, once a second
//   tap_monitor mic LOG                   # the Mac's microphone: what the Mac's
//                                         # own receiver plays (no tap reaches it)
//   tap_monitor global LOG                # the whole output mix, muted: what
//                                         # the Mac's AirPlay receiver needs
//   tap_monitor record LOG [match...]     # tap the first process whose bundle id
//                                         # or pid contains a match (default:
//                                         # AirPlay, then ControlCenter); waits
//                                         # for it to appear, re-attaches if it goes
//   pcm_monitor.py --summarize LOG        # gaps and silences, as before
//
// A receiver with nothing to play shows as "GAP" lines (no process playing),
// so a stalled or dead stream shows as a GAP or a silence in the log.
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func stamp() -> String {
  let f = DateFormatter()
  f.dateFormat = "HH:mm:ss.SSS"
  return f.string(from: Date())
}

func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T? {
  var addr = AudioObjectPropertyAddress(
    mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  var value = initial
  var size = UInt32(MemoryLayout<T>.size)
  let err = withUnsafeMutablePointer(to: &value) {
    AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
  }
  return err == noErr ? value : nil
}

func stringProp(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
  var addr = AudioObjectPropertyAddress(
    mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  var s: Unmanaged<CFString>?
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &s) == noErr,
    let v = s?.takeRetainedValue()
  else { return "" }
  return v as String
}

struct Proc {
  let id: AudioObjectID
  let pid: pid_t
  let bundle: String
  let output: Bool
}

func processes() -> [Proc] {
  var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var size: UInt32 = 0
  let sys = AudioObjectID(kAudioObjectSystemObject)
  guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
  var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
  guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
  return ids.map { id in
    Proc(
      id: id,
      pid: prop(id, kAudioProcessPropertyPID, pid_t(0)) ?? 0,
      bundle: stringProp(id, kAudioProcessPropertyBundleID),
      output: (prop(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0)
  }
}

func procName(_ pid: pid_t) -> String {
  var buf = [CChar](repeating: 0, count: 4096)
  return proc_pidpath(pid, &buf, 4096) > 0 ? String(cString: buf) : "?"
}

func defaultOutputUID() -> String {
  let dev = prop(AudioObjectID(kAudioObjectSystemObject),
    kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(0)) ?? 0
  return stringProp(dev, kAudioDevicePropertyDeviceUID)
}

// MARK: list

func list(seconds: Int) {
  for _ in 0..<seconds {
    let playing = processes().filter { $0.output }
    print("\(stamp()) playing: " + (playing.isEmpty ? "-" :
      playing.map { "\($0.pid) \($0.bundle.isEmpty ? procName($0.pid) : $0.bundle)" }
        .joined(separator: " | ")))
    sleep(1)
  }
}

// MARK: record

final class Recorder {
  let out: FileHandle
  var tapID = AudioObjectID(0)
  var aggID = AudioObjectID(0)
  var procID: AudioDeviceIOProcID?
  var frames = 0, chunkFrames = 0, sumSq = 0.0, n = 0, total = 0
  var rate = 48000.0
  let lock = NSLock()

  init(path: String) {
    if !FileManager.default.fileExists(atPath: path) {
      FileManager.default.createFile(atPath: path, contents: nil)
    }
    out = FileHandle(forWritingAtPath: path)!
    out.seekToEndOfFile()
  }

  func write(_ s: String) {
    out.write("\(stamp()) \(s)\n".data(using: .utf8)!)
  }

  func attach(_ p: Proc?) -> Bool {
    let desc = p.map { CATapDescription(stereoMixdownOfProcesses: [$0.id]) }
      ?? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    desc.uuid = UUID()
    desc.muteBehavior = .mutedWhenTapped
    desc.isPrivate = true
    desc.name = "vpc-airplay-tap"
    var err = AudioHardwareCreateProcessTap(desc, &tapID)
    guard err == noErr else { write("ERROR creating tap: \(err) (permission?)"); return false }
    if let asbd = prop(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription()) {
      rate = asbd.mSampleRate
    }
    let agg: [String: Any] = [
      kAudioAggregateDeviceNameKey: "vpc-airplay-agg",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: defaultOutputUID(),
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: defaultOutputUID()]],
      kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]
      ],
    ]
    err = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
    guard err == noErr else { write("ERROR creating aggregate: \(err)"); detach(); return false }
    chunkFrames = Int(rate / 10)
    err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { [weak self] _, input, _, _, _ in
      self?.consume(input)
    }
    guard err == noErr else { write("ERROR creating IO proc: \(err)"); detach(); return false }
    err = AudioDeviceStart(aggID, procID)
    guard err == noErr else { write("ERROR starting: \(err)"); detach(); return false }
    write("tapping " + (p.map { "pid \($0.pid) \($0.bundle.isEmpty ? procName($0.pid) : $0.bundle)" }
      ?? "the whole output mix (global)") + " at \(Int(rate)) Hz")
    return true
  }

  func consume(_ list: UnsafePointer<AudioBufferList>) {
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
    lock.lock(); defer { lock.unlock() }
    for buf in abl {
      guard let data = buf.mData else { continue }
      let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
      let ch = max(1, Int(buf.mNumberChannels))
      let f = data.assumingMemoryBound(to: Float.self)
      for i in 0..<count {
        let x = Double(f[i])
        sumSq += x * x
        n += 1
        if (i + 1) % ch == 0 {
          frames += 1
          if frames >= chunkFrames {
            total += frames
            let rms = (sumSq / Double(max(n, 1))).squareRoot()
            let db = rms > 0 ? 20 * log10(rms) : -120
            write(String(format: "t=%.1fs rms=%.1fdB", Double(total) / rate, db))
            frames = 0; sumSq = 0; n = 0
          }
        }
      }
    }
  }

  func detach() {
    if aggID != 0 {
      if let procID { AudioDeviceStop(aggID, procID); AudioDeviceDestroyIOProcID(aggID, procID) }
      AudioHardwareDestroyAggregateDevice(aggID)
    }
    if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
    aggID = 0; tapID = 0; procID = nil
  }
}

/// Everything the Mac plays, muted. The Mac's AirPlay receiver renders in
/// AirPlayXPCHelper, a root process that isn't in this user's process list,
/// so a per-process tap can't reach it (measured 2026-11-22, macOS 26.7).
/// Anything else playing on the Mac lands in the log too: keep it quiet.
func recordGlobal(path: String) {
  let r = Recorder(path: path)
  r.write("tap monitor start (global)")
  signal(SIGINT) { _ in exit(0) }
  signal(SIGTERM) { _ in exit(0) }
  guard r.attach(nil) else { exit(1) }
  while true { sleep(60) }
}

func record(path: String, matches: [String]) {
  let r = Recorder(path: path)
  r.write("tap monitor start (matching \(matches.joined(separator: ", ")))")
  signal(SIGINT) { _ in exit(0) }
  signal(SIGTERM) { _ in exit(0) }
  var current: Proc?
  var inGap = false
  while true {
    let procs = processes()
    func pick() -> Proc? {
      for m in matches {
        if let p = procs.first(where: {
          $0.bundle.localizedCaseInsensitiveContains(m)
            || procName($0.pid).localizedCaseInsensitiveContains(m) || "\($0.pid)" == m
        }) { return p }
      }
      return nil
    }
    let target = pick()
    if let c = current, target?.id != c.id || !(procs.contains { $0.id == c.id }) {
      r.write("target pid \(c.pid) went away")
      r.detach()
      current = nil
    }
    if current == nil, let t = target {
      if r.attach(t) { current = t; inGap = false } else { sleep(5) }
    }
    // Playing = the target process is running output. Not playing = GAP.
    let playing = current.map { c in procs.first { $0.id == c.id }?.output ?? false } ?? false
    if !playing && !inGap { r.write("GAP"); inGap = true }
    if playing && inGap { r.write("RESUME"); inGap = false }
    usleep(250_000)
  }
}

/// The Mac's microphone, listening to the Mac's speakers: the ground truth
/// for the Mac's own AirPlay receiver, which no tap can reach. Room noise
/// sits around -50 dBFS, so summarize with `--silent-db -45` or so.
/// The first run asks for Microphone permission for the terminal app.
func recordMic(path: String) {
  let r = Recorder(path: path)
  r.write("mic monitor start")
  signal(SIGINT) { _ in exit(0) }
  signal(SIGTERM) { _ in exit(0) }
  let engine = AVAudioEngine()
  let input = engine.inputNode
  let format = input.outputFormat(forBus: 0)
  r.rate = format.sampleRate
  r.chunkFrames = Int(format.sampleRate / 10)
  input.installTap(onBus: 0, bufferSize: 4096, format: format) { buf, _ in
    guard let ch = buf.floatChannelData else { return }
    r.lock.lock(); defer { r.lock.unlock() }
    for i in 0..<Int(buf.frameLength) {
      let x = Double(ch[0][i])
      r.sumSq += x * x; r.n += 1; r.frames += 1
      if r.frames >= r.chunkFrames {
        r.total += r.frames
        let rms = (r.sumSq / Double(max(r.n, 1))).squareRoot()
        r.write(String(format: "t=%.1fs rms=%.1fdB", Double(r.total) / r.rate,
          rms > 0 ? 20 * log10(rms) : -120))
        r.frames = 0; r.sumSq = 0; r.n = 0
      }
    }
  }
  do { try engine.start() } catch { r.write("ERROR starting mic: \(error)"); exit(1) }
  r.write("listening at \(Int(format.sampleRate)) Hz")
  while true { sleep(60) }
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "list":
  list(seconds: args.count > 2 ? Int(args[2]) ?? 30 : 30)
case "mic" where args.count > 2:
  recordMic(path: args[2])
case "global" where args.count > 2:
  recordGlobal(path: args[2])
case "record" where args.count > 2:
  let matches = args.count > 3 ? Array(args[3...]) : ["AirPlay", "ControlCenter"]
  record(path: args[2], matches: matches)
default:
  print("usage: tap_monitor list [seconds] | mic LOG | global LOG | record LOG [match...]")
  exit(2)
}
