import SwiftUI

@main
struct CatalogoAGApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack {
                VStack(spacing: 18) {
                    Image(systemName: "film.stack.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.purple)
                    Text("Catalogo AG")
                        .font(.largeTitle.bold())
                    Text("La tua collezione, sempre con te.")
                        .foregroundStyle(.secondary)
                    Text("Test SwiftUI • LiveContainer")
                        .font(.footnote)
                        .padding(10)
                        .background(.thinMaterial, in: Capsule())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Home")
            }
            .tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack {
                List {
                    Label("Film di prova", systemImage: "film")
                    Text("Qui collegheremo il tuo catalogo")
                        .foregroundStyle(.secondary)
                }
                .navigationTitle("Film")
            }
            .tabItem { Label("Film", systemImage: "film") }
            NavigationStack {
                List {
                    Label("Serie di prova", systemImage: "tv")
                    Text("Qui collegheremo le tue serie")
                        .foregroundStyle(.secondary)
                }
                .navigationTitle("Serie TV")
            }
            .tabItem { Label("Serie", systemImage: "tv") }
        }
    }
}
