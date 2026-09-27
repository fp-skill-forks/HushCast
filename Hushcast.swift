// Hushcast: makeshift test app.
// White noise -> one output (CarPlay), podcast -> another output (AirPods),
// using AVAudioSession category .multiRoute.
// Two routing methods are included because it is not documented which one iOS honours
// for CarPlay + Bluetooth:
//   A: AVAudioPlayer.channelAssignments (Apple's intended multiroute API)
//   B: one AVAudioEngine per stream, each with an output-unit channel map
// Everything is in one file so the repo has no folder structure to recreate.

import SwiftUI
import UIKit
import AVFoundation
import MediaPlayer
import CryptoKit

// MARK: - App

@main
struct HushcastApp: App {
    @StateObject private var route: RouteManager
    @StateObject private var audio: AudioController
    @StateObject private var feed = FeedStore()

    init() {
        let r = RouteManager()
        _route = StateObject(wrappedValue: r)
        _audio = StateObject(wrappedValue: AudioController(route: r))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(route)
                .environmentObject(audio)
                .environmentObject(feed)
        }
    }
}

// MARK: - Audio session and output ports

struct OutputPort: Identifiable, Hashable {
    let id: String              // port UID
    let name: String
    let type: String
    let channelCount: Int
    let firstHardwareChannel: Int   // index of this port's first channel in the aggregate multiroute device
}

final class RouteManager: ObservableObject {
    @Published private(set) var ports: [OutputPort] = []
    @Published var noisePortID: String?
    @Published var podcastPortID: String?
    @Published private(set) var log: [String] = []

    /// Called on the main thread whenever the set of output ports changes; argument = removed port UIDs.
    var onPortsChanged: ((Set<String>) -> Void)?

    private var tokens: [NSObjectProtocol] = []
    private let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    init() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            self?.append("Route change (reason \(reason))")
            self?.refresh()
        })
        tokens.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 99
            self?.append("Interruption (type \(type)); tap Apply routing to restart if needed")
        })
        tokens.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.append("Media services reset")
            self?.activate()
        })
    }

    func activate() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.multiRoute, mode: .default, options: [])
            try s.setActive(true)
            append("Session active, category = \(s.category.rawValue)")
        } catch {
            append("Session error: \(error.localizedDescription)")
        }
        refresh()
    }

    func refresh() {
        let s = AVAudioSession.sharedInstance()
        var list: [OutputPort] = []
        var idx = 0
        for p in s.currentRoute.outputs {
            let n = max(p.channels?.count ?? 2, 1)
            list.append(OutputPort(id: p.uid, name: p.portName, type: p.portType.rawValue,
                                   channelCount: n, firstHardwareChannel: idx))
            idx += n
        }
        let oldIDs = Set(ports.map(\.id))
        let newIDs = Set(list.map(\.id))
        ports = list

        // Default assignment: noise -> CarPlay, podcast -> earphones.
        if noisePortID == nil || !newIDs.contains(noisePortID!) {
            noisePortID = list.first(where: { $0.type == AVAudioSession.Port.carAudio.rawValue })?.id ?? list.first?.id
        }
        if podcastPortID == nil || !newIDs.contains(podcastPortID!) {
            let ear = Set([AVAudioSession.Port.bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .headphones].map { $0.rawValue })
            podcastPortID = list.first(where: { ear.contains($0.type) })?.id ?? list.last?.id
        }

        let desc = list.map { "\($0.name) [\($0.type), \($0.channelCount)ch, from #\($0.firstHardwareChannel)]" }
            .joined(separator: " + ")
        append("Route: \(desc.isEmpty ? "none" : desc); outputNumberOfChannels = \(s.outputNumberOfChannels)")
        if oldIDs != newIDs { onPortsChanged?(oldIDs.subtracting(newIDs)) }
    }

    func port(_ id: String?) -> OutputPort? { ports.first { $0.id == id } }

    /// Method B: output-unit channel map. One entry per hardware channel; value = client channel (0 = L, 1 = R) or -1.
    /// Returns nil when there is only one output (nothing to split).
    func channelMap(portID: String?, hardwareChannels h: Int) -> [NSNumber]? {
        guard ports.count > 1, h > 0, let p = port(portID) else { return nil }
        var map = [NSNumber](repeating: NSNumber(value: -1), count: h)
        let start = p.firstHardwareChannel
        if start < h { map[start] = NSNumber(value: 0) }
        if p.channelCount > 1, start + 1 < h { map[start + 1] = NSNumber(value: 1) }
        return map
    }

    /// Method A: channel assignments for AVAudioPlayer. Returns nil when there is only one output.
    func channelAssignments(portID: String?, fileChannels: Int) -> [AVAudioSessionChannelDescription]? {
        guard ports.count > 1, let id = portID,
              let p = AVAudioSession.sharedInstance().currentRoute.outputs.first(where: { $0.uid == id }),
              let ch = p.channels, !ch.isEmpty else { return nil }
        return (0..<max(fileChannels, 1)).map { ch[min($0, ch.count - 1)] }
    }

    func append(_ s: String) {
        log.append("\(clock.string(from: Date())) \(s)")
        if log.count > 80 { log.removeFirst(log.count - 80) }
    }
}

