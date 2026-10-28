import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

/// Feed 图标视图。与旧 AsyncImage 实现的关键差异：
/// 图标经 `FeedIconStore` 同步查询，首帧即命中内存/磁盘缓存，不存在加载期占位态；
/// 字母徽章只出现在"该 feed 确定无图标"或"首次预热尚未完成"的帧，
/// 且失败记忆保证坏 URL 不会反复进入"徽章→图→徽章"的闪烁循环。
struct FeedFaviconView: View {
    let feedID: UUID
    let iconURL: URL?
    let title: String
    var size: CGFloat = 16

    @EnvironmentObject private var icons: FeedIconStore

    var body: some View {
        FeedFaviconContent(
            title: title,
            size: size,
            state: icons.state(for: feedID)
        )
        .onAppear { icons.warmUp(feedID: feedID, iconURL: iconURL) }
        .onChange(of: iconURL) { _, newURL in
            icons.warmUp(feedID: feedID, iconURL: newURL)
        }
    }
}

struct FeedFaviconContent: View {
    let title: String
    let size: CGFloat
    @ObservedObject var state: FeedIconState

    var body: some View {
        if let image = state.image {
            Image(decorative: image, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size > 15 ? 4 : 3, style: .continuous))
        } else {
            fallbackBadge
        }
    }

    private var fallbackBadge: some View {
        Text(title.prefix(1).uppercased())
            .font(.system(size: max(8, size * 0.58), weight: .bold, design: .rounded))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: size > 15 ? 4 : 3, style: .continuous))
    }
}

