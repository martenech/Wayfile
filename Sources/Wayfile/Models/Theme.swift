import AppKit
import Observation
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

struct ThemePreset: Identifiable, Hashable {
    let id: String
    let name: String
    /// Dark/light palettes force their appearance so system text colours stay readable.
    var appearance: AppearanceMode? = nil
    var accent: Color? = nil
    /// Background of the file area; nil keeps the system colours.
    var content: Color? = nil
    /// Background of the tab/navigation/command/status bars.
    var chrome: Color? = nil
    /// See-through window that blends with the desktop (Files' Mica/Acrylic).
    var translucent = false
    /// Cards and panels on top of the content (Home widgets, Timeline rows); nil = system colour.
    var surface: Color? = nil
    /// Sidebar background; nil keeps the system's translucent sidebar.
    var sidebar: Color? = nil

    static let all: [ThemePreset] = [
        ThemePreset(id: "default", name: "Default"),
        ThemePreset(id: "glass", name: "Glass", translucent: true),
        ThemePreset(id: "nord", name: "Nord", appearance: .dark, accent: Color(hex: "88C0D0"),
                    content: Color(hex: "2E3440"), chrome: Color(hex: "3B4252")),
        ThemePreset(id: "dracula", name: "Dracula", appearance: .dark, accent: Color(hex: "BD93F9"),
                    content: Color(hex: "282A36"), chrome: Color(hex: "21222C")),
        ThemePreset(id: "solarized", name: "Solarized Light", appearance: .light, accent: Color(hex: "268BD2"),
                    content: Color(hex: "FDF6E3"), chrome: Color(hex: "EEE8D5")),
        ThemePreset(id: "midnight", name: "Midnight", appearance: .dark, accent: Color(hex: "4F8CFF"),
                    content: Color(hex: "0D1117"), chrome: Color(hex: "161B22")),
        ThemePreset(id: "navy", name: "Navy", appearance: .dark, accent: Color(hex: "2F7BFF"),
                    content: Color(hex: "121729"), chrome: Color(hex: "0E1222"),
                    surface: Color(hex: "1A2038"), sidebar: Color(hex: "0E1222")),
        // Popular editor palettes, with their published colours.
        ThemePreset(id: "catppuccin-mocha", name: "Catppuccin Mocha", appearance: .dark, accent: Color(hex: "CBA6F7"),
                    content: Color(hex: "1E1E2E"), chrome: Color(hex: "181825"), surface: Color(hex: "313244"), sidebar: Color(hex: "181825")),
        ThemePreset(id: "tokyo-night", name: "Tokyo Night", appearance: .dark, accent: Color(hex: "7AA2F7"),
                    content: Color(hex: "1A1B26"), chrome: Color(hex: "16161E"), surface: Color(hex: "24283B"), sidebar: Color(hex: "16161E")),
        ThemePreset(id: "gruvbox-dark", name: "Gruvbox Dark", appearance: .dark, accent: Color(hex: "FABD2F"),
                    content: Color(hex: "282828"), chrome: Color(hex: "1D2021"), surface: Color(hex: "3C3836"), sidebar: Color(hex: "1D2021")),
        ThemePreset(id: "one-dark", name: "One Dark", appearance: .dark, accent: Color(hex: "61AFEF"),
                    content: Color(hex: "282C34"), chrome: Color(hex: "21252B"), surface: Color(hex: "2C313A"), sidebar: Color(hex: "21252B")),
        ThemePreset(id: "rose-pine", name: "Rosé Pine", appearance: .dark, accent: Color(hex: "C4A7E7"),
                    content: Color(hex: "191724"), chrome: Color(hex: "1F1D2E"), surface: Color(hex: "26233A"), sidebar: Color(hex: "1F1D2E")),
        ThemePreset(id: "monokai", name: "Monokai", appearance: .dark, accent: Color(hex: "A6E22E"),
                    content: Color(hex: "272822"), chrome: Color(hex: "1E1F1C"), surface: Color(hex: "3E3D32"), sidebar: Color(hex: "1E1F1C")),
        ThemePreset(id: "everforest", name: "Everforest", appearance: .dark, accent: Color(hex: "A7C080"),
                    content: Color(hex: "2D353B"), chrome: Color(hex: "232A2E"), surface: Color(hex: "343F44"), sidebar: Color(hex: "232A2E")),
        ThemePreset(id: "kanagawa", name: "Kanagawa", appearance: .dark, accent: Color(hex: "7E9CD8"),
                    content: Color(hex: "1F1F28"), chrome: Color(hex: "16161D"), surface: Color(hex: "2A2A37"), sidebar: Color(hex: "16161D")),
        ThemePreset(id: "solarized-dark", name: "Solarized Dark", appearance: .dark, accent: Color(hex: "268BD2"),
                    content: Color(hex: "002B36"), chrome: Color(hex: "073642"), surface: Color(hex: "073642"), sidebar: Color(hex: "00252F")),
        ThemePreset(id: "catppuccin-latte", name: "Catppuccin Latte", appearance: .light, accent: Color(hex: "8839EF"),
                    content: Color(hex: "EFF1F5"), chrome: Color(hex: "E6E9EF"), surface: Color(hex: "E6E9EF"), sidebar: Color(hex: "DCE0E8")),
        ThemePreset(id: "rose-pine-dawn", name: "Rosé Pine Dawn", appearance: .light, accent: Color(hex: "907AA9"),
                    content: Color(hex: "FAF4ED"), chrome: Color(hex: "F2E9E1"), surface: Color(hex: "FFFAF3"), sidebar: Color(hex: "F2E9E1")),
        ThemePreset(id: "gruvbox-light", name: "Gruvbox Light", appearance: .light, accent: Color(hex: "076678"),
                    content: Color(hex: "FBF1C7"), chrome: Color(hex: "F2E5BC"), surface: Color(hex: "EBDBB2"), sidebar: Color(hex: "F2E5BC")),
        ThemePreset(id: "github-light", name: "GitHub Light", appearance: .light, accent: Color(hex: "0969DA"),
                    content: Color(hex: "FFFFFF"), chrome: Color(hex: "F6F8FA"), surface: Color(hex: "F6F8FA"), sidebar: Color(hex: "F6F8FA")),
    ]
}

