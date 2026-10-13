import SwiftUI

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
    var displayTitle: String { title ?? name ?? "Titolo" }
    var releaseYear: String { String((release_date ?? first_air_date ?? "").prefix(4)) }
    var posterURL: URL? { poster_path.flatMap { URL(string: "https://image.tmdb.org/t/p/w500\($0)") } }
    var backdropURL: URL? { backdrop_path.flatMap { URL(string: "https://image.tmdb.org/t/p/w780\($0)") } }
}

struct SearchResponse: Decodable { let results: [MediaDetails] }

enum TMDbService {
    static func details(for item: CatalogItem, apiKey: String) async -> MediaDetails? {
        guard !apiKey.isEmpty else { return nil }
        let kind = item.isMovie ? "movie" : "tv"
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
            if item.id != nil { return try JSONDecoder().decode(MediaDetails.self, from: data) }
            return try JSONDecoder().decode(SearchResponse.self, from: data).results.first
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
    private var base: [CatalogItem] = []

    init() {
        if let url = Bundle.main.url(forResource: "catalog", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([CatalogItem].self, from: data) {
            base = decoded
        }
        items = base
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
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            guard let csv = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
            var merged = base
            var indices = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($0.element.identity, $0.offset) })
            for var item in Self.parseSheet(csv) {
                item.origin = "sheet"
                if let existing = indices[item.identity] { merged[existing] = item }
                else { indices[item.identity] = merged.count; merged.append(item) }
            }
            items = merged.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            lastError = nil
        } catch {
            lastError = "Non riesco ad aggiornare Google Sheets. Mostro i titoli già disponibili."
        }
    }
    private static func parseSheet(_ input: String) -> [CatalogItem] {
        // CSV parser: supports quoted commas, embedded line breaks, and escaped double quotes.
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else { quoted.toggle() }
            } else if c == "," && !quoted {
                row.append(field); field = ""
            } else if (c == "\n" || c == "\r") && !quoted {
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                row.append(field); field = ""
                if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
                row = []
            } else { field.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        guard let header = rows.first else { return [] }
        let headers = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func value(_ name: String, _ row: [String]) -> String {
            guard let index = headers.firstIndex(of: name), index < row.count else { return "" }
            return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rows.dropFirst().compactMap { row in
            let title = value("title", row)
            guard !title.isEmpty else { return nil }
            let flag = value("todo", row).lowercased()
            return CatalogItem(title: title, type: value("type", row) == "tv" ? "tv" : "movie", id: Int(value("id", row)), search: value("search", row), todo: ["yes", "1", "true"].contains(flag), origin: "sheet")
        }
    }
}

