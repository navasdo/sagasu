// ═══════════════════════════════════════════════════════════════════
//  SAGASU — iOS 2026 Modernization  (error-corrected build)
//  Minimum Deployment: iOS 17.0
//  Recommended:        iOS 18.0  (MeshGradient)
//
//  CHANGES FROM ORIGINAL v1:
//  • import Combine added (Timer.publish)
//  • BGMManager: NSObject only (ObservableObject removed – unused)
//  • ALL multi-variable @State / @AppStorage declarations split
//  • BootAnimationPhase moved to file scope; extension non-private
//  • foregroundStyle() calls use Color.synthXxx explicitly
//  • Complex GameBoardView cell expression broken into helper
//  • columnPanel func simplified to avoid type-checker timeout
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import AVFoundation
import Observation
import Combine

// MARK: - Color System ───────────────────────────────────────────────

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let int = UInt64(hex, radix: 16) ?? 0
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:  (a, r, g, b) = (255, (int >> 8)*17, ((int >> 4) & 0xF)*17, (int & 0xF)*17)
        case 6:  (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:  (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red:     Double(r) / 255,
                  green:   Double(g) / 255,
                  blue:    Double(b) / 255,
                  opacity: Double(a) / 255)
    }

    static let synthBackground = Color(hex: "070118")
    static let synthSurface    = Color(hex: "0D022A")
    static let synthCard       = Color(hex: "160A2C")
    static let synthCyan       = Color(hex: "00F5FF")
    static let synthPink       = Color(hex: "FF0BA5")
    static let synthPurple     = Color(hex: "9B00FF")
    static let synthOrange     = Color(hex: "FF6C11")
    static let synthYellow     = Color(hex: "FFD000")
    static let synthGreen      = Color(hex: "00FF9F")
}

// MARK: - Typography ──────────────────────────────────────────────────

extension Font {
    static func synthDisplay(_ size: CGFloat, weight: Weight = .black) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func synthMono(_ size: CGFloat, weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Enums ───────────────────────────────────────────────────────

enum KanaMode { case hiragana, kanji, furigana }

enum BoonTier: String {
    case common = "Common", uncommon = "Uncommon", rare = "Rare", epic = "Epic"
    var color: Color {
        switch self {
        case .common:   return .synthOrange
        case .uncommon: return .synthCyan
        case .rare:     return .synthPurple
        case .epic:     return .synthPink
        }
    }
}

enum GameState {
    case selection, uplink, review, gridTransition, grid
    case bossTransition, boss, roundComplete, gameOver
}

enum AppScreen { case boot, home, grid, settings }

// ────────────────────────────────────────────────────────────────────
// Boot animation phase — file-scope so the Comparable extension works
// ────────────────────────────────────────────────────────────────────
enum BootAnimationPhase: CaseIterable { case hidden, icon, title, tagline, done }

extension BootAnimationPhase: Comparable {
    var sortIndex: Int { BootAnimationPhase.allCases.firstIndex(of: self) ?? 0 }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.sortIndex < rhs.sortIndex }
}

// MARK: - @Observable State ──────────────────────────────────────────

@Observable
final class AppRouter {
    var currentScreen: AppScreen = .boot
}

@Observable
final class GauntletManager {
    var gameState: GameState = .selection
    var currentRound: Int = 1
    var maxRounds: Int = 4
    var originalPacket: [VocabWord] = []
    var availableVocab: [VocabWord] = []
    var activePool: [VocabWord] = []
    var cumulativePool: [VocabWord] = []
    var currentGridPhase: Int = 1
    var chunkedGrids: [[VocabWord]] = []
    var currentGridWords: [VocabWord] = []
    var gridFoundWords: Set<UUID> = []
    var bossQuizQueue: [VocabWord] = []
    var currentQuizQuestion: VocabWord? = nil
    var score: Int = 0
    var multiplier: Double = 1.0
    var navigationResetID = UUID()
    var revealHintsRemaining: Int = 3
    var scoreDrainTrigger = UUID()
    var hasSeenRevealWarningThisRun = false
    var hasSeenSpellCheckWarningThisRun = false

    func startCustomGauntlet(words: [VocabWord]) {
        originalPacket = words
        currentRound = 1; cumulativePool = []; score = 0; multiplier = 1.0
        revealHintsRemaining = 3
        hasSeenRevealWarningThisRun = false
        hasSeenSpellCheckWarningThisRun = false
        navigationResetID = UUID()
        availableVocab = words.shuffled()
        maxRounds = max(1, words.count / 5)
        withAnimation(.spring(duration: 0.5, bounce: 0.2)) { gameState = .uplink }
    }

    func retryRun() { startCustomGauntlet(words: originalPacket) }

    func finishUplink() { setupRound() }

    func setupRound() {
        activePool = []
        for _ in 0..<5 {
            if !availableVocab.isEmpty { activePool.append(availableVocab.removeFirst()) }
        }
        if activePool.isEmpty { gameState = .gameOver; return }
        cumulativePool.append(contentsOf: activePool)
        gameState = .review
    }

    func finishReviewPhase() {
        let shuffled = cumulativePool.shuffled()
        chunkedGrids = stride(from: 0, to: shuffled.count, by: 5).map {
            Array(shuffled[$0..<min($0 + 5, shuffled.count)])
        }
        currentGridPhase = 1
        withAnimation(.easeInOut(duration: 0.3)) { gameState = .gridTransition }
    }

    func startGridPhase() {
        currentGridWords = chunkedGrids[currentGridPhase - 1]
        gridFoundWords.removeAll()
        gameState = .grid
    }

    func processGridWordFound(_ word: VocabWord) {
        gridFoundWords.insert(word.id)
        score += Int(100 * multiplier); multiplier += 0.2
        if gridFoundWords.count == currentGridWords.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.spring(duration: 0.5, bounce: 0.15)) {
                    if self.currentGridPhase < self.chunkedGrids.count {
                        self.currentGridPhase += 1; self.gameState = .gridTransition
                    } else {
                        self.gameState = .bossTransition
                    }
                }
            }
        }
    }

    func startBossFight() {
        bossQuizQueue = cumulativePool.shuffled()
        nextQuizQuestion()
        gameState = .boss
    }

    func nextQuizQuestion() {
        if !bossQuizQueue.isEmpty {
            currentQuizQuestion = bossQuizQueue.removeFirst()
        } else if currentRound < maxRounds && !availableVocab.isEmpty {
            currentRound += 1; setupRound()
        } else {
            gameState = .gameOver
        }
    }

    func processQuizAnswer(correct: Bool) {
        if correct { score += 250; nextQuizQuestion() }
        else { score -= 30; scoreDrainTrigger = UUID(); nextQuizQuestion() }
    }
}

// MARK: - UserDefaults Defaults ──────────────────────────────────────

func registerInitialDefaults() {
    UserDefaults.standard.register(defaults: [
        "sfxEnabled": true,       "sfxVolume": 0.8,
        "vocabAudioEnabled": true, "vocabAudioVolume": 1.0,
        "bgmEnabled": true,        "bgmVolume": 0.3,
        "bgmMotherboard": "motherboard",
        "bgmPhase1": "Mydoom",     "bgmPhase2": "DDoS",
        "bgmPhase3": "Man in the Middle", "bgmPhase4": "Backdoor",
        "bgmBoss1": "ILOVEYOU",   "bgmBoss2": "Logic Bomb",
        "bgmBoss3": "Boot Sector Virus",  "bgmBoss4": "Firewall"
    ])
}

// MARK: - BGMManager ─────────────────────────────────────────────────
// NSObject only — ObservableObject removed (not used with @StateObject anywhere)

class BGMManager: NSObject {
    static let shared = BGMManager()
    private var currentPlayer: AVAudioPlayer?
    private var nextPlayer:    AVAudioPlayer?
    private var currentTrackName: String = ""
    let availableTracks: [String]

    override init() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "mp3", subdirectory: nil) ?? []
        var found = Set(urls.map { $0.deletingPathExtension().lastPathComponent })
        ["motherboard","Mydoom","DDoS","Man in the Middle","Backdoor",
         "ILOVEYOU","Logic Bomb","Boot Sector Virus","Firewall"].forEach { found.insert($0) }
        availableTracks = found.sorted()
        super.init()
        registerInitialDefaults()
    }

    func updateVolume() {
        guard UserDefaults.standard.bool(forKey: "bgmEnabled") else {
            currentPlayer?.setVolume(0, fadeDuration: 1.0); return
        }
        currentPlayer?.setVolume(Float(UserDefaults.standard.double(forKey: "bgmVolume")),
                                 fadeDuration: 0.5)
    }

    func playTrack(named trackName: String) {
        let isEnabled = UserDefaults.standard.bool(forKey: "bgmEnabled")
        let maxVol    = Float(UserDefaults.standard.double(forKey: "bgmVolume"))
        if trackName == currentTrackName {
            if isEnabled && currentPlayer?.volume == 0 { currentPlayer?.setVolume(maxVol, fadeDuration: 1.0) }
            else if !isEnabled { currentPlayer?.setVolume(0, fadeDuration: 1.0) }
            return
        }
        guard let url = Bundle.main.url(forResource: trackName, withExtension: "mp3") else {
            currentTrackName = trackName
            currentPlayer?.setVolume(0, fadeDuration: 1.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.currentPlayer?.stop() }
            return
        }
        do {
            nextPlayer = try AVAudioPlayer(contentsOf: url)
            nextPlayer?.numberOfLoops = -1; nextPlayer?.volume = 0; nextPlayer?.prepareToPlay()
            if isEnabled { nextPlayer?.play(); nextPlayer?.setVolume(maxVol, fadeDuration: 1.5) }
            let old = currentPlayer; old?.setVolume(0, fadeDuration: 1.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { old?.stop() }
            currentPlayer = nextPlayer; currentTrackName = trackName
        } catch { print("❌ BGM Error: \(error)") }
    }
}

// MARK: - RetroAudioEngine ────────────────────────────────────────────

class RetroAudioEngine: NSObject {
    static let shared = RetroAudioEngine()

    private var tonePlayers: [AVAudioPlayer] = []
    private var successPlayer:     AVAudioPlayer?
    private var errorPlayer:       AVAudioPlayer?
    private var enemyHitPlayer:    AVAudioPlayer?
    private var playerHitPlayer:   AVAudioPlayer?
    private var jackInPlayer:      AVAudioPlayer?
    private var uplinkRevPlayer:   AVAudioPlayer?
    private var bossWarningPlayer: AVAudioPlayer?
    private var bootPlayer:        AVAudioPlayer?
    private var scoreDrainPlayer:  AVAudioPlayer?
    private var selectionPlayers: [AVAudioPlayer] = []
    private var currentSelectionPlayerIndex = 0
    private var whooshPlayer: AVAudioPlayer?

    override init() {
        super.init()
        registerInitialDefaults()
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default,
                                                         options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        DispatchQueue.global(qos: .userInitiated).async { self.precompileSounds() }
    }

    enum WaveType { case square, sawtooth, noise }

    private func precompileSounds() {
        let freqs: [Float] = [261.63,293.66,329.63,392,440,523.25,587.33,659.25,783.99,880]
        for f in freqs {
            if let d = generateWav(freqs:[f], type:.square, dur:0.15, vol:0.1),
               let p = try? AVAudioPlayer(data: d) { p.prepareToPlay(); tonePlayers.append(p) }
        }
        func make(_ ff: [Float], _ t: WaveType, _ d: TimeInterval, _ v: Float) -> AVAudioPlayer? {
            guard let data = generateWav(freqs:ff, type:t, dur:d, vol:v) else { return nil }
            let p = try? AVAudioPlayer(data: data); p?.prepareToPlay(); return p
        }
        successPlayer     = make([523.25,659.25,783.99,1046.50], .square,   0.08, 0.15)
        errorPlayer       = make([164.81,130.81],                 .sawtooth, 0.20, 0.15)
        enemyHitPlayer    = make([1046.50,880,523.25],            .square,   0.06, 0.15)
        playerHitPlayer   = make([110,73.42,55],                  .sawtooth, 0.12, 0.20)
        jackInPlayer      = make([220,330,440,660,880,1320,1760,2640], .square, 0.05, 0.15)
        uplinkRevPlayer   = make([220,261.63,329.63,392,440,523.25,659.25,783.99,880,1046.50,1318.51,1567.98],
                                  .sawtooth, 0.15, 0.15)
        bossWarningPlayer = make([440,660,440,660,440,660,440,660], .square,   0.15, 0.20)
        bootPlayer        = make([55,110,220,329.63,440,880],        .sawtooth, 0.25, 0.15)
        scoreDrainPlayer  = make([880,440,220,110],                  .sawtooth, 0.10, 0.20)
        if let data = generateWav(freqs:[880,1108.73], type:.square, dur:0.05, vol:0.1) {
            for _ in 0..<5 {
                if let p = try? AVAudioPlayer(data: data) { p.prepareToPlay(); selectionPlayers.append(p) }
            }
        }
        whooshPlayer = make([0], .noise, 0.25, 0.15)
    }

    private func sfxVol() -> Float? {
        guard UserDefaults.standard.bool(forKey: "sfxEnabled") else { return nil }
        return Float(UserDefaults.standard.double(forKey: "sfxVolume"))
    }
    private func play(_ p: AVAudioPlayer?) {
        guard let vol = sfxVol() else { return }
        p?.volume = vol; p?.currentTime = 0; p?.play()
    }

