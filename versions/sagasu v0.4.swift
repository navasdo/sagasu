import SwiftUI
import Combine
import AVFoundation

// MARK: - Theme Colors (Outrun / Synthwave)
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let int = UInt64(hex, radix: 16) ?? 0
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, ((int >> 4) & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue:  Double(b) / 255.0,
            opacity: Double(a) / 255.0
        )
    }

    static let synthBackground = Color(hex: "0D0221")
    static let synthCard = Color(hex: "241734")
    static let synthCyan = Color(hex: "2DE2E6")
    static let synthPink = Color(hex: "F6019D")
    static let synthPurple = Color(hex: "920075")
    static let synthOrange = Color(hex: "FF6C11")
    static let synthYellow = Color(hex: "F9C80E")
}

// MARK: - Enums & Settings
enum KanaMode {
    case hiragana, kanji, furigana
}

enum BoonTier: String {
    case common = "Common"
    case uncommon = "Uncommon"
    case rare = "Rare"
    case epic = "Epic"
    
    var color: Color {
        switch self {
        case .common: return .synthOrange
        case .uncommon: return .synthCyan
        case .rare: return .synthPurple
        case .epic: return .synthPink
        }
    }
}

enum GameState {
    case selection
    case review
    case gridTransition
    case grid
    case bossTransition
    case boss
    case roundComplete
    case gameOver
}

// MARK: - Bulletproof Audio Synth Engine (Pre-Cached & Haptic)
class RetroAudioEngine: NSObject {
    static let shared = RetroAudioEngine()
    
    private var tonePlayers: [AVAudioPlayer] = []
    private var successPlayer: AVAudioPlayer?
    private var errorPlayer: AVAudioPlayer?
    private var enemyHitPlayer: AVAudioPlayer?
    private var playerHitPlayer: AVAudioPlayer?
    
    private var jackInPlayer: AVAudioPlayer?
    private var bossWarningPlayer: AVAudioPlayer?
    
    // NEW: Menu Navigation Player
    private var selectionPlayer: AVAudioPlayer?
    
    private let tapHaptic = UIImpactFeedbackGenerator(style: .light)
    private let notificationHaptic = UINotificationFeedbackGenerator()
    
    override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        
        DispatchQueue.global(qos: .userInitiated).async {
            self.precompileSounds()
        }
    }
    
    enum WaveType { case square, sawtooth }
    
    private func precompileSounds() {
        let freqs: [Float] = [261.63, 293.66, 329.63, 392.00, 440.00, 523.25, 587.33, 659.25, 783.99, 880.00]
        for freq in freqs {
            if let data = generateSequenceWavData(freqs: [freq], type: .square, noteDuration: 0.15, volume: 0.1) {
                if let player = try? AVAudioPlayer(data: data) {
                    player.prepareToPlay()
                    tonePlayers.append(player)
                }
            }
        }
        
        if let data = generateSequenceWavData(freqs: [523.25, 659.25, 783.99, 1046.50], type: .square, noteDuration: 0.08, volume: 0.15) {
            successPlayer = try? AVAudioPlayer(data: data)
            successPlayer?.prepareToPlay()
        }
        
        if let data = generateSequenceWavData(freqs: [164.81, 130.81], type: .sawtooth, noteDuration: 0.2, volume: 0.15) {
            errorPlayer = try? AVAudioPlayer(data: data)
            errorPlayer?.prepareToPlay()
        }
        
        if let data = generateSequenceWavData(freqs: [1046.50, 880.00, 523.25], type: .square, noteDuration: 0.06, volume: 0.15) {
            enemyHitPlayer = try? AVAudioPlayer(data: data)
            enemyHitPlayer?.prepareToPlay()
        }
        
        if let data = generateSequenceWavData(freqs: [110.0, 73.42, 55.0], type: .sawtooth, noteDuration: 0.12, volume: 0.2) {
            playerHitPlayer = try? AVAudioPlayer(data: data)
            playerHitPlayer?.prepareToPlay()
        }
        
        if let data = generateSequenceWavData(freqs: [220.0, 330.0, 440.0, 660.0, 880.0, 1320.0, 1760.0, 2640.0], type: .square, noteDuration: 0.05, volume: 0.15) {
            jackInPlayer = try? AVAudioPlayer(data: data)
            jackInPlayer?.prepareToPlay()
        }
        
        if let data = generateSequenceWavData(freqs: [440.0, 660.0, 440.0, 660.0, 440.0, 660.0, 440.0, 660.0], type: .square, noteDuration: 0.15, volume: 0.2) {
            bossWarningPlayer = try? AVAudioPlayer(data: data)
            bossWarningPlayer?.prepareToPlay()
        }
        
        // Quick two-note ascending blip for menu taps
        if let data = generateSequenceWavData(freqs: [880.0, 1108.73], type: .square, noteDuration: 0.05, volume: 0.1) {
            selectionPlayer = try? AVAudioPlayer(data: data)
            selectionPlayer?.prepareToPlay()
        }
    }
    
    func playGridTone(index: Int) {
        DispatchQueue.main.async { self.tapHaptic.impactOccurred() }
        guard !tonePlayers.isEmpty else { return }
        let safeIndex = max(0, min(index, tonePlayers.count - 1))
        tonePlayers[safeIndex].currentTime = 0
        tonePlayers[safeIndex].play()
    }
    
    func playSuccess() {
        DispatchQueue.main.async { self.notificationHaptic.notificationOccurred(.success) }
        successPlayer?.currentTime = 0
        successPlayer?.play()
    }
    
    func playError() {
        DispatchQueue.main.async { self.notificationHaptic.notificationOccurred(.error) }
        errorPlayer?.currentTime = 0
        errorPlayer?.play()
    }
    
    func playEnemyHit() {
        enemyHitPlayer?.currentTime = 0
        enemyHitPlayer?.play()
    }
    
    func playPlayerHit() {
        DispatchQueue.main.async { self.notificationHaptic.notificationOccurred(.warning) }
        playerHitPlayer?.currentTime = 0
        playerHitPlayer?.play()
    }
    
    func playJackIn() {
        jackInPlayer?.currentTime = 0
        jackInPlayer?.play()
    }
    
    func playBossWarning() {
        bossWarningPlayer?.currentTime = 0
        bossWarningPlayer?.play()
    }
    
    func playSelectionTap() {
        DispatchQueue.main.async { self.tapHaptic.impactOccurred() }
        selectionPlayer?.currentTime = 0
        selectionPlayer?.play()
    }
    
    private func generateSequenceWavData(freqs: [Float], type: WaveType, noteDuration: TimeInterval, volume: Float) -> Data? {
        let sampleRate: Int32 = 44100
        let framesPerNote = Int(Double(sampleRate) * noteDuration)
        let totalFrames = framesPerNote * freqs.count
        
        if totalFrames == 0 { return nil }
        
        var pcmData = [Int16](repeating: 0, count: totalFrames)
        
        for (noteIndex, freq) in freqs.enumerated() {
            let offset = noteIndex * framesPerNote
            for i in 0..<framesPerNote {
                let time = Float(i) / Float(sampleRate)
                let envelope = exp(-6.0 * Float(i) / Float(framesPerNote))
                
                var sample: Float = 0
                switch type {
                case .square:
                    sample = sin(2.0 * Float.pi * freq * time) > 0 ? volume : -volume
                case .sawtooth:
                    sample = (2.0 * (time * freq - floor(time * freq + 0.5))) * volume
                }
                
                pcmData[offset + i] = Int16(max(-1.0, min(1.0, sample * envelope)) * 32767.0)
            }
        }
        return createWavFile(pcmData: pcmData, sampleRate: sampleRate)
    }
    
    private func createWavFile(pcmData: [Int16], sampleRate: Int32) -> Data {
        let dataSize = Int32(pcmData.count * 2)
        let fileSize = dataSize + 36
        var data = Data()
        
        data.append(contentsOf: "RIFF".utf8)
        var fs = fileSize; data.append(Data(bytes: &fs, count: MemoryLayout.size(ofValue: fs)))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        
        var fmtSize: Int32 = 16; data.append(Data(bytes: &fmtSize, count: MemoryLayout.size(ofValue: fmtSize)))
        var format: Int16 = 1; data.append(Data(bytes: &format, count: MemoryLayout.size(ofValue: format)))
        var channels: Int16 = 1; data.append(Data(bytes: &channels, count: MemoryLayout.size(ofValue: channels)))
        var sRate = sampleRate; data.append(Data(bytes: &sRate, count: MemoryLayout.size(ofValue: sRate)))
        var byteRate = sampleRate * 2; data.append(Data(bytes: &byteRate, count: MemoryLayout.size(ofValue: byteRate)))
        var blockAlign: Int16 = 2; data.append(Data(bytes: &blockAlign, count: MemoryLayout.size(ofValue: blockAlign)))
        var bitsPerSample: Int16 = 16; data.append(Data(bytes: &bitsPerSample, count: MemoryLayout.size(ofValue: bitsPerSample)))
        
        data.append(contentsOf: "data".utf8)
        var dSize = dataSize; data.append(Data(bytes: &dSize, count: MemoryLayout.size(ofValue: dSize)))
        
        data.append(pcmData.withUnsafeBufferPointer { Data(buffer: $0) })
        return data
    }
}