struct MainView: View {
    @EnvironmentObject var store: CatalogStore
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { CollectionView(type: "movie", title: "Film") }
                .tabItem { Label("Film", systemImage: "film.fill") }
            NavigationStack { CollectionView(type: "tv", title: "Serie TV") }
                .tabItem { Label("Serie", systemImage: "tv.fill") }
            NavigationStack { CollectionView(type: "todo", title: "Da vedere") }
                .tabItem { Label("Da vedere", systemImage: "bookmark.fill") }
        }
        .tint(.cyan)
        .task { await store.refresh() }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: CatalogStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("LA TUA COLLEZIONE").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.cyan)
                    Text("Catalogo AG").font(.system(size: 39, weight: .bold, design: .rounded))
                    Text("Film e serie TV dal 2020").foregroundStyle(.secondary)
                }.padding(.top, 20)
                HStack(spacing: 12) {
                    stat("Film", store.items.filter { $0.isMovie && !$0.isTodo }.count, "film.stack")
                    stat("Serie", store.items.filter { !$0.isMovie }.count, "tv")
                    stat("Da vedere", store.items.filter { $0.isTodo }.count, "bookmark")
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Dal tuo catalogo").font(.title2.bold())
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(Array(store.items.filter { !$0.todo }.prefix(12)), id: \.identity) { item in
                                NavigationLink { DetailView(item: item) } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        PosterView(item: item, width: 132, height: 194)
                                        Text(item.title).font(.caption.weight(.medium)).lineLimit(2).frame(width: 132, alignment: .leading)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                if let error = store.lastError {
                    Label(error, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.orange)
                }
                if store.apiKey.isEmpty {
                    Label("Per visualizzare le locandine, inserisci la chiave TMDb nelle impostazioni.", systemImage: "photo")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
        .background(Color(red: 0.025, green: 0.035, blue: 0.065))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") } } }
        .refreshable { await store.refresh() }
    }
    private func stat(_ title: String, _ count: Int, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).foregroundStyle(.cyan)
            Text("\(count)").font(.title2.bold())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct CollectionView: View {
    @EnvironmentObject var store: CatalogStore
    let type: String
    let title: String
    @State private var query = ""
    private let columns = [GridItem(.flexible(), spacing: 13), GridItem(.flexible(), spacing: 13)]
    private var filtered: [CatalogItem] {
        store.items.filter { item in
            let inSection = type == "todo" ? item.isTodo : type == "tv" ? !item.isMovie : item.isMovie && !item.isTodo
            return inSection && (query.isEmpty || item.title.localizedStandardContains(query))
        }
    }
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(filtered, id: \.identity) { item in
                    NavigationLink { DetailView(item: item) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            PosterView(item: item, width: nil, height: 230)
                            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 17).padding(.top, 8).padding(.bottom, 30)
        }
        .background(Color(red: 0.025, green: 0.035, blue: 0.065))
        .navigationTitle(title)
        .searchable(text: $query, prompt: "Cerca per titolo")
        .overlay {
            if filtered.isEmpty {
                VStack(spacing: 12) { Image(systemName: "magnifyingglass").font(.largeTitle); Text("Nessun titolo").font(.headline); Text("Prova un’altra ricerca.").foregroundStyle(.secondary) }
            }
        }
        .refreshable { await store.refresh() }
    }
}

struct PosterView: View {
    @EnvironmentObject var store: CatalogStore
    let item: CatalogItem
    let width: CGFloat?
    let height: CGFloat
    @State private var details: MediaDetails?
    var body: some View {
        Group {
            if let url = details?.posterURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: { placeholder }
            } else { placeholder }
        }
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .clipped()
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .task(id: store.apiKey) { details = await TMDbService.details(for: item, apiKey: store.apiKey) }
    }
    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [.indigo.opacity(0.6), .black, .cyan.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 9) {
                Image(systemName: item.isMovie ? "film" : "tv").font(.largeTitle).foregroundStyle(.white.opacity(0.7))
                Text(item.title).font(.footnote.weight(.medium)).multilineTextAlignment(.center).padding(.horizontal, 10).lineLimit(4)
            }
        }
    }
}

struct DetailView: View {
    @EnvironmentObject var store: CatalogStore
    let item: CatalogItem
    @State private var details: MediaDetails?
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
                Text("Trama").font(.title3.bold())
                Text(details?.overview.flatMap { $0.isEmpty ? nil : $0 } ?? (store.apiKey.isEmpty ? "Aggiungi la chiave TMDb nelle impostazioni per caricare la trama." : "Trama non disponibile."))
                    .foregroundStyle(.secondary)
            }.padding(20)
        }
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(red: 0.025, green: 0.035, blue: 0.065))
        .task(id: store.apiKey) { details = await TMDbService.details(for: item, apiKey: store.apiKey) }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: CatalogStore
    @State private var key = ""
    var body: some View {
        Form {
            Section("TMDb") {
                SecureField("Chiave API TMDb v3", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Salva chiave") { store.setAPIKey(key) }
                Text("La chiave rimane sul tuo iPhone e non viene inserita nel repository GitHub. Serve per poster e trame.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Sincronizzazione") {
                LabeledContent("Google Sheets", value: "Solo lettura")
                Button("Aggiorna catalogo") { Task { await store.refresh() } }
                if let error = store.lastError { Text(error).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Impostazioni")
        .onAppear { key = store.apiKey }
    }
}