    func playGridTone(index: Int) {
        guard let vol = sfxVol(), !tonePlayers.isEmpty else { return }
        let p = tonePlayers[max(0, min(index, tonePlayers.count-1))]
        p.volume = vol; p.currentTime = 0; p.play()
    }
    func playSuccess()      { play(successPlayer) }
    func playError()        { play(errorPlayer) }
    func playEnemyHit()     { play(enemyHitPlayer) }
    func playPlayerHit()    { play(playerHitPlayer) }
    func playJackIn()       { play(jackInPlayer) }
    func playUplinkRev()    { play(uplinkRevPlayer) }
    func playBossWarning()  { play(bossWarningPlayer) }
    func playBootSound()    { play(bootPlayer) }
    func playScoreDrain()   { play(scoreDrainPlayer) }
    func playWhoosh()       { play(whooshPlayer) }
    func playSelectionTap() {
        guard let vol = sfxVol(), !selectionPlayers.isEmpty else { return }
        let p = selectionPlayers[currentSelectionPlayerIndex]
        p.volume = vol; p.currentTime = 0; p.play()
        currentSelectionPlayerIndex = (currentSelectionPlayerIndex + 1) % selectionPlayers.count
    }

    private func generateWav(freqs: [Float], type: WaveType, dur: TimeInterval, vol: Float) -> Data? {
        let sr: Int32 = 44100
        let fpn = Int(Double(sr) * dur)
        let total = fpn * freqs.count
        if total == 0 { return nil }
        var pcm = [Int16](repeating: 0, count: total)
        for (ni, freq) in freqs.enumerated() {
            let off = ni * fpn
            for i in 0..<fpn {
                let t = Float(i) / Float(sr)
                let p = Float(i) / Float(fpn)
                let env: Float = type == .noise ? exp(-4.0*p) : exp(-6.0*p)
                var s: Float
                switch type {
                case .square:   s = sin(2.0 * .pi * freq * t) > 0 ? vol : -vol
                case .sawtooth: s = (2.0*(t*freq - floor(t*freq+0.5))) * vol
                case .noise:    s = Float.random(in: -1...1) * vol
                }
                pcm[off+i] = Int16(max(-1, min(1, s*env)) * 32767)
            }
        }
        return makeWav(pcm: pcm, sr: sr)
    }

    private func makeWav(pcm: [Int16], sr: Int32) -> Data {
        let ds = Int32(pcm.count * 2); let fs = ds + 36; var d = Data()
        d.append(contentsOf: "RIFF".utf8)
        var fss = fs; d.append(Data(bytes: &fss, count: 4))
        d.append(contentsOf: "WAVEfmt ".utf8)
        var fmtSz: Int32 = 16; d.append(Data(bytes: &fmtSz, count: 4))
        var fmt: Int16 = 1;  d.append(Data(bytes: &fmt, count: 2))
        var ch:  Int16 = 1;  d.append(Data(bytes: &ch,  count: 2))
        var sRate = sr;       d.append(Data(bytes: &sRate, count: 4))
        var br = sr*2;        d.append(Data(bytes: &br, count: 4))
        var ba:  Int16 = 2;  d.append(Data(bytes: &ba,  count: 2))
        var bps: Int16 = 16; d.append(Data(bytes: &bps, count: 2))
        d.append(contentsOf: "data".utf8)
        var dss = ds; d.append(Data(bytes: &dss, count: 4))
        d.append(pcm.withUnsafeBufferPointer { Data(buffer: $0) })
        return d
    }
}

// MARK: - SpeechManager ───────────────────────────────────────────────

class SpeechManager {
    static let shared = SpeechManager()
    private let synthesizer = AVSpeechSynthesizer()

    func speak(text: String, language: String) {
        let volume = Float(UserDefaults.standard.double(forKey: "vocabAudioVolume"))
        guard volume > 0 else { return }
        let u = AVSpeechUtterance(string: text)
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        u.voice = voices.max(by: { $0.quality.rawValue < $1.quality.rawValue })
                  ?? AVSpeechSynthesisVoice(language: language)
        u.rate = language == "ja-JP" ? 0.45 : 0.5; u.volume = volume
        synthesizer.stopSpeaking(at: .immediate); synthesizer.speak(u)
    }

    func isPremiumJapaneseVoiceAvailable() -> Bool {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "ja-JP" }
            .contains { $0.quality == .enhanced || $0.quality == .premium }
    }
}

// MARK: - Models ──────────────────────────────────────────────────────

struct PlayerProfile { var level = 1, xp = 0, dailyStreak = 3, score = 1250, health = 100 }

struct Boon: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let flavorText: String
    let tier: BoonTier
    let icon: String
}

struct VocabWord: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    let kanji:       String
    let hiragana:    String
    let meaning:     String
    let category:    String
    let subcategory: String?
    let level:       String
    enum CodingKeys: String, CodingKey {
        case kanji="Kanji", hiragana="Hiragana", meaning="Meaning"
        case category="Category", subcategory="Subcategory", level="Level"
    }
    func hash(into h: inout Hasher) { h.combine(id) }
}

class DataLoader {
    static let shared = DataLoader()
    var allVocab: [VocabWord] = []
    private init() {
        guard let url  = Bundle.main.url(forResource: "jlpt_vocab", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let words = try? JSONDecoder().decode([VocabWord].self, from: data)
        else { print("⚠️ jlpt_vocab.json not found"); return }
        allVocab = words
    }
    func getCategories(for level: Int) -> [String] {
        let cats = Array(Set(allVocab.filter { $0.level == String(level) }.map { $0.category })).sorted()
        return cats.isEmpty ? ["Time, Dates, and Counters","People and Communication","Actions (Verbs)"] : cats
    }
    func getSubcategories(for level: Int, category: String) -> [String] {
        let subs = Array(Set(allVocab.filter { $0.level == String(level) && $0.category == category }
                                     .compactMap { $0.subcategory })).filter { !$0.isEmpty }.sorted()
        return subs.isEmpty ? ["General Databank"] : subs
    }
    func getWords(for level: Int, category: String, subcategory: String) -> [VocabWord] {
        let m = allVocab.filter {
            $0.level == String(level) && $0.category == category &&
            ($0.subcategory == subcategory ||
             (subcategory == "General Databank" && ($0.subcategory == nil || $0.subcategory!.isEmpty)))
        }
        if m.isEmpty {
            return [
                VocabWord(kanji:"朝",   hiragana:"あさ",   meaning:"Morning",   category:category,subcategory:subcategory,level:String(level)),
                VocabWord(kanji:"先生", hiragana:"せんせい", meaning:"Teacher",   category:category,subcategory:subcategory,level:String(level)),
                VocabWord(kanji:"食べる",hiragana:"たべる", meaning:"To eat",    category:category,subcategory:subcategory,level:String(level))
            ]
        }
        return m
    }
}

// ════════════════════════════════════════════════════════════════════
// MARK: - SHARED UI COMPONENTS
// ════════════════════════════════════════════════════════════════════

// MARK: GlassCard ─────────────────────────────────────────────────────

struct GlassCard<Content: View>: View {
    var borderColor:  Color    = .synthCyan
    var borderWidth:  CGFloat  = 1.5
    var cornerRadius: CGFloat  = 16
    var padding:      CGFloat  = 20
    var glowEnabled:  Bool     = true
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.synthCard.opacity(0.55))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [borderColor.opacity(0.9), borderColor.opacity(0.2)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: borderWidth
                    )
            }
            .shadow(color: glowEnabled ? borderColor.opacity(0.25) : .clear, radius: 16, y: 4)
    }
}

// MARK: Button Styles ─────────────────────────────────────────────────

struct CyberButtonStyle: ButtonStyle {
    var fillColor: Color = .synthPink
    var textColor: Color = Color.synthBackground

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.synthDisplay(16))
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fillColor)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(configuration.isPressed ? Color.white.opacity(0.15) : Color.clear)
                    }
            }
            .shadow(color: fillColor.opacity(configuration.isPressed ? 0.2 : 0.5),
                    radius: configuration.isPressed ? 4 : 12)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(duration: 0.18, bounce: 0.3), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    var borderColor: Color = .synthCyan
    var textColor:   Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.synthDisplay(15))
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.synthCard.opacity(configuration.isPressed ? 0.8 : 0.5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(borderColor.opacity(0.6), lineWidth: 1.5)
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(duration: 0.18, bounce: 0.3), value: configuration.isPressed)
    }
}

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .brightness(configuration.isPressed ? 0.1 : 0)
            .animation(.spring(duration: 0.15, bounce: 0.4), value: configuration.isPressed)
    }
}

// MARK: ScoreView ─────────────────────────────────────────────────────

struct ScoreView: View {
    let score:      Int
    let multiplier: Double
    let isDraining: Bool
    @AppStorage("enableNeonGlow") private var glowEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("CREDITS")
                .font(.synthMono(10, weight: .black))
                .foregroundStyle(Color.synthCyan.opacity(0.7))
                .tracking(2)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(score)")
                    .font(.synthDisplay(26))
                    .foregroundStyle(isDraining ? Color.synthPink : Color.white)
                    .contentTransition(.numericText(countsDown: isDraining))
                    .shadow(color: glowEnabled
                            ? (isDraining ? Color.synthPink.opacity(0.7) : Color.synthCyan.opacity(0.4))
                            : Color.clear,
                            radius: 8)
                    .scaleEffect(isDraining ? 1.12 : 1.0)
                    .animation(.spring(duration: 0.2, bounce: 0.4), value: isDraining)

                Text("×\(String(format: "%.1f", multiplier))")
                    .font(.synthDisplay(13))
                    .foregroundStyle(Color.synthPink)
                    .contentTransition(.numericText())
            }
        }
    }
}

// MARK: SynthProgressBar ──────────────────────────────────────────────

struct SynthProgressBar: View {
    let value:  Double
    let total:  Double
    var color:  Color   = .synthCyan
    var height: CGFloat = 6
    @AppStorage("enableNeonGlow") private var glowEnabled = true

    private var fraction: Double { max(0, min(1, value / total)) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height/2, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: height)
                RoundedRectangle(cornerRadius: height/2, style: .continuous)
                    .fill(color)
                    .frame(width: geo.size.width * fraction, height: height)
                    .shadow(color: glowEnabled ? color.opacity(0.7) : .clear, radius: 4)
                    .animation(.spring(duration: 0.4, bounce: 0.1), value: fraction)
            }
        }
        .frame(height: height)
    }
}

// MARK: TierBadge ─────────────────────────────────────────────────────

struct TierBadge: View {
    let tier: BoonTier
    var body: some View {
        Text(tier.rawValue.uppercased())
            .font(.synthMono(9, weight: .black))
            .tracking(1)
            .foregroundStyle(tier.color)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background {
                Capsule().fill(tier.color.opacity(0.15))
                    .overlay { Capsule().strokeBorder(tier.color.opacity(0.4), lineWidth: 1) }
            }
    }
}

// MARK: CyberAlertView ────────────────────────────────────────────────

struct CyberAlertView: View {
    var title:        String
    var message:      String
    var buttonText:   String
    var alertColor:   Color
    var action:       () -> Void
    var cancelAction: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                .background(Color.black.opacity(0.7).ignoresSafeArea())

            VStack(spacing: 24) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(alertColor)
                    .symbolEffect(.bounce, value: true)
                    .shadow(color: alertColor.opacity(0.6), radius: 12)

                Text(title)
                    .font(.synthDisplay(20))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.synthMono(14, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.gray)
                    .lineSpacing(5)

                VStack(spacing: 12) {
                    Button(buttonText) {
                        RetroAudioEngine.shared.playSelectionTap()
                        withAnimation(.spring(duration: 0.3, bounce: 0.2)) { action() }
                    }
                    .buttonStyle(CyberButtonStyle(fillColor: alertColor))

                    if let cancel = cancelAction {
                        Button("CANCEL") {
                            RetroAudioEngine.shared.playSelectionTap()
                            withAnimation(.spring(duration: 0.3)) { cancel() }
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
                .padding(.top, 8)
            }
            .padding(28)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.synthCard.opacity(0.6)) }
                    .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(alertColor.opacity(0.5), lineWidth: 1.5) }
            }
            .shadow(color: alertColor.opacity(0.3), radius: 30)
            .padding(.horizontal, 32)
        }
        .transition(.scale(scale: 0.88).combined(with: .opacity))
        .zIndex(100)
    }
}

// MARK: GlitchFileIcon ────────────────────────────────────────────────

struct GlitchFileIcon: View {
    @State private var glitch = false

    var body: some View {
        ZStack {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 70))
                .foregroundStyle(Color.synthCyan)
                .offset(x: glitch ? -4 : 0, y: glitch ? 2 : 0)
                .opacity(0.7)
            Image(systemName: "doc.text.fill")
                .font(.system(size: 70))
                .foregroundStyle(Color.synthPink)
                .offset(x: glitch ? 4 : 0, y: glitch ? -2 : 0)
                .opacity(0.7)
            Image(systemName: "doc.text.fill")
                .font(.system(size: 70))
                .foregroundStyle(Color.white)
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
                if Double.random(in: 0...1) < 0.3 {
                    withAnimation(.linear(duration: 0.08)) { glitch = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.linear(duration: 0.08)) { glitch = false }
                    }
                }
            }
        }
    }
}

// MARK: CorruptedCard ─────────────────────────────────────────────────
// NOTE: Each @State on its own line — fixes "Cannot assign to property: self is immutable"

struct CorruptedCard<Content: View>: View {
    var severity:  Double
    var baseColor: Color
    @ViewBuilder var content: Content

