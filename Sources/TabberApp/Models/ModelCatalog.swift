import Foundation

extension ModelManager.Model {
    /// Base (pretrained) GGUF models, smallest first. Sizes are the exact file sizes on Hugging Face
    /// and are used to validate downloads and detect complete files.
    static let catalog: [ModelManager.Model] = [
        .init(
            id: "qwen3-0.6b-base",
            displayName: "Qwen3 0.6B",
            tier: "Tiny",
            summary: "Lightest and quickest. Simpler suggestions.",
            family: "Qwen3",
            repo: "mradermacher/Qwen3-0.6B-Base-i1-GGUF",
            fileName: "Qwen3-0.6B-Base.i1-Q4_K_M.gguf",
            sizeBytes: 396_705_184,
            minRAMGB: 8,
            license: .apache2(url: "https://huggingface.co/Qwen/Qwen3-0.6B-Base")
        ),
        .init(
            id: "qwen3-1.7b-base",
            displayName: "Qwen3 1.7B",
            tier: "Fast",
            summary: "Quick on any Mac with 8 GB of memory.",
            family: "Qwen3",
            repo: "mradermacher/Qwen3-1.7B-Base-i1-GGUF",
            fileName: "Qwen3-1.7B-Base.i1-Q4_K_M.gguf",
            sizeBytes: 1_107_409_248,
            minRAMGB: 8,
            license: .apache2(url: "https://huggingface.co/Qwen/Qwen3-1.7B-Base")
        ),
        .init(
            id: "gemma-4-e2b",
            displayName: "Gemma 4 E2B",
            tier: "Balanced",
            summary: "Better suggestions. Best with 16 GB or more.",
            family: "Gemma 4",
            repo: "mradermacher/gemma-4-E2B-i1-GGUF",
            fileName: "gemma-4-E2B.i1-Q4_K_M.gguf",
            sizeBytes: 3_427_862_240,
            minRAMGB: 16,
            license: .gemma4
        ),
        .init(
            id: "qwen3-4b-base",
            displayName: "Qwen3 4B",
            tier: "Quality",
            summary: "Richer wording. Best with 16 GB or more.",
            family: "Qwen3",
            repo: "mradermacher/Qwen3-4B-Base-i1-GGUF",
            fileName: "Qwen3-4B-Base.i1-Q4_K_M.gguf",
            sizeBytes: 2_497_280_960,
            minRAMGB: 16,
            license: .apache2(url: "https://huggingface.co/Qwen/Qwen3-4B-Base")
        ),
        .init(
            id: "gemma-4-e4b",
            displayName: "Gemma 4 E4B",
            tier: "Best",
            summary: "Highest quality. For 24 GB or more.",
            family: "Gemma 4",
            repo: "mradermacher/gemma-4-E4B-i1-GGUF",
            fileName: "gemma-4-E4B.i1-Q4_K_M.gguf",
            sizeBytes: 5_335_274_240,
            minRAMGB: 24,
            license: .gemma4
        ),
    ]
}

extension ModelManager.Model {
    init(
        id: String, displayName: String, tier: String, summary: String, family: String,
        repo: String, fileName: String, sizeBytes: Int64, minRAMGB: Int, license: License, notes: String? = nil
    ) {
        self.init(
            id: id,
            displayName: displayName,
            tier: tier,
            summary: summary,
            family: family,
            fileName: fileName,
            url: URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)?download=true")!,
            sizeBytes: sizeBytes,
            minRAMGB: minRAMGB,
            notes: notes,
            license: license
        )
    }
}

extension ModelManager.Model.License {
    static func apache2(url: String) -> Self {
        .init(name: "Apache 2.0", url: URL(string: url)!, notice: nil)
    }

    static let gemma4 = Self(
        name: "Apache 2.0",
        url: URL(string: "https://ai.google.dev/gemma/docs/gemma_4_license")!,
        notice: "Gemma 4 is provided by Google under the [Apache 2.0 license](https://ai.google.dev/gemma/docs/gemma_4_license)."
    )
}