// MARK: - Speech Manager
class SpeechManager {
    static let shared = SpeechManager()
    private let synthesizer = AVSpeechSynthesizer()
    
    func isPremiumJapaneseVoiceAvailable() -> Bool {
        let availableVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "ja-JP" }
        return availableVoices.contains { $0.quality == .enhanced || $0.quality == .premium }
    }
    
    func speak(text: String, language: String) {
        let utterance = AVSpeechUtterance(string: text)
        let availableVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        
        if let bestVoice = availableVoices.max(by: { $0.quality.rawValue < $1.quality.rawValue }) {
            utterance.voice = bestVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        
        if language == "ja-JP" {
            utterance.rate = 0.45
        } else {
            utterance.rate = 0.5
        }
        
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }
}

// MARK: - Models
struct PlayerProfile {
    var level: Int = 1
    var xp: Int = 0
    var dailyStreak: Int = 3
    var score: Int = 1250
    var health: Int = 100
}

struct Boon: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let flavorText: String
    let tier: BoonTier
    let icon: String
}

// MARK: UPDATED: Codable VocabWord matches JSON schema perfectly
struct VocabWord: Identifiable, Codable, Equatable {
    var id = UUID() // Generated automatically so it doesn't need to be in the JSON
    let kanji: String
    let hiragana: String
    let meaning: String
    let category: String
    let subcategory: String? // Optional in case some words don't have it
    let level: String // Changed to String since the JSON has "5" in quotes
    
    // Maps your exact capitalized JSON keys to the Swift variables
    enum CodingKeys: String, CodingKey {
        case kanji = "Kanji"
        case hiragana = "Hiragana"
        case meaning = "Meaning"
        case category = "Category"
        case subcategory = "Subcategory"
        case level = "Level"
    }
}

// MARK: - NEW: Data Loader (Reads JSON from App Bundle)
class DataLoader {
    static let shared = DataLoader()
    var allVocab: [VocabWord] = []
    
    private init() {
        loadVocabFromJSON()
    }
    
    private func loadVocabFromJSON() {
        guard let url = Bundle.main.url(forResource: "jlpt_vocab", withExtension: "json") else {
            print("⚠️ Error: Could not find jlpt_vocab.json in the app bundle.")
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            allVocab = try decoder.decode([VocabWord].self, from: data)
            print("✅ Successfully loaded \(allVocab.count) words from JSON!")
        } catch {
            print("❌ Error parsing JSON data: \(error)")
        }
    }
    
    // Grabs words matching the specific level (and optional category)
    func getWords(for level: Int, category: String? = nil, subcategory: String? = nil) -> [VocabWord] {
        return allVocab.filter { word in
            let matchesLevel = word.level == String(level)
            let matchesCategory = category == nil || word.category == category
            let matchesSubcategory = subcategory == nil || subcategory == "General" || word.subcategory == subcategory
            return matchesLevel && matchesCategory && matchesSubcategory
        }
    }
    
    // Grabs unique categories available for a specific level
    func getCategories(for level: Int) -> [String] {
        let words = allVocab.filter { $0.level == String(level) }
        let categories = Array(Set(words.map { $0.category })).sorted()
        // Provide mock categories if JSON is missing or empty
        return categories.isEmpty ? ["Time, Dates, and Counters", "People and Communication", "The Physical World: Nature and Places", "Daily Objects and Lifestyle", "Actions (Verbs)", "Descriptors (Adjectives)", "Particles and Connectors"] : categories
    }
    
    // Grabs unique subcategories for a specific level and category combination
    func getSubcategories(for level: Int, category: String) -> [String] {
        let words = allVocab.filter { $0.level == String(level) && $0.category == category }
        let subcategories = Array(Set(words.compactMap { $0.subcategory })).filter { !$0.isEmpty }.sorted()
        // Provide a default if no subcategories are found for the selection
        return subcategories.isEmpty ? ["General"] : subcategories
    }
}

// MARK: - Logic Handler: Gauntlet Manager
class GauntletManager: ObservableObject {
    @Published var gameState: GameState = .selection
    @Published var currentRound: Int = 1
    let maxRounds: Int = 4
    
    @Published var availableVocab: [VocabWord] = [] // Words loaded from JSON for the run
    @Published var activePool: [VocabWord] = [] // The current 5 words being learned
    @Published var cumulativePool: [VocabWord] = [] // All words collected for the Boss Fight
    
    @Published var currentGridPhase: Int = 1
    @Published var chunkedGrids: [[VocabWord]] = []
    @Published var currentGridWords: [VocabWord] = []
    @Published var gridFoundWords: Set<UUID> = []
    
    @Published var bossQuizQueue: [VocabWord] = []
    @Published var currentQuizQuestion: VocabWord? = nil
    
    @Published var score: Int = 0
    @Published var multiplier: Double = 1.0
    
    // Forces the NavigationStack in the menu to reset to root when finishing a run
    @Published var navigationResetID = UUID()
    
    func startGauntlet(level: Int = 5, category: String? = nil, subcategory: String? = nil) {
        currentRound = 1
        cumulativePool = []
        score = 0
        multiplier = 1.0
        navigationResetID = UUID() // Resets the navigation router
        
        // Fetch words from our new JSON DataLoader
        let words = DataLoader.shared.getWords(for: level, category: category, subcategory: subcategory)
        
        // Fallback safety in case the JSON isn't linked correctly during testing
        if words.isEmpty {
            print("⚠️ WARNING: No words found in JSON. Using fallback data.")
            availableVocab = [
                VocabWord(kanji: "朝", hiragana: "あさ", meaning: "Morning", category: "Time", subcategory: nil, level: "5"),
                VocabWord(kanji: "先生", hiragana: "せんせい", meaning: "Teacher", category: "People", subcategory: nil, level: "5"),
                VocabWord(kanji: "食べる", hiragana: "たべる", meaning: "To eat", category: "Verbs", subcategory: nil, level: "5"),
                VocabWord(kanji: "水", hiragana: "みず", meaning: "Water", category: "Nature", subcategory: nil, level: "5"),
                VocabWord(kanji: "赤い", hiragana: "あかい", meaning: "Red", category: "Adjectives", subcategory: nil, level: "5")
            ]
        } else {
            availableVocab = words.shuffled() // Shuffle the deck!
        }
        
        setupRound()
    }
    