    @State private var dashPhase:   CGFloat = 0
    @State private var glitchX:     CGFloat = 0
    @State private var glitchY:     CGFloat = 0
    @State private var showSlice:   Bool    = false
    @State private var sliceOffset: CGFloat = 0

    var body: some View {
        content
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.synthCard.opacity(0.6))
                    }
                    .overlay {
                        if showSlice && severity > 0.3 {
                            Color.synthBackground.frame(height: severity * 12).offset(y: sliceOffset)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        baseColor.opacity(severity == 0 ? 0.4 : 0.8),
                        style: StrokeStyle(
                            lineWidth:  severity > 0.7 ? 2.5 : 1.5,
                            dash:       severity == 0 ? [] : (severity < 0.5 ? [60,15] : [20,10,5,20,40,15]),
                            dashPhase:  dashPhase
                        )
                    )
            }
            .shadow(color: baseColor.opacity(severity * 0.3), radius: 12)
            .offset(x: glitchX, y: glitchY)
            .onAppear {
                guard severity > 0 else { return }
                withAnimation(.linear(duration: Double.random(in: 3...6)).repeatForever(autoreverses: false)) {
                    dashPhase = 100
                }
                Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
                    guard severity > 0, Double.random(in: 0...1) < severity * 0.3 else { return }
                    glitchX = CGFloat.random(in: -severity*3...severity*3)
                    glitchY = CGFloat.random(in: -severity*2...severity*2)
                    if severity > 0.3 {
                        showSlice  = true
                        sliceOffset = CGFloat.random(in: -30...30)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        glitchX = 0; glitchY = 0; showSlice = false
                    }
                }
            }
    }
}

// MARK: GlitchText ────────────────────────────────────────────────────
// NOTE: Each @State on its own line — fixes "inaccessible initializer"

struct GlitchText: View {
    var text:      String
    var font:      Font
    var baseColor: Color
    var severity:  Double

    @State private var offsetX:         CGFloat = 0
    @State private var glitchOpacity:   Double  = 1
    @State private var showAberration:  Bool    = false

    var body: some View {
        ZStack {
            if showAberration {
                Text(text).font(font).foregroundStyle(Color.synthPink).offset(x: severity * 4)
                Text(text).font(font).foregroundStyle(Color.synthCyan).offset(x: -severity * 4)
            }
            Text(text).font(font).foregroundStyle(baseColor).opacity(glitchOpacity)
        }
        .offset(x: offsetX)
        .onAppear {
            guard severity > 0 else { return }
            Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
                guard Double.random(in: 0...1) < severity * 0.25 else { return }
                offsetX        = CGFloat.random(in: -severity*4...severity*4)
                glitchOpacity  = Double.random(in: 0.3...0.9)
                showAberration = severity > 0.6 && Bool.random()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    offsetX = 0; glitchOpacity = 1; showAberration = false
                }
            }
        }
    }
}

// MARK: Matrix Rain ───────────────────────────────────────────────────

struct MatrixRainView: View {
    var color:             Color  = .synthPurple
    var speedMultiplier:   Double = 1.0
    var opacityValue:      Double = 0.3

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 12) {
                ForEach(0..<Int(geo.size.width / 15), id: \.self) { _ in
                    MatrixColumn(height: geo.size.height,
                                 color:  color,
                                 speedMultiplier: speedMultiplier)
                }
            }
        }
        .opacity(opacityValue)
        .mask(LinearGradient(colors: [.clear, .black, .black, .clear],
                             startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }
}

// NOTE: Separate @State declarations — fixes "property wrapper single variable"
struct MatrixColumn: View {
    let height:          CGFloat
    var color:           Color
    var speedMultiplier: Double

    @State private var offset: CGFloat = 0
    @State private var chars:  String  = ""

    var body: some View {
        Text(chars)
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 15)
            .fixedSize(horizontal: false, vertical: true)
            .offset(y: offset)
            .onAppear {
                let k = "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ"
                chars  = (0..<Int.random(in: 15...30)).map { _ in String(k.randomElement()!) }.joined(separator: "\n")
                offset = -height - CGFloat.random(in: 0...height)
                withAnimation(.linear(duration: Double.random(in: 5...12) / speedMultiplier)
                    .repeatForever(autoreverses: false)) { offset = height * 1.5 }
            }
    }
}

// MARK: Sector Backgrounds ────────────────────────────────────────────

struct SectorBackgroundView: View {
    let phase: Int
    var body: some View {
        switch phase % 4 {
        case 1:  MatrixRainView(color: .synthCyan, speedMultiplier: 0.4, opacityValue: 0.2)
        case 2:  CRTScanlinesView()
        case 3:  HorizontalDataStreamView()
        default: MovingGridView()
        }
    }
}

struct CRTScanlinesView: View {
    @State private var offset: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 8) {
                ForEach(0..<Int(geo.size.height/8+10), id: \.self) { _ in
                    Rectangle().fill(Color.synthCyan.opacity(0.06)).frame(height: 2)
                }
            }
            .frame(height: geo.size.height * 2)
            .offset(y: offset)
            .onAppear {
                offset = -geo.size.height
                withAnimation(.linear(duration: 10).repeatForever(autoreverses: false)) { offset = 0 }
            }
        }.allowsHitTesting(false)
    }
}

struct HorizontalDataStreamView: View {
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 30) {
                ForEach(0..<Int(geo.size.height/30), id: \.self) { i in
                    HorizontalDataRow(width: geo.size.width, isReversed: i % 2 == 0)
                }
            }
        }.opacity(0.18).allowsHitTesting(false)
    }
}

// NOTE: Separate @State declarations
struct HorizontalDataRow: View {
    let width:      CGFloat
    let isReversed: Bool

    @State private var offset: CGFloat = 0
    @State private var chars:  String  = ""

    var body: some View {
        Text(chars)
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(isReversed ? Color.synthCyan : Color.synthYellow)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .offset(x: offset)
            .onAppear {
                let k = "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ"
                chars = (0..<Int.random(in: 30...60)).map { _ in String(k.randomElement()!) }.joined(separator: " ")
                let start: CGFloat = isReversed ? -width-300 : width+300
                offset = start
                withAnimation(.linear(duration: Double.random(in: 15...25)).repeatForever(autoreverses: false)) {
                    offset = isReversed ? width+300 : -width-300
                }
            }
    }
}

struct MovingGridView: View {
    @State private var offset: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            ZStack {
                HStack(spacing: 40) {
                    ForEach(0..<Int(geo.size.width/40+5), id: \.self) { _ in
                        Rectangle().fill(Color.synthPink.opacity(0.12)).frame(width: 1)
                    }
                }
                VStack(spacing: 40) {
                    ForEach(0..<Int(geo.size.height/40+10), id: \.self) { _ in
                        Rectangle().fill(Color.synthPink.opacity(0.12)).frame(height: 1)
                    }
                }.offset(y: offset)
            }
            .frame(width: geo.size.width, height: geo.size.height*2)
            .onAppear {
                offset = -40
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { offset = 0 }
            }
        }.allowsHitTesting(false)
    }
}

// ════════════════════════════════════════════════════════════════════
// MARK: - BOOT SCREEN
// ════════════════════════════════════════════════════════════════════
// Uses file-scope BootAnimationPhase enum (no nested-type issues)

struct BootSplashView: View {
    @Environment(AppRouter.self) private var router

    @State private var phase:        BootAnimationPhase = .hidden
    @State private var glitchOffset: CGFloat            = 0

    var body: some View {
        ZStack {
            Color.synthBackground.ignoresSafeArea()
            MatrixRainView(color: .synthPurple, speedMultiplier: 0.6, opacityValue: 0.15)

            VStack(spacing: 32) {
                PhaseAnimator(BootAnimationPhase.allCases, trigger: phase) { p in
                    GlitchFileIcon()
                        .opacity(p == .hidden ? 0 : 1)
                        .scaleEffect(p == .hidden ? 0.6 : (p == .icon ? 1.05 : 1.0))
                } animation: { _ in .spring(duration: 0.6, bounce: 0.3) }

                VStack(spacing: 10) {
                    Text("S A G A S U")
                        .font(.synthDisplay(40))
                        .foregroundStyle(Color.white)
                        .tracking(8)
                        .shadow(color: Color.synthCyan.opacity(0.6), radius: 12)
                        .offset(x: glitchOffset)
                        .opacity(phase >= .title ? 1 : 0)
                        .animation(.spring(duration: 0.5, bounce: 0.2), value: phase)

                    Text("NEURAL LINK BOOT v4.2.6")
                        .font(.synthMono(12, weight: .bold))
                        .foregroundStyle(Color.synthPink.opacity(0.8))
                        .tracking(3)
                        .opacity(phase >= .tagline ? 1 : 0)
                        .animation(.easeIn(duration: 0.4), value: phase)
                }
            }
        }
        .onAppear {
            RetroAudioEngine.shared.playBootSound()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4)  { phase = .icon    }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9)  { phase = .title   }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3)  { phase = .tagline }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.linear(duration: 0.06)) { glitchOffset = 6 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    withAnimation(.linear(duration: 0.06)) { glitchOffset = -6 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        withAnimation(.linear(duration: 0.06)) { glitchOffset = 0 }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                withAnimation(.easeOut(duration: 0.6)) { router.currentScreen = .home }
            }
        }
    }
}

// ════════════════════════════════════════════════════════════════════
// MARK: - ROOT CONTAINER
// ════════════════════════════════════════════════════════════════════

struct MainTabView: View {
    @State private var router   = AppRouter()
    @State private var gauntlet = GauntletManager()

    @State private var showVoicePrompt = false
    @AppStorage("hasSeenVoicePrompt") private var hasSeenVoicePrompt = false
    @AppStorage("enableNeonGlow")     private var enableNeonGlow     = true

    init() {
        let a = UINavigationBarAppearance()
        a.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance   = a
        UINavigationBar.appearance().scrollEdgeAppearance = a
    }

    private func updateBGM() {
        guard router.currentScreen != .boot else { return }
        let ud = UserDefaults.standard
        let track: String
        if router.currentScreen == .home || router.currentScreen == .settings {
            track = ud.string(forKey: "bgmMotherboard") ?? "motherboard"
        } else if router.currentScreen == .grid {
            switch gauntlet.gameState {
            case .selection, .uplink, .review, .roundComplete, .gameOver:
                track = ud.string(forKey: "bgmMotherboard") ?? "motherboard"
            case .gridTransition, .grid:
                switch gauntlet.currentRound {
                case 1:  track = ud.string(forKey: "bgmPhase1") ?? "Mydoom"
                case 2:  track = ud.string(forKey: "bgmPhase2") ?? "DDoS"
                case 3:  track = ud.string(forKey: "bgmPhase3") ?? "Man in the Middle"
                default: track = ud.string(forKey: "bgmPhase4") ?? "Backdoor"
                }
            case .bossTransition, .boss:
                switch gauntlet.currentRound {
                case 1:  track = ud.string(forKey: "bgmBoss1") ?? "ILOVEYOU"
                case 2:  track = ud.string(forKey: "bgmBoss2") ?? "Logic Bomb"
                case 3:  track = ud.string(forKey: "bgmBoss3") ?? "Boot Sector Virus"
                default: track = ud.string(forKey: "bgmBoss4") ?? "Firewall"
                }
            }
        } else { return }
        BGMManager.shared.playTrack(named: track)
    }

    var body: some View {
        ZStack {
            Color.synthBackground.ignoresSafeArea()

            switch router.currentScreen {
            case .boot:     BootSplashView()
            case .home:     HomeView()
            case .grid:     GauntletSelectionView()
            case .settings: SettingsView()
            }

            if gauntlet.gameState != .selection && router.currentScreen != .boot {
                Color.synthBackground.ignoresSafeArea()
                GauntletContainerView()
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity))
            }

            if showVoicePrompt && router.currentScreen != .boot {
                VoicePromptOverlay {
                    withAnimation(.spring(duration: 0.4, bounce: 0.2)) { showVoicePrompt = false }
                }
            }
        }
        .environment(router)
        .environment(gauntlet)
        .onChange(of: router.currentScreen)      { updateBGM() }
        .onChange(of: gauntlet.gameState)        { updateBGM() }
        .onChange(of: gauntlet.currentRound)     { updateBGM() }
        .onAppear {
            if !hasSeenVoicePrompt && !SpeechManager.shared.isPremiumJapaneseVoiceAvailable() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.spring(duration: 0.5, bounce: 0.2)) { showVoicePrompt = true }
                }
                hasSeenVoicePrompt = true
            }
        }
    }
}

struct VoicePromptOverlay: View {
    var dismiss: () -> Void
    @AppStorage("enableNeonGlow") private var glowEnabled = true

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                .background(Color.black.opacity(0.7).ignoresSafeArea())

            VStack(spacing: 24) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(Color.synthPink)
                    .symbolEffect(.variableColor.iterative, value: true)
                    .shadow(color: glowEnabled ? Color.synthPink.opacity(0.8) : .clear, radius: 15)

                Text("SYSTEM UPGRADE REQUIRED")
                    .font(.synthDisplay(18))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)

                Text("For the optimal neural-link experience, Sagasu requests the Enhanced Japanese Voice pack.\n\nInitialize via:\nSettings › Accessibility › Spoken Content › Voices › Japanese")
                    .font(.synthMono(13, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.gray)
                    .lineSpacing(5)

                Button("ACKNOWLEDGE", action: dismiss)
                    .buttonStyle(CyberButtonStyle(fillColor: .synthCyan, textColor: Color.synthBackground))
                    .padding(.top, 8)
            }
            .padding(28)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.synthCard.opacity(0.6)) }
                    .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.synthPink.opacity(0.5), lineWidth: 1.5) }
            }
            .padding(.horizontal, 32)
        }
        .transition(.scale(scale: 0.88).combined(with: .opacity))
    }
}

