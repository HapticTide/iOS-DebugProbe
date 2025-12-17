// PageTimingSwiftUI.swift
// DebugProbe
//
// Created by Sun on 2025/12/17.
// Copyright © 2025 Sun. All rights reserved.
//

#if canImport(SwiftUI)
    import SwiftUI

    // MARK: - Page Timing View Modifier

    /// SwiftUI 页面耗时追踪 Modifier
    /// 自动在 onAppear 时开始计时，onDisappear 时结束并上报
    public struct PageTimingModifier: ViewModifier {
        /// 页面标识（如 "ProductDetailView"）
        let pageId: String

        /// 页面显示名称（如 "商品详情"）
        let pageName: String?

        /// 业务路由（可选）
        let route: String?

        /// 是否追踪首次布局（SwiftUI 中通常无法精确获取）
        let trackFirstLayout: Bool

        /// 当前访问 ID
        @State private var visitId: String = ""

        /// 是否已显示（用于处理 SwiftUI 的多次 onAppear 调用）
        @State private var hasAppeared: Bool = false

        public init(
            pageId: String,
            pageName: String? = nil,
            route: String? = nil,
            trackFirstLayout: Bool = false
        ) {
            self.pageId = pageId
            self.pageName = pageName
            self.route = route
            self.trackFirstLayout = trackFirstLayout
        }

        public func body(content: Content) -> some View {
            content
                .onAppear {
                    guard !hasAppeared else { return }
                    hasAppeared = true

                    // 开始计时
                    visitId = PageTimingRecorder.shared.markPageStart(
                        pageId: pageId,
                        pageName: pageName,
                        route: route,
                        isPush: nil,
                        parentPageId: nil
                    )

                    // SwiftUI 中通常在 onAppear 后立即可见，模拟 firstLayout 和 appear
                    if trackFirstLayout {
                        // 延迟一小段时间模拟首次布局
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                            PageTimingRecorder.shared.markPageFirstLayout(visitId: visitId)
                        }
                    }

                    // 标记页面出现
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                        PageTimingRecorder.shared.markPageAppear(visitId: visitId)
                    }
                }
                .onDisappear {
                    guard hasAppeared, !visitId.isEmpty else { return }

                    // 结束计时并上报
                    PageTimingRecorder.shared.markPageEnd(visitId: visitId)

                    // 重置状态
                    visitId = ""
                    hasAppeared = false
                }
        }
    }

    // MARK: - View Extension

    public extension View {
        /// 追踪页面耗时
        /// - Parameters:
        ///   - pageId: 页面标识（如 VC 类名或自定义 ID）
        ///   - pageName: 页面显示名称（可选，默认使用 pageId）
        ///   - route: 业务路由（可选）
        /// - Returns: 添加了耗时追踪的 View
        ///
        /// 使用示例:
        /// ```swift
        /// struct ProductDetailView: View {
        ///     var body: some View {
        ///         VStack { ... }
        ///             .trackPageTiming("ProductDetailView", pageName: "商品详情")
        ///     }
        /// }
        /// ```
        func trackPageTiming(
            _ pageId: String,
            pageName: String? = nil,
            route: String? = nil
        ) -> some View {
            modifier(PageTimingModifier(
                pageId: pageId,
                pageName: pageName,
                route: route
            ))
        }

        /// 追踪页面耗时（使用类型名作为 pageId）
        /// - Parameters:
        ///   - pageName: 页面显示名称（可选）
        ///   - route: 业务路由（可选）
        /// - Returns: 添加了耗时追踪的 View
        ///
        /// 使用示例:
        /// ```swift
        /// struct ProductDetailView: View {
        ///     var body: some View {
        ///         VStack { ... }
        ///             .trackPageTiming(pageName: "商品详情")
        ///     }
        /// }
        /// ```
        func trackPageTiming(
            pageName: String? = nil,
            route: String? = nil
        ) -> some View {
            modifier(PageTimingModifier(
                pageId: String(describing: type(of: self)),
                pageName: pageName,
                route: route
            ))
        }
    }

    // MARK: - Page Timing Wrapper View

    /// 页面耗时追踪包装视图
    /// 适用于需要在 View 外部控制追踪的场景
    public struct PageTimingView<Content: View>: View {
        let pageId: String
        let pageName: String?
        let route: String?
        let content: () -> Content

        @State private var visitId: String = ""

        public init(
            pageId: String,
            pageName: String? = nil,
            route: String? = nil,
            @ViewBuilder content: @escaping () -> Content
        ) {
            self.pageId = pageId
            self.pageName = pageName
            self.route = route
            self.content = content
        }

        public var body: some View {
            content()
                .trackPageTiming(pageId, pageName: pageName, route: route)
        }
    }

    // MARK: - Manual Marker Extension

    public extension View {
        /// 在 View 出现时添加自定义标记
        /// - Parameters:
        ///   - name: 标记名称
        ///   - visitId: 访问 ID（从 markPageStart 获取）
        /// - Returns: 添加了标记的 View
        func addPageTimingMarker(_ name: String, visitId: String) -> some View {
            onAppear {
                PageTimingRecorder.shared.addMarker(name: name, visitId: visitId)
            }
        }
    }

    // MARK: - Environment Key (Optional Advanced Usage)

    /// 页面访问 ID 环境键
    private struct PageVisitIdKey: EnvironmentKey {
        static let defaultValue: String = ""
    }

    public extension EnvironmentValues {
        /// 当前页面访问 ID（用于在子视图中添加标记）
        var pageVisitId: String {
            get { self[PageVisitIdKey.self] }
            set { self[PageVisitIdKey.self] = newValue }
        }
    }

    // MARK: - Advanced Page Timing Modifier with Environment

    /// 高级页面耗时追踪 Modifier
    /// 会将 visitId 注入环境，子视图可通过 `@Environment(\.pageVisitId)` 获取
    public struct AdvancedPageTimingModifier: ViewModifier {
        let pageId: String
        let pageName: String?
        let route: String?

        @State private var visitId: String = ""
        @State private var hasAppeared: Bool = false

        public init(pageId: String, pageName: String? = nil, route: String? = nil) {
            self.pageId = pageId
            self.pageName = pageName
            self.route = route
        }

        public func body(content: Content) -> some View {
            content
                .environment(\.pageVisitId, visitId)
                .onAppear {
                    guard !hasAppeared else { return }
                    hasAppeared = true

                    visitId = PageTimingRecorder.shared.markPageStart(
                        pageId: pageId,
                        pageName: pageName,
                        route: route
                    )

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                        PageTimingRecorder.shared.markPageAppear(visitId: visitId)
                    }
                }
                .onDisappear {
                    guard hasAppeared, !visitId.isEmpty else { return }
                    PageTimingRecorder.shared.markPageEnd(visitId: visitId)
                    visitId = ""
                    hasAppeared = false
                }
        }
    }

    public extension View {
        /// 追踪页面耗时并将 visitId 注入环境
        /// 子视图可通过 `@Environment(\.pageVisitId)` 获取并添加自定义标记
        func trackPageTimingWithEnvironment(
            _ pageId: String,
            pageName: String? = nil,
            route: String? = nil
        ) -> some View {
            modifier(AdvancedPageTimingModifier(
                pageId: pageId,
                pageName: pageName,
                route: route
            ))
        }
    }
#endif