    func setupRound() {
        activePool = []
        // Pull 5 words off the top of the available vocab deck
        for _ in 0..<5 {
            if !availableVocab.isEmpty {
                activePool.append(availableVocab.removeFirst())
            }
        }
        
        // If we ran out of words, end the game early
        if activePool.isEmpty {
            gameState = .gameOver
            return
        }
        
        cumulativePool.append(contentsOf: activePool)
        gameState = .review
    }
    
    func finishReviewPhase() {
        let shuffledPool = cumulativePool.shuffled()
        chunkedGrids = stride(from: 0, to: shuffledPool.count, by: 5).map {
            Array(shuffledPool[$0..<min($0 + 5, shuffledPool.count)])
        }
        currentGridPhase = 1
        
        withAnimation(.easeInOut(duration: 0.3)) {
            gameState = .gridTransition
        }
    }
    
    func startGridPhase() {
        currentGridWords = chunkedGrids[currentGridPhase - 1]
        gridFoundWords.removeAll()
        gameState = .grid
    }
    
    func processGridWordFound(_ word: VocabWord) {
        gridFoundWords.insert(word.id)
        score += Int(100 * multiplier)
        multiplier += 0.2
        
        if gridFoundWords.count == currentGridWords.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    if self.currentGridPhase < self.chunkedGrids.count {
                        self.currentGridPhase += 1
                        self.gameState = .gridTransition
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
        } else {
            if currentRound < maxRounds && !availableVocab.isEmpty {
                currentRound += 1
                setupRound()
            } else {
                gameState = .gameOver
            }
        }
    }
    
    func processQuizAnswer(correct: Bool) {
        if correct {
            score += 250
            nextQuizQuestion()
        } else {
            nextQuizQuestion()
        }
    }
}

// MARK: - Dynamic Digital Rain Component
struct MatrixRainView: View {
    var color: Color = .synthPurple
    var speedMultiplier: Double = 1.0
    var opacityValue: Double = 0.3
    
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 12) {
                ForEach(0..<Int(geo.size.width / 15), id: \.self) { _ in
                    MatrixColumn(height: geo.size.height, color: color, speedMultiplier: speedMultiplier)
                }
            }
        }
        .opacity(opacityValue)
        .mask(LinearGradient(gradient: Gradient(colors: [.clear, .black, .black, .clear]), startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }
}

struct MatrixColumn: View {
    let height: CGFloat
    var color: Color
    var speedMultiplier: Double
    
    @State private var offset: CGFloat = 0
    @State private var chars: String = ""

    var body: some View {
        Text(chars)
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .frame(width: 15)
            .fixedSize(horizontal: false, vertical: true)
            .offset(y: offset)
            .onAppear {
                let katakana = "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ"
                chars = (0..<Int.random(in: 15...30)).map { _ in String(katakana.randomElement()!) }.joined(separator: "\n")
                offset = -height - CGFloat.random(in: 0...height)
                
                let duration = Double.random(in: 5...12) / speedMultiplier
                withAnimation(Animation.linear(duration: duration).repeatForever(autoreverses: false)) {
                    offset = height * 1.5
                }
            }
    }
}

// MARK: - Transition Views
struct GridTransitionView: View {
    @EnvironmentObject var gauntlet: GauntletManager
    
    var body: some View {
        ZStack {
            Color.synthBackground.edgesIgnoringSafeArea(.all)
            
            MatrixRainView(color: .synthCyan, speedMultiplier: 3.0, opacityValue: 0.8)
            
            VStack(spacing: 20) {
                Image(systemName: "network")
                    .font(.system(size: 60))
                    .foregroundColor(.synthCyan)
                    .shadow(color: .synthCyan, radius: 10)
                
                Text("INITIALIZING SECTOR...")
                    .font(.title2.weight(.black)).fontDesign(.monospaced)
                    .foregroundColor(.synthCyan)
                    .shadow(color: .synthCyan, radius: 10)
            }
        }
        .onAppear {
            RetroAudioEngine.shared.playJackIn()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    gauntlet.startGridPhase()
                }
            }
        }
    }
}

struct BossTransitionView: View {
    @EnvironmentObject var gauntlet: GauntletManager
    @State private var isFlashing = false
    
    var body: some View {
        ZStack {
            Color.synthBackground.edgesIgnoringSafeArea(.all)
            
            MatrixRainView(color: .synthPink, speedMultiplier: 4.0, opacityValue: 0.9)
            
            if isFlashing {
                Color.synthPink.opacity(0.3).edgesIgnoringSafeArea(.all)
            }
            
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.synthPink)
                    .shadow(color: .synthPink, radius: 20)
                
                Text("SYSTEM OVERRIDE\nIMMINENT")
                    .font(.largeTitle.weight(.black)).fontDesign(.monospaced)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .synthPink, radius: 15)
            }
            .opacity(isFlashing ? 1.0 : 0.8)
        }
        .onAppear {
            RetroAudioEngine.shared.playBossWarning()
            withAnimation(Animation.easeInOut(duration: 0.2).repeatForever()) {
                isFlashing = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    gauntlet.startBossFight()
                }
            }
        }
    }
}

// MARK: - Content View (Navigation)
struct MainTabView: View {
    @State private var selectedTab = 0
    @StateObject private var gauntletManager = GauntletManager()
    
    @State private var showVoicePrompt = false
    @AppStorage("hasSeenVoicePrompt") private var hasSeenVoicePrompt = false
    @AppStorage("enableNeonGlow") private var enableNeonGlow = true
    
    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Color.synthBackground)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        
        // Navigation bar transparency makes the custom transitions look better
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        navAppearance.backgroundColor = .clear
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
    }
    
    var body: some View {
        ZStack {
            Color.synthBackground.edgesIgnoringSafeArea(.all)
            
            TabView(selection: $selectedTab) {
                HomeView()
                    .tabItem { Image(systemName: "house.fill"); Text("Hub") }
                    .tag(0)
                
                GauntletSelectionView()
                    .environmentObject(gauntletManager)
                    .tabItem { Image(systemName: "cpu"); Text("The Grid") }
                    .tag(1)
                
                ProfileView()
                    .tabItem { Image(systemName: "slider.horizontal.3"); Text("Settings") }
                    .tag(2)
            }
            .accentColor(.synthCyan)
            
            // Overlays the game screens over the Tab Bar completely
            if gauntletManager.gameState != .selection {
                Color.synthBackground.edgesIgnoringSafeArea(.all)
                GauntletContainerView()
                    .environmentObject(gauntletManager)
                    .transition(.opacity)
            }
            
            if showVoicePrompt {
                Color.black.opacity(0.85).edgesIgnoringSafeArea(.all)
                VStack(spacing: 24) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.synthPink)
                        .shadow(color: enableNeonGlow ? .synthPink.opacity(0.8) : .clear, radius: 15)
                    
                    Text("SYSTEM UPGRADE REQUIRED")
                        .font(.title2.weight(.black)).fontDesign(.monospaced)
                        .foregroundColor(.white)
                        .shadow(color: enableNeonGlow ? .synthCyan.opacity(0.5) : .clear, radius: 5)
                    
                    Text("For the optimal neural-link experience, Sagasu requests the Enhanced Japanese Voice pack.\n\nInitialize via:\nSettings > Accessibility > Spoken Content > Voices > Japanese")
                        .font(.callout.weight(.medium)).fontDesign(.monospaced)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.gray)
                        .lineSpacing(6)
                    
                    Button(action: {
                        withAnimation(.spring()) { showVoicePrompt = false }
                    }) {
                        Text("ACKNOWLEDGE")
                            .font(.headline.weight(.black)).fontDesign(.monospaced)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.synthCyan)
                            .foregroundColor(.synthBackground)
                            .cornerRadius(8)
                            .shadow(color: enableNeonGlow ? .synthCyan.opacity(0.5) : .clear, radius: 10)
                    }
                    .padding(.top, 10)
                }
                .padding(30)
                .background(Color.synthCard)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.synthPink.opacity(0.8), lineWidth: 2)
                        .shadow(color: enableNeonGlow ? .synthPink.opacity(0.5) : .clear, radius: 8)
                )
                .padding(40)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .onAppear {
            if !hasSeenVoicePrompt && !SpeechManager.shared.isPremiumJapaneseVoiceAvailable() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.spring()) { showVoicePrompt = true }
                }
                hasSeenVoicePrompt = true
            }
        }
    }
}