// ════════════════════════════════════════════════════════════════════
// MARK: - HOME VIEW  (MeshGradient iOS 18+)
// ════════════════════════════════════════════════════════════════════

struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @State private var profile  = PlayerProfile()
    @State private var appeared = false
    @AppStorage("enableNeonGlow") private var glowEnabled = true

    var body: some View {
        ZStack {
            if #available(iOS 18.0, *) {
                MeshGradient(
                    width: 3, height: 3,
                    points: [[0,0],[0.5,0],[1,0],[0,0.5],[0.5,0.5],[1,0.5],[0,1],[0.5,1],[1,1]],
                    colors: [
                        Color.synthBackground, Color.synthSurface, Color.synthBackground,
                        Color.synthSurface, Color(hex:"1A0040"), Color.synthSurface,
                        Color.synthBackground, Color.synthSurface, Color.synthBackground
                    ]
                )
                .ignoresSafeArea()
            } else {
                Color.synthBackground.ignoresSafeArea()
            }
            MatrixRainView(opacityValue: 0.2)

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SAGASU")
                            .font(.synthDisplay(28))
                            .foregroundStyle(Color.white)
                            .shadow(color: glowEnabled ? Color.synthCyan.opacity(0.7) : .clear, radius: 10)
                        Text("NEURAL LINK ESTABLISHED")
                            .font(.synthMono(10, weight: .bold))
                            .foregroundStyle(Color.synthPink)
                            .tracking(2)
                    }
                    Spacer()
                    Button {
                        RetroAudioEngine.shared.playSelectionTap()
                        withAnimation(.spring(duration: 0.4, bounce: 0.1)) { router.currentScreen = .settings }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Color.synthCyan)
                            .frame(width: 44, height: 44)
                            .background {
                                Circle().fill(.ultraThinMaterial)
                                    .overlay { Circle().strokeBorder(Color.synthCyan.opacity(0.4), lineWidth: 1) }
                            }
                            .symbolEffect(.bounce, value: appeared)
                            .shadow(color: glowEnabled ? Color.synthCyan.opacity(0.4) : .clear, radius: 8)
                    }
                    .buttonStyle(ChipButtonStyle())
                }
                .padding(.horizontal, 24).padding(.top, 16)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : -20)
                .animation(.spring(duration: 0.6, bounce: 0.2).delay(0.1), value: appeared)

                Spacer()

                Button {
                    RetroAudioEngine.shared.playSelectionTap()
                    withAnimation(.spring(duration: 0.4, bounce: 0.15)) { router.currentScreen = .grid }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.synthCyan)
                            .symbolEffect(.pulse, value: appeared)
                            .shadow(color: glowEnabled ? Color.synthCyan.opacity(0.8) : .clear, radius: 10)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ENTER THE GRID")
                                .font(.synthDisplay(20))
                                .foregroundStyle(Color.white)
                            Text("INITIALIZE HUNT SEQUENCE")
                                .font(.synthMono(11, weight: .bold))
                                .foregroundStyle(Color.synthCyan.opacity(0.7))
                                .tracking(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(Color.synthCyan)
                    }
                }
                .buttonStyle(EnterGridButtonStyle(glowEnabled: glowEnabled))
                .padding(.horizontal, 24)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 30)
                .animation(.spring(duration: 0.7, bounce: 0.25).delay(0.25), value: appeared)

                HStack(spacing: 14) {
                    GlassCard(borderColor: .synthYellow, borderWidth: 1, cornerRadius: 14,
                              padding: 16, glowEnabled: glowEnabled) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("UPLINK STREAK")
                                .font(.synthMono(10, weight: .black))
                                .foregroundStyle(Color.gray).tracking(1)
                            HStack(spacing: 6) {
                                Image(systemName: "bolt.fill")
                                    .foregroundStyle(Color.synthYellow)
                                    .symbolEffect(.bounce, value: appeared)
                                    .shadow(color: glowEnabled ? Color.synthYellow : .clear, radius: 4)
                                Text("\(profile.dailyStreak) CYCLES")
                                    .font(.synthDisplay(15))
                                    .foregroundStyle(Color.white)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Button { RetroAudioEngine.shared.playSelectionTap() } label: {
                        GlassCard(borderColor: .synthPurple, borderWidth: 1, cornerRadius: 14,
                                  padding: 16, glowEnabled: glowEnabled) {
                            VStack(spacing: 8) {
                                Image(systemName: "shippingbox.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(Color.synthPurple)
                                    .shadow(color: glowEnabled ? Color.synthPurple : .clear, radius: 4)
                                Text("DECRYPT")
                                    .font(.synthMono(11, weight: .black))
                                    .foregroundStyle(Color.white)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(ChipButtonStyle())
                    .frame(width: 110)
                }
                .padding(.horizontal, 24).padding(.top, 16)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 30)
                .animation(.spring(duration: 0.7, bounce: 0.2).delay(0.35), value: appeared)

                VStack(alignment: .leading, spacing: 12) {
                    Text("ACTIVE PROTOCOLS (24h)")
                        .font(.synthMono(10, weight: .black))
                        .foregroundStyle(Color.gray).tracking(1)
                        .padding(.horizontal, 24)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            BoonCard(boon: Boon(name:"Scholar's Candle",
                                               description:"Hint Cost Reduction (50%)",
                                               flavorText:"", tier:.common, icon:"flame.fill"))
                            BoonCard(boon: Boon(name:"Chronos Hourglass",
                                               description:"Freezes timer for 1st Quiz question.",
                                               flavorText:"", tier:.rare, icon:"hourglass.circle.fill"))
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.top, 20)
                .opacity(appeared ? 1 : 0)
                .animation(.easeIn(duration: 0.5).delay(0.5), value: appeared)

                Spacer().frame(height: 32)
            }
        }
        .onAppear { withAnimation { appeared = true } }
    }
}

private struct EnterGridButtonStyle: ButtonStyle {
    let glowEnabled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(22)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.synthCard.opacity(0.7)) }
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                LinearGradient(colors: [Color.synthCyan, Color.synthPurple],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 2
                            )
                    }
            }
            .shadow(color: glowEnabled ? Color.synthCyan.opacity(configuration.isPressed ? 0.15 : 0.35) : .clear,
                    radius: 20)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: configuration.isPressed)
    }
}

struct BoonCard: View {
    let boon: Boon
    @AppStorage("enableNeonGlow") private var glowEnabled = true

    var body: some View {
        GlassCard(borderColor: boon.tier.color, borderWidth: 1.5, cornerRadius: 14,
                  padding: 16, glowEnabled: glowEnabled) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: boon.icon)
                        .font(.system(size: 26))
                        .foregroundStyle(boon.tier.color)
                        .shadow(color: glowEnabled ? boon.tier.color.opacity(0.7) : .clear, radius: 6)
                    Spacer()
                    TierBadge(tier: boon.tier)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(boon.name).font(.synthDisplay(14)).foregroundStyle(Color.white)
                    Text(boon.description).font(.synthMono(11)).foregroundStyle(Color.gray).lineLimit(2)
                }
            }
        }
        .frame(width: 165, height: 140)
    }
}

// ════════════════════════════════════════════════════════════════════
// MARK: - LEVEL SELECT  (NavigationStack + scrollTransition)
// ════════════════════════════════════════════════════════════════════

struct LevelConfig: Hashable {
    let level: Int
    let title: String
    let desc:  String
    let colorHex: String
    let severity: Double
    var color: Color { Color(hex: colorHex) }
}

struct GauntletSelectionView: View {
    @Environment(GauntletManager.self) private var gauntlet
    @Environment(AppRouter.self)       private var router

    let configs: [LevelConfig] = [
        LevelConfig(level:5, title:"JLPT N5", desc:"SYSTEM STABLE",          colorHex:"00F5FF", severity:0.0),
        LevelConfig(level:4, title:"JLPT N4", desc:"MINOR ANOMALIES",         colorHex:"FFD000", severity:0.2),
        LevelConfig(level:3, title:"JLPT N3", desc:"DATA CORRUPTION",         colorHex:"FF6C11", severity:0.5),
        LevelConfig(level:2, title:"JLPT N2", desc:"WARNING: THREAT HIGH",    colorHex:"FF0BA5", severity:0.8),
        LevelConfig(level:1, title:"JLPT N1", desc:"FATAL ERROR // OVERRIDE", colorHex:"FF003C", severity:1.0)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.synthBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            RetroAudioEngine.shared.playSelectionTap()
                            withAnimation(.spring(duration: 0.4)) { router.currentScreen = .home }
                        } label: {
                            Label("HOME", systemImage: "house.fill")
                                .font(.synthDisplay(14))
                                .foregroundStyle(Color.synthPink)
                        }
                        .buttonStyle(ChipButtonStyle())
                        Spacer()
                    }
                    .padding(.horizontal, 24).padding(.top, 12)

                    Text("SELECT TARGET GRID")
                        .font(.synthDisplay(28))
                        .foregroundStyle(Color.white)
                        .padding(.vertical, 16)

                    ScrollView {
                        LazyVStack(spacing: 18) {
                            ForEach(configs, id: \.level) { cfg in
                                NavigationLink(value: cfg) {
                                    CorruptedCard(severity: cfg.severity, baseColor: cfg.color) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 10) {
                                                GlitchText(text: "SECTOR \(cfg.level) // \(cfg.desc)",
                                                           font: .synthMono(11, weight: .black),
                                                           baseColor: cfg.color, severity: cfg.severity)
                                                GlitchText(text: cfg.title,
                                                           font: .synthDisplay(22),
                                                           baseColor: .white, severity: cfg.severity)
                                                HStack(spacing: 4) {
                                                    ForEach(0..<5, id: \.self) { i in
                                                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                                                            .fill(Double(i) < cfg.severity * 5
                                                                  ? cfg.color : cfg.color.opacity(0.2))
                                                            .frame(width: 22, height: 4)
                                                    }
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 18, weight: .bold))
                                                .foregroundStyle(cfg.color)
                                        }
                                    }
                                }
                                .simultaneousGesture(TapGesture().onEnded {
                                    RetroAudioEngine.shared.playSelectionTap()
                                })
                                .scrollTransition(axis: .vertical) { content, phase in
                                    content
                                        .opacity(phase.isIdentity ? 1.0 : 0.5)
                                        .scaleEffect(phase.isIdentity ? 1.0 : 0.94)
                                        .blur(radius: phase.isIdentity ? 0 : 2)
                                }
                            }
                        }
                        .padding(.horizontal, 24).padding(.bottom, 48)
                    }
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: LevelConfig.self) { cfg in
                DataPacketBuilderView(config: cfg)
            }
        }
        .id(gauntlet.navigationResetID)
    }
}

// MARK: - Data Packet Builder ─────────────────────────────────────────
// NOTE: All @State on separate lines — fixes inaccessible initializer

struct DataPacketBuilderView: View {
    @Environment(\.dismiss)            private var dismiss
    @Environment(GauntletManager.self) private var gauntlet
    var config: LevelConfig

    @State private var viewDepth:           Int         = 0
    @State private var selectedCategory:    String      = ""
    @State private var selectedSubcategory: String      = ""
    @State private var categories:          [String]    = []
    @State private var subcategories:       [String]    = []
    @State private var words:               [VocabWord] = []
    @State private var packet:              [VocabWord] = []
    @State private var showOverloadAlert:   Bool        = false
    @State private var showWhy20Alert:      Bool        = false
    @State private var slotsRemaining:      Int         = 0

    var isPacketReady: Bool { packet.count > 0 && packet.count % 5 == 0 && packet.count <= 20 }

