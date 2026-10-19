import AppKit
import SwiftUI

/// Fonts used for item content. Chrome (toolbar, menus, hints) stays at system sizes.
struct Typography: Equatable {
    static let defaultSize: CGFloat = 13
    static let system = "system"
    static let rounded = "rounded"
    static let serif = "serif"
    static let monospaced = "monospaced"

    var family = Typography.system
    var size = Typography.defaultSize
    /// `Typography.system` means SF Mono.
    var codeFamily = Typography.system

    var scale: CGFloat { size / Typography.defaultSize }

    /// Body text, `delta` points larger or smaller than the chosen size.
    func text(_ delta: CGFloat = 0, weight: Font.Weight = .regular) -> Font {
        let points = size + delta
        switch family {
        case Typography.system: return .system(size: points, weight: weight)
        case Typography.rounded: return .system(size: points, weight: weight, design: .rounded)
        case Typography.serif: return .system(size: points, weight: weight, design: .serif)
        case Typography.monospaced: return .system(size: points, weight: weight, design: .monospaced)
        default: return .custom(family, size: points).weight(weight)
        }
    }

    /// Code blocks and inline code, one point smaller than body text.
    func code(_ delta: CGFloat = -1) -> Font {
        let points = size + delta
        return codeFamily == Typography.system ? .system(size: points, design: .monospaced) : .custom(codeFamily, size: points)
    }

    /// System-font UI next to content (metadata, section headers, icons), scaled with the text size.
    func ui(_ base: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: (base * scale).rounded(), weight: weight)
    }
}

private struct TypographyKey: EnvironmentKey {
    static let defaultValue = Typography()
}

extension EnvironmentValues {
    var typography: Typography {
        get { self[TypographyKey.self] }
        set { self[TypographyKey.self] = newValue }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let sizeRange: ClosedRange<CGFloat> = 11...20

    @Published var typography: Typography {
        didSet { save() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        func family(_ key: String) -> String {
            guard let value = defaults.string(forKey: key), !value.isEmpty else { return Typography.system }
            // Fall back when a chosen font has been uninstalled.
            return [Typography.system, Typography.rounded, Typography.serif, Typography.monospaced].contains(value) || installed.contains(value)
                ? value : Typography.system
        }
        let size = defaults.double(forKey: "fontSize")
        typography = Typography(
            family: family("fontFamily"),
            size: size == 0 ? Typography.defaultSize : min(max(size, AppSettings.sizeRange.lowerBound), AppSettings.sizeRange.upperBound),
            codeFamily: family("codeFontFamily")
        )
    }

    private func save() {
        defaults.set(typography.family, forKey: "fontFamily")
        defaults.set(Double(typography.size), forKey: "fontSize")
        defaults.set(typography.codeFamily, forKey: "codeFontFamily")
    }

    func reset() {
        typography = Typography()
    }

    static var installedFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
    }

    static var monospacedFamilies: [String] {
        installedFamilies.filter { family in
            let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
            return NSFont(descriptor: descriptor, size: 12)?.isFixedPitch ?? false
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    private let families = AppSettings.installedFamilies
    private let monoFamilies = AppSettings.monospacedFamilies

    private static let sample = """
    ## Preview
    The **refresh token** rotates on every use, via `token.rotate!`.
    1. Ask Claude for *edge cases*
       - expired tokens
    ```
    if token.expired? then redirect_to login_path
    ```
    """

    var body: some View {
        Form {
            SwiftUI.Section("Text") {
                Picker("Font", selection: $settings.typography.family) {
                    Text("System").tag(Typography.system)
                    Text("System Rounded").tag(Typography.rounded)
                    Text("System Serif").tag(Typography.serif)
                    Text("System Monospaced").tag(Typography.monospaced)
                    Divider()
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Size") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.typography.size, in: AppSettings.sizeRange, step: 1)
                        Text("\(Int(settings.typography.size)) pt")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            SwiftUI.Section("Code") {
                Picker("Font", selection: $settings.typography.codeFamily) {
                    Text("System Monospaced").tag(Typography.system)
                    Divider()
                    ForEach(monoFamilies, id: \.self) { Text($0).tag($0) }
                }
            }
            SwiftUI.Section("Preview") {
                MarkdownText(text: Self.sample)
                    .font(settings.typography.text())
                    .environment(\.typography, settings.typography)
                    .padding(.vertical, 4)
            }
            HStack {
                Spacer()
                Button("Reset to Defaults") { settings.reset() }
                    .disabled(settings.typography == Typography())
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isKey: Bool { window?.isKeyWindow ?? false }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Chat Todos Settings"
        window.isReleasedWhenClosed = false
        // Stay above the floating panel.
        window.level = .floating
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
        window.center()
        return window
    }
}