// MARK: - Gauntlet Router
struct GauntletContainerView: View {
    @EnvironmentObject var gauntlet: GauntletManager
    @AppStorage("enableNeonGlow") private var enableNeonGlow = true
    
    var body: some View {
        Group {
            switch gauntlet.gameState {
            case .selection:
                EmptyView()
            case .review:
                FlashcardReviewView()
            case .gridTransition:
                GridTransitionView()
            case .grid:
                GameBoardView()
            case .bossTransition:
                BossTransitionView()
            case .boss:
                BossFightQuizView()
            case .roundComplete:
                Text("Round Complete").foregroundColor(.white)
            case .gameOver:
                VStack(spacing: 20) {
                    Text("SYSTEM PURGED!")
                        .font(.largeTitle.weight(.black)).fontDesign(.monospaced)
                        .foregroundColor(.synthCyan)
                        .shadow(color: enableNeonGlow ? .synthCyan.opacity(0.8) : .clear, radius: 10)
                    
                    Text("Final Credits: \(gauntlet.score)")
                        .font(.title3.weight(.bold)).fontDesign(.monospaced)
                        .foregroundColor(.white)
                    
                    Button("RETURN TO HUB") { withAnimation { gauntlet.gameState = .selection } }
                        .font(.headline.weight(.black)).fontDesign(.monospaced)
                        .padding().background(Color.synthPink).foregroundColor(.white).cornerRadius(8)
                        .shadow(color: enableNeonGlow ? .synthPink.opacity(0.5) : .clear, radius: 8)
                }
            }
        }
    }
}

// MARK: - Home / Camp View
struct HomeView: View {
    @State private var profile = PlayerProfile()
    @AppStorage("enableNeonGlow") private var enableNeonGlow = true
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.synthBackground.edgesIgnoringSafeArea(.all)
                MatrixRainView() // Subtle Vaporwave rain
                
                VStack(spacing: 24) {
                    VStack(spacing: 2) {
                        Text("S A G A S U")
                            .font(.system(size: 36, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                            .shadow(color: enableNeonGlow ? .synthCyan.opacity(0.8) : .clear, radius: 10, x: 0, y: 0)
                            .tracking(6)
                        
                        Text("NEURAL LINK ESTABLISHED")
                            .font(.caption.weight(.bold)).fontDesign(.monospaced)
                            .foregroundColor(.synthPink)
                            .tracking(2)
                    }
                    .padding(.top, 40)
                    
                    VStack {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Uplink Streak")
                                    .font(.headline).fontDesign(.monospaced)
                                    .foregroundColor(.gray)
                                HStack {
                                    Image(systemName: "bolt.fill")
                                        .foregroundColor(.synthCyan)
                                        .shadow(color: enableNeonGlow ? .synthCyan : .clear, radius: 5)
                                    Text("\(profile.dailyStreak) Cycles")
                                        .font(.title2.weight(.black)).fontDesign(.monospaced)
                                        .foregroundColor(.white)
                                }
                            }
                            Spacer()
                            Button(action: { }) {
                                VStack {
                                    Image(systemName: "shippingbox.fill")
                                        .resizable().frame(width: 40, height: 40)
                                        .foregroundColor(.synthPurple)
                                        .shadow(color: enableNeonGlow ? .synthPurple : .clear, radius: 5)
                                    Text("Decrypt")
                                        .font(.caption.weight(.bold)).fontDesign(.monospaced).foregroundColor(.white)
                                }
                                .padding()
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.synthPurple.opacity(0.5), lineWidth: 1))
                            }
                        }
                        .padding()
                        .background(Color.synthCard)
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.synthCyan.opacity(0.3), lineWidth: 1))
                    }
                    .padding(.horizontal)
                    
                    VStack(alignment: .leading) {
                        Text("Active Protocols (24h)")
                            .font(.headline).fontDesign(.monospaced)
                            .foregroundColor(.synthCyan).padding(.horizontal)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                BoonCard(boon: Boon(name: "Scholar's Candle", description: "Hint Cost Reduction (50%)", flavorText: "", tier: .common, icon: "flame"))
                                BoonCard(boon: Boon(name: "Chronos Hourglass", description: "Freezes timer for 1st Quiz question.", flavorText: "", tier: .rare, icon: "hourglass"))
                            }
                            .padding(.horizontal)
                        }
                    }
                    Spacer()
                }
            }
            .navigationBarHidden(true)
        }
    }
}

struct BoonCard: View {
    let boon: Boon
    @AppStorage("enableNeonGlow") private var enableNeonGlow = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: boon.icon)
                    .font(.title)
                    .foregroundColor(boon.tier.color)
                    .shadow(color: enableNeonGlow ? boon.tier.color.opacity(0.8) : .clear, radius: 5)
                Spacer()
                Text(boon.tier.rawValue.uppercased())
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(boon.tier.color.opacity(0.15))
                    .foregroundColor(boon.tier.color)
                    .cornerRadius(4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(boon.name).font(.headline.weight(.black)).fontDesign(.monospaced).foregroundColor(.white)
                Text(boon.description).font(.caption).fontDesign(.monospaced).foregroundColor(.gray).lineLimit(2)
            }
        }
        .padding()
        .frame(width: 160, height: 140)
        .background(Color.synthCard)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(boon.tier.color.opacity(0.6), lineWidth: 1.5))
        .shadow(color: enableNeonGlow ? boon.tier.color.opacity(0.2) : .clear, radius: 8)
    }
}

// MARK: - Dynamic Glitch Text Component
struct GlitchText: View {
    var text: String
    var font: Font
    var baseColor: Color
    var severity: Double // Scale of 0.0 (Stable) to 1.0 (Fatal Error)

    @State private var offsetX: CGFloat = 0
    @State private var opacity: Double = 1.0
    @State private var showAberration: Bool = false

    let timer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // A brief, jarring chromatic split that ONLY appears during high-severity glitch frames
            if showAberration {
                Text(text).font(font).foregroundColor(.synthPink).offset(x: severity * 4)
                Text(text).font(font).foregroundColor(.synthCyan).offset(x: -severity * 4)
            }
            
            // Clean, readable core text
            Text(text)
                .font(font)
                .foregroundColor(baseColor)
                .opacity(opacity)
        }
        .offset(x: offsetX)
        .onReceive(timer) { _ in
            guard severity > 0 else { return } // N5 stays perfectly stable
            
            // The higher the level, the more likely a glitch frame triggers
            if Double.random(in: 0...1) < (severity * 0.25) {
                offsetX = CGFloat.random(in: -severity * 4...severity * 4)
                opacity = Double.random(in: 0.3...0.9)
                
                // Only severly broken levels get the chromatic split
                showAberration = severity > 0.6 && Bool.random()
                
                // Instantly snap back to clean text so it remains readable
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    offsetX = 0
                    opacity = 1.0
                    showAberration = false
                }
            }
        }
    }
}

// MARK: - Corrupted Card Component
struct CorruptedCard<Content: View>: View {
    var severity: Double
    var baseColor: Color
    @ViewBuilder var content: Content
    
