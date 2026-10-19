import Foundation

/// Built-in virtual folders: live searches shown in the sidebar.
enum SmartCollection: String, CaseIterable, Identifiable {
    case recentDocuments, downloadsThisWeek, screenshots, photosAndVideos, largeFiles, notOpened

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentDocuments: return String(localized: "Recent Documents")
        case .downloadsThisWeek: return String(localized: "Downloads This Week")
        case .screenshots: return String(localized: "Screenshots")
        case .photosAndVideos: return String(localized: "Photos & Videos")
        case .largeFiles: return String(localized: "Large Files")
        case .notOpened: return String(localized: "Not Opened in 90 Days")
        }
    }

    var symbol: String {
        switch self {
        case .recentDocuments: return "doc.text.magnifyingglass"
        case .downloadsThisWeek: return "arrow.down.circle"
        case .screenshots: return "camera.viewfinder"
        case .photosAndVideos: return "photo.on.rectangle"
        case .largeFiles: return "externaldrive.badge.exclamationmark"
        case .notOpened: return "clock.badge.questionmark"
        }
    }

    var query: SearchQuery {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var q = SearchQuery()
        q.scope = .subfolders(home)
        switch self {
        case .recentDocuments:
            q.kinds = [.document, .pdf, .text]
            q.dateRange = .last7Days
        case .downloadsThisWeek:
            q.scope = .subfolders(home.appendingPathComponent("Downloads"))
            q.dateField = .created
            q.dateRange = .last7Days
        case .screenshots:
            q.text = "Screenshot*"
            q.textMatch = .glob
            q.kinds = [.image]
        case .photosAndVideos:
            q.kinds = [.image, .video]
            q.dateRange = .last30Days
        case .largeFiles:
            q.minSize = 500 << 20
        case .notOpened:
            q.notOpenedForDays = 90
            q.minSize = 10 << 20
        }
        return q
    }

    static func matching(_ query: SearchQuery) -> SmartCollection? {
        allCases.first { $0.query == query }
    }
}
