import AppKit
import SwiftUI

struct AboutPane: View {
    private static let repository = URL(string: "https://github.com/chriscorbell/tabber")!

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

            Section("Built with") {
                credit("llama.cpp", "MIT License", "https://github.com/ggml-org/llama.cpp")
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