    var body: some View {
        ZStack {
            Color.synthBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                builderHeader
                builderTitle
                builderColumns
                packetFooter
            }
            if showOverloadAlert {
                CyberAlertView(title: "MEMORY OVERFLOW",
                               message: "Exceeds 20-node limit.\n[ \(slotsRemaining) ] slots remaining.",
                               buttonText: "ACKNOWLEDGE", alertColor: .synthPink,
                               action: { showOverloadAlert = false })
            }
            if showWhy20Alert {
                CyberAlertView(title: "OPTIMAL RETENTION",
                               message: "Most learners retain 10–20 words per day long-term.\n\n[ ENDLESS RUN MODE: COMING SOON ]",
                               buttonText: "ACKNOWLEDGE", alertColor: .synthCyan,
                               action: { showWhy20Alert = false })
            }
        }
        .navigationBarHidden(true)
        .onAppear { categories = DataLoader.shared.getCategories(for: config.level) }
    }

    private var builderHeader: some View {
        HStack {
            Button {
                if viewDepth == 0 {
                    RetroAudioEngine.shared.playSelectionTap(); dismiss()
                } else {
                    RetroAudioEngine.shared.playWhoosh()
                    withAnimation(.spring(duration: 0.4, bounce: 0.1)) { viewDepth -= 1 }
                }
            } label: {
                Label(viewDepth == 0 ? "ABORT" : "BACK", systemImage: "chevron.left")
                    .font(.synthDisplay(14))
                    .foregroundStyle(viewDepth == 0 ? Color.synthPink : config.color)
            }
            .buttonStyle(ChipButtonStyle())
            Spacer()
        }
        .padding(.horizontal, 24).padding(.top, 12)
    }

    private var builderTitle: some View {
        VStack(spacing: 4) {
            GlitchText(text: "SECTOR \(config.level) // DATA COMPILER",
                       font: .synthMono(11, weight: .black),
                       baseColor: config.color, severity: config.severity)
            let depthTitle = viewDepth == 0 ? "SELECT CATEGORY"
                           : viewDepth == 1 ? "SELECT SUBCATEGORY"
                           : "SELECT NODES"
            Text(depthTitle)
                .font(.synthDisplay(22))
                .foregroundStyle(Color.white)
                .contentTransition(.opacity)
                .animation(.spring(duration: 0.3), value: viewDepth)
        }
        .padding(.vertical, 14)
    }

    private var builderColumns: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                categoriesColumn(width: geo.size.width)
                subcategoriesColumn(width: geo.size.width)
                wordsColumn(width: geo.size.width)
            }
            .offset(x: -CGFloat(viewDepth) * geo.size.width)
            .animation(.spring(duration: 0.4, bounce: 0.1), value: viewDepth)
        }
    }

    private func categoriesColumn(width: CGFloat) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(categories, id: \.self) { cat in
                    Button {
                        selectedCategory = cat
                        subcategories    = DataLoader.shared.getSubcategories(for: config.level, category: cat)
                        RetroAudioEngine.shared.playWhoosh()
                        withAnimation(.spring(duration: 0.4, bounce: 0.1)) { viewDepth = 1 }
                    } label: {
                        HStack {
                            Text(cat.uppercased())
                                .font(.synthDisplay(14))
                                .foregroundStyle(config.color)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(config.color)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.synthCard.opacity(0.6)) }
                                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(config.color.opacity(0.3), lineWidth: 1) }
                        }
                    }
                    .buttonStyle(ChipButtonStyle())
                }
            }
            .padding(20)
        }
        .frame(width: width)
    }

    private func subcategoriesColumn(width: CGFloat) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(subcategories, id: \.self) { sub in
                    Button {
                        selectedSubcategory = sub
                        words = DataLoader.shared.getWords(for: config.level,
                                                          category: selectedCategory,
                                                          subcategory: sub)
                        RetroAudioEngine.shared.playWhoosh()
                        withAnimation(.spring(duration: 0.4, bounce: 0.1)) { viewDepth = 2 }
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(Color.synthYellow)
                            Text(sub.uppercased())
                                .font(.synthDisplay(13))
                                .foregroundStyle(Color.white)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Color.synthYellow)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.synthCard.opacity(0.6)) }
                                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.synthYellow.opacity(0.3), lineWidth: 1) }
                        }
                    }
                    .buttonStyle(ChipButtonStyle())
                }
            }
            .padding(20)
        }
        .frame(width: width)
    }

    private func wordsColumn(width: CGFloat) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if !words.isEmpty {
                    let allSelected = words.allSatisfy { packet.contains($0) }
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if allSelected {
                                packet.removeAll { words.contains($0) }
                                RetroAudioEngine.shared.playSelectionTap()
                            } else {
                                let toAdd = words.filter { !packet.contains($0) }
                                if packet.count + toAdd.count > 20 {
                                    slotsRemaining = 20 - packet.count
                                    RetroAudioEngine.shared.playError()
                                    withAnimation { showOverloadAlert = true }
                                } else {
                                    packet.append(contentsOf: toAdd)
                                    if packet.count % 5 == 0 { RetroAudioEngine.shared.playSuccess() }
                                    else                      { RetroAudioEngine.shared.playSelectionTap() }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: allSelected ? "square.dashed" : "checkmark.square.fill")
                            Text(allSelected ? "DESELECT ALL" : "SELECT ALL")
                                .font(.synthMono(12, weight: .bold))
                        }
                        .foregroundStyle(allSelected ? Color.synthPink : config.color)
                        .padding(.vertical, 8).padding(.horizontal, 12)
                        .background {
                            Capsule().fill(Color.synthCard)
                                .overlay { Capsule().strokeBorder((allSelected ? Color.synthPink : config.color).opacity(0.5), lineWidth: 1) }
                        }
                    }
                    .buttonStyle(ChipButtonStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
                }
                ForEach(words, id: \.id) { word in
                    wordRow(word)
                }
            }
            .padding(20)
        }
        .frame(width: width)
    }

    private func wordRow(_ word: VocabWord) -> some View {
        let isSelected = packet.contains(word)
        return Button {
            withAnimation(.spring(duration: 0.25, bounce: 0.3)) {
                if isSelected {
                    packet.removeAll { $0.id == word.id }
                    RetroAudioEngine.shared.playSelectionTap()
                } else if packet.count >= 20 {
                    slotsRemaining = 0
                    RetroAudioEngine.shared.playError()
                    withAnimation { showOverloadAlert = true }
                } else {
                    packet.append(word)
                    if packet.count % 5 == 0 { RetroAudioEngine.shared.playSuccess() }
                    else                      { RetroAudioEngine.shared.playSelectionTap() }
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(word.kanji.isEmpty ? word.hiragana : "\(word.kanji) (\(word.hiragana))")
                        .font(.synthDisplay(15))
                        .foregroundStyle(isSelected ? Color.synthBackground : Color.white)
                    Text(word.meaning)
                        .font(.synthMono(12))
                        .foregroundStyle(isSelected ? Color.synthBackground.opacity(0.7) : Color.gray)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.square.fill" : "square.dashed")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.synthBackground : config.color.opacity(0.5))
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? config.color : Color.synthCard)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(config.color.opacity(isSelected ? 0 : 0.3), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(ChipButtonStyle())
    }

    private var packetFooter: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: isPacketReady
                      ? "externaldrive.fill.badge.checkmark"
                      : "externaldrive.badge.plus")
                    .font(.system(size: 26))
                    .foregroundStyle(isPacketReady ? Color.synthPink : config.color)
                    .symbolEffect(.bounce, value: isPacketReady)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("DATA PACKET")
                            .font(.synthMono(10, weight: .black))
                            .foregroundStyle(Color.gray).tracking(1)
                        Button {
                            RetroAudioEngine.shared.playSelectionTap()
                            showWhy20Alert = true
                        } label: {
                            Image(systemName: "questionmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.synthCyan)
                        }
                        .buttonStyle(ChipButtonStyle())
                    }
                    Text("[ \(packet.count) / 20 ] NODES")
                        .font(.synthDisplay(15))
                        .foregroundStyle(packet.count == 20 ? Color.synthPink : Color.white)
                        .contentTransition(.numericText())
                    Text("[ \(packet.count/5) / 4 ] SECTORS CONFIGURED")
                        .font(.synthMono(11, weight: .bold))
                        .foregroundStyle(config.color)
                        .contentTransition(.numericText())
                }
                Spacer()
            }
            .padding(.horizontal, 22)

            if isPacketReady {
                Button("INITIALIZE UPLINK") {
                    RetroAudioEngine.shared.playSelectionTap()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        withAnimation(.spring(duration: 0.5, bounce: 0.15)) {
                            gauntlet.startCustomGauntlet(words: packet)
                        }
                    }
                }
                .buttonStyle(CyberButtonStyle(fillColor: .synthPink))
                .padding(.horizontal, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if packet.count > 0 {
                Text("Select \(5 - (packet.count % 5)) more node(s) to configure a sector.")
                    .font(.synthMono(12, weight: .bold))
                    .foregroundStyle(Color.synthYellow)
                    .padding(.horizontal, 22)
            }
        }
        .padding(.top, 14).padding(.bottom, 30)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(isPacketReady ? Color.synthPink : config.color)
                .frame(height: 1.5)
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: isPacketReady)
    }
}

// ════════════════════════════════════════════════════════════════════
// MARK: - TRANSITIONS
// ════════════════════════════════════════════════════════════════════

struct UplinkTransitionView: View {
    @Environment(GauntletManager.self) private var gauntlet
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Color.synthBackground.ignoresSafeArea()
            MatrixRainView(color: .synthCyan, speedMultiplier: 4, opacityValue: 0.8)
            VStack(spacing: 40) {
                Image(systemName: "network")
                    .font(.system(size: 80))
                    .foregroundStyle(Color.synthCyan)
                    .symbolEffect(.variableColor.iterative, value: progress)
                    .shadow(color: Color.synthCyan, radius: 20)
                Text("INITIALIZING UPLINK...")
                    .font(.synthDisplay(20))
                    .foregroundStyle(Color.synthCyan)
                    .shadow(color: Color.synthCyan, radius: 10)
                SynthProgressBar(value: Double(progress), total: 1.0, color: .synthPink, height: 8)
                    .padding(.horizontal, 60)
            }
        }
        .onAppear {
            RetroAudioEngine.shared.playUplinkRev()
            withAnimation(.easeInOut(duration: 1.8)) { progress = 1.0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeInOut(duration: 0.3)) { gauntlet.finishUplink() }
            }
        }
    }
}

struct GridTransitionView: View {
    @Environment(GauntletManager.self) private var gauntlet
    var body: some View {
        ZStack {
            Color.synthBackground.ignoresSafeArea()
            MatrixRainView(color: .synthCyan, speedMultiplier: 3, opacityValue: 0.8)
            VStack(spacing: 20) {
                Image(systemName: "network")
                    .font(.system(size: 60))
                    .foregroundStyle(Color.synthCyan)
                    .symbolEffect(.bounce, value: true)
                    .shadow(color: Color.synthCyan, radius: 12)
                Text("INITIALIZING SECTOR...")
                    .font(.synthDisplay(20))
                    .foregroundStyle(Color.synthCyan)
            }
        }
        .onAppear {
            RetroAudioEngine.shared.playJackIn()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.easeInOut(duration: 0.3)) { gauntlet.startGridPhase() }
            }
        }
    }
}

struct BossTransitionView: View {
    @Environment(GauntletManager.self) private var gauntlet
    @State private var pulse = false
    var body: some View {
        ZStack {
            Color.synthBackground.ignoresSafeArea()
            MatrixRainView(color: .synthPink, speedMultiplier: 4, opacityValue: 0.9)
            Color.synthPink.opacity(pulse ? 0.25 : 0.05).ignoresSafeArea()
                .animation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true), value: pulse)
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(Color.synthPink)
                    .symbolEffect(.bounce.byLayer, value: pulse)
                    .shadow(color: Color.synthPink, radius: 25)
                Text("SYSTEM OVERRIDE\nIMMINENT")
                    .font(.synthDisplay(32))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: Color.synthPink, radius: 15)
            }
        }
        .onAppear {
            RetroAudioEngine.shared.playBossWarning()
            withAnimation { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeInOut(duration: 0.3)) { gauntlet.startBossFight() }
            }
        }
    }
}

// ════════════════════════════════════════════════════════════════════
// MARK: - GAUNTLET CONTAINER
// ════════════════════════════════════════════════════════════════════

struct GauntletContainerView: View {
    @Environment(GauntletManager.self) private var gauntlet
    @Environment(AppRouter.self)       private var router

    var body: some View {
        Group {
            switch gauntlet.gameState {
            case .selection:       EmptyView()
            case .uplink:          UplinkTransitionView()
            case .review:          FlashcardReviewView()
            case .gridTransition:  GridTransitionView()
            case .grid:            GameBoardView()
            case .bossTransition:  BossTransitionView()
            case .boss:            BossFightQuizView()
            case .roundComplete:   Text("Round Complete").foregroundStyle(Color.white)
            case .gameOver:        GameOverView()
            }
        }
    }
}

struct GameOverView: View {
    @Environment(GauntletManager.self) private var gauntlet
    @Environment(AppRouter.self)       private var router
    @AppStorage("enableNeonGlow") private var glowEnabled = true
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.synthBackground.ignoresSafeArea()
            MovingGridView()
            MatrixRainView(color: .synthPink, speedMultiplier: 2, opacityValue: 0.2)
            CRTScanlinesView()
            VStack(spacing: 28) {
                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.synthPink)
                    .symbolEffect(.bounce, value: appeared)
                    .shadow(color: glowEnabled ? Color.synthPink.opacity(0.8) : .clear, radius: 18)
                VStack(spacing: 8) {
                    Text("SYSTEM PURGED")
                        .font(.synthDisplay(36))
                        .foregroundStyle(Color.white)
                        .shadow(color: glowEnabled ? Color.synthPink.opacity(0.6) : .clear, radius: 10)
                    Text("DATA INJECTION COMPLETE")
                        .font(.synthMono(13, weight: .bold))
                        .foregroundStyle(Color.synthCyan).tracking(2)
                }
                GlassCard(borderColor: .synthYellow, cornerRadius: 16, padding: 24) {
                    VStack(spacing: 6) {
                        Text("FINAL CREDITS")
                            .font(.synthMono(11, weight: .black))
                            .foregroundStyle(Color.gray).tracking(1)
                        Text("\(gauntlet.score)")
                            .font(.synthDisplay(52))
                            .foregroundStyle(Color.synthYellow)
                            .contentTransition(.numericText())
                            .shadow(color: glowEnabled ? Color.synthYellow.opacity(0.5) : .clear, radius: 12)
                    }
                }
                VStack(spacing: 14) {
                    Button("RE-INJECT PACKET") {
                        RetroAudioEngine.shared.playJackIn(); gauntlet.retryRun()
                    }
                    .buttonStyle(CyberButtonStyle(fillColor: .synthPink))

                    Button("RETURN TO MOTHERBOARD") {
                        RetroAudioEngine.shared.playSelectionTap()
                        withAnimation(.spring(duration: 0.4)) {
                            gauntlet.gameState = .selection
                            router.currentScreen = .home
                        }
                    }
                    .buttonStyle(GhostButtonStyle(borderColor: .synthCyan))
                }
                .padding(.horizontal, 40)
            }
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.92)
            .animation(.spring(duration: 0.6, bounce: 0.2), value: appeared)
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { appeared = true } }
    }
}