// MARK: - Noise generation (seamless 60 s stereo loop, cached)

enum NoiseColor: String, CaseIterable, Identifiable {
    case white, pink, brown
    var id: String { rawValue }
}

enum NoiseGenerator {
    static let sampleRate = 44_100.0
    static let loopSeconds = 60.0
    static let fadeSeconds = 1.0

    static func file(for color: NoiseColor) throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("noise_\(color.rawValue)_v1.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let tmp = dir.appendingPathComponent("noise_\(color.rawValue)_tmp.wav")
        try? FileManager.default.removeItem(at: tmp)
        try write(color, to: tmp)          // file object is closed when write() returns
        try FileManager.default.moveItem(at: tmp, to: url)
        return url
    }

    private static func write(_ color: NoiseColor, to url: URL) throws {
        let n = Int(sampleRate * loopSeconds)
        let f = Int(sampleRate * fadeSeconds)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)),
              let data = buf.floatChannelData else { throw CocoaError(.fileWriteUnknown) }
        buf.frameLength = AVAudioFrameCount(n)

        var peak: Float = 0
        for c in 0..<2 {                                  // independent L/R noise
            let x = generate(color, count: n + f)
            let out = data[c]
            for i in 0..<n { out[i] = x[i] }
            // Equal-power crossfade of samples n..n+f-1 into the head:
            // out[0] = x[n] and out[n-1] = x[n-1], so the loop point is continuous.
            for i in 0..<f {
                let t = Float(i) / Float(f)
                out[i] = x[i] * t.squareRoot() + x[n + i] * (1 - t).squareRoot()
            }
            for i in 0..<n { peak = max(peak, abs(out[i])) }
        }
        if peak > 0 {
            let g: Float = 0.8 / peak
            for c in 0..<2 { let out = data[c]; for i in 0..<n { out[i] *= g } }
        }
        try file.write(from: buf)
    }

    private static func generate(_ color: NoiseColor, count: Int) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        var y = [Float](repeating: 0, count: count)
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, br: Float = 0
        for i in 0..<count {
            let w = Float.random(in: -1...1, using: &rng)
            switch color {
            case .white:
                y[i] = w
            case .pink:   // Paul Kellet's economy pink filter (approx. -3 dB/oct)
                b0 = 0.99765 * b0 + w * 0.0990460
                b1 = 0.96300 * b1 + w * 0.2965164
                b2 = 0.57000 * b2 + w * 1.0526913
                y[i] = b0 + b1 + b2 + w * 0.1848
            case .brown:  // leaky integrator (approx. -6 dB/oct, no DC drift)
                br = (br + 0.02 * w) / 1.02
                y[i] = br
            }
        }
        return y
    }
}

// MARK: - Playback

enum RoutingMethod: String, CaseIterable, Identifiable {
    case player = "A · AVAudioPlayer"
    case engine = "B · AVAudioEngine"
    var id: String { rawValue }
}

final class AudioController: ObservableObject {
    @Published var method: RoutingMethod = .player
    @Published var color: NoiseColor = .brown
    @Published private(set) var noiseOn = false
    @Published private(set) var podcastOn = false
    @Published private(set) var episodeTitle = ""
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var noiseVolume: Float = 0.3 { didSet { applyVolumes() } }
    @Published var podcastVolume: Float = 1.0 { didSet { applyVolumes() } }

