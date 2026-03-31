// IPSWExtractor.swift -- IPSW download, extraction, and component cataloging.
// VortexBoot
//
// An IPSW file is a ZIP archive containing a macOS restore image. This module
// handles downloading the latest IPSW from Apple's software catalog, unzipping
// it, and parsing the BuildManifest.plist to locate all boot-critical
// components (kernel cache, device tree, firmware blobs, disk images).

import Foundation
import VortexCore

// MARK: - IPSW Contents

/// Cataloged contents of an extracted IPSW restore image.
///
/// After extraction, the caller uses this struct to locate individual
/// components needed for macOS guest boot preparation.
public struct IPSWContents: Sendable {
    /// Path to the BuildManifest.plist within the extracted IPSW.
    public let restoreManifest: URL

    /// Path to the kernel cache file, if found.
    ///
    /// On Apple Silicon IPSWs this is typically a Mach-O kernel collection
    /// (e.g. `kernelcache.release.*`).
    public let kernelCache: URL?

    /// Path to the device tree file, if found.
    ///
    /// The device tree describes hardware to the XNU kernel at boot time.
    public let deviceTree: URL?

    /// Directory containing firmware components (iBoot, SEP, etc.).
    public let firmwareDirectory: URL

    /// All `.dmg` disk image files found in the IPSW.
    ///
    /// Typically includes the root filesystem image and any recovery images.
    public let diskImages: [URL]

    /// The root directory of the extracted IPSW.
    public let extractionDirectory: URL

    /// The `Restore.plist` file, if present.
    ///
    /// Contains restore metadata such as supported hardware identifiers
    /// and firmware version information.
    public let restorePlist: URL?

    public init(
        restoreManifest: URL,
        kernelCache: URL? = nil,
        deviceTree: URL? = nil,
        firmwareDirectory: URL,
        diskImages: [URL] = [],
        extractionDirectory: URL,
        restorePlist: URL? = nil
    ) {
        self.restoreManifest = restoreManifest
        self.kernelCache = kernelCache
        self.deviceTree = deviceTree
        self.firmwareDirectory = firmwareDirectory
        self.diskImages = diskImages
        self.extractionDirectory = extractionDirectory
        self.restorePlist = restorePlist
    }
}

// MARK: - IPSW Extractor

/// Downloads and extracts macOS IPSW restore images.
///
/// IPSW files are standard ZIP archives. After extraction, the
/// `BuildManifest.plist` is parsed to catalog all components. The
/// extractor also scans the filesystem for kernel caches, device trees,
/// firmware directories, and disk images by well-known naming patterns.
///
/// ## Usage
/// ```swift
/// // Download the latest IPSW.
/// let ipswURL = try await IPSWExtractor.downloadLatestIPSW(to: workDir) { fraction in
///     print("Download: \(Int(fraction * 100))%")
/// }
///
/// // Extract and catalog.
/// let contents = try await IPSWExtractor.extract(ipsw: ipswURL, to: extractDir)
/// print("Kernel cache: \(contents.kernelCache?.path ?? "not found")")
/// ```
///
/// - Note: IPSW download requires network access. Extraction requires
///   enough disk space for the decompressed contents (~15-25 GB typical).
public final class IPSWExtractor: @unchecked Sendable {

    // MARK: - Apple Software Catalog

    /// URL for Apple's macOS software update catalog on Apple Silicon.
    ///
    /// This catalog contains metadata about available macOS restore images.
    /// The actual IPSW download URL is extracted from the catalog entries.
    private static let appleCatalogURL = URL(
        string: "https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml"
    )!

    /// Alternative catalog URL for specific macOS versions.
    private static let sucatalogURL = URL(
        string: "https://swscan.apple.com/content/catalogs/others/index-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog.gz"
    )!

    // MARK: - Download

