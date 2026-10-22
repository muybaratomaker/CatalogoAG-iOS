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
    let genre_ids: [Int]?
    let genres: [TMDbGenre]?
    var genreIDs: [Int] { genres?.map(\.id) ?? genre_ids ?? [] }
    var displayTitle: String { title ?? name ?? "Titolo" }
    var releaseYear: String { String((release_date ?? first_air_date ?? "").prefix(4)) }
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

enum TMDbService {
    static func details(for item: CatalogItem, apiKey: String) async -> MediaDetails? {
        guard !apiKey.isEmpty else { return nil }
        let kind = item.isMovie ? "movie" : "tv"
        let cacheKey = "\(kind)|\(item.id.map { String($0) } ?? (item.search.isEmpty ? item.title : item.search))|\(apiKey)"
        if let cached = await TMDbMemoryCache.shared.get(cacheKey) { return cached }
        var parts = URLComponents(string: "https://api.themoviedb.org/3/" + (item.id == nil ? "search/\(kind)" : "\(kind)/\(item.id!)"))!
        var queries = [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "language", value: "it-IT")]
        if item.id == nil {
            queries.append(URLQueryItem(name: "query", value: item.search.isEmpty ? item.title : item.search))
        }
        parts.queryItems = queries
        guard let url = parts.url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let result: MediaDetails?
            if item.id != nil {
                result = try JSONDecoder().decode(MediaDetails.self, from: data)
            } else {
                result = try JSONDecoder().decode(SearchResponse.self, from: data).results.first
            }
            if let result { await TMDbMemoryCache.shared.put(result, for: cacheKey) }
            return result
        } catch { return nil }
    }
}

@MainActor
final class CatalogStore: ObservableObject {
    @Published var items: [CatalogItem] = []
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var apiKey: String = UserDefaults.standard.string(forKey: "tmdbKey") ?? ""
    private let csvURL = URL(string: "https://docs.google.com/spreadsheets/d/e/2PACX-1vQnH2Zqe52gw2KTWFy9QpxNcqq3giSz-Xn1oAIa9Sk7cgf8-aJ4_Klri9oe2Dq8EN7CiHx0Gx87B9Av/pub?output=csv")!
    private let savedCSVKey = "catalogoAGLastValidCSV"

    init() {
        // La copia locale appare anche senza rete dopo un caricamento riuscito.
        if let saved = UserDefaults.standard.string(forKey: savedCSVKey) {
            items = Self.uniqueItems(from: saved)
        }
    }

    private static func uniqueItems(from csv: String) -> [CatalogItem] {
        var merged: [CatalogItem] = []
        var indices: [String: Int] = [:]
        for var item in parseSheet(csv) {
            item.origin = "sheet"
            if let existing = indices[item.identity] {
                merged[existing] = item
            } else {
                indices[item.identity] = merged.count
                merged.append(item)
            }
        }
        return merged.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    func setAPIKey(_ key: String) {
        apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(apiKey, forKey: "tmdbKey")
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var request = URLRequest(url: csvURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 25
            request.setValue("text/csv,text/plain,*/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastError = "Google Sheets: risposta di rete non HTTP."
                return
            }
            guard http.statusCode == 200 else {
                lastError = "Google Sheets: HTTP \(http.statusCode)."
                return
            }
            // Google talvolta include il BOM UTF-8 nell'intestazione CSV.
            guard var csv = String(data: data, encoding: .utf8) else {
                lastError = "Google Sheets: dati non leggibili come UTF-8 (\(data.count) byte)."
                return
            }
            if csv.hasPrefix("\u{FEFF}") { csv.removeFirst() }
            let firstText = csv.prefix(250).lowercased()
            if firstText.contains("<!doctype html") || firstText.contains("<html") {
                lastError = "Google Sheets ha restituito una pagina HTML anziché il CSV."
                return
            }
            let parsed = Self.uniqueItems(from: csv)
            guard !parsed.isEmpty else {
                let first = csv.components(separatedBy: .newlines).first ?? ""
                let cleanHeader = first.prefix(100).replacingOccurrences(of: "\"", with: "")
                lastError = "CSV ricevuto ma nessun titolo letto (\(data.count) byte). Prima riga: \(cleanHeader)"
                return
            }
            items = parsed
            UserDefaults.standard.set(csv, forKey: savedCSVKey)
            lastError = nil
        } catch {
            lastError = "Google Sheets: \(error.localizedDescription)"
        }
    }
    // Lettore CSV robusto: virgola, punto e virgola o tabulazione.
    // Riconosce le colonne per nome, ma recupera anche i fogli esportati
    // senza intestazione purché ogni riga abbia un tipo valido movie/tv.
    private static func parseSheet(_ input: String) -> [CatalogItem] {
        // Google Sheets esporta righe CRLF (Windows). In Swift Character,
        // CRLF e un unico grapheme cluster: normalizziamo PRIMA di iterare.
        let clean = input
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let candidates: [Character] = [",", ";", "\t"]
        let parsed = candidates.map { separator -> [[String]] in
            var rows: [[String]] = []
            var row: [String] = []
            var field = ""
            var inQuotes = false
            let characters = Array(clean)
            var index = 0

            while index < characters.count {
                let current = characters[index]
                if current == "\"" {
                    if inQuotes && index + 1 < characters.count && characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes.toggle()
                    }
                } else if current == separator && !inQuotes {
                    row.append(field)
                    field = ""
                } else if (current == "\n" || current == "\r") && !inQuotes {
                    if current == "\r" && index + 1 < characters.count && characters[index + 1] == "\n" {
                        index += 1
                    }
                    row.append(field)
                    field = ""
                    if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        rows.append(row)
                    }
                    row = []
                } else {
                    field.append(current)
                }
                index += 1
            }
            if !field.isEmpty || !row.isEmpty {
                row.append(field)
                rows.append(row)
            }
            return rows
        }