    let route: RouteManager
    private var activeMethod: RoutingMethod = .player
    private var noiseURL: URL?
    private var podcastURL: URL?
    private var noiseUsesPort: String?
    private var podcastUsesPort: String?

    // Method A
    private var noisePlayer: AVAudioPlayer?
    private var podPlayer: AVAudioPlayer?
    // Method B
    private var noiseEngine: AVAudioEngine?
    private var noiseNode: AVAudioPlayerNode?
    private var podEngine: AVAudioEngine?
    private var podNode: AVAudioPlayerNode?
    private var podFile: AVAudioFile?
    private var podStartFrame: AVAudioFramePosition = 0

    private var timer: Timer?

    init(route: RouteManager) {
        self.route = route
        route.onPortsChanged = { [weak self] removed in self?.portsChanged(removed: removed) }
        route.activate()
        setupRemoteCommands()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: Noise

    func toggleNoise() { noiseOn ? stopNoise() : startNoise() }

    func startNoise() {
        let c = color
        route.append("Preparing \(c.rawValue) noise…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try NoiseGenerator.file(for: c)
                DispatchQueue.main.async { self.noiseURL = url; self.buildNoise() }
            } catch {
                DispatchQueue.main.async { self.route.append("Noise generation failed: \(error.localizedDescription)") }
            }
        }
    }

    func stopNoise() { teardownNoise(); noiseOn = false }

    private func teardownNoise() {
        noisePlayer?.stop(); noisePlayer = nil
        noiseNode?.stop(); noiseEngine?.stop()
        noiseNode = nil; noiseEngine = nil
    }

    private func buildNoise() {
        teardownNoise()
        guard let url = noiseURL else { return }
        let port = route.noisePortID
        do {
            switch activeMethod {
            case .player:
                let p = try AVAudioPlayer(contentsOf: url)
                p.numberOfLoops = -1
                p.volume = noiseVolume
                p.channelAssignments = route.channelAssignments(portID: port, fileChannels: p.numberOfChannels)
                p.prepareToPlay()
                p.play()
                noisePlayer = p
                route.append("Noise (A) -> \(portName(port)); assignments \(describe(p.channelAssignments))")
            case .engine:
                let file = try AVAudioFile(forReading: url)
                let (e, n, desc) = try makeEngine(file: file, portID: port, loop: true, startFrame: 0,
                                                  volume: noiseVolume, autoplay: true)
                noiseEngine = e; noiseNode = n
                route.append("Noise (B) -> \(portName(port)); \(desc)")
            }
            noiseUsesPort = port
            noiseOn = true
        } catch {
            noiseOn = false
            route.append("Noise start failed: \(error.localizedDescription)")
        }
    }

    // MARK: Podcast

    func load(url: URL, title: String) {
        teardownPodcast()
        podcastURL = url
        episodeTitle = title
        position = 0
        buildPodcast(from: 0, play: true)
    }

    func togglePodcast() { podcastOn ? pausePodcast() : resumePodcast() }

    func pausePodcast() {
        position = currentTime
        podPlayer?.pause()
        podNode?.pause()
        podcastOn = false
        updateNowPlaying()
    }

    func resumePodcast() {
        guard podcastURL != nil else { return }
        let t = currentTime
        // Rebuild if nothing is loaded or the target output changed since the last build.
        if (podPlayer == nil && podNode == nil) || podcastUsesPort != route.podcastPortID {
            buildPodcast(from: t, play: true)
            return
        }
        if targetIsCar(podcastUsesPort) { blockCar(); return }
        podPlayer?.play()
        if let e = podEngine, !e.isRunning { try? e.start() }
        podNode?.play()
        position = t
        podcastOn = true
        updateNowPlaying()
    }

    func skip(_ d: TimeInterval) { seek(to: currentTime + d) }