@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    var appearance: AppearanceMode {
        didSet { save("theme.appearance", appearance.rawValue); applyAppearance() }
    }
    var presetID: String {
        didSet { save("theme.preset", presetID); applyAppearance() }
    }
    var customAccent: Color? {
        didSet { save("theme.accent", customAccent?.hex) }
    }
    var backgroundImage: URL? {
        didSet { save("theme.backgroundImage", backgroundImage?.path); loadImage() }
    }
    var backgroundOpacity: Double {
        didSet { save("theme.backgroundOpacity", backgroundOpacity) }
    }

    private(set) var image: NSImage?

    private init() {
        let ud = UserDefaults.standard
        appearance = ud.string(forKey: "theme.appearance").flatMap(AppearanceMode.init(rawValue:)) ?? .system
        presetID = ud.string(forKey: "theme.preset") ?? "default"
        customAccent = ud.string(forKey: "theme.accent").map(Color.init(hex:))
        backgroundImage = ud.string(forKey: "theme.backgroundImage").map { URL(fileURLWithPath: $0) }
        backgroundOpacity = ud.object(forKey: "theme.backgroundOpacity") as? Double ?? 0.25
        loadImage()
    }

    var preset: ThemePreset { ThemePreset.all.first { $0.id == presetID } ?? ThemePreset.all[0] }

    var accent: Color { customAccent ?? preset.accent ?? .accentColor }

    /// When something other than system colours is behind the files, list/table backgrounds must be hidden.
    var customizesContent: Bool { preset.content != nil || preset.translucent || image != nil }

    var effectiveAppearance: AppearanceMode { preset.appearance ?? appearance }

    /// Call once at launch and whenever the theme changes.
    func applyAppearance() {
        NSApp?.appearance = effectiveAppearance.nsAppearance
    }

    private func loadImage() {
        image = backgroundImage.flatMap { NSImage(contentsOf: $0) }
    }

    private func save(_ key: String, _ value: Any?) {
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

extension Color {
    /// The theme's accent; use instead of `Color.accentColor` so themes can recolour selection.
    @MainActor static var themeAccent: Color { ThemeStore.shared.accent }

    /// Cards and panels: the theme's surface colour, or the system control background.
    @MainActor static var themeSurface: Color { ThemeStore.shared.preset.surface ?? Color(nsColor: .controlBackgroundColor) }

    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hex: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }
}

/// Behind-window blur (like the sidebar) for the Glass theme.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Background for the file area: theme colour, glass, background image, or the system default.
struct ThemedContentBackground: ViewModifier {
    private var theme: ThemeStore { .shared }

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(theme.customizesContent ? .hidden : .automatic)
            .background {
                if theme.customizesContent {
                    // The pane-level background (colour, glass, image) shows through.
                    Color.clear
                } else {
                    Color(nsColor: .controlBackgroundColor)
                }
            }
    }
}

/// Background for the whole content column; draws the theme behind every pane.
struct ThemedWindowBackground: View {
    private var theme: ThemeStore { .shared }

    var body: some View {
        ZStack {
            if theme.preset.translucent {
                VisualEffectBackground()
            } else if let color = theme.preset.content {
                color
            } else if theme.image != nil {
                Color(nsColor: .controlBackgroundColor)
            }
            if let image = theme.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(theme.backgroundOpacity)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .ignoresSafeArea()
    }
}

struct ThemedChrome: ViewModifier {
    private var theme: ThemeStore { .shared }

    func body(content: Content) -> some View {
        if let chrome = theme.preset.chrome {
            content.background(chrome)
        } else if theme.preset.translucent {
            content.background(.ultraThinMaterial)
        } else {
            content.background(.bar)
        }
    }
}

/// Sidebar list: the theme's colour instead of the translucent system sidebar, when it has one.
struct ThemedSidebar: ViewModifier {
    private var theme: ThemeStore { .shared }

    func body(content: Content) -> some View {
        if let sidebar = theme.preset.sidebar {
            content.scrollContentBackground(.hidden).background(sidebar)
        } else {
            content
        }
    }
}

extension View {
    func themedSidebar() -> some View { modifier(ThemedSidebar()) }
    func themedContentBackground() -> some View { modifier(ThemedContentBackground()) }
    func themedChrome() -> some View { modifier(ThemedChrome()) }
}