        // Preferiamo il separatore che produce una tabella di almeno 5 colonne.
        let rows = parsed.max { left, right in
            func score(_ data: [[String]]) -> Int {
                let sample = data.prefix(15)
                let complete = sample.filter { $0.count >= 5 }.count
                return complete * 10 + (sample.first?.count ?? 0)
            }
            return score(left) < score(right)
        } ?? []
        guard !rows.isEmpty else { return [] }

        func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{FEFF}", with: "")
                .replacingOccurrences(of: "\"", with: "")
                .lowercased()
        }
        func cell(_ row: [String], _ column: Int) -> String {
            guard column >= 0 && column < row.count else { return "" }
            return row[column].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let titleNames = ["title", "titolo"]
        let typeNames = ["type", "tipo"]
        var columns = [0, 1, 2, 3, 4]
        var firstDataRow = 0

        if let headerIndex = rows.prefix(12).firstIndex(where: { row in
            let names = row.map(normalized)
            return names.contains(where: { titleNames.contains($0) }) &&
                   names.contains(where: { typeNames.contains($0) })
        }) {
            let names = rows[headerIndex].map(normalized)
            func find(_ options: [String], fallback: Int) -> Int {
                names.firstIndex(where: { options.contains($0) }) ?? fallback
            }
            columns = [
                find(titleNames, fallback: 0),
                find(typeNames, fallback: 1),
                find(["id", "tmdb", "tmdb_id"], fallback: 2),
                find(["search", "ricerca"], fallback: 3),
                find(["todo", "da vedere"], fallback: 4)
            ]
            firstDataRow = headerIndex + 1
        }

        return rows.dropFirst(firstDataRow).compactMap { row in
            let title = cell(row, columns[0])
            let rawType = normalized(cell(row, columns[1]))
            // Evita di scambiare una pagina o un file errato per un catalogo.
            guard !title.isEmpty && (rawType == "movie" || rawType == "tv") else {
                return nil
            }
            let flag = normalized(cell(row, columns[4]))
            let id = Int(cell(row, columns[2]))
            return CatalogItem(
                title: title,
                type: rawType,
                id: id,
                search: cell(row, columns[3]),
                todo: ["yes", "1", "true", "si", "sì"].contains(flag),
                origin: "sheet"
            )
        }
    }

}