    /// Downloads the latest macOS IPSW restore image for Apple Silicon.
    ///
    /// Queries Apple's software update catalog, identifies the most recent
    /// IPSW for the current hardware, and downloads it to `directory`.
    ///
    /// - Parameters:
    ///   - directory: Local directory to save the downloaded IPSW file.
    ///     Created if it does not exist.
    ///   - progress: Called periodically with download progress as a fraction
    ///     from 0.0 to 1.0. May be called from any thread.
    /// - Returns: URL of the downloaded IPSW file on disk.
    /// - Throws: `VortexError.bootFailed` if the catalog cannot be fetched
    ///   or no compatible IPSW is found.
    public static func downloadLatestIPSW(
        to directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        // Ensure the output directory exists.
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        // Fetch the IPSW catalog to find the download URL.
        let ipswDownloadURL = try await fetchLatestIPSWURL()

        // Determine the local filename from the download URL.
        let filename = ipswDownloadURL.lastPathComponent
        let destinationURL = directory.appendingPathComponent(filename)

        // Skip download if the file already exists at the destination.
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            progress(1.0)
            return destinationURL
        }

        // Download using URLSession with progress tracking.
        let delegate = DownloadProgressDelegate(progressHandler: progress)
        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let (temporaryURL, response) = try await session.download(from: ipswDownloadURL)