// ════════════════════════════════════════════════════════════════════
// MARK: - FLASHCARD REVIEW
// ════════════════════════════════════════════════════════════════════

struct FlashcardReviewView: View {
    @Environment(GauntletManager.self) private var gauntlet
    @Environment(AppRouter.self)       private var router
    @State private var isFlipped     = false
    @State private var currentIndex  = 0
    @AppStorage("autoPlayAudio") private var autoPlayAudio = true
    @AppStorage("enableNeonGlow") private var glowEnabled  = true

    var currentWord: VocabWord {
        gauntlet.activePool.isEmpty
        ? VocabWord(kanji:"", hiragana:"エラー", meaning:"Error", category:"", subcategory:nil, level:"0")
        : gauntlet.activePool[currentIndex]
    }

    var progressFraction: Double {
        gauntlet.activePool.isEmpty ? 0
        : Double(currentIndex + 1) / Double(gauntlet.activePool.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.spring(duration: 0.4)) {
                        gauntlet.gameState = .selection; router.currentScreen = .home
                    }
                } label: {
                    Image(systemName: "house.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.synthPink)
                        .frame(width: 40, height: 40)
                        .background { Circle().fill(.ultraThinMaterial)
                            .overlay { Circle().strokeBorder(Color.synthPink.opacity(0.4), lineWidth: 1) } }
                }
                .buttonStyle(ChipButtonStyle())
                Spacer()
                Text("DATA INJECTION — R\(gauntlet.currentRound)")
                    .font(.synthDisplay(14))
                    .foregroundStyle(Color.synthCyan)
                    .shadow(color: glowEnabled ? Color.synthCyan.opacity(0.5) : .clear, radius: 5)
                Spacer()
                Circle().fill(Color.clear).frame(width: 40, height: 40)
            }
            .padding(.horizontal, 20).padding(.top, 12)

            SynthProgressBar(value: progressFraction, total: 1.0, color: .synthCyan, height: 4)
                .padding(.horizontal, 20).padding(.top, 12)
            Text("\(currentIndex + 1) of \(gauntlet.activePool.count)")
                .font(.synthMono(11, weight: .bold))
                .foregroundStyle(Color.gray).padding(.top, 6)

            Spacer()

            ZStack {
                if isFlipped {
                    GlassCard(borderColor: .synthYellow, cornerRadius: 20, padding: 30) {
                        VStack(spacing: 20) {
                            Text(currentWord.meaning)
                                .font(.synthDisplay(30))
                                .foregroundStyle(Color.synthYellow)
                                .multilineTextAlignment(.center)
                                .shadow(color: glowEnabled ? Color.synthYellow.opacity(0.6) : .clear, radius: 8)
                            Button {
                                SpeechManager.shared.speak(text: currentWord.meaning, language: "en-US")
                            } label: {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.title2).foregroundStyle(Color.synthBackground)
                                    .frame(width: 50, height: 50)
                                    .background { Circle().fill(Color.synthYellow) }
                                    .shadow(color: glowEnabled ? Color.synthYellow : .clear, radius: 10)
                            }
                            .buttonStyle(ChipButtonStyle())
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .rotation3DEffect(.degrees(180), axis: (0, 1, 0))
                } else {
                    GlassCard(borderColor: .synthCyan, cornerRadius: 20, padding: 30) {
                        VStack(spacing: 20) {
                            if !currentWord.kanji.isEmpty {
                                Text(currentWord.kanji)
                                    .font(.synthDisplay(42)).foregroundStyle(Color.white)
                                    .shadow(color: glowEnabled ? Color.white.opacity(0.4) : .clear, radius: 8)
                            }
                            Text(currentWord.hiragana)
                                .font(.synthDisplay(currentWord.kanji.isEmpty ? 42 : 26))
                                .foregroundStyle(currentWord.kanji.isEmpty ? Color.white : Color.synthCyan.opacity(0.8))
                            Button {
                                SpeechManager.shared.speak(text: currentWord.hiragana, language: "ja-JP")
                            } label: {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.title2).foregroundStyle(Color.synthBackground)
                                    .frame(width: 50, height: 50)
                                    .background { Circle().fill(Color.synthCyan) }
                                    .shadow(color: glowEnabled ? Color.synthCyan : .clear, radius: 10)
                            }
                            .buttonStyle(ChipButtonStyle())
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: 260)
            .padding(.horizontal, 24)
            .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (0, 1, 0))
            .animation(.spring(duration: 0.55, bounce: 0.15), value: isFlipped)
            .onTapGesture { withAnimation(.spring(duration: 0.55, bounce: 0.15)) { isFlipped.toggle() } }
            .gesture(DragGesture(minimumDistance: 40).onEnded { v in
                if abs(v.translation.height) > 60 {
                    withAnimation(.spring(duration: 0.5, bounce: 0.15)) { isFlipped.toggle() }
                }
            })

            Text(isFlipped ? "Tap to see reading" : "Tap to reveal meaning")
                .font(.synthMono(11)).foregroundStyle(Color.gray).padding(.top, 12)
            Spacer()

            Group {
                if isFlipped {
                    if currentIndex < gauntlet.activePool.count - 1 {
                        Button("NEXT WORD") {
                            withAnimation(.spring(duration: 0.3, bounce: 0.2)) { currentIndex += 1; isFlipped = false }
                        }
                        .buttonStyle(CyberButtonStyle(fillColor: .synthCyan, textColor: Color.synthBackground))
                    } else {
                        Button("EXECUTE SEARCH") { gauntlet.finishReviewPhase() }
                            .buttonStyle(CyberButtonStyle(fillColor: .synthPink))
                    }
                } else {
                    Button("FLIP CARD") { withAnimation(.spring(duration: 0.55, bounce: 0.15)) { isFlipped = true } }
                        .buttonStyle(GhostButtonStyle(borderColor: .synthCyan))
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 36)
            .animation(.spring(duration: 0.35), value: isFlipped)
        }
        .background(Color.synthBackground.ignoresSafeArea())
        .onAppear { if autoPlayAudio { SpeechManager.shared.speak(text: currentWord.hiragana, language: "ja-JP") } }
        .onChange(of: isFlipped) { if autoPlayAudio { SpeechManager.shared.speak(text: isFlipped ? currentWord.meaning : currentWord.hiragana, language: isFlipped ? "en-US" : "ja-JP") } }
        .onChange(of: currentIndex) { if autoPlayAudio && !isFlipped { SpeechManager.shared.speak(text: currentWord.hiragana, language: "ja-JP") } }
    }
}

// ════════════════════════════════════════════════════════════════════
// MARK: - GAME BOARD
// ════════════════════════════════════════════════════════════════════

// Grid cell appearance computed as a dedicated struct — prevents type-checker timeout
private struct GridCellAppearance {
    let fill:        Color
    let stroke:      Color
    let textColor:   Color
    let shadowColor: Color
    let isActive:    Bool

    init(index: Int, foundCellCounts: [Int: Int], revealedPath: [Int],
         selectedIndices: [Int], glowEnabled: Bool) {
        let foundCount = foundCellCounts[index, default: 0]
        let isFound    = foundCount > 0
        let isMulti    = foundCount > 1
        let isRevealed = revealedPath.contains(index)
        let isSelected = selectedIndices.contains(index)
        isActive = isRevealed || isSelected

        if isRevealed {
            fill        = Color.synthPink
            stroke      = Color.white
            textColor   = Color.synthBackground
            shadowColor = glowEnabled ? Color.synthPink : Color.clear
        } else if isSelected {
            fill        = Color.synthCyan
            stroke      = Color.synthCyan
            textColor   = Color.synthBackground
            shadowColor = glowEnabled ? Color.synthCyan : Color.clear
        } else if isMulti {
            fill        = Color.synthPink.opacity(0.3)
            stroke      = Color.synthPink.opacity(0.6)
            textColor   = Color.white
            shadowColor = Color.clear
        } else if isFound {
            fill        = Color.synthCyan.opacity(0.18)
            stroke      = Color.synthCyan.opacity(0.4)
            textColor   = Color.white
            shadowColor = Color.clear
        } else {
            fill        = Color.synthCard.opacity(0.9)
            stroke      = Color.white.opacity(0.18)
            textColor   = Color.white
            shadowColor = Color.clear
        }
    }
}

struct GameBoardView: View {
    @Environment(GauntletManager.self) private var gauntlet
    @Environment(AppRouter.self)       private var router
    @AppStorage("enableNeonGlow")  private var glowEnabled  = true
    @AppStorage("autoPlayAudio")   private var autoPlayAudio = true

    let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    @State private var gridChars:           [String]        = Array(repeating: "", count: 48)
    @State private var hasGeneratedBoard:   Bool            = false
    @State private var cellFrames:          [Int: CGRect]   = [:]
    @State private var selectedIndices:     [Int]           = []
    @State private var foundCellCounts:     [Int: Int]      = [:]
    @State private var wordPaths:           [UUID: [Int]]   = [:]
    @State private var revealedPath:        [Int]           = []
    @State private var activeSpellCheckWord: VocabWord?     = nil
    @State private var isDraggingScore:     Bool            = false
    @State private var showRevealWarning:   Bool            = false
    @State private var showSpellCheckWarning: Bool          = false
    @State private var showInsufficientCredits: Bool        = false
    @State private var insufficientMsg:     String          = ""
    @State private var pendingSpellCheckWord: VocabWord?    = nil
    @State private var isDragging:          Bool            = false
    @State private var lastTapIndex:        Int?            = nil
    @State private var lastTapTime:         Date            = Date.distantPast
    @State private var tapTrigger:          Int             = 0
    @State private var successTrigger:      Int             = 0
    @State private var errorTrigger:        Int             = 0

    var sortedGridWords: [VocabWord] {
        gauntlet.currentGridWords.sorted {
            let f0 = gauntlet.gridFoundWords.contains($0.id)
            let f1 = gauntlet.gridFoundWords.contains($1.id)
            if f0 == f1 { return false }
            return !f0
        }
    }

    var body: some View {
        ZStack {
            Color.synthBackground.ignoresSafeArea()
            SectorBackgroundView(phase: gauntlet.currentGridPhase).ignoresSafeArea()
            VStack(spacing: 0) {
                gridHeader.padding(.horizontal, 18).padding(.top, 10)
                statsRow.padding(.horizontal, 18).padding(.top, 10)
                wordChips.padding(.top, 14).padding(.bottom, 16)
                theGrid.padding(.horizontal, 14)
                Spacer(minLength: 0)
            }
            if let word = activeSpellCheckWord { spellCheckOverlay(word) }
            if showRevealWarning   { revealWarningAlert }
            if showSpellCheckWarning { spellCheckWarningAlert }
            if showInsufficientCredits {
                CyberAlertView(title: "INSUFFICIENT CREDITS", message: insufficientMsg,
                               buttonText: "ACKNOWLEDGE", alertColor: .synthPink,
                               action: { showInsufficientCredits = false })
            }
        }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: tapTrigger)
        .sensoryFeedback(.success, trigger: successTrigger)
        .sensoryFeedback(.error,   trigger: errorTrigger)
        .onAppear { if !hasGeneratedBoard { generateBoard(); hasGeneratedBoard = true } }
        .onChange(of: gauntlet.currentGridPhase) { foundCellCounts.removeAll(); generateBoard() }
    }

    // MARK: Header

    private var gridHeader: some View {
        HStack {
            Button {
                withAnimation(.spring(duration: 0.4)) {
                    gauntlet.gameState = .selection; router.currentScreen = .home
                }
            } label: {
                Image(systemName: "house.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.synthPink)
                    .frame(width: 38, height: 38)
                    .background { Circle().fill(.ultraThinMaterial)
                        .overlay { Circle().strokeBorder(Color.synthPink.opacity(0.4), lineWidth: 1) } }
            }
            .buttonStyle(ChipButtonStyle())
            Spacer()
            VStack(spacing: 2) {
                Text("PHASE \(gauntlet.currentRound)")
                    .font(.synthMono(10, weight: .black))
                    .foregroundStyle(Color.synthPurple).tracking(2)
                Text("SECTOR \(gauntlet.currentGridPhase)/\(gauntlet.chunkedGrids.count)")
                    .font(.synthDisplay(16)).foregroundStyle(Color.white)
            }
            Spacer()
            Button {
                guard gauntlet.revealHintsRemaining > 0 else { return }
                if gauntlet.score < 1000 {
                    insufficientMsg = "Red Eye Reveal requires 1000 credits."
                    showInsufficientCredits = true
                    RetroAudioEngine.shared.playError()
                } else if !gauntlet.hasSeenRevealWarningThisRun {
                    showRevealWarning = true
                    RetroAudioEngine.shared.playSelectionTap()
                } else {
                    executeReveal()
                }
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "eye.trianglebadge.exclamationmark.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(gauntlet.revealHintsRemaining > 0 ? Color.synthBackground : Color.white.opacity(0.4))
                        .frame(width: 38, height: 38)
                        .background {
                            Circle()
                                .fill(gauntlet.revealHintsRemaining > 0 ? Color.synthPink : Color.gray.opacity(0.4))
                                .shadow(color: gauntlet.revealHintsRemaining > 0 && glowEnabled ? Color.synthPink.opacity(0.7) : .clear, radius: 8)
                        }
                    if gauntlet.revealHintsRemaining > 0 {
                        Text("\(gauntlet.revealHintsRemaining)")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(Color.white)
                            .frame(width: 18, height: 18)
                            .background { Circle().fill(Color.synthBackground) }
                            .offset(x: 4, y: 4)
                    }
                }
            }
            .buttonStyle(ChipButtonStyle())
            .disabled(gauntlet.revealHintsRemaining == 0)
        }
    }