// MARK: - Catalogo AG 2.1 — stile blu notte
private enum AGStyle {
    static let base = Color(red: 0.018, green: 0.043, blue: 0.084)
    static let surface = Color(red: 0.055, green: 0.115, blue: 0.19)
    static let surfaceLight = Color(red: 0.095, green: 0.17, blue: 0.26)
    static let accent = Color(red: 0.19, green: 0.66, blue: 0.98)
    static let muted = Color(red: 0.65, green: 0.74, blue: 0.86)
    static let border = Color(red: 0.19, green: 0.35, blue: 0.53)
    static let backdrop = LinearGradient(
        colors: [Color(red: 0.025, green: 0.085, blue: 0.155), base, Color(red: 0.008, green: 0.022, blue: 0.045)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

struct MainView: View {
    @EnvironmentObject var store: CatalogStore
    @StateObject private var admin = AdminSession()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView(selectedTab: $selectedTab) }
                .tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            NavigationStack { CollectionView(type: "movie", title: "Film") }
                .tabItem { Label("Film", systemImage: "film.fill") }.tag(1)
            NavigationStack { CollectionView(type: "tv", title: "Serie TV") }
                .tabItem { Label("Serie TV", systemImage: "tv") }.tag(2)
            NavigationStack { CollectionView(type: "todo", title: "Da vedere") }
                .tabItem { Label("Da vedere", systemImage: "bookmark.fill") }.tag(3)
        }
        .tint(AGStyle.accent)
        .environmentObject(admin)
        .task { await store.refresh() }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: CatalogStore
    @Binding var selectedTab: Int
    @State private var heroItems: [CatalogItem] = []

    private var filmCount: Int { store.items.filter { $0.isMovie && !$0.isTodo }.count }
    private var tvCount: Int { store.items.filter { !$0.isMovie && !$0.isTodo }.count }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 17) {
                    hero(height: min(max(geometry.size.height * 0.47, 275), 380))
                    HStack(spacing: 13) {
                        countCard("Film", count: filmCount, subtitle: "già visti")
                        countCard("Serie TV", count: tvCount, subtitle: "già viste")
                    }
                    Button { selectedTab = 3 } label: {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Da vedere")
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text("Apri la tua lista")
                                    .font(.subheadline)
                                    .foregroundStyle(AGStyle.muted)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(AGStyle.accent)
                                .frame(width: 40, height: 40)
                                .background(AGStyle.surfaceLight, in: Circle())
                        }
                        .padding(19)
                        .background(
                            LinearGradient(colors: [AGStyle.surfaceLight, AGStyle.surface], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 19)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 19).stroke(AGStyle.border.opacity(0.65), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    if let error = store.lastError {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.footnote).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if store.apiKey.isEmpty {
                        Label("Inserisci la chiave TMDb nelle impostazioni per mostrare il collage di locandine.", systemImage: "photo")
                            .font(.footnote).foregroundStyle(AGStyle.muted)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .background(AGStyle.backdrop.ignoresSafeArea())
        }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await store.refresh() }
        .onAppear { updateHeroIfNeeded() }
        .onChange(of: store.items.count) { _ in updateHeroIfNeeded() }
    }

    private func updateHeroIfNeeded() {
        if heroItems.isEmpty {
            let seen = store.items.filter { $0.isMovie && !$0.isTodo }
            // Locandine prese soltanto dal proprio catalogo, senza contenuti esterni inventati.
            heroItems = Array(seen.filter { $0.id != nil }.shuffled().prefix(12))
            if heroItems.count < 9 { heroItems = Array(seen.shuffled().prefix(12)) }
        }
    }