    @State private var dashPhase: CGFloat = 0
    @State private var glitchX: CGFloat = 0
    @State private var glitchY: CGFloat = 0
    @State private var sliceOffset: CGFloat = 0
    @State private var showSlice: Bool = false

    let timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()
    
    var body: some View {
        let isStable = severity == 0
        // Lower levels have solid or cleanly dashed borders. N1 borders are erratic and highly fragmented.
        let dashPattern: [CGFloat] = isStable ? [] : (severity < 0.5 ? [60, 15] : [20, 10, 5, 20, 40, 15])

        content
            .padding(20)
            .background(
                ZStack {
                    Color.synthCard
                    
                    // Simulated data "slice" cutting horizontally across the card, masking out chunks
                    if showSlice && severity > 0.3 {
                        Color.synthBackground
                            .frame(height: severity * 12)
                            .offset(y: sliceOffset)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8)) // Keeps the glitching slice contained to the box
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(baseColor.opacity(isStable ? 0.5 : 0.8), 
                            style: StrokeStyle(lineWidth: severity > 0.7 ? 3 : 2, dash: dashPattern, dashPhase: dashPhase))
            )
            .offset(x: glitchX, y: glitchY)
            .onAppear {
                if severity > 0 {
                    // Animates the broken border so it continuously crawls around the card
                    withAnimation(Animation.linear(duration: Double.random(in: 3...6)).repeatForever(autoreverses: false)) {
                        dashPhase = 100
                    }
                }
            }
            .onReceive(timer) { _ in
                guard severity > 0 else { return }
                
                if Double.random(in: 0...1) < (severity * 0.3) {
                    // Jerk the entire card slightly
                    glitchX = CGFloat.random(in: -severity * 3...severity * 3)
                    glitchY = CGFloat.random(in: -severity * 2...severity * 2)
                    
                    // Trigger a missing "chunk" of the box background
                    if severity > 0.3 {
                        showSlice = true
                        sliceOffset = CGFloat.random(in: -30...30)
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        glitchX = 0
                        glitchY = 0
                        showSlice = false
                    }
                }
            }
    }
}

// MARK: - Level -> Category -> Subcategory Selection Views
struct GauntletSelectionView: View {
    @EnvironmentObject var gauntlet: GauntletManager
    
    // Configuration for the descending difficulty aesthetic
    let levels = [
        (level: 5, title: "JLPT N5", desc: "SYSTEM STABLE", color: Color.synthCyan, severity: 0.0),
        (level: 4, title: "JLPT N4", desc: "MINOR ANOMALIES", color: Color.synthYellow, severity: 0.2),
        (level: 3, title: "JLPT N3", desc: "DATA CORRUPTION", color: Color.synthOrange, severity: 0.5),
        (level: 2, title: "JLPT N2", desc: "WARNING: THREAT HIGH", color: Color.synthPink, severity: 0.8),
        (level: 1, title: "JLPT N1", desc: "FATAL ERROR // OVERRIDE", color: Color(hex: "FF003C"), severity: 1.0)
    ]
    
    var body: some View {
        // NavigationStack is forced to rebuild to its root when returning from a run
        NavigationView {
            ZStack {
                Color.synthBackground.edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 0) {
                    Text("SELECT TARGET GRID")
                        .font(.largeTitle.weight(.black)).fontDesign(.monospaced)
                        .foregroundColor(.white)
                        .padding(.top, 20)
                        .padding(.bottom, 10)
                    
                    ScrollView {
                        VStack(spacing: 24) {
                            ForEach(levels, id: \.level) { config in
                                // Navigate down to Category level
                                NavigationLink(destination: CategorySelectionView(level: config.level)) {
                                    CorruptedCard(severity: config.severity, baseColor: config.color) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 8) {
                                                GlitchText(text: "SECTOR \(config.level) // \(config.desc)", 
                                                           font: .caption.weight(.black).monospaced(), 
                                                           baseColor: config.color, 
                                                           severity: config.severity)
                                                
                                                GlitchText(text: config.title, 
                                                           font: .title2.weight(.black).monospaced(), 
                                                           baseColor: .white, 
                                                           severity: config.severity)
                                                
                                                GeometryReader { geometry in
                                                    ZStack(alignment: .leading) {
                                                        Rectangle()
                                                            .frame(width: geometry.size.width, height: 4)
                                                            .opacity(0.3)
                                                            .foregroundColor(Color.gray)
                                                    }
                                                }.frame(height: 4)
                                            }
                                            
                                            Spacer()
                                            
                                            Image(systemName: "chevron.right")
                                                .font(.title3.weight(.bold))
                                                .foregroundColor(config.color)
                                        }
                                    }
                                }
                                // Triggers a quick feedback audio chirp when clicked
                                .simultaneousGesture(TapGesture().onEnded {
                                    RetroAudioEngine.shared.playSelectionTap()
                                })
                            }
                        }
                        .padding(24)
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationBarHidden(true)
        }
        .id(gauntlet.navigationResetID) // Auto-resets to top when finishing game
    }
}

// Level 2 Drilldown: Select the Category
struct CategorySelectionView: View {
    @Environment(\.presentationMode) var presentationMode
    var level: Int
    @State private var categories: [String] = []
    
    var body: some View {
        ZStack {
            Color.synthBackground.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                // Custom Synthwave Back Button
                HStack {
                    Button(action: { 
                        RetroAudioEngine.shared.playSelectionTap()
                        presentationMode.wrappedValue.dismiss() 
                    }) {
                        Image(systemName: "chevron.left")
                        Text("BACK")
                    }
                    .font(.headline.weight(.black).monospaced())
                    .foregroundColor(.synthPink)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                
                Text("SECTOR \(level) // CATEGORY")
                    .font(.title2.weight(.black)).fontDesign(.monospaced)
                    .foregroundColor(.white)
                    .padding(.top, 10)
                    .padding(.bottom, 20)
                
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(categories, id: \.self) { category in
                            NavigationLink(destination: SubcategorySelectionView(level: level, category: category)) {
                                HStack {
                                    Text(category.uppercased())
                                        .font(.headline.weight(.black).monospaced())
                                        .foregroundColor(.synthCyan)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.synthCyan)
                                }
                                .padding(20)
                                .background(Color.synthCard)
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.synthCyan.opacity(0.5), lineWidth: 1))
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                RetroAudioEngine.shared.playSelectionTap()
                            })
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            categories = DataLoader.shared.getCategories(for: level)
        }
    }
}

// Level 3 Drilldown: Select Subcategory and Start Game
struct SubcategorySelectionView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var gauntlet: GauntletManager
    
    var level: Int
    var category: String
    @State private var subcategories: [String] = []
    
    var body: some View {
        ZStack {
            Color.synthBackground.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                // Custom Synthwave Back Button
                HStack {
                    Button(action: { 
                        RetroAudioEngine.shared.playSelectionTap()
                        presentationMode.wrappedValue.dismiss() 
                    }) {
                        Image(systemName: "chevron.left")
                        Text("BACK")
                    }
                    .font(.headline.weight(.black).monospaced())
                    .foregroundColor(.synthPink)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                
                Text("DATABANK")
                    .font(.caption.weight(.black)).fontDesign(.monospaced)
                    .foregroundColor(.synthCyan)
                    .padding(.top, 10)
                Text("SELECT TARGET NODE")
                    .font(.title2.weight(.black)).fontDesign(.monospaced)
                    .foregroundColor(.white)
                    .padding(.bottom, 20)
                
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(subcategories, id: \.self) { sub in
                            Button(action: {
                                RetroAudioEngine.shared.playSelectionTap()
                                withAnimation {
                                    gauntlet.startGauntlet(level: level, category: category, subcategory: sub)
                                }
                            }) {
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundColor(.synthYellow)
                                    Text(sub.uppercased())
                                        .font(.headline.weight(.bold)).fontDesign(.monospaced)
                                        .foregroundColor(.white)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    Image(systemName: "play.fill")
                                        .foregroundColor(.synthPink)
                                }
                                .padding(20)
                                .background(Color.synthCard)
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.synthYellow.opacity(0.3), lineWidth: 1))
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            subcategories = DataLoader.shared.getSubcategories(for: level, category: category)
        }
    }
}

