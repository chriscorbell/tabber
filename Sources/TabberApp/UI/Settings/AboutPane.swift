import AppKit
import SwiftUI

struct AboutPane: View {
    private static let repository = URL(string: "https://github.com/chriscorbell/tabber")!

    @EnvironmentObject private var updater: Updater

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tabber")
                            .font(.title2.weight(.semibold))
                        Text(version)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Free and open source under the MIT License.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)

                LabeledContent("Source code") {
                    Link("github.com/chriscorbell/tabber", destination: Self.repository)
                }
            }

            Section("Updates") {
                if updater.isAvailable {
                    Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                    Toggle(isOn: $updater.installsAutomatically) {
                        Text("Install updates automatically")
                        Text("New versions download in the background and install the next time Tabber quits.")
                    }
                    .disabled(!updater.checksAutomatically)
                    LabeledContent {
                        Button("Check Now") { updater.checkForUpdates() }
                    } label: {
                        Text("Check for updates")
                        Text(lastCheck)
                    }
                } else {
                    Text("Development builds don't update themselves.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Built with") {
                credit("llama.cpp", "MIT License", "https://github.com/ggml-org/llama.cpp")
                credit("Sparkle", "MIT License", "https://github.com/sparkle-project/Sparkle")
                credit("Lucide icons", "ISC License", "https://lucide.dev/license")
            }

            Section("Models") {
                credit("Qwen3 by Alibaba Cloud", "Apache 2.0", "https://huggingface.co/Qwen/Qwen3-1.7B-Base")
                credit("Gemma 4 by Google", "Apache 2.0", "https://ai.google.dev/gemma/docs/gemma_4_license")
                credit("GGUF quantizations by mradermacher", "Same as the model", "https://huggingface.co/mradermacher")
            }
        }
        .formStyle(.grouped)
    }

    private var lastCheck: String {
        guard let date = updater.lastCheck else { return "Not checked yet" }
        return "Last checked \(date.formatted(.relative(presentation: .named)))"
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "development build"
        if let build = info?["CFBundleVersion"] as? String, build != short {
            return "Version \(short) (\(build))"
        }
        return "Version \(short)"
    }

    private func credit(_ name: String, _ license: String, _ url: String) -> some View {
        LabeledContent(name) {
            Link(license, destination: URL(string: url)!)
        }
    }
}