        // Validate the response.
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw VortexError.bootFailed(
                reason: "IPSW download failed with HTTP status \(statusCode)"
            )
        }

        // Move the downloaded file to the destination.
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)

        progress(1.0)
        return destinationURL
    }

    /// Downloads an IPSW from a specific URL.
    ///
    /// Use this when you already know the IPSW URL (e.g. from a previous
    /// catalog query or user-provided path).
    ///
    /// - Parameters:
    ///   - url: Direct URL to the IPSW file.
    ///   - directory: Local directory to save the downloaded file.
    ///   - progress: Download progress callback (0.0 to 1.0).
    /// - Returns: URL of the downloaded IPSW file on disk.
    public static func downloadIPSW(
        from url: URL,
        to directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let filename = url.lastPathComponent
        let destinationURL = directory.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            progress(1.0)
            return destinationURL
        }

        let delegate = DownloadProgressDelegate(progressHandler: progress)
        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let (temporaryURL, response) = try await session.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw VortexError.bootFailed(
                reason: "IPSW download from \(url) failed with HTTP status \(statusCode)"
            )
        }

        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        progress(1.0)
        return destinationURL
    }

    // MARK: - Extraction

    /// Extracts an IPSW archive and catalogs its contents.
    ///
    /// The IPSW (which is a ZIP archive) is extracted using the system
    /// `unzip` utility. After extraction, the `BuildManifest.plist` is
    /// parsed and the directory is scanned for known component types.
    ///
    /// - Parameters:
    ///   - ipsw: Path to the IPSW file on disk.
    ///   - directory: Directory where contents should be extracted.
    ///     A subdirectory named after the IPSW (without extension) is created.
    /// - Returns: Cataloged contents of the extracted IPSW.
    /// - Throws: `VortexError.invalidRestoreImage` if the IPSW is not a valid
    ///   ZIP archive or is missing required components.
    public static func extract(
        ipsw: URL,
        to directory: URL
    ) async throws -> IPSWContents {
        guard FileManager.default.fileExists(atPath: ipsw.path) else {
            throw VortexError.fileNotFound(path: ipsw.path)
        }

        // Create extraction directory named after the IPSW.
        let ipswName = ipsw.deletingPathExtension().lastPathComponent
        let extractionDir = directory.appendingPathComponent(ipswName)

        try FileManager.default.createDirectory(
            at: extractionDir,
            withIntermediateDirectories: true
        )

        // Extract using the system unzip utility.
        try await unzipIPSW(ipsw, to: extractionDir)

        // Catalog the extracted contents.
        return try catalogContents(in: extractionDir)
    }

    // MARK: - Catalog

    /// Scans an already-extracted IPSW directory and catalogs its contents.
    ///
    /// Useful when the IPSW has already been extracted in a prior session
    /// and only the catalog needs to be rebuilt.
    ///
    /// - Parameter directory: Root directory of an extracted IPSW.
    /// - Returns: Cataloged contents.
    /// - Throws: `VortexError.invalidRestoreImage` if `BuildManifest.plist`
    ///   is missing.
    public static func catalogContents(
        in directory: URL
    ) throws -> IPSWContents {
        let fm = FileManager.default

        // BuildManifest.plist is required.
        let manifestURL = directory.appendingPathComponent("BuildManifest.plist")
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw VortexError.invalidRestoreImage(
                path: directory.path,
                reason: "BuildManifest.plist not found in extracted IPSW"
            )
        }

        // Locate the firmware directory.
        // IPSWs typically contain a Firmware/ directory with boot chain components.
        let firmwareDir = directory.appendingPathComponent("Firmware")
        if !fm.fileExists(atPath: firmwareDir.path) {
            try fm.createDirectory(at: firmwareDir, withIntermediateDirectories: true)
        }

        // Scan for kernel cache files.
        let kernelCache = findKernelCache(in: directory)

        // Scan for device tree files.
        let deviceTree = findDeviceTree(in: directory)

        // Scan for disk images (.dmg files).
        let diskImages = findDiskImages(in: directory)

        // Check for Restore.plist.
        let restorePlist = directory.appendingPathComponent("Restore.plist")
        let hasRestorePlist = fm.fileExists(atPath: restorePlist.path)

        return IPSWContents(
            restoreManifest: manifestURL,
            kernelCache: kernelCache,
            deviceTree: deviceTree,
            firmwareDirectory: firmwareDir,
            diskImages: diskImages,
            extractionDirectory: directory,
            restorePlist: hasRestorePlist ? restorePlist : nil
        )
    }

    // MARK: - Build Manifest Parsing

    /// Parses the BuildManifest.plist and returns the raw dictionary.
    ///
    /// The manifest contains build identities, firmware file paths, and
    /// version information needed to select the correct components for
    /// the target hardware.
    ///
    /// - Parameter url: Path to BuildManifest.plist.
    /// - Returns: The parsed plist as a dictionary.
    public static func parseBuildManifest(
        at url: URL
    ) throws -> [String: Any] {
        let data = try Data(contentsOf: url)

        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw VortexError.invalidRestoreImage(
                path: url.path,
                reason: "BuildManifest.plist is not a valid dictionary"
            )
        }

        return plist
    }

    /// Extracts the list of build identities from a BuildManifest.
    ///
    /// Each build identity describes a specific configuration (hardware model,
    /// firmware versions, component paths). The caller selects the identity
    /// matching their target hardware.
    ///
    /// - Parameter manifest: Parsed BuildManifest dictionary.
    /// - Returns: Array of build identity dictionaries.
    public static func buildIdentities(
        from manifest: [String: Any]
    ) -> [[String: Any]] {
        manifest["BuildIdentities"] as? [[String: Any]] ?? []
    }

    /// Extracts the product version string from the manifest.
    ///
    /// - Parameter manifest: Parsed BuildManifest dictionary.
    /// - Returns: The macOS version string (e.g. "15.3"), or nil.
    public static func productVersion(
        from manifest: [String: Any]
    ) -> String? {
        // The product version is typically in the first build identity's Info dict.
        guard let identities = manifest["BuildIdentities"] as? [[String: Any]],
              let firstIdentity = identities.first,
              let info = firstIdentity["Info"] as? [String: Any] else {
            return nil
        }
        return info["RestoreVersion"] as? String
    }

    /// Extracts the product build version (e.g. "24D5034f") from the manifest.
    ///
    /// - Parameter manifest: Parsed BuildManifest dictionary.
    /// - Returns: The build version string, or nil.
    public static func productBuildVersion(
        from manifest: [String: Any]
    ) -> String? {
        guard let identities = manifest["BuildIdentities"] as? [[String: Any]],
              let firstIdentity = identities.first,
              let info = firstIdentity["Info"] as? [String: Any] else {
            return nil
        }
        return info["BuildNumber"] as? String
    }

    // MARK: - Private Helpers

    /// Fetches the latest Apple Silicon IPSW download URL from Apple's catalog.
    private static func fetchLatestIPSWURL() async throws -> URL {
        // Fetch the IPSW catalog XML/plist.
        let (data, response) = try await URLSession.shared.data(from: appleCatalogURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw VortexError.bootFailed(
                reason: "Failed to fetch IPSW catalog (HTTP \(statusCode))"
            )
        }

        // Parse the catalog plist.
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw VortexError.bootFailed(
                reason: "IPSW catalog is not a valid plist"
            )
        }

        // The catalog contains an array of IPSW entries with download URLs.
        // Each entry has keys like "FirmwareURL" or similar.
        // Extract the first available IPSW URL for Apple Silicon (arm64e).
        if let ipswURL = extractIPSWDownloadURL(from: plist) {
            return ipswURL
        }

        throw VortexError.bootFailed(
            reason: "No compatible Apple Silicon IPSW found in catalog"
        )
    }

    /// Parses the catalog plist to find an IPSW download URL.
    ///
    /// The catalog structure varies between releases. This method checks
    /// known key paths for download URLs.
    private static func extractIPSWDownloadURL(
        from catalog: [String: Any]
    ) -> URL? {
        // Strategy 1: Look for a direct "Assets" array.
        if let assets = catalog["Assets"] as? [[String: Any]] {
            for asset in assets.reversed() {
                // Prefer the most recent entry (last in array).
                if let urlString = asset["__BaseURL"] as? String,
                   let relativeURL = asset["__RelativePath"] as? String {
                    return URL(string: urlString + relativeURL)
                }
                if let urlString = asset["FirmwareURL"] as? String {
                    return URL(string: urlString)
                }
            }
        }

        // Strategy 2: Look for entries keyed by hardware model.
        if let products = catalog["Products"] as? [String: Any] {
            for (_, value) in products {
                guard let product = value as? [String: Any],
                      let packages = product["Packages"] as? [[String: Any]] else {
                    continue
                }
                for package in packages {
                    if let urlString = package["URL"] as? String,
                       urlString.hasSuffix(".ipsw") {
                        return URL(string: urlString)
                    }
                }
            }
        }

        return nil
    }

    /// Extracts an IPSW ZIP archive using the system `unzip` utility.
    private static func unzipIPSW(
        _ ipsw: URL,
        to directory: URL
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = [
            "-o",             // Overwrite without prompting.
            "-q",             // Quiet mode.
            ipsw.path,
            "-d", directory.path
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()

        // Wait for completion in a non-blocking way.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "unknown error"
            throw VortexError.invalidRestoreImage(
                path: ipsw.path,
                reason: "unzip failed (exit \(process.terminationStatus)): \(errorMessage)"
            )
        }
    }

    /// Scans the extracted directory tree for a kernel cache file.
    ///
    /// Kernel caches on Apple Silicon are typically named
    /// `kernelcache.release.*` and may be inside subdirectories.
    private static func findKernelCache(in directory: URL) -> URL? {
        let fm = FileManager.default
        let knownPaths = [
            "kernelcache.release.vmapple2",
            "kernelcache.release.vma2",
            "kernelcache",
        ]

        // Check top-level first.
        for name in knownPaths {
            let url = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                return url
            }
        }

        // Scan Firmware/ subdirectory.
        let firmwareDir = directory.appendingPathComponent("Firmware")
        if fm.fileExists(atPath: firmwareDir.path) {
            for name in knownPaths {
                let url = firmwareDir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) {
                    return url
                }
            }
        }

        // Broad search: any file matching kernelcache* pattern.
        return findFirstFile(in: directory, matching: "kernelcache")
    }

    /// Scans the extracted directory tree for a device tree file.
    ///
    /// Device trees are typically named `DeviceTree.*.im4p` or
    /// `devicetree.*` and reside in the Firmware/ directory.
    private static func findDeviceTree(in directory: URL) -> URL? {
        let fm = FileManager.default
        let firmwareDir = directory.appendingPathComponent("Firmware")
        let allFirmwareDir = firmwareDir.appendingPathComponent("all_flash")

        // Check common locations.
        let searchDirs = [allFirmwareDir, firmwareDir, directory]
        for searchDir in searchDirs {
            guard fm.fileExists(atPath: searchDir.path),
                  let contents = try? fm.contentsOfDirectory(atPath: searchDir.path) else {
                continue
            }
            for item in contents {
                let lowered = item.lowercased()
                if lowered.hasPrefix("devicetree") {
                    return searchDir.appendingPathComponent(item)
                }
            }
        }

        return nil
    }

    /// Scans the extracted directory tree for all .dmg disk images.
    private static func findDiskImages(in directory: URL) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return results
        }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "dmg" {
                results.append(fileURL)
            }
        }

        return results
    }

    /// Finds the first file whose name contains the given prefix.
    private static func findFirstFile(
        in directory: URL,
        matching prefix: String
    ) -> URL? {
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.lowercased().hasPrefix(prefix.lowercased()) {
                return fileURL
            }
        }

        return nil
    }
}

// MARK: - Download Progress Delegate

/// Tracks download progress for URLSession download tasks.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let progressHandler: @Sendable (Double) -> Void

    init(progressHandler: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler(min(fraction, 1.0))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The caller handles moving the file. Nothing to do here.
    }
}