    private func hero(height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geometry in
                let tileWidth = (geometry.size.width + 56) / 3
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: 7), count: 3), spacing: 7) {
                    ForEach(0..<12, id: \.self) { index in
                        if !heroItems.isEmpty {
                            HeroPosterTile(item: heroItems[index % heroItems.count])
                                .frame(width: tileWidth, height: tileWidth * 1.38)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(AGStyle.surfaceLight)
                                .frame(width: tileWidth, height: tileWidth * 1.38)
                        }
                    }
                }
                .rotationEffect(.degrees(-8))
                .offset(x: -17, y: -48)
                .opacity(0.8)
            }
            .clipped()
            LinearGradient(stops: [
                .init(color: AGStyle.base.opacity(0.12), location: 0),
                .init(color: AGStyle.base.opacity(0.35), location: 0.38),
                .init(color: AGStyle.base.opacity(0.9), location: 0.77),
                .init(color: AGStyle.base, location: 1)
            ], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                (Text("Catalogo ").foregroundColor(.white) + Text("AG").foregroundColor(AGStyle.accent))
                    .font(.system(size: 43, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("La tua collezione di film e serie TV dal 2020")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
            HStack {
                Spacer()
                NavigationLink { SettingsView() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(AGStyle.surface.opacity(0.9), in: Circle())
                        .overlay(Circle().stroke(AGStyle.border.opacity(0.5)))
                }
                .accessibilityLabel("Impostazioni")
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 16)
            .padding(.horizontal, 10)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private func countCard(_ title: String, count: Int, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AGStyle.muted)
            Text("\(count)")
                .font(.system(size: 43, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(AGStyle.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .padding(15)
        .background(AGStyle.surface, in: RoundedRectangle(cornerRadius: 19))
        .overlay(RoundedRectangle(cornerRadius: 19).stroke(AGStyle.border.opacity(0.65), lineWidth: 1))
    }
}

private struct HeroPosterTile: View {
    @EnvironmentObject var store: CatalogStore
    let item: CatalogItem
    @State private var details: MediaDetails?
    var body: some View {
        Group {
            if let url = details?.posterURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(AGStyle.surfaceLight)
                }
            } else {
                Rectangle().fill(AGStyle.surfaceLight)
                    .overlay(Image(systemName: "film").foregroundStyle(.white.opacity(0.25)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: store.apiKey) {
            details = await TMDbService.details(for: item, apiKey: store.apiKey)
        }
    }
}

struct CollectionView: View {
    @EnvironmentObject var store: CatalogStore
    @State private var showAdd = false
    let type: String
    let title: String
    @State private var query = ""
    @State private var selectedGenre = "Tutti"
    @State private var reverseSort = false
    @State private var showFilterMenu = false
    @State private var genreIDs: [String: [Int]] = [:]
    @State private var loadingGenres = false
    private let columns = [GridItem(.flexible(), spacing: 13), GridItem(.flexible(), spacing: 13)]

    private var genreOptions: [(String, [Int])] {
        if type == "tv" {
            return [("Tutti", []), ("Dramma", [18]), ("Commedia", [35]), ("Crime", [80]), ("Fantascienza", [10765]), ("Azione", [10759])]
        }
        if type == "todo" {
            return [("Tutti", []), ("Film", []), ("Serie TV", []), ("Azione", [28, 10759]), ("Horror", [27])]
        }
        return [("Tutti", []), ("Azione", [28]), ("Commedia", [35]), ("Horror", [27]), ("Thriller", [53]), ("Fantascienza", [878])]
    }

    private var sectionItems: [CatalogItem] {
        store.items.filter { item in
            type == "todo" ? item.isTodo : (type == "tv" ? !item.isMovie && !item.isTodo : item.isMovie && !item.isTodo)
        }
    }

    private var filtered: [CatalogItem] {
        let wantedIDs = genreOptions.first(where: { $0.0 == selectedGenre })?.1 ?? []
        let result = sectionItems.filter { item in
            guard query.isEmpty || item.title.localizedStandardContains(query) else { return false }
            if selectedGenre == "Film" { return item.isMovie }
            if selectedGenre == "Serie TV" { return !item.isMovie }
            if wantedIDs.isEmpty { return true }
            return !(genreIDs[item.identity] ?? []).filter { wantedIDs.contains($0) }.isEmpty
        }
        return result.sorted {
            reverseSort
                ? $0.title.localizedStandardCompare($1.title) == .orderedDescending
                : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(type == "todo" ? "Film e serie che vuoi guardare" : "La tua collezione")
                        .font(.caption).foregroundStyle(AGStyle.muted)
                }
                Spacer()
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 47, height: 47)
                        .background(AGStyle.accent, in: Circle())
                }
                .accessibilityLabel("Aggiungi titolo")
            }
            .padding(.horizontal, 19)
            .padding(.top, 10)
            .padding(.bottom, 15)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(AGStyle.muted)
                TextField(type == "movie" ? "Cerca un film..." : (type == "tv" ? "Cerca una serie TV..." : "Cerca tra i titoli da vedere..."), text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(.white)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(AGStyle.muted) }
                }
            }
            .padding(.horizontal, 15)
            .frame(height: 45)
            .background(AGStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AGStyle.border.opacity(0.45), lineWidth: 1))
            .padding(.horizontal, 19)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(genreOptions.map { $0.0 }, id: \.self) { genre in
                        Button { chooseGenre(genre) } label: {
                            Text(genre)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(selectedGenre == genre ? AGStyle.base : .white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(selectedGenre == genre ? AGStyle.accent : AGStyle.surface, in: Capsule())
                                .overlay(Capsule().stroke(selectedGenre == genre ? AGStyle.accent : AGStyle.border.opacity(0.55)))
                        }
                        .disabled(loadingGenres)
                    }
                }
                .padding(.horizontal, 19)
            }
            .padding(.top, 13)
            .padding(.bottom, 9)

            HStack(spacing: 8) {
                Button { reverseSort.toggle() } label: {
                    Label(reverseSort ? "Ordine: Z-A" : "Ordine: A-Z", systemImage: "arrow.up.arrow.down")
                        .font(.caption)
                        .foregroundStyle(AGStyle.muted)
                }
                Spacer()
                if loadingGenres {
                    ProgressView().tint(AGStyle.accent)
                    Text("Caricamento generi...").font(.caption2).foregroundStyle(AGStyle.muted)
                } else {
                    Text("\(filtered.count) titoli").font(.caption).foregroundStyle(AGStyle.muted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            ScrollView {
                LazyVGrid(columns: columns, alignment: .center, spacing: 18) {
                    ForEach(filtered, id: \.identity) { item in
                        NavigationLink { DetailView(item: item) } label: {
                            PosterCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
            .refreshable { await store.refresh() }
            .overlay {
                if filtered.isEmpty && !loadingGenres {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.title2)
                        Text("Nessun titolo").font(.headline)
                        Text("Prova un'altra ricerca o cambia filtro.").font(.footnote)
                    }
                    .foregroundStyle(AGStyle.muted)
                }
            }
        }
        .background(AGStyle.backdrop.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showAdd) { AddMovieView() }
    }

    private func chooseGenre(_ genre: String) {
        selectedGenre = genre
        guard let targets = genreOptions.first(where: { $0.0 == genre })?.1, !targets.isEmpty else { return }
        guard !store.apiKey.isEmpty else { selectedGenre = "Tutti"; return }
        let missing = sectionItems.filter { genreIDs[$0.identity] == nil }
        guard !missing.isEmpty else { return }
        loadingGenres = true
        let apiKey = store.apiKey
        Task {
            // Massimo quattro richieste TMDb in parallelo per non saturare la rete.
            await withTaskGroup(of: (String, [Int]).self) { group in
                var iterator = missing.makeIterator()
                for _ in 0..<4 {
                    if let item = iterator.next() {
                        group.addTask {
                            let details = await TMDbService.details(for: item, apiKey: apiKey)
                            return (item.identity, details?.genreIDs ?? [])
                        }
                    }
                }
                for await (key, ids) in group {
                    genreIDs[key] = ids
                    if let item = iterator.next() {
                        group.addTask {
                            let details = await TMDbService.details(for: item, apiKey: apiKey)
                            return (item.identity, details?.genreIDs ?? [])
                        }
                    }
                }
            }
            loadingGenres = false
        }
    }
}

private struct PosterCard: View {
    @EnvironmentObject var store: CatalogStore
    let item: CatalogItem
    @State private var details: MediaDetails?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: details?.posterURL, title: item.title)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(AGStyle.border.opacity(0.5), lineWidth: 0.8))
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(height: 36, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(details?.releaseYear.isEmpty == false ? (details?.releaseYear ?? "") : (item.isMovie ? "Film" : "Serie TV"))
                .font(.caption).foregroundStyle(AGStyle.muted)
        }
        .task(id: store.apiKey) {
            details = await TMDbService.details(for: item, apiKey: store.apiKey)
        }
    }
}

