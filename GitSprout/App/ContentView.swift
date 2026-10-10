import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let session = model.session {
                WorkspaceView(session: session, model: model)
            } else {
                WelcomeView(model: model)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .alert(
            "Couldn't Open",
            isPresented: Binding(
                get: { model.openError != nil },
                set: { if !$0 { model.openError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.openError ?? "")
        }
    }
}

private struct WelcomeView: View {
    var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("GitSprout")
                .font(.largeTitle)
            Text("Open a folder to work with diffs, history, and stashes.")
                .foregroundStyle(.secondary)
            Button("Open Repository…") {
                model.openPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            if !model.recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent Repositories")
                        .font(.headline)
                    ForEach(model.recent, id: \.self) { path in
                        Button(path) {
                            Task { await model.open(path: path) }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                }
                .frame(maxWidth: 480, alignment: .leading)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView(model: AppModel())
}
