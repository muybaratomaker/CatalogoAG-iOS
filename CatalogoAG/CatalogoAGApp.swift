import SwiftUI
import Security

@main
struct CatalogoAGApp: App {
    @StateObject private var store = CatalogStore()
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}

struct CatalogItem: Identifiable, Decodable, Hashable {
    var title: String
    var type: String
    var id: Int?
    var search: String
    var todo: Bool
    var origin: String = "base"
    var identity: String { "\(type)|\(title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).trimmingCharacters(in: .whitespacesAndNewlines))" }
    var isTodo: Bool { todo }
    var isMovie: Bool { type == "movie" }
    var displayType: String { isMovie ? "Film" : "Serie TV" }
    var identifiableTitle: String { title }
    var stableId: String { identity }
    var swiftId: String { identity }
    var tmdbId: Int? { id }
    var uuid: String { identity }
    var hashKey: String { identity }
    var key: String { identity }
    var normalizedId: String { identity }
    var identifier: String { identity }
    // Decoding from the static catalogue ignores the optional origin field.
    enum CodingKeys: String, CodingKey { case title, type, id, search, todo }
}

struct MediaDetails: Decodable {
    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let poster_path: String?
    let backdrop_path: String?
    let release_date: String?
    let first_air_date: String?
    let vote_average: Double?
    let runtime: Int?
    let number_of_seasons: Int?
    let genre_ids: [Int]?
    let genres: [TMDbGenre]?
    var genreIDs: [Int] { genres?.map(\.id) ?? genre_ids ?? [] }
    var displayTitle: String { title ?? name ?? "Titolo" }
    var releaseYear: String { String((release_date ?? first_air_date ?? "").prefix(4)) }
    var lengthLabel: String? {
        if let runtime, runtime > 0 { return "\(runtime / 60) h \(runtime % 60) min" }
        if let number_of_seasons, number_of_seasons > 0 { return "\(number_of_seasons) \(number_of_seasons == 1 ? "stagione" : "stagioni")" }
        return nil
    }
    var posterURL: URL? { poster_path.flatMap { URL(string: "https://image.tmdb.org/t/p/w500\($0)") } }
    var backdropURL: URL? { backdrop_path.flatMap { URL(string: "https://image.tmdb.org/t/p/w780\($0)") } }
}

struct TMDbGenre: Decodable { let id: Int; let name: String }

struct SearchResponse: Decodable { let results: [MediaDetails] }

actor TMDbMemoryCache {
    static let shared = TMDbMemoryCache()
    private var data: [String: MediaDetails] = [:]
    func get(_ key: String) -> MediaDetails? { data[key] }
    func put(_ value: MediaDetails, for key: String) { data[key] = value }
}

// Diagnostica locale: conta esclusivamente le chiamate API effettivamente inviate a TMDb.
// Le immagini, la cache, Google Sheets e Cloudflare non rientrano nel conteggio.
@MainActor
private final class AGTMDbDiagnostics: ObservableObject {
    static let shared = AGTMDbDiagnostics()
    @Published private(set) var sessionRequests = 0
    @Published private(set) var http429 = 0
    @Published private(set) var peakPerSecond = 0
    @Published private(set) var recentMinute = 0
    private var timestamps: [Date] = []
    private init() {}

    func recordRequest() {
        let now = Date()
        sessionRequests += 1
        timestamps.append(now)
        timestamps.removeAll { now.timeIntervalSince($0) > 60 }
        recentMinute = timestamps.count
        let currentSecond = timestamps.filter { now.timeIntervalSince($0) < 1 }.count
        peakPerSecond = max(peakPerSecond, currentSecond)