    // MARK: Stats

    private var statsRow: some View {
        HStack {
            ScoreView(score: gauntlet.score, multiplier: gauntlet.multiplier, isDraining: isDraggingScore)
                .onChange(of: gauntlet.scoreDrainTrigger) {
                    isDraggingScore = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { isDraggingScore = false }
                }
            Spacer()
            HStack(spacing: 8) {
                ForEach(["flame.fill", "hourglass"], id: \.self) { icon in
                    Image(systemName: icon).font(.system(size: 13))
                        .foregroundStyle(Color.synthCyan)
                        .frame(width: 30, height: 30)
                        .background { Circle().fill(.ultraThinMaterial)
                            .overlay { Circle().strokeBorder(Color.synthCyan.opacity(0.3), lineWidth: 1) } }
                        .shadow(color: glowEnabled ? Color.synthCyan.opacity(0.4) : .clear, radius: 4)
                }
            }
            .padding(6)
            .background { Capsule().fill(.ultraThinMaterial)
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1) } }
        }
    }

    // MARK: Word Chips

    private var wordChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(sortedGridWords) { word in
                    let isFound = gauntlet.gridFoundWords.contains(word.id)
                    Button {
                        guard !isFound else { return }
                        if gauntlet.score < 150 {
                            insufficientMsg = "Databank Query requires 150 credits."
                            showInsufficientCredits = true
                            RetroAudioEngine.shared.playError()
                        } else if !gauntlet.hasSeenSpellCheckWarningThisRun {
                            pendingSpellCheckWord = word
                            showSpellCheckWarning = true
                            RetroAudioEngine.shared.playSelectionTap()
                        } else {
                            executeSpellCheck(for: word)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if isFound {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12)).foregroundStyle(Color.synthYellow)
                            }
                            Text(word.meaning.uppercased())
                                .font(.synthMono(13, weight: .black))
                                .foregroundStyle(isFound ? Color.synthYellow : Color.synthCyan)
                                .strikethrough(isFound)
                        }
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isFound ? Color.synthYellow.opacity(0.1) : Color.synthCyan.opacity(0.08))
                                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(isFound ? Color.synthYellow.opacity(0.5) : Color.synthCyan.opacity(0.5), lineWidth: 1.5) }
                        }
                        .opacity(isFound ? 0.55 : 1.0)
                        .shadow(color: glowEnabled ? (isFound ? Color.synthYellow.opacity(0.2) : Color.synthCyan.opacity(0.2)) : .clear, radius: 6)
                    }
                    .buttonStyle(ChipButtonStyle())
                }
            }
            .padding(.horizontal, 18)
            .animation(.spring(duration: 0.4, bounce: 0.2), value: gauntlet.gridFoundWords)
        }
    }

    // MARK: Grid

    private var theGrid: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(0..<gridChars.count, id: \.self) { index in
                let app = GridCellAppearance(index: index,
                                             foundCellCounts: foundCellCounts,
                                             revealedPath: revealedPath,
                                             selectedIndices: selectedIndices,
                                             glowEnabled: glowEnabled)
                gridCell(index: index, char: gridChars[index], appearance: app)
            }
        }
        .coordinateSpace(name: "GridSpace")
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("GridSpace"))
                .onChanged { v in
                    if abs(v.translation.width) > 5 || abs(v.translation.height) > 5 { isDragging = true }
                    guard let cur = cellIndex(at: v.location) else { return }
                    if selectedIndices.isEmpty {
                        selectedIndices.append(cur); tapTrigger += 1
                    } else if let last = selectedIndices.last, cur != last {
                        let cols = 6
                        let (lr, lc) = (last/cols, last%cols)
                        let (cr, cc) = (cur/cols,  cur%cols)
                        if selectedIndices.count >= 2 && selectedIndices[selectedIndices.count-2] == cur {
                            selectedIndices.removeLast(); tapTrigger += 1
                        } else if !selectedIndices.contains(cur) && abs(lr-cr) <= 1 && abs(lc-cc) <= 1 {
                            selectedIndices.append(cur); tapTrigger += 1
                        } else if !isDragging {
                            selectedIndices = [cur]; tapTrigger += 1
                        }
                    }
                    RetroAudioEngine.shared.playGridTone(index: selectedIndices.count - 1)
                }
                .onEnded { v in
                    if isDragging { checkSelectedWord(); isDragging = false }
                    else if let cur = cellIndex(at: v.location), let last = selectedIndices.last, cur == last {
                        let now = Date()
                        if cur == lastTapIndex && now.timeIntervalSince(lastTapTime) < 0.5 {
                            checkSelectedWord(); lastTapIndex = nil
                        } else { lastTapIndex = cur; lastTapTime = now }
                    }
                }
        )
    }

    @ViewBuilder
    private func gridCell(index: Int, char: String, appearance: GridCellAppearance) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(appearance.fill)
                .aspectRatio(1, contentMode: .fit)
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(appearance.stroke, lineWidth: appearance.isActive ? 2 : 1) }
                .shadow(color: appearance.shadowColor, radius: 8)
                .scaleEffect(appearance.isActive ? 1.06 : 1.0)
                .animation(.spring(duration: 0.2, bounce: 0.4), value: appearance.isActive)
            Text(char)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(appearance.textColor)
        }
        .background {
            GeometryReader { geo in
                Color.clear.onAppear {
                    DispatchQueue.main.async { cellFrames[index] = geo.frame(in: .named("GridSpace")) }
                }
            }
        }
    }

    // MARK: Overlays

    private func spellCheckOverlay(_ word: VocabWord) -> some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                .background(Color.black.opacity(0.75).ignoresSafeArea())
                .onTapGesture { withAnimation(.spring(duration: 0.3)) { activeSpellCheckWord = nil } }
            GlassCard(borderColor: .synthCyan, cornerRadius: 20, padding: 28) {
                VStack(spacing: 20) {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.system(size: 48)).foregroundStyle(Color.synthCyan)
                        .symbolEffect(.bounce, value: true)
                        .shadow(color: glowEnabled ? Color.synthCyan.opacity(0.7) : .clear, radius: 12)
                    Text("DATABANK QUERY")
                        .font(.synthMono(11, weight: .black)).foregroundStyle(Color.synthCyan).tracking(2)
                    VStack(spacing: 10) {
                        Text(word.kanji.isEmpty ? word.hiragana : word.kanji)
                            .font(.synthDisplay(48)).foregroundStyle(Color.white)
                        if !word.kanji.isEmpty {
                            Text(word.hiragana).font(.synthDisplay(22)).foregroundStyle(Color.gray)
                        }
                        Text(word.meaning.uppercased()).font(.synthDisplay(18)).foregroundStyle(Color.synthYellow).padding(.top, 6)
                    }
                    Button("CLOSE") { withAnimation(.spring(duration: 0.3)) { activeSpellCheckWord = nil } }
                        .buttonStyle(GhostButtonStyle())
                }
            }
            .padding(.horizontal, 36)
        }
        .transition(.scale(scale: 0.88).combined(with: .opacity))
        .zIndex(90)
    }

    private var revealWarningAlert: some View {
        CyberAlertView(title: "RED EYE REVEAL",
                       message: "Highlights the path of a random unfound word for 2 seconds.\n\nCOST: 1000 CREDITS",
                       buttonText: "EXECUTE", alertColor: .synthPink,
                       action: { gauntlet.hasSeenRevealWarningThisRun = true; showRevealWarning = false; executeReveal() },
                       cancelAction: { showRevealWarning = false })
    }

    private var spellCheckWarningAlert: some View {
        CyberAlertView(title: "DATABANK QUERY",
                       message: "Displays the flashcard for the selected word.\nLocation not revealed.\n\nCOST: 150 CREDITS",
                       buttonText: "EXECUTE", alertColor: .synthCyan,
                       action: {
                           gauntlet.hasSeenSpellCheckWarningThisRun = true
                           showSpellCheckWarning = false
                           if let w = pendingSpellCheckWord { executeSpellCheck(for: w); pendingSpellCheckWord = nil }
                       },
                       cancelAction: { showSpellCheckWarning = false; pendingSpellCheckWord = nil })
    }

    // MARK: Game Logic

    private func executeReveal() {
        let unfound = gauntlet.currentGridWords.filter { !gauntlet.gridFoundWords.contains($0.id) }
        guard let rw = unfound.randomElement(), let path = wordPaths[rw.id] else { return }
        gauntlet.revealHintsRemaining -= 1; gauntlet.score -= 1000
        gauntlet.scoreDrainTrigger = UUID(); RetroAudioEngine.shared.playScoreDrain()
        withAnimation(.spring(duration: 0.4)) { revealedPath = path }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { withAnimation { revealedPath = [] } }
    }

    private func executeSpellCheck(for word: VocabWord) {
        gauntlet.score -= 150; gauntlet.scoreDrainTrigger = UUID()
        RetroAudioEngine.shared.playScoreDrain(); RetroAudioEngine.shared.playSelectionTap()
        SpeechManager.shared.speak(text: word.hiragana, language: "ja-JP")
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { activeSpellCheckWord = word }
    }

    private func cellIndex(at location: CGPoint) -> Int? {
        cellFrames.first { $0.value.contains(location) }?.key
    }

    private func checkSelectedWord() {
        let chars = selectedIndices.map { gridChars[$0] }.joined()
        if let m = gauntlet.currentGridWords.first(where: {
            !gauntlet.gridFoundWords.contains($0.id) &&
            (chars == $0.hiragana || chars == String($0.hiragana.reversed()))
        }) {
            RetroAudioEngine.shared.playSuccess(); successTrigger += 1
            if autoPlayAudio { SpeechManager.shared.speak(text: m.hiragana, language: "ja-JP") }
            for idx in selectedIndices { foundCellCounts[idx, default: 0] += 1 }
            selectedIndices = []
            gauntlet.processGridWordFound(m)
        } else {
            RetroAudioEngine.shared.playError(); errorTrigger += 1
            gauntlet.multiplier = 1.0; gauntlet.score -= 25
            withAnimation(.spring(duration: 0.2, bounce: 0.6)) { selectedIndices = [] }
        }
    }

    private func generateBoard() {
        var grid  = Array(repeating: "", count: 48)
        var paths = [UUID: [Int]]()
        var placed = false
        let hiragana = Array("あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん")
                            .map(String.init)
        while !placed {
            grid = Array(repeating: "", count: 48); paths.removeAll(); placed = true
            for word in gauntlet.currentGridWords {
                let chars = Array(word.hiragana).map(String.init)
                var ok = false; var att = 0
                while !ok && att < 200 {
                    var tmp = grid
                    let sr = Int.random(in: 0..<8), sc = Int.random(in: 0..<6)
                    if let p = placeWord(chars, 0, sr, sc, &tmp, 8, 6, []) {
                        grid = tmp; paths[word.id] = p; ok = true
                    }
                    att += 1
                }
                if !ok { placed = false; break }
            }
        }
        for i in 0..<48 { if grid[i].isEmpty { grid[i] = hiragana.randomElement()! } }
        gridChars = grid; wordPaths = paths
    }

    private func placeWord(_ chars: [String], _ idx: Int, _ r: Int, _ c: Int,
                            _ grid: inout [String], _ rows: Int, _ cols: Int,
                            _ path: [Int]) -> [Int]? {
        guard r >= 0, r < rows, c >= 0, c < cols else { return nil }
        let ci = r*cols+c
        if !grid[ci].isEmpty && grid[ci] != chars[idx] { return nil }
        if path.contains(ci) { return nil }
        let prev = grid[ci]; grid[ci] = chars[idx]
        let cur  = path + [ci]
        if idx == chars.count-1 { return cur }
        for d in [(-1,-1),(-1,0),(-1,1),(0,-1),(0,1),(1,-1),(1,0),(1,1)].shuffled() {
            if let p = placeWord(chars, idx+1, r+d.0, c+d.1, &grid, rows, cols, cur) { return p }
        }
        grid[ci] = prev; return nil
    }
}

// ════════════════════════════════════════════════════════════════════
// MARK: - BOSS FIGHT
// ════════════════════════════════════════════════════════════════════
// NOTE: All @State on separate lines — fixes "property wrapper single variable"
// NOTE: import Combine at top fixes Timer.publish autoconnect

struct BossFightQuizView: View {
    @Environment(GauntletManager.self) private var gauntlet
    @Environment(AppRouter.self)       private var router
    @AppStorage("enableNeonGlow") private var glowEnabled = true

    @State private var bossHealth:     Double       = 100.0
    @State private var playerHealth:   Double       = 100.0
    @State private var timeElapsed:    TimeInterval = 0
    @State private var lastPenalty:    TimeInterval = 0
    @State private var isDraining:     Bool         = false
    @State private var currentOptions: [String]     = []
    @State private var selectedOption: String?      = nil
    @State private var answerResult:   Bool?        = nil
    @State private var pulse:          Bool         = false

    let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var damagePerQ: Double { let ps = Double(gauntlet.cumulativePool.count); return ps > 0 ? 100.0/ps : 100.0 }