    func seek(to target: TimeInterval) {
        guard podcastURL != nil else { return }
        let t = min(max(0, target), max(duration - 1, 0))
        switch activeMethod {
        case .player:
            podPlayer?.currentTime = t
        case .engine:
            guard let n = podNode, let f = podFile else { break }
            n.stop()
            let start = AVAudioFramePosition(t * f.processingFormat.sampleRate)
            let frames = AVAudioFrameCount(max(0, f.length - start))
            if frames > 0 { n.scheduleSegment(f, startingFrame: start, frameCount: frames, at: nil) }
            podStartFrame = start
            if podcastOn { n.play() }
        }
        position = t
        updateNowPlaying()
    }

    private func teardownPodcast() {
        podPlayer?.stop(); podPlayer = nil
        podNode?.stop(); podEngine?.stop()
        podNode = nil; podEngine = nil; podFile = nil
    }

    private func buildPodcast(from t: TimeInterval, play: Bool) {
        teardownPodcast()
        guard let url = podcastURL else { return }
        let port = route.podcastPortID
        if play && targetIsCar(port) { position = t; blockCar(); return }
        do {
            switch activeMethod {
            case .player:
                let p = try AVAudioPlayer(contentsOf: url)
                p.volume = podcastVolume
                p.channelAssignments = route.channelAssignments(portID: port, fileChannels: p.numberOfChannels)
                p.currentTime = t
                p.prepareToPlay()
                if play { p.play() }
                podPlayer = p
                duration = p.duration
                route.append("Podcast (A, \(p.numberOfChannels)ch) -> \(portName(port)); assignments \(describe(p.channelAssignments))")
            case .engine:
                let file = try AVAudioFile(forReading: url)
                let sr = file.processingFormat.sampleRate
                let start = AVAudioFramePosition(t * sr)
                let (e, n, desc) = try makeEngine(file: file, portID: port, loop: false, startFrame: start,
                                                  volume: podcastVolume, autoplay: play)
                podEngine = e; podNode = n; podFile = file; podStartFrame = start
                duration = Double(file.length) / sr
                route.append("Podcast (B, \(file.processingFormat.channelCount)ch) -> \(portName(port)); \(desc)")
            }
            podcastUsesPort = port
            position = t
            podcastOn = play
            updateNowPlaying()
        } catch {
            podcastOn = false
            route.append("Podcast start failed: \(error.localizedDescription)")
        }
    }

    private var currentTime: TimeInterval {
        switch activeMethod {
        case .player:
            return podPlayer?.currentTime ?? position
        case .engine:
            guard let n = podNode, let f = podFile, n.isPlaying,
                  let lt = n.lastRenderTime, let pt = n.playerTime(forNodeTime: lt) else { return position }
            return Double(podStartFrame + pt.sampleTime) / f.processingFormat.sampleRate
        }
    }

    // Safety: never play the podcast on CarPlay (it would go to the baby).
    private func targetIsCar(_ id: String?) -> Bool {
        route.port(id)?.type == AVAudioSession.Port.carAudio.rawValue
    }

    private func blockCar() {
        podcastOn = false
        route.append("Podcast blocked: target output is CarPlay (earphones not in route)")
        updateNowPlaying()
    }

    // MARK: Routing changes

    func applyRouting() {
        let t = currentTime                  // read with the old method before switching
        let wasPlaying = podcastOn
        let hadPodcast = podcastURL != nil
        let hadNoise = noiseOn
        activeMethod = method
        route.append("Apply routing: \(method.rawValue)")
        if hadNoise { buildNoise() }
        if hadPodcast { buildPodcast(from: t, play: wasPlaying) }
    }

    private func portsChanged(removed: Set<String>) {
        // Safety: if a stream's output disappears, stop it rather than let iOS move it to the other listener.
        if podcastOn, let p = podcastUsesPort, removed.contains(p) {
            pausePodcast(); route.append("Podcast paused: its output disappeared")
        }
        if noiseOn, let p = noiseUsesPort, removed.contains(p) {
            stopNoise(); route.append("Noise stopped: its output disappeared")
        }
        // Channel indices may have shifted: rebuild whatever is still running.
        let t = currentTime
        if noiseOn { buildNoise() }
        if podcastOn { buildPodcast(from: t, play: true) }
    }

    // MARK: Engine helper (method B)