private struct PosterImage: View {
    let url: URL?
    let title: String
    var body: some View {
        GeometryReader { geo in
            Group {
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        default: placeholder
                        }
                    }
                } else { placeholder }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .background(AGStyle.surface)
    }
    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [AGStyle.surfaceLight, AGStyle.surface, AGStyle.base], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "film.stack")
                .font(.system(size: 32)).foregroundStyle(.white.opacity(0.25))
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(12)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

struct PosterView: View {
    @EnvironmentObject var store: CatalogStore
    let item: CatalogItem
    let width: CGFloat?
    let height: CGFloat
    @State private var details: MediaDetails?
    var body: some View {
        PosterImage(url: details?.posterURL, title: item.title)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .task(id: store.apiKey) {
                details = await TMDbService.details(for: item, apiKey: store.apiKey)
            }
    }
}

struct DetailView: View {
    @EnvironmentObject var store: CatalogStore
    @EnvironmentObject var admin: AdminSession
    @Environment(\.dismiss) private var dismiss
    let item: CatalogItem
    @State private var details: MediaDetails?
    @State private var confirmDelete = false
    @State private var errorMessage: String?
    @State private var busy = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    PosterView(item: item, width: 135, height: 203)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.title).font(.title2.bold())
                        Label(item.displayType, systemImage: item.isMovie ? "film" : "tv")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if item.isTodo { Label("Da vedere", systemImage: "bookmark.fill").foregroundStyle(.cyan) }
                        if let year = details?.releaseYear, !year.isEmpty { Text(year).foregroundStyle(.secondary) }
                        if let rating = details?.vote_average, rating > 0 {
                            Label(String(format: "%.1f / 10", rating), systemImage: "star.fill").foregroundStyle(.yellow)
                        }
                    }
                }
                Divider()
                if admin.isLoggedIn {
                    HStack(spacing: 12) {
                        if item.isTodo {
                            Button("Segna come visto") { Task { await perform("seen") } }
                                .buttonStyle(.borderedProminent)
                                .disabled(busy)
                        }
                        Button("Elimina", role: .destructive) { confirmDelete = true }
                            .buttonStyle(.bordered)
                            .disabled(busy)
                    }
                } else {
                    NavigationLink("Accedi per modificare", destination: AdminLoginView())
                        .font(.footnote)
                }
                if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.orange) }
                Text("Trama").font(.title3.bold())
                Text(details?.overview.flatMap { $0.isEmpty ? nil : $0 } ?? (store.apiKey.isEmpty ? "Aggiungi la chiave TMDb nelle impostazioni per caricare la trama." : "Trama non disponibile."))
                    .foregroundStyle(.secondary)
            }.padding(20)
        }
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(red: 0.025, green: 0.035, blue: 0.065))
        .task(id: store.apiKey) { details = await TMDbService.details(for: item, apiKey: store.apiKey) }
        .confirmationDialog("Eliminare \(item.title)?", isPresented: $confirmDelete) {
            Button("Elimina definitivamente", role: .destructive) { Task { await perform("delete") } }
        } message: { Text("Il titolo sarà eliminato da Google Sheets.") }
    }
    private func perform(_ operation: String) async {
        busy = true
        defer { busy = false }
        do {
            try await admin.perform(operation, title: item.title, type: item.type)
            await store.refresh()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: CatalogStore
    @EnvironmentObject var admin: AdminSession
    @State private var key = ""
    var body: some View {
        Form {
            Section("Amministrazione") {
                if admin.isLoggedIn {
                    Label("Accesso attivo", systemImage: "checkmark.shield")
                    Button("Esci") { Task { await admin.logout() } }
                } else {
                    NavigationLink("Accedi", destination: AdminLoginView())
                }
                Text("Le sessioni Cloudflare durano 30 minuti. La password non viene memorizzata nell’app.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("TMDb") {
                SecureField("Chiave API TMDb v3", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Salva chiave") { store.setAPIKey(key) }
                Text("La chiave rimane sul tuo iPhone e non viene inserita nel repository GitHub. Serve per poster e trame.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Sincronizzazione") {
                LabeledContent("Google Sheets", value: "Sincronizzato")
                Button("Aggiorna catalogo") { Task { await store.refresh() } }
                if let error = store.lastError { Text(error).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Impostazioni")
        .onAppear { key = store.apiKey }
    }
}


// MARK: - API Cloudflare
private enum AdminAPI {
    static let base = URL(string: "https://catalogo-ag-api.joshgeogr.workers.dev")!

    static func send(_ path: String, token: String? = nil, body: [String: String]? = nil) async throws -> [String: Any] {
        let url = base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AdminError.message("Risposta del server non valida") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AdminError.message("Risposta Cloudflare non valida")
        }
        if http.statusCode == 401 { throw AdminError.unauthorized }
        if http.statusCode == 429 { throw AdminError.message("Troppi tentativi. Riprova tra un minuto.") }
        if http.statusCode >= 500 { throw AdminError.message("Errore temporaneo del server") }
        if http.statusCode >= 400 || (json["success"] as? Bool) == false {
            let code = (json["error"] as? String) ?? (json["message"] as? String) ?? "Operazione non riuscita"
            throw AdminError.message(code == "ALREADY_EXISTS" ? "Il titolo è già presente" : code)
        }
        return json
    }
}

private enum AdminError: LocalizedError {
    case unauthorized
    case message(String)
    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Accesso scaduto. Effettua nuovamente il login."
        case .message(let value): return value
        }
    }
}

// Il token, non la password, è conservato nel Portachiavi iOS.
private enum SessionKeychain {
    static let account = "cloudflare-session"
    static let service = "it.catalogoag.ios"
    static func get() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func set(_ token: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard let token, let data = token.data(using: .utf8) else { return }
        var insertion = query
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insertion as CFDictionary, nil)
    }
}

@MainActor
final class AdminSession: ObservableObject {
    @Published private(set) var isLoggedIn = false
    @Published var errorMessage: String?
    private var token: String?

    init() {
        token = SessionKeychain.get()
        isLoggedIn = token != nil
        Task { await checkSession() }
    }
    func checkSession() async {
        guard let token else { isLoggedIn = false; return }
        do {
            let response = try await AdminAPI.send("session", token: token)
            if (response["valid"] as? Bool) == true { isLoggedIn = true }
            else { clear() }
        } catch {
            // Con rete assente non revocare il token, ma non dare accesso alle modifiche.
            isLoggedIn = false
        }
    }
    func login(password: String) async throws {
        let response = try await AdminAPI.send("login", body: ["password": password])
        guard let newToken = response["token"] as? String, !newToken.isEmpty else {
            throw AdminError.message("Token non ricevuto")
        }
        token = newToken
        SessionKeychain.set(newToken)
        isLoggedIn = true
    }
    func logout() async {
        if let token {
            // La revoca lato server ha precedenza, ma l'uscita locale avviene comunque.
            _ = try? await AdminAPI.send("logout", token: token, body: [:])
        }
        clear()
    }
    func perform(_ action: String, title: String, type: String, id: String = "", search: String = "", todo: String = "no") async throws {
        guard let token, isLoggedIn else { throw AdminError.unauthorized }
        let path: String
        switch action {
        case "add": path = "movie/add"
        case "seen": path = "movie/seen"
        case "delete": path = "movie/delete"
        default: throw AdminError.message("Operazione non riconosciuta")
        }
        var body = ["title": title, "type": type]
        if action == "add" {
            body["id"] = id
            body["search"] = search
            body["todo"] = todo
        }
        do {
            _ = try await AdminAPI.send(path, token: token, body: body)
        } catch AdminError.unauthorized {
            clear()
            throw AdminError.unauthorized
        }
    }
    private func clear() {
        token = nil
        isLoggedIn = false
        SessionKeychain.set(nil)
    }
}

struct AdminLoginView: View {
    @EnvironmentObject var admin: AdminSession
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var isBusy = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Accesso Catalogo AG") {
                Text("Inserisci la password amministratore Cloudflare.")
                    .foregroundStyle(.secondary)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit { Task { await authenticate() } }
                Button(isBusy ? "Accesso in corso…" : "Accedi") {
                    Task { await authenticate() }
                }
                .disabled(isBusy || password.isEmpty)
                if let message { Text(message).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Amministratore")
    }
    private func authenticate() async {
        guard !password.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await admin.login(password: password)
            password = ""
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Ricerca TMDb per il modulo Aggiungi
private enum TMDbLookup {
    static func search(_ query: String, type: String, apiKey: String) async throws -> [MediaDetails] {
        guard !apiKey.isEmpty else { throw TMDbLookupError.missingKey }
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/\(type)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "language", value: "it-IT"),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "page", value: "1")
        ]
        guard let url = components.url else { throw TMDbLookupError.invalidRequest }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TMDbLookupError.serviceUnavailable
        }
        return Array(try JSONDecoder().decode(SearchResponse.self, from: data).results.prefix(15))
    }
}

private enum TMDbLookupError: LocalizedError {
    case missingKey, invalidRequest, serviceUnavailable
    var errorDescription: String? {
        switch self {
        case .missingKey: return "Inserisci prima la chiave API TMDb nelle Impostazioni dell'app."
        case .invalidRequest: return "Ricerca non valida."
        case .serviceUnavailable: return "TMDb non risponde. Riprova o usa l'inserimento manuale."
        }
    }
}

struct AddMovieView: View {
    @EnvironmentObject var store: CatalogStore
    @EnvironmentObject var admin: AdminSession
    @Environment(\.dismiss) private var dismiss

    @State private var type = "movie"
    @State private var query = ""
    @State private var results: [MediaDetails] = []
    @State private var selected: MediaDetails?
    @State private var searching = false
    @State private var searchMessage: String?
    @State private var manualEntry = false

    @State private var title = ""
    @State private var tmdbId = ""
    @State private var alternateSearch = ""
    @State private var todo = false
    @State private var busy = false
    @State private var message: String?

    private var duplicateInCatalog: Bool {
        let normalized = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return store.items.contains {
            $0.type == type &&
            $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines) == normalized
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !admin.isLoggedIn {
                    AdminLoginView()
                } else {
                    Form {
                        Section {
                            Picker("Cosa vuoi aggiungere?", selection: $type) {
                                Text("Film").tag("movie")
                                Text("Serie TV").tag("tv")
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: type) { _ in
                                clearSelection()
                                results = []
                                searchMessage = nil
                            }
                        }

                        if !manualEntry {
                            Section("Trova su TMDb") {
                                HStack {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundStyle(.secondary)
                                    TextField(type == "movie" ? "Cerca un film..." : "Cerca una serie TV...", text: $query)
                                        .textInputAutocapitalization(.sentences)
                                        .autocorrectionDisabled()
                                    if !query.isEmpty {
                                        Button {
                                            query = ""
                                            clearSelection()
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                                if store.apiKey.isEmpty {
                                    Label("Per cercare su TMDb, configura la chiave API nelle Impostazioni.", systemImage: "key")
                                        .font(.footnote)
                                        .foregroundStyle(.orange)
                                } else if searching {
                                    HStack {
                                        ProgressView()
                                        Text("Cerco su TMDb...")
                                            .foregroundStyle(.secondary)
                                    }
                                } else if let searchMessage {
                                    Text(searchMessage)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if selected == nil && !results.isEmpty {
                                Section("Risultati") {
                                    ForEach(results, id: \.id) { item in
                                        Button { select(item) } label: {
                                            HStack(spacing: 12) {
                                                AsyncImage(url: item.posterURL) { phase in
                                                    if let image = phase.image {
                                                        image.resizable().scaledToFill()
                                                    } else {
                                                        RoundedRectangle(cornerRadius: 6)
                                                            .fill(Color.gray.opacity(0.2))
                                                            .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                                                    }
                                                }
                                                .frame(width: 48, height: 72)
                                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                                VStack(alignment: .leading, spacing: 5) {
                                                    Text(item.displayTitle)
                                                        .font(.subheadline.weight(.semibold))
                                                        .foregroundStyle(.primary)
                                                        .multilineTextAlignment(.leading)
                                                    Text(item.releaseYear.isEmpty ? "Anno non disponibile" : item.releaseYear)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                Spacer(minLength: 0)
                                                Image(systemName: "chevron.right")
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            if let selected {
                                Section("Titolo selezionato") {
                                    HStack(spacing: 12) {
                                        AsyncImage(url: selected.posterURL) { phase in
                                            if let image = phase.image {
                                                image.resizable().scaledToFill()
                                            } else {
                                                Color.gray.opacity(0.2)
                                            }
                                        }
                                        .frame(width: 58, height: 88)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(selected.displayTitle).font(.headline)
                                            Text(selected.releaseYear)
                                                .font(.caption).foregroundStyle(.secondary)
                                            Text("TMDb ID: \(selected.id)")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    Button("Cambia risultato") {
                                        clearSelection()
                                    }
                                    .foregroundStyle(AGStyle.accent)
                                }
                            }
                        }

                        if manualEntry || selected != nil {
                            Section("Conferma aggiunta") {
                                TextField("Titolo da salvare", text: $title)
                                if manualEntry {
                                    TextField("ID TMDb (facoltativo)", text: $tmdbId)
                                        .keyboardType(.numberPad)
                                    TextField("Ricerca alternativa (facoltativa)", text: $alternateSearch)
                                }
                                Toggle("Da vedere", isOn: $todo)
                            }
                            if duplicateInCatalog {
                                Section {
                                    Label("Questo titolo è già nel catalogo. Controlla prima di procedere.", systemImage: "exclamationmark.triangle")
                                        .font(.footnote)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Section {
                                Button {
                                    Task { await add() }
                                } label: {
                                    HStack {
                                        Spacer()
                                        if busy { ProgressView() }
                                        Text(busy ? "Salvataggio..." : "Aggiungi al catalogo")
                                            .fontWeight(.semibold)
                                        Spacer()
                                    }
                                }
                                .disabled(busy || duplicateInCatalog || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                if let message { Text(message).foregroundStyle(.orange) }
                            }
                        }

                        Section {
                            Button(manualEntry ? "Torna alla ricerca TMDb" : "Inserimento manuale") {
                                manualEntry.toggle()
                                clearSelection()
                                message = nil
                            }
                        } footer: {
                            Text("L'inserimento manuale è utile per i titoli che TMDb non trova o per usare un nome personalizzato.")
                        }
                    }
                }
            }
            .navigationTitle("Aggiungi titolo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .task(id: "\(type)|\(query)|\(manualEntry)|\(selected?.id ?? 0)") {
                guard admin.isLoggedIn, !manualEntry, selected == nil else { return }
                let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.count >= 2 else {
                    results = []
                    searchMessage = value.isEmpty ? "Scrivi un titolo per cercarlo." : "Scrivi almeno due caratteri."
                    searching = false
                    return
                }
                searching = true
                searchMessage = nil
                do {
                    try await Task.sleep(nanoseconds: 400_000_000)
                    try Task.checkCancellation()
                    let found = try await TMDbLookup.search(value, type: type, apiKey: store.apiKey)
                    try Task.checkCancellation()
                    results = found
                    searchMessage = found.isEmpty ? "Nessun risultato. Prova un altro nome oppure l'inserimento manuale." : nil
                } catch is CancellationError {
                    return
                } catch {
                    results = []
                    searchMessage = error.localizedDescription
                }
                searching = false
            }
        }
    }

    private func clearSelection() {
        selected = nil
        title = ""
        tmdbId = ""
        alternateSearch = ""
        message = nil
    }

    private func select(_ item: MediaDetails) {
        selected = item
        title = item.displayTitle
        tmdbId = String(item.id)
        alternateSearch = ""
        message = nil
        results = []
    }

    private func add() async {
        guard !busy, !duplicateInCatalog else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await admin.perform(
                "add",
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                type: type,
                id: tmdbId.trimmingCharacters(in: .whitespacesAndNewlines),
                search: alternateSearch.trimmingCharacters(in: .whitespacesAndNewlines),
                todo: todo ? "yes" : "no"
            )
            await store.refresh()
            dismiss()
        } catch {
            // Non riprovare automaticamente: il salvataggio potrebbe essere già avvenuto.
            message = error.localizedDescription
        }
    }
}
