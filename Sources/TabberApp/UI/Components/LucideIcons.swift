import CoreGraphics

// Icons from Lucide 1.55.0 (https://lucide.dev), ISC license. Elements copied from the SVG sources.
extension LucideIcon {
    static let arrowRightToLine = LucideIcon(name: "arrow-right-to-line", elements: [
        .path("M17 12H3"),
        .path("m11 18 6-6-6-6"),
        .path("M21 5v14"),
    ])

    static let sparkle = LucideIcon(name: "sparkle", elements: [
        .path("M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z"),
    ])

    static let slidersHorizontal = LucideIcon(name: "sliders-horizontal", elements: [
        .path("M10 5H3"),
        .path("M12 19H3"),
        .path("M14 3v4"),
        .path("M16 17v4"),
        .path("M21 12h-9"),
        .path("M21 19h-5"),
        .path("M21 5h-7"),
        .path("M8 10v4"),
        .path("M8 12H3"),
    ])

    static let keyboard = LucideIcon(name: "keyboard", elements: [
        .path("M10 8h.01"),
        .path("M12 12h.01"),
        .path("M14 8h.01"),
        .path("M16 12h.01"),
        .path("M18 8h.01"),
        .path("M6 8h.01"),
        .path("M7 16h10"),
        .path("M8 12h.01"),
        .rect(x: 2, y: 4, width: 20, height: 16, rx: 2),
    ])

    static let scanText = LucideIcon(name: "scan-text", elements: [
        .path("M3 7V5a2 2 0 0 1 2-2h2"),
        .path("M17 3h2a2 2 0 0 1 2 2v2"),
        .path("M21 17v2a2 2 0 0 1-2 2h-2"),
        .path("M7 21H5a2 2 0 0 1-2-2v-2"),
        .path("M7 8h8"),
        .path("M7 12h10"),
        .path("M7 16h6"),
    ])

    static let fingerprint = LucideIcon(name: "fingerprint", elements: [
        .path("M12 10a2 2 0 0 0-2 2c0 1.02-.1 2.51-.26 4"),
        .path("M14 13.12c0 2.38 0 6.38-1 8.88"),
        .path("M17.29 21.02c.12-.6.43-2.3.5-3.02"),
        .path("M2 12a10 10 0 0 1 18-6"),
        .path("M2 16h.01"),
        .path("M21.8 16c.2-2 .131-5.354 0-6"),
        .path("M5 19.5C5.5 18 6 15 6 12a6 6 0 0 1 .34-2"),
        .path("M8.65 22c.21-.66.45-1.32.57-2"),
        .path("M9 6.8a6 6 0 0 1 9 5.2v2"),
    ])

    static let appWindow = LucideIcon(name: "app-window", elements: [
        .rect(x: 2, y: 4, width: 20, height: 16, rx: 2),
        .path("M10 4v4"),
        .path("M2 8h20"),
        .path("M6 4v4"),
    ])

    static let cpu = LucideIcon(name: "cpu", elements: [
        .path("M12 20v2"),
        .path("M12 2v2"),
        .path("M17 20v2"),
        .path("M17 2v2"),
        .path("M2 12h2"),
        .path("M2 17h2"),
        .path("M2 7h2"),
        .path("M20 12h2"),
        .path("M20 17h2"),
        .path("M20 7h2"),
        .path("M7 20v2"),
        .path("M7 2v2"),
        .rect(x: 4, y: 4, width: 16, height: 16, rx: 2),
        .rect(x: 8, y: 8, width: 8, height: 8, rx: 1),
    ])

    static let chartColumn = LucideIcon(name: "chart-column", elements: [
        .path("M3 3v16a2 2 0 0 0 2 2h16"),
        .path("M18 17V9"),
        .path("M13 17V5"),
        .path("M8 17v-3"),
    ])

    static let info = LucideIcon(name: "info", elements: [
        .circle(cx: 12, cy: 12, r: 10),
        .path("M12 16v-4"),
        .path("M12 8h.01"),
    ])

    static let check = LucideIcon(name: "check", elements: [
        .path("M20 6 9 17l-5-5"),
    ])

    static let circleCheck = LucideIcon(name: "circle-check", elements: [
        .circle(cx: 12, cy: 12, r: 10),
        .path("m16 9-5.5 5.5L8 12"),
    ])

    static let download = LucideIcon(name: "download", elements: [
        .path("M12 15V3"),
        .path("M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"),
        .path("m7 10 5 5 5-5"),
    ])

    static let x = LucideIcon(name: "x", elements: [
        .path("M18 6 6 18"),
        .path("m6 6 12 12"),
    ])

    static let trash2 = LucideIcon(name: "trash-2", elements: [
        .path("M10 11v6"),
        .path("M14 11v6"),
        .path("M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"),
        .path("M3 6h18"),
        .path("M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"),
    ])