    private func makeEngine(file: AVAudioFile, portID: String?, loop: Bool, startFrame: AVAudioFramePosition,
                            volume: Float, autoplay: Bool) throws -> (AVAudioEngine, AVAudioPlayerNode, String) {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        let hw = engine.outputNode.outputFormat(forBus: 0)
        let rate = hw.sampleRate > 0 ? hw.sampleRate : 44_100
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw CocoaError(.featureUnsupported)
        }
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: stereo)
        let h = Int(hw.channelCount)
        let map = route.channelMap(portID: portID, hardwareChannels: h)
        if let map { engine.outputNode.auAudioUnit.channelMap = map }
        engine.mainMixerNode.outputVolume = volume

        if loop {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(file.length)) else {
                throw CocoaError(.fileReadUnknown)
            }
            try file.read(into: buf)
            node.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        } else {
            let frames = AVAudioFrameCount(max(0, file.length - startFrame))
            if frames > 0 { node.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil) }
        }
        engine.prepare()
        try engine.start()
        if autoplay { node.play() }
        let mapText = map.map { m in m.map { $0.stringValue }.joined(separator: ",") } ?? "none"
        return (engine, node, "hw \(h)ch, map [\(mapText)]")
    }

    // MARK: Misc

    private func applyVolumes() {
        noisePlayer?.volume = noiseVolume
        noiseEngine?.mainMixerNode.outputVolume = noiseVolume
        podPlayer?.volume = podcastVolume
        podEngine?.mainMixerNode.outputVolume = podcastVolume
    }

    private func tick() {
        guard podcastURL != nil else { return }
        if activeMethod == .player, podcastOn, let p = podPlayer, !p.isPlaying {   // reached the end
            podcastOn = false; updateNowPlaying()
        }
        let t = currentTime
        if abs(t - position) > 0.25 { position = t }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.resumePodcast(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pausePodcast(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePodcast(); return .success }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget { [weak self] _ in self?.skip(30); return .success }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(-15); return .success }
    }

    private func updateNowPlaying() {
        guard podcastURL != nil else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: episodeTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: podcastOn ? 1.0 : 0.0,
        ]
    }

    private func portName(_ id: String?) -> String { route.port(id)?.name ?? "default route" }

    private func describe(_ a: [AVAudioSessionChannelDescription]?) -> String {
        guard let a else { return "none (default route)" }
        return a.map { "\($0.channelName)@\($0.owningPortUID.suffix(6))" }.joined(separator: ", ")
    }
}

// MARK: - Podcast feeds (iTunes search / Apple Podcasts link / raw RSS)

struct Show: Identifiable, Hashable { let id: String; let name: String; let feedURL: URL }
struct Episode: Identifiable, Hashable { let id: String; let title: String; let date: String; let url: URL }

enum FeedError: LocalizedError {
    case badInput, noFeed, http(Int)
    var errorDescription: String? {
        switch self {
        case .badInput: return "Not a valid link"
        case .noFeed: return "No RSS feed found for that show"
        case .http(let c): return "Server returned HTTP \(c)"
        }
    }
}

private struct ITunesResponse: Decodable {
    struct Item: Decodable { let feedUrl: String?; let collectionName: String? }
    let results: [Item]
}

@MainActor
final class FeedStore: ObservableObject {
    @Published var shows: [Show] = []
    @Published var showTitle = ""
    @Published var episodes: [Episode] = []
    @Published var status = ""
    @Published var busy = false

