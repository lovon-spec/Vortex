// DisplayConfig.swift — Display resolution and pixel density configuration.
// VortexCore

/// Display configuration for a virtual machine's virtual framebuffer.
public struct DisplayConfiguration: Codable, Sendable, Hashable {
    /// Horizontal resolution in pixels.
    public var widthPixels: Int

    /// Vertical resolution in pixels.
    public var heightPixels: Int

    /// Pixels per inch for the virtual display. Higher values produce sharper
    /// rendering on Retina-capable guests.
    public var pixelsPerInch: Int

    /// Whether to automatically match the host display's resolution when possible.
    public var automaticResizing: Bool

    public init(
        widthPixels: Int = 1920,
        heightPixels: Int = 1200,
        pixelsPerInch: Int = 144,
        automaticResizing: Bool = true
    ) {
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.pixelsPerInch = pixelsPerInch
        self.automaticResizing = automaticResizing
    }

    // MARK: - Computed properties

    /// The aspect ratio as a simplified string (e.g. "16:10").
    public var aspectRatioDescription: String {
        let divisor = gcd(widthPixels, heightPixels)
        guard divisor > 0 else { return "\(widthPixels):\(heightPixels)" }
        return "\(widthPixels / divisor):\(heightPixels / divisor)"
    }

    /// Total pixel count.
    public var totalPixels: Int {
        widthPixels * heightPixels
    }

    /// Resolution formatted for display (e.g. "1920 x 1200").
    public var resolutionString: String {
        "\(widthPixels) x \(heightPixels)"
    }

    // MARK: - Presets

    /// Standard 1080p display.
    public static let hd = DisplayConfiguration(
        widthPixels: 1920,
        heightPixels: 1080,
        pixelsPerInch: 96
    )

    /// 1920x1200 (16:10) with Retina-level PPI -- good default for macOS guests.
    public static let standard = DisplayConfiguration(
        widthPixels: 1920,
        heightPixels: 1200,
        pixelsPerInch: 144
    )

    /// 2560x1600 (16:10) Retina-style.
    public static let retina = DisplayConfiguration(
        widthPixels: 2560,
        heightPixels: 1600,
        pixelsPerInch: 218
    )

    /// 4K (3840x2160).
    public static let uhd = DisplayConfiguration(
        widthPixels: 3840,
        heightPixels: 2160,
        pixelsPerInch: 192
    )
}

// MARK: - Private helpers

private func gcd(_ a: Int, _ b: Int) -> Int {
    var a = abs(a)
    var b = abs(b)
    while b != 0 {
        let temp = b
        b = a % b
        a = temp
    }
    return a
}