// MARK: - Phase 1: Flashcard Review
struct FlashcardReviewView: View {
    @EnvironmentObject var gauntlet: GauntletManager
    @State private var isFlipped = false
    @State private var currentIndex = 0
    
    @AppStorage("autoPlayAudio") private var autoPlayAudio = true
    @AppStorage("enableNeonGlow") private var enableNeonGlow = true
    
    var currentWord: VocabWord {
        if gauntlet.activePool.isEmpty { return VocabWord(kanji: "", hiragana: "エラー", meaning: "Error", category: "", subcategory: nil, level: "0") }
        return gauntlet.activePool[currentIndex]
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Button(action: { withAnimation { gauntlet.gameState = .selection } }) {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.black))
                        .foregroundColor(.synthPink)
                        .padding(12)
                        .background(Color.synthPink.opacity(0.15))
                        .clipShape(Circle())
                }
                Spacer()
                Text("DATA INJECTION - R\(gauntlet.currentRound)")
                    .font(.headline.weight(.black)).fontDesign(.monospaced)
                    .foregroundColor(.synthCyan)
                    .shadow(color: enableNeonGlow ? .synthCyan.opacity(0.5) : .clear, radius: 5)
                Spacer()
                Circle().frame(width: 44, height: 44).foregroundColor(.clear)
            }
            .padding(.horizontal)
            .padding(.top, 10)
            
            Spacer()
            
            // Flashcard
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.synthCard)
                    .frame(height: 250)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.synthCyan.opacity(0.6), lineWidth: 2))
                    .shadow(color: enableNeonGlow ? .synthCyan.opacity(0.4) : .clear, radius: 15, x: 0, y: 0)
                    
                if !isFlipped {
                    // Front (Japanese)
                    VStack(spacing: 20) {
                        Text(currentWord.hiragana)
                            .font(.system(size: 36, weight: .black))
                            .foregroundColor(.white)
                            .shadow(color: enableNeonGlow ? .white.opacity(0.5) : .clear, radius: 5)
                        Button(action: { SpeechManager.shared.speak(text: currentWord.hiragana, language: "ja-JP") }) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.title2).foregroundColor(.synthBackground).padding(16)
                                .background(Color.synthCyan).clipShape(Circle())
                                .shadow(color: enableNeonGlow ? .synthCyan : .clear, radius: 10)
                        }
                    }
                } else {
                    // Back (English)
                    VStack(spacing: 20) {
                        Text(currentWord.meaning)
                            .font(.system(size: 32, weight: .black, design: .monospaced))
                            .foregroundColor(.synthYellow)
                            .shadow(color: enableNeonGlow ? .synthYellow.opacity(0.6) : .clear, radius: 5)
                        Button(action: { SpeechManager.shared.speak(text: currentWord.meaning, language: "en-US") }) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.title2).foregroundColor(.synthBackground).padding(16)
                                .background(Color.synthYellow).clipShape(Circle())
                                .shadow(color: enableNeonGlow ? .synthYellow : .clear, radius: 10)
                        }
                    }
                    .rotation3DEffect(.degrees(180), axis: (x: 0.0, y: 1.0, z: 0.0))
                }
            }
            .padding(.horizontal, 30)
            .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0.0, y: 1.0, z: 0.0))
            .onTapGesture { withAnimation(.spring()) { isFlipped.toggle() } }
            
            // Next Button
            Button(action: {
                if currentIndex < gauntlet.activePool.count - 1 {
                    currentIndex += 1
                    isFlipped = false
                } else {
                    gauntlet.finishReviewPhase()
                }
            }) {
                Text(currentIndex < gauntlet.activePool.count - 1 ? "NEXT" : "EXECUTE SEARCH")
                    .font(.headline.weight(.black)).fontDesign(.monospaced)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.synthCyan)
                    .foregroundColor(.synthBackground)
                    .cornerRadius(8)
                    .shadow(color: enableNeonGlow ? .synthCyan.opacity(0.6) : .clear, radius: 10)
            }
            .padding(.horizontal, 30)
            .padding(.top, 20)
            .opacity(isFlipped ? 1.0 : 0.0)
            .disabled(!isFlipped)
            
            Spacer()
        }
        .onAppear {
            if autoPlayAudio && !isFlipped { SpeechManager.shared.speak(text: currentWord.hiragana, language: "ja-JP") }
        }
        .onChange(of: isFlipped) {
            if autoPlayAudio {
                SpeechManager.shared.speak(text: isFlipped ? currentWord.meaning : currentWord.hiragana, language: isFlipped ? "en-US" : "ja-JP")
            }
        }
        .onChange(of: currentIndex) {
            if autoPlayAudio && !isFlipped { SpeechManager.shared.speak(text: currentWord.hiragana, language: "ja-JP") }
        }
    }
}