    func go(_ input: String) {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        busy = true; status = "Loading…"
        Task {
            do {
                if s.lowercased().hasPrefix("http") {
                    try await loadFeed(try await Self.resolveFeed(s))
                } else {
                    shows = try await Self.search(s)
                    status = shows.isEmpty ? "No shows found" : "Pick a show:"
                }
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    func select(_ show: Show) {
        busy = true; status = "Loading…"
        Task {
            do { try await loadFeed(show.feedURL) } catch { status = "Error: \(error.localizedDescription)" }
            busy = false
        }
    }

    private func loadFeed(_ url: URL) async throws {
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw FeedError.http(h.statusCode) }
        let parser = RSSParser()
        let eps = parser.parse(data)
        showTitle = parser.channelTitle
        episodes = Array(eps.prefix(50))
        shows = []
        status = eps.isEmpty ? "No playable episodes in this feed" : ""
        UserDefaults.standard.set(url.absoluteString, forKey: "lastFeed")
    }

    static func resolveFeed(_ s: String) async throws -> URL {
        if s.contains("podcasts.apple.com") {
            guard let r = s.range(of: #"id\d+"#, options: .regularExpression) else { throw FeedError.badInput }
            let id = s[r].dropFirst(2)
            guard let u = URL(string: "https://itunes.apple.com/lookup?id=\(id)&entity=podcast") else { throw FeedError.badInput }
            let (d, _) = try await URLSession.shared.data(from: u)
            let res = try JSONDecoder().decode(ITunesResponse.self, from: d)
            guard let f = res.results.compactMap({ $0.feedUrl }).first, let url = URL(string: f) else { throw FeedError.noFeed }
            return url
        }
        guard let u = URL(string: s) else { throw FeedError.badInput }
        return u
    }

    static func search(_ term: String) async throws -> [Show] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [URLQueryItem(name: "media", value: "podcast"),
                        URLQueryItem(name: "term", value: term),
                        URLQueryItem(name: "limit", value: "15")]
        guard let url = c.url else { throw FeedError.badInput }
        let (d, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(ITunesResponse.self, from: d).results.compactMap { r in
            guard let f = r.feedUrl, let u = URL(string: f) else { return nil }
            return Show(id: f, name: r.collectionName ?? f, feedURL: u)
        }
    }

    private static var episodeDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("episodes", isDirectory: true)
    }

    private static func localURL(for ep: Episode) -> URL {
        let hash = SHA256.hash(data: Data(ep.url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(20)
        let e = ep.url.pathExtension.lowercased()
        let ext = ["mp3", "m4a", "aac", "mp4", "wav"].contains(e) ? e : "mp3"
        return episodeDir.appendingPathComponent("\(hash).\(ext)")
    }

    /// Downloads the episode (AVAudioPlayer/AVAudioFile need a local file). Cached on disk.
    func download(_ ep: Episode) async throws -> URL {
        let dest = Self.localURL(for: ep)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        try FileManager.default.createDirectory(at: Self.episodeDir, withIntermediateDirectories: true)
        status = "Downloading “\(ep.title)”…"
        busy = true
        defer { busy = false }
        let (tmp, resp) = try await URLSession.shared.download(from: ep.url)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw FeedError.http(h.statusCode) }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        status = ""
        return dest
    }

    func deleteDownloads() {
        try? FileManager.default.removeItem(at: Self.episodeDir)
        status = "Downloads deleted"
    }
}

final class RSSParser: NSObject, XMLParserDelegate {
    private(set) var episodes: [Episode] = []
    private(set) var channelTitle = ""
    private var inItem = false
    private var element = ""
    private var title = ""
    private var date = ""
    private var enclosure: URL?
    private var gotChannelTitle = false

    func parse(_ data: Data) -> [Episode] {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        return episodes
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        element = elementName
        if elementName == "item" { inItem = true; title = ""; date = ""; enclosure = nil }
        if inItem, elementName == "enclosure", let u = attributeDict["url"], let url = URL(string: u) { enclosure = url }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { add(string) }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { add(s) }
    }

    private func add(_ s: String) {
        if inItem {
            if element == "title" { title += s }
            if element == "pubDate" { date += s }
        } else if element == "title" && !gotChannelTitle {
            channelTitle += s
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "title" && !inItem && !channelTitle.isEmpty { gotChannelTitle = true }
        if elementName == "item" {
            inItem = false
            if let e = enclosure {
                episodes.append(Episode(id: e.absoluteString,
                                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                        date: String(date.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16)),
                                        url: e))
            }
        }
        element = ""
    }
}

// MARK: - UI

struct ContentView: View {
    @EnvironmentObject var route: RouteManager
    @EnvironmentObject var audio: AudioController
    @EnvironmentObject var feed: FeedStore
    @State private var query = UserDefaults.standard.string(forKey: "lastFeed") ?? ""
    @State private var scrub: Double = 0
    @State private var scrubbing = false

    var body: some View {
        NavigationStack {
            Form {
                outputsSection
                routingSection
                noiseSection
                podcastSection
                diagnosticsSection
            }
            .navigationTitle("Hushcast")
        }
        .onChange(of: audio.color) { _ in if audio.noiseOn { audio.startNoise() } }
    }

    private var outputsSection: some View {
        Section {
            if route.ports.count > 1 {
                Label("\(route.ports.count) outputs active: split possible", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("One output only: \(route.ports.first?.name ?? "none")", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(route.ports) { p in
                VStack(alignment: .leading) {
                    Text(p.name)
                    Text("\(p.type) · \(p.channelCount) ch · hw ch \(p.firstHardwareChannel)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Re-scan outputs") { route.refresh() }
        } header: { Text("Outputs") }
    }

    private var routingSection: some View {
        Section {
            Picker("Method", selection: $audio.method) {
                ForEach(RoutingMethod.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Noise →", selection: $route.noisePortID) {
                ForEach(route.ports) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Podcast →", selection: $route.podcastPortID) {
                ForEach(route.ports) { Text($0.name).tag(Optional($0.id)) }
            }
            Button("Apply routing") { audio.applyRouting() }
        } header: { Text("Routing") } footer: {
            Text("Changing method or outputs takes effect on Apply. The podcast is never allowed onto CarPlay.")
        }
    }

    private var noiseSection: some View {
        Section {
            Picker("Colour", selection: $audio.color) {
                ForEach(NoiseColor.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: $audio.noiseVolume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
            }
            Button(audio.noiseOn ? "Stop noise" : "Start noise") { audio.toggleNoise() }
        } header: { Text("Noise (baby)") }
    }

    private var podcastSection: some View {
        Section {
            HStack {
                TextField("Search, or paste RSS / Apple Podcasts link", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { feed.go(query) }
                Button("Go") { feed.go(query) }.disabled(feed.busy)
            }
            if !feed.status.isEmpty { Text(feed.status).font(.caption).foregroundStyle(.secondary) }
            ForEach(feed.shows) { s in Button(s.name) { feed.select(s) } }
            if !audio.episodeTitle.isEmpty { controls }
            if !feed.episodes.isEmpty {
                Text(feed.showTitle).font(.headline)
                ForEach(feed.episodes) { ep in
                    Button { play(ep) } label: {
                        VStack(alignment: .leading) {
                            Text(ep.title).lineLimit(2)
                            Text(ep.date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(feed.busy)
                }
            }
        } header: { Text("Podcast (you)") }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Text(audio.episodeTitle).font(.subheadline).lineLimit(2)
            Slider(value: Binding(get: { scrubbing ? scrub : audio.position }, set: { scrub = $0 }),
                   in: 0...max(audio.duration, 1),
                   onEditingChanged: { editing in
                       if editing { scrub = audio.position; scrubbing = true }
                       else { audio.seek(to: scrub); scrubbing = false }
                   })
            HStack {
                Text(fmt(scrubbing ? scrub : audio.position))
                Spacer()
                Text(fmt(audio.duration))
            }
            .font(.caption.monospacedDigit())
            HStack(spacing: 40) {
                Button { audio.skip(-15) } label: { Image(systemName: "gobackward.15").font(.title2) }
                Button { audio.togglePodcast() } label: {
                    Image(systemName: audio.podcastOn ? "pause.circle.fill" : "play.circle.fill").font(.largeTitle)
                }
                Button { audio.skip(30) } label: { Image(systemName: "goforward.30").font(.title2) }
            }
            .buttonStyle(.borderless)
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: $audio.podcastVolume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
            }
        }
    }

    private var diagnosticsSection: some View {
        Section {
            Button("Copy log") { UIPasteboard.general.string = route.log.joined(separator: "\n") }
            Button("Delete downloaded episodes", role: .destructive) { feed.deleteDownloads() }
            ForEach(route.log.indices.reversed(), id: \.self) { i in
                Text(route.log[i]).font(.system(.caption2, design: .monospaced))
            }
        } header: { Text("Diagnostics") }
    }

    private func play(_ ep: Episode) {
        Task {
            do {
                let url = try await feed.download(ep)
                audio.load(url: url, title: ep.title)
            } catch {
                feed.status = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    private func fmt(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