    static let folderOpen = LucideIcon(name: "folder-open", elements: [
        .path("m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"),
    ])

    static let shieldCheck = LucideIcon(name: "shield-check", elements: [
        .path("M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"),
        .path("m9 12 2 2 4-4"),
    ])

    static let monitor = LucideIcon(name: "monitor", elements: [
        .rect(x: 2, y: 3, width: 20, height: 14, rx: 2),
        .line(x1: 8, y1: 21, x2: 16, y2: 21),
        .line(x1: 12, y1: 17, x2: 12, y2: 21),
    ])

    static let globe = LucideIcon(name: "globe", elements: [
        .circle(cx: 12, cy: 12, r: 10),
        .path("M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"),
        .path("M2 12h20"),
    ])

    static let plus = LucideIcon(name: "plus", elements: [
        .path("M5 12h14"),
        .path("M12 5v14"),
    ])

    static let minus = LucideIcon(name: "minus", elements: [
        .path("M5 12h14"),
    ])

    static let chevronLeft = LucideIcon(name: "chevron-left", elements: [
        .path("m15 18-6-6 6-6"),
    ])

    static let chevronRight = LucideIcon(name: "chevron-right", elements: [
        .path("m9 18 6-6-6-6"),
    ])

    static let pause = LucideIcon(name: "pause", elements: [
        .rect(x: 14, y: 3, width: 5, height: 18, rx: 1),
        .rect(x: 5, y: 3, width: 5, height: 18, rx: 1),
    ])

    static let play = LucideIcon(name: "play", elements: [
        .path("M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z"),
    ])

    static let penLine = LucideIcon(name: "pen-line", elements: [
        .path("M13 21h8"),
        .path("M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"),
    ])

    static let textCursorInput = LucideIcon(name: "text-cursor-input", elements: [
        .path("M12 20h-1a2 2 0 0 1-2-2 2 2 0 0 1-2 2H6"),
        .path("M13 8h7a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2h-7"),
        .path("M5 16H4a2 2 0 0 1-2-2v-4a2 2 0 0 1 2-2h1"),
        .path("M6 4h1a2 2 0 0 1 2 2 2 2 0 0 1 2-2h1"),
        .path("M9 6v12"),
    ])

    static let refreshCw = LucideIcon(name: "refresh-cw", elements: [
        .path("M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"),
        .path("M21 3v5h-5"),
        .path("M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"),
        .path("M8 16H3v5"),
    ])

    static let triangleAlert = LucideIcon(name: "triangle-alert", elements: [
        .path("m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"),
        .path("M12 9v4"),
        .path("M12 17h.01"),
    ])

    static let accessibility = LucideIcon(name: "accessibility", elements: [
        .circle(cx: 16, cy: 4, r: 1),
        .path("m18 19 1-7-6 1"),
        .path("m5 8 3-3 5.5 3-2.36 3.5"),
        .path("M4.24 14.5a5 5 0 0 0 6.88 6"),
        .path("M13.76 17.5a5 5 0 0 0-6.88-6"),
    ])

    static let hardDrive = LucideIcon(name: "hard-drive", elements: [
        .path("M10 16h.01"),
        .path("M2.212 11.577a2 2 0 0 0-.212.896V18a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-5.527a2 2 0 0 0-.212-.896L18.55 5.11A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"),
        .path("M21.946 12.013H2.054"),
        .path("M6 16h.01"),
    ])

    static let circleAlert = LucideIcon(name: "circle-alert", elements: [
        .circle(cx: 12, cy: 12, r: 10),
        .line(x1: 12, y1: 8, x2: 12, y2: 12),
        .line(x1: 12, y1: 16, x2: 12.01, y2: 16),
    ])

    static let lockKeyhole = LucideIcon(name: "lock-keyhole", elements: [
        .circle(cx: 12, cy: 16, r: 1),
        .rect(x: 3, y: 10, width: 18, height: 12, rx: 2),
        .path("M7 10V7a5 5 0 0 1 10 0v3"),
    ])

    static let externalLink = LucideIcon(name: "external-link", elements: [
        .path("M15 3h6v6"),
        .path("M10 14 21 3"),
        .path("M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"),
    ])

    static let userRound = LucideIcon(name: "user-round", elements: [
        .circle(cx: 12, cy: 8, r: 5),
        .path("M20 21a8 8 0 0 0-16 0"),
    ])
}

extension LucideIcon {
    /// Tabber's mark: a Tab arrow (after Lucide's arrow-right-to-line) with a small sparkle.
    static let tabberMark = LucideIcon(
        name: "Tabber",
        elements: [
            .path("M3 15H14"),
            .path("M10 11l4 4-4 4"),
            .path("M18 10v10"),
        ],
        filled: [
            .path("M19.5 1Q20.13 3.87 23 4.5Q20.13 5.13 19.5 8Q18.87 5.13 16 4.5Q18.87 3.87 19.5 1Z"),
        ]
    )
}