// MARK: - Phase 2: Active Game Board (The Grid)
struct GameBoardView: View {
    @EnvironmentObject var gauntlet: GauntletManager
    let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)
    @AppStorage("enableNeonGlow") private var enableNeonGlow = true
    
    @State private var gridChars: [String] = Array(repeating: "", count: 48)
    @State private var hasGeneratedBoard = false
    
    // Swipe mechanics state
    @State private var cellFrames: [Int: CGRect] = [:]
    @State private var selectedIndices: [Int] = []
    
    // Tracks how many times a cell has been used to denote overlapping intersections
    @State private var foundCellCounts: [Int: Int] = [:]
    
    @State private var isDragging = false
    @State private var lastTapIndex: Int? = nil
    @State private var lastTapTime: Date = Date.distantPast
    
    var sortedGridWords: [VocabWord] {
        gauntlet.currentGridWords.sorted { w1, w2 in
            let found1 = gauntlet.gridFoundWords.contains(w1.id)
            let found2 = gauntlet.gridFoundWords.contains(w2.id)
            if found1 == found2 { return false }
            return !found1 && found2
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: Top Header
            HStack {
                Button(action: { withAnimation { gauntlet.gameState = .selection } }) {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.black))
                        .foregroundColor(.synthPink)
                        .frame(width: 40, height: 40)
                        .background(Color.synthPink.opacity(0.15))
                        .clipShape(Circle())
                }
                
                Spacer()
                
                VStack(spacing: 2) {
                    Text("PHASE \(gauntlet.currentRound)")
                        .font(.caption2.weight(.black)).fontDesign(.monospaced)
                        .foregroundColor(.synthPurple)
                        .tracking(2)
                    Text("SECTOR \(gauntlet.currentGridPhase)/\(gauntlet.chunkedGrids.count)")
                        .font(.headline.weight(.black)).fontDesign(.monospaced)
                        .foregroundColor(.white)
                        .shadow(color: enableNeonGlow ? .white.opacity(0.5) : .clear, radius: 5)
                }
                
                Spacer()
                
                Button(action: {
                    gauntlet.score = max(0, gauntlet.score - 25)
                    gauntlet.multiplier = 1.0
                }) {
                    Image(systemName: "eye.trianglebadge.exclamationmark.fill")
                        .font(.headline)
                        .foregroundColor(.synthBackground)
                        .frame(width: 40, height: 40)
                        .background(Color.synthPink)
                        .clipShape(Circle())
                        .shadow(color: enableNeonGlow ? .synthPink.opacity(0.8) : .clear, radius: 8)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            // MARK: Stats & Boon Row
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("CREDITS")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundColor(.synthCyan)
                        .tracking(1)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(gauntlet.score)")
                            .font(.title2.weight(.black)).fontDesign(.monospaced)
                            .foregroundColor(.white)
                            .shadow(color: enableNeonGlow ? .synthCyan.opacity(0.5) : .clear, radius: 5)
                        Text("x\(String(format: "%.1f", gauntlet.multiplier))")
                            .font(.subheadline.weight(.black)).fontDesign(.monospaced)
                            .foregroundColor(.synthPink)
                    }
                }
                
                Spacer()
                
                // Active Boons Mini-Window
                HStack(spacing: 8) {
                    ForEach(["flame.fill", "hourglass"], id: \.self) { icon in
                        Image(systemName: icon)
                            .font(.system(size: 12))
                            .foregroundColor(.synthCyan)
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(Color.synthCard)
                                    .overlay(Circle().stroke(Color.synthCyan.opacity(0.4), lineWidth: 1))
                            )
                            .shadow(color: enableNeonGlow ? .synthCyan.opacity(0.5) : .clear, radius: 3)
                    }
                }
                .padding(6)
                .background(Color.synthBackground.opacity(0.8))
                .cornerRadius(20)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.1), lineWidth: 1))
            }
            .padding(.horizontal)
            .padding(.top, 12)
            
            // MARK: Target Words (Horizontal Pills)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(sortedGridWords) { word in
                        let isFound = gauntlet.gridFoundWords.contains(word.id)
                        HStack(spacing: 4) {
                            if isFound {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.synthYellow)
                            }
                            Text(word.meaning.uppercased())
                                .font(.system(size: 14, weight: .black, design: .monospaced))
                                .foregroundColor(isFound ? .synthYellow : .synthCyan)
                                .strikethrough(isFound)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(isFound ? Color.synthYellow.opacity(0.1) : Color.synthCyan.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isFound ? Color.synthYellow.opacity(0.6) : Color.synthCyan.opacity(0.6), lineWidth: 1.5)
                        )
                        .shadow(color: enableNeonGlow ? (isFound ? .synthYellow.opacity(0.3) : .synthCyan.opacity(0.3)) : .clear, radius: 5)
                        .opacity(isFound ? 0.5 : 1.0)
                        .id(word.id)
                    }
                }
                .padding(.horizontal)
                .animation(.spring(response: 0.4, dampingFraction: 0.75), value: gauntlet.gridFoundWords)
            }
            .padding(.top, 16)
            .padding(.bottom, 24)
            
            // MARK: The Grid
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<gridChars.count, id: \.self) { index in
                    
                    let foundCount = foundCellCounts[index, default: 0]
                    let isFound = foundCount > 0
                    let isMultiFound = foundCount > 1
                    
                    let baseColor = isMultiFound ? Color.synthPink.opacity(0.3) : (isFound ? Color.synthCyan.opacity(0.15) : Color.synthCard)
                    let strokeColor = isMultiFound ? Color.synthPink.opacity(0.5) : (isFound ? Color.synthCyan.opacity(0.3) : Color.synthCyan.opacity(0.1))
                    
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedIndices.contains(index) ? Color.synthCyan : baseColor)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(selectedIndices.contains(index) ? Color.white : strokeColor, lineWidth: selectedIndices.contains(index) ? 2 : 1)
                            )
                            .shadow(color: enableNeonGlow ? (selectedIndices.contains(index) ? .synthCyan : .clear) : .clear, radius: 8)
                        
                        Text(gridChars[index])
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(selectedIndices.contains(index) ? .synthBackground : .white)
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.onAppear {
                                let frame = geo.frame(in: .named("GridSpace"))
                                DispatchQueue.main.async {
                                    if cellFrames[index] != frame {
                                        cellFrames[index] = frame
                                    }
                                }
                            }
                        }
                    )
                }
            }
            .padding(.horizontal)
            .coordinateSpace(name: "GridSpace")
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("GridSpace"))
                    .onChanged { value in
                        if abs(value.translation.width) > 5 || abs(value.translation.height) > 5 { isDragging = true }
                        if let current = cellIndex(at: value.location) {
                            if selectedIndices.isEmpty {
                                selectedIndices.append(current)
                                RetroAudioEngine.shared.playGridTone(index: selectedIndices.count - 1)
                            } else if let lastIndex = selectedIndices.last, current != lastIndex {
                                if selectedIndices.count >= 2 && selectedIndices[selectedIndices.count - 2] == current {
                                    selectedIndices.removeLast()
                                    RetroAudioEngine.shared.playGridTone(index: selectedIndices.count - 1)
                                } else if !selectedIndices.contains(current) {
                                    let cols = 6
                                    let lastRow = lastIndex / cols, lastCol = lastIndex % cols
                                    let currRow = current / cols, currCol = current % cols
                                    
                                    if abs(lastRow - currRow) <= 1 && abs(lastCol - currCol) <= 1 {
                                        selectedIndices.append(current)
                                        RetroAudioEngine.shared.playGridTone(index: selectedIndices.count - 1)
                                    } else if !isDragging {
                                        selectedIndices = [current]
                                        RetroAudioEngine.shared.playGridTone(index: 0)
                                    }
                                }
                            }
                        }
                    }
                    .onEnded { value in
                        if isDragging {
                            checkSelectedWord()
                            isDragging = false
                        } else {
                            if let current = cellIndex(at: value.location), let lastIndex = selectedIndices.last, current == lastIndex {
                                let now = Date()
                                if current == lastTapIndex && now.timeIntervalSince(lastTapTime) < 0.5 {
                                    checkSelectedWord()
                                    lastTapIndex = nil
                                } else {
                                    lastTapIndex = current
                                    lastTapTime = now
                                }
                            }
                        }
                    }
            )
            
            Spacer()
        }
        .onAppear {
            if !hasGeneratedBoard {
                generateBoard()
                hasGeneratedBoard = true
            }
        }
        .onChange(of: gauntlet.currentGridPhase) {
            foundCellCounts.removeAll()
            generateBoard()
        }
    }
    
    func cellIndex(at location: CGPoint) -> Int? {
        for (index, frame) in cellFrames {
            if frame.contains(location) { return index }
        }
        return nil
    }

    func generateBoard() {
        var newGrid = Array(repeating: "", count: 48)
        let rows = 8, cols = 6
        var allPlaced = false
        
        while !allPlaced {
            newGrid = Array(repeating: "", count: 48)
            allPlaced = true
            
            for word in gauntlet.currentGridWords {
                let chars = Array(word.hiragana).map { String($0) }
                var placed = false
                var attempts = 0
                
                while !placed && attempts < 200 {
                    var tempGrid = newGrid
                    let startRow = Int.random(in: 0..<rows), startCol = Int.random(in: 0..<cols)
                    if placeWord(chars, index: 0, r: startRow, c: startCol, grid: &tempGrid, rows: rows, cols: cols) {
                        newGrid = tempGrid
                        placed = true
                    }
                    attempts += 1
                }
                
                if !placed {
                    allPlaced = false
                    break
                }
            }
        }
        
        let hiragana = Array("あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん").map { String($0) }
        for i in 0..<48 {
            if newGrid[i] == "" { newGrid[i] = hiragana.randomElement()! }
        }
        gridChars = newGrid
    }
    
    private func placeWord(_ chars: [String], index: Int, r: Int, c: Int, grid: inout [String], rows: Int, cols: Int) -> Bool {
        if r < 0 || r >= rows || c < 0 || c >= cols { return false }
        let cellIndex = r * cols + c
        
        if grid[cellIndex] != "" && grid[cellIndex] != chars[index] { return false }
        
        let previousChar = grid[cellIndex]
        grid[cellIndex] = chars[index]
        
        if index == chars.count - 1 { return true }
        
        let directions = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)].shuffled()
                          
        for d in directions {
            if placeWord(chars, index: index + 1, r: r + d.0, c: c + d.1, grid: &grid, rows: rows, cols: cols) {
                return true
            }
        }
        
        grid[cellIndex] = previousChar
        return false
    }
    
    func checkSelectedWord() {
        let selectedChars = selectedIndices.map { gridChars[$0] }.joined()
        
        if let match = gauntlet.currentGridWords.first(where: { 
            !gauntlet.gridFoundWords.contains($0.id) && 
            (selectedChars == $0.hiragana || selectedChars == String($0.hiragana.reversed())) 
        }) {
            RetroAudioEngine.shared.playSuccess()
            
            for idx in selectedIndices {
                foundCellCounts[idx, default: 0] += 1
            }
            
            selectedIndices = []
            gauntlet.processGridWordFound(match)
        } else {
            RetroAudioEngine.shared.playError()
            gauntlet.multiplier = 1.0
            gauntlet.score = max(0, gauntlet.score - 25)
            selectedIndices = []
        }
    }
}

