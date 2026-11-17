import SwiftUI

struct StudioHelp: View {
    let title: String
    let detail: String
    let assets: [String]
    var illustration = false
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "info.circle").font(.body)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("About \(title)")
        .help("About \(title)")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            StudioHelpPopup(title: title, detail: detail, assets: assets, illustration: illustration) { open = false }
        }
    }
}

struct StudioHelpPopup: View {
    let title: String
    let detail: String
    let assets: [String]
    let illustration: Bool
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                Text(detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                ForEach(assets, id: \.self) { asset in
                    Image(asset).resizable().scaledToFit().accessibilityLabel(title + " diagram")
                }
                if illustration { Text("Illustration").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("Done", action: close).keyboardShortcut(.cancelAction)
                }
            }.padding(16)
        }.frame(width: 350).frame(maxHeight: 500)
    }
}