    var formattedTime: String {
        let m  = Int(timeElapsed) / 60
        let s  = Int(timeElapsed) % 60
        let ms = Int(timeElapsed.truncatingRemainder(dividingBy: 1) * 100)
        return String(format: "%02d:%02d.%02d", m, s, ms)
    }

    var body: some View {
        ZStack {
            Color.synthBackground.ignoresSafeArea()
            MatrixRainView(color: .synthPink, speedMultiplier: 2.5, opacityValue: 0.45)
            Color.synthPink.opacity(pulse ? 0.08 : 0.03).ignoresSafeArea()
                .animation(.easeInOut(duration: 1.5).repeatForever(), value: pulse)

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Button {
                        withAnimation(.spring(duration: 0.4)) {
                            gauntlet.gameState = .selection; router.currentScreen = .home
                        }
                    } label: {
                        Image(systemName: "house.fill").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.white).frame(width: 38, height: 38)
                            .background { Circle().fill(.ultraThinMaterial)
                                .overlay { Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1) } }
                    }
                    .buttonStyle(ChipButtonStyle())
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        ScoreView(score: gauntlet.score, multiplier: gauntlet.multiplier, isDraining: isDraining)
                            .onChange(of: gauntlet.scoreDrainTrigger) {
                                isDraining = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { isDraining = false }
                            }
                        Text(formattedTime)
                            .font(.synthDisplay(16))
                            .foregroundStyle(Color.synthPink)
                            .contentTransition(.numericText())
                            .shadow(color: glowEnabled ? Color.synthPink.opacity(0.5) : .clear, radius: 5)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12)

                if let q = gauntlet.currentQuizQuestion {
                    VStack(spacing: 10) {
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 70))
                            .foregroundStyle(Color.synthPink)
                            .symbolEffect(.bounce.byLayer, value: pulse)
                            .shadow(color: glowEnabled ? Color.synthPink.opacity(0.8) : .clear, radius: 20)
                            .padding(.top, 14)
                        Text("SYSTEM OVERRIDE — LEVEL \(gauntlet.currentRound)")
                            .font(.synthDisplay(13)).foregroundStyle(Color.white)
                        SynthProgressBar(value: max(0, bossHealth), total: 100, color: .synthPink, height: 8)
                            .padding(.horizontal, 40)
                    }
                    Spacer()
                    GlassCard(borderColor: .synthPink, cornerRadius: 20, padding: 24) {
                        VStack(spacing: 16) {
                            Text("NODES REMAINING: \(gauntlet.bossQuizQueue.count + 1)")
                                .font(.synthMono(11, weight: .black))
                                .foregroundStyle(Color.synthPink.opacity(0.7)).tracking(1)
                            Text(q.hiragana)
                                .font(.synthDisplay(44)).foregroundStyle(Color.white)
                                .shadow(color: glowEnabled ? Color.white.opacity(0.4) : .clear, radius: 10)
                                .contentTransition(.opacity)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 20)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(currentOptions, id: \.self) { opt in
                            optionButton(opt: opt, question: q)
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 18)
                    Spacer()
                    VStack(spacing: 8) {
                        Text("RUNNER INTEGRITY")
                            .font(.synthMono(10, weight: .black))
                            .foregroundStyle(Color.synthCyan.opacity(0.7)).tracking(2)
                        SynthProgressBar(value: max(0, playerHealth), total: 100, color: .synthCyan, height: 8)
                            .padding(.horizontal, 40)
                    }
                    .padding(.bottom, 36)
                }
            }
        }
        .onAppear {
            pulse = true
            if let w = gauntlet.currentQuizQuestion { currentOptions = generateOptions(for: w) }
        }
        .onChange(of: gauntlet.currentQuizQuestion) {
            if let w = gauntlet.currentQuizQuestion { currentOptions = generateOptions(for: w) }
        }
        .onReceive(timer) { _ in
            guard gauntlet.gameState == .boss, gauntlet.currentQuizQuestion != nil else { return }
            timeElapsed += 0.05
            if timeElapsed - lastPenalty >= 3.0 {
                lastPenalty += 3.0; gauntlet.score -= 15
                gauntlet.scoreDrainTrigger = UUID(); RetroAudioEngine.shared.playScoreDrain()
            }
        }
    }

    @ViewBuilder
    private func optionButton(opt: String, question: VocabWord) -> some View {
        let isCorrect    = opt == question.meaning
        let wasSelected  = selectedOption == opt
        let showResult   = answerResult != nil && wasSelected
        let resultIsGood = answerResult == true

        Button {
            guard selectedOption == nil else { return }
            selectedOption = opt; answerResult = isCorrect
            if isCorrect { withAnimation { bossHealth -= damagePerQ }; RetroAudioEngine.shared.playEnemyHit() }
            else         { withAnimation { playerHealth -= damagePerQ }; RetroAudioEngine.shared.playPlayerHit() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                gauntlet.processQuizAnswer(correct: isCorrect)
                selectedOption = nil; answerResult = nil
            }
        } label: {
            Text(opt.uppercased())
                .font(.synthDisplay(13))
                .foregroundStyle(optionTextColor(showResult: showResult, resultIsGood: resultIsGood))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16).padding(.horizontal, 10)
                .background { optionBackground(showResult: showResult, resultIsGood: resultIsGood) }
                .shadow(color: glowEnabled && showResult
                        ? (resultIsGood ? Color.synthGreen.opacity(0.5) : Color.synthPink.opacity(0.5))
                        : .clear, radius: 10)
                .scaleEffect(showResult ? 1.02 : 1.0)
                .animation(.spring(duration: 0.25, bounce: 0.3), value: showResult)
        }
        .buttonStyle(ChipButtonStyle())
        .disabled(selectedOption != nil)
    }

    private func optionTextColor(showResult: Bool, resultIsGood: Bool) -> Color {
        if showResult { return resultIsGood ? Color.synthBackground : Color.white }
        return selectedOption == nil ? Color.synthCyan : Color.synthCyan.opacity(0.4)
    }

    @ViewBuilder
    private func optionBackground(showResult: Bool, resultIsGood: Bool) -> some View {
        let bg: Color = showResult ? (resultIsGood ? Color.synthGreen : Color.synthPink) : Color.clear
        let border: Color = showResult ? (resultIsGood ? Color.synthGreen : Color.synthPink) : Color.synthCyan.opacity(0.4)
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(bg)
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(showResult ? Color.clear : Color.synthCard.opacity(0.7)) }
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(border, lineWidth: 1.5) }
    }

    private func generateOptions(for word: VocabWord) -> [String] {
        var opts = [word.meaning]
        var pool = DataLoader.shared.allVocab.filter { $0.id != word.id }.shuffled()
        if pool.isEmpty {
            pool = [
                VocabWord(kanji:"",hiragana:"",meaning:"Fake 1",category:"",subcategory:nil,level:"0"),
                VocabWord(kanji:"",hiragana:"",meaning:"Fake 2",category:"",subcategory:nil,level:"0"),
                VocabWord(kanji:"",hiragana:"",meaning:"Fake 3",category:"",subcategory:nil,level:"0")
            ]
        }
        while opts.count < 4, !pool.isEmpty { opts.append(pool.removeFirst().meaning) }
        return opts.shuffled()
    }
}

// ════════════════════════════════════════════════════════════════════
// MARK: - SETTINGS
// ════════════════════════════════════════════════════════════════════

struct SettingsView: View {
    @Environment(AppRouter.self) private var router

    @AppStorage("enableNeonGlow")    private var enableNeonGlow   = true
    @AppStorage("autoPlayAudio")     private var autoPlayAudio    = true
    @AppStorage("vocabAudioVolume")  private var vocabAudioVolume = 1.0
    @AppStorage("sfxEnabled")        private var sfxEnabled       = true
    @AppStorage("sfxVolume")         private var sfxVolume        = 0.8
    @AppStorage("bgmEnabled")        private var bgmEnabled       = true
    @AppStorage("bgmVolume")         private var bgmVolume        = 0.3
    @AppStorage("bgmMotherboard")    private var bgmMotherboard   = "motherboard"
    @AppStorage("bgmPhase1")         private var bgmPhase1        = "Mydoom"
    @AppStorage("bgmPhase2")         private var bgmPhase2        = "DDoS"
    @AppStorage("bgmPhase3")         private var bgmPhase3        = "Man in the Middle"
    @AppStorage("bgmPhase4")         private var bgmPhase4        = "Backdoor"
    @AppStorage("bgmBoss1")          private var bgmBoss1         = "ILOVEYOU"
    @AppStorage("bgmBoss2")          private var bgmBoss2         = "Logic Bomb"
    @AppStorage("bgmBoss3")          private var bgmBoss3         = "Boot Sector Virus"
    @AppStorage("bgmBoss4")          private var bgmBoss4         = "Firewall"

    var body: some View {
        ZStack {
            Color.synthBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button {
                        RetroAudioEngine.shared.playSelectionTap()
                        withAnimation(.spring(duration: 0.4)) { router.currentScreen = .home }
                    } label: {
                        Label("HOME", systemImage: "house.fill")
                            .font(.synthDisplay(14))
                            .foregroundStyle(Color.synthPink)
                    }
                    .buttonStyle(ChipButtonStyle())
                    Spacer()
                }
                .padding(.horizontal, 24).padding(.top, 12)

                VStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 52))
                        .foregroundStyle(Color.synthCyan)
                        .symbolEffect(.bounce, value: true)
                        .shadow(color: enableNeonGlow ? Color.synthCyan : .clear, radius: 12)
                    Text("SYSTEM SETTINGS")
                        .font(.synthDisplay(26))
                        .foregroundStyle(Color.white)
                }
                .padding(.bottom, 18)

                ScrollView {
                    VStack(spacing: 20) {
                        settingsSection(title: "AUDIO MIXER", icon: "waveform") {
                            Toggle("Vocab Audio (Auto-Play)", isOn: $autoPlayAudio).styledToggle()
                            VolumeSlider(value: $vocabAudioVolume)
                            Divider().background(Color.white.opacity(0.08))
                            Toggle("Sound Effects (SFX)", isOn: $sfxEnabled).styledToggle()
                            if sfxEnabled { VolumeSlider(value: $sfxVolume) }
                            Divider().background(Color.white.opacity(0.08))
                            Toggle("Background Music (BGM)", isOn: $bgmEnabled).styledToggle()
                                .onChange(of: bgmEnabled) { BGMManager.shared.updateVolume() }
                            if bgmEnabled {
                                VolumeSlider(value: $bgmVolume)
                                    .onChange(of: bgmVolume) { BGMManager.shared.updateVolume() }
                            }
                            Button("RESET DEFAULT VOLUMES") {
                                RetroAudioEngine.shared.playSelectionTap()
                                withAnimation {
                                    vocabAudioVolume = 1.0; sfxEnabled = true; sfxVolume = 0.8
                                    bgmEnabled = true; bgmVolume = 0.3
                                    BGMManager.shared.updateVolume()
                                }
                            }
                            .font(.synthMono(12, weight: .bold))
                            .foregroundStyle(Color.synthYellow)
                            .padding(.top, 4)
                        }

                        settingsSection(title: "BGM PROTOCOLS", icon: "music.note.list") {
                            BGMRow(title: "Motherboard",      selection: $bgmMotherboard)
                            Divider().background(Color.white.opacity(0.08))
                            BGMRow(title: "Phase 1 Grid",     selection: $bgmPhase1)
                            BGMRow(title: "Phase 2 Grid",     selection: $bgmPhase2)
                            BGMRow(title: "Phase 3 Grid",     selection: $bgmPhase3)
                            BGMRow(title: "Phase 4 Grid",     selection: $bgmPhase4)
                            Divider().background(Color.white.opacity(0.08))
                            BGMRow(title: "Override (Boss 1)", selection: $bgmBoss1)
                            BGMRow(title: "Override (Boss 2)", selection: $bgmBoss2)
                            BGMRow(title: "Override (Boss 3)", selection: $bgmBoss3)
                            BGMRow(title: "Override (Boss 4)", selection: $bgmBoss4)
                        }

                        settingsSection(title: "VISUALS", icon: "sparkles") {
                            Toggle("Neon Glow FX", isOn: $enableNeonGlow).styledToggle()
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 48)
                }
            }
        }
    }

    private func settingsSection<C: View>(title: String, icon: String,
                                          @ViewBuilder content: () -> C) -> some View {
        GlassCard(borderColor: .synthPurple, borderWidth: 1, cornerRadius: 14, padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                Label(title, systemImage: icon)
                    .font(.synthMono(11, weight: .black))
                    .foregroundStyle(Color.synthPink).tracking(1)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct VolumeSlider: View {
    @Binding var value: Double
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").foregroundStyle(Color.synthCyan).font(.system(size: 13))
            Slider(value: $value, in: 0...1).tint(.synthCyan)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(Color.synthCyan).font(.system(size: 13))
        }
    }
}

extension View {
    func styledToggle() -> some View {
        self.font(.synthDisplay(14)).tint(.synthPink).foregroundStyle(Color.white)
    }
}

struct BGMRow: View {
    var title:     String
    @Binding var selection: String
    var body: some View {
        HStack {
            Text(title).font(.synthMono(13, weight: .bold)).foregroundStyle(Color.white)
            Spacer()
            Picker("", selection: $selection) {
                ForEach(BGMManager.shared.availableTracks, id: \.self) { Text($0).tag($0) }
            }
            .tint(.synthCyan)
            .onChange(of: selection) { BGMManager.shared.playTrack(named: selection) }
        }
    }
}