// MARK: - Phase 3: The Boss Fight (Retention Quiz)
struct BossFightQuizView: View {
    @EnvironmentObject var gauntlet: GauntletManager
    @State private var bossHealth = 100.0
    @State private var playerHealth = 100.0
    @AppStorage("enableNeonGlow") private var enableNeonGlow = true
    
    var damagePerQuestion: Double {
        let poolSize = Double(gauntlet.cumulativePool.count)
        return poolSize > 0 ? (100.0 / poolSize) : 100.0
    }
    
    var body: some View {
        ZStack {
            Color.synthBackground.edgesIgnoringSafeArea(.all)
            
            Color.synthPink.opacity(0.05).edgesIgnoringSafeArea(.all)
            
            VStack {
                HStack {
                    Button(action: { withAnimation { gauntlet.gameState = .selection } }) {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.black))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 10)
                
                if let targetWord = gauntlet.currentQuizQuestion {
                    VStack {
                        VStack(spacing: 8) {
                            Image(systemName: "cpu")
                                .resizable().frame(width: 80, height: 80)
                                .foregroundColor(.synthPink)
                                .shadow(color: enableNeonGlow ? .synthPink.opacity(0.8) : .clear, radius: 15)
                                .padding(.top, 10)
                            
                            Text("SYSTEM OVERRIDE - LEVEL \(gauntlet.currentRound)")
                                .font(.headline.weight(.black)).fontDesign(.monospaced)
                                .foregroundColor(.white)
                                .shadow(color: enableNeonGlow ? .synthPink.opacity(0.5) : .clear, radius: 5)
                            
                            ProgressView(value: max(0, bossHealth), total: 100.0)
                                .progressViewStyle(LinearProgressViewStyle(tint: .synthPink))
                                .frame(height: 8).padding(.horizontal, 40)
                                .shadow(color: enableNeonGlow ? .synthPink : .clear, radius: 5)
                        }
                        
                        Spacer()
                        
                        VStack(spacing: 20) {
                            Text("NODES REMAINING: \(gauntlet.bossQuizQueue.count + 1)")
                                .font(.caption.weight(.bold)).fontDesign(.monospaced).foregroundColor(.synthPink)
                                .tracking(2)
                            
                            Text(targetWord.hiragana)
                                .font(.system(size: 44, weight: .black))
                                .foregroundColor(.white)
                                .shadow(color: enableNeonGlow ? .white.opacity(0.5) : .clear, radius: 10)
                            
                            let options = generateOptions(for: targetWord)
                            
                            VStack(spacing: 16) {
                                ForEach(options, id: \.self) { option in
                                    Button(action: {
                                        if option == targetWord.meaning {
                                            withAnimation { bossHealth -= damagePerQuestion }
                                            RetroAudioEngine.shared.playEnemyHit()
                                            gauntlet.processQuizAnswer(correct: true)
                                        } else {
                                            withAnimation { playerHealth -= damagePerQuestion }
                                            RetroAudioEngine.shared.playPlayerHit()
                                            gauntlet.processQuizAnswer(correct: false)
                                        }
                                    }) {
                                        Text(option.uppercased())
                                            .font(.headline.weight(.bold)).fontDesign(.monospaced)
                                            .frame(maxWidth: .infinity)
                                            .padding()
                                            .background(Color.synthCard)
                                            .foregroundColor(.synthCyan)
                                            .cornerRadius(8)
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.synthCyan.opacity(0.5), lineWidth: 1))
                                    }
                                }
                            }
                            .padding(.horizontal, 30)
                        }
                        
                        Spacer()
                        
                        VStack(spacing: 8) {
                            Text("RUNNER INTEGRITY").font(.caption.weight(.black)).fontDesign(.monospaced).foregroundColor(.synthCyan).tracking(1)
                            ProgressView(value: max(0, playerHealth), total: 100.0)
                                .progressViewStyle(LinearProgressViewStyle(tint: .synthCyan))
                                .padding(.horizontal, 40)
                                .shadow(color: enableNeonGlow ? .synthCyan : .clear, radius: 5)
                        }
                        .padding(.bottom, 40)
                    }
                }
            }
        }
    }
    
    func generateOptions(for word: VocabWord) -> [String] {
        var options = [word.meaning]
        var pool = DataLoader.shared.allVocab.filter { $0.id != word.id }.shuffled() // Use the DataLoader pool for wrong answers
        
        // Safety fallback if the JSON is somehow smaller than 4 items
        if pool.isEmpty {
            pool = [
                VocabWord(kanji: "", hiragana: "", meaning: "Fake Answer 1", category: "", subcategory: nil, level: "0"),
                VocabWord(kanji: "", hiragana: "", meaning: "Fake Answer 2", category: "", subcategory: nil, level: "0"),
                VocabWord(kanji: "", hiragana: "", meaning: "Fake Answer 3", category: "", subcategory: nil, level: "0")
            ]
        }
        
        while options.count < 4 && !pool.isEmpty { options.append(pool.removeFirst().meaning) }
        return options.shuffled()
    }
}

// MARK: - Profile Settings Placeholder
struct ProfileView: View {
    @AppStorage("enableNeonGlow") private var enableNeonGlow = true
    @AppStorage("autoPlayAudio") private var autoPlayAudio = true
    
    var body: some View {
        ZStack {
            Color.synthBackground.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 40) {
                VStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 60))
                        .foregroundColor(.synthCyan)
                        .shadow(color: enableNeonGlow ? .synthCyan : .clear, radius: 10)
                    
                    Text("SYSTEM SETTINGS")
                        .font(.largeTitle.weight(.black)).fontDesign(.monospaced)
                        .foregroundColor(.white)
                }
                .padding(.top, 40)
                
                VStack(spacing: 20) {
                    // Settings Card
                    VStack(spacing: 24) {
                        Toggle(isOn: $enableNeonGlow) {
                            Text("Neon Glow FX")
                                .font(.headline.weight(.bold)).fontDesign(.monospaced)
                                .foregroundColor(.white)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .synthPink))
                        
                        Divider().background(Color.gray.opacity(0.3))
                        
                        Toggle(isOn: $autoPlayAudio) {
                            Text("Auto-Play Vocab Audio")
                                .font(.headline.weight(.bold)).fontDesign(.monospaced)
                                .foregroundColor(.white)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .synthCyan))
                    }
                    .padding(24)
                    .background(Color.synthCard)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.synthPurple.opacity(0.5), lineWidth: 1))
                }
                .padding(.horizontal, 30)
                
                Spacer()
            }
        }
    }
}
