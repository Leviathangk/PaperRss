import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

struct AccountProviderIcon: View {
    let type: AccountType
    var size: CGFloat = 24

    private var assetName: String? {
        switch type {
        case .iCloud: "AccountProviderICloud"
        case .freshRSS: "AccountProviderFreshRSS"
        case .miniflux: "AccountProviderMiniflux"
        case .local: nil
        }
    }

    private var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        .main
        #endif
    }

    var body: some View {
        Group {
            if let assetName {
                Image(assetName, bundle: resourceBundle)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
            } else {
                Image(systemName: "desktopcomputer")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
