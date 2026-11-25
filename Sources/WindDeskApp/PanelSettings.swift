import SwiftUI
import WindDeskCore

struct PanelSettings: View {
    @Bindable var store: MarketStore
    let showMarkets: () -> Void

    @State private var editingKey = false
    @State private var draft = ""
    @State private var saved = false
    @FocusState private var keyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("Wind Alice API Key", systemImage: "key").font(.headline)
                    Spacer()
                    if store.hasKey && !editingKey {
                        Button("更换") {
                            editingKey = true
                            saved = false
                        }
                        .controlSize(.small)
                    }
                }
                if !store.hasKey || editingKey {
                    SecureField(store.hasKey ? "输入新的 API Key" : "输入 API Key", text: $draft)
                        .focused($keyFocused)
                        .onSubmit { saveKey() }
                        .onAppear { if editingKey { keyFocused = true } }
                    HStack {
                        Button("保存") { saveKey() }
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || requestInProgress)
                        if editingKey {
                            Button("取消") {
                                draft = ""
                                editingKey = false
                            }
                        } else if !store.hasKey {
                            Button("从旧钥匙串迁移") { saved = store.migrateKey() }
                                .disabled(requestInProgress)
                                .help("迁移旧版本保存的 Wind Key，系统可能请求钥匙串授权。")
                        }
                    }
                    .controlSize(.small)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                        Text(saved ? "已保存到本机" : "已配置，保存在本机用户目录")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 1)
                        if saved {
                            Button("查看并刷新") {
                                showMarkets()
                                Task { await store.refresh() }
                            }
                            .controlSize(.small)
                            .disabled(requestInProgress)
                        }
                    }
                }
                if let error = store.settingsError { PanelNotice(text: error) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent {
                    Picker("自动刷新间隔", selection: $store.autoRefreshInterval) {
                        ForEach(AutoRefreshInterval.allCases, id: \.rawValue) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                } label: {
                    Label("行情自动刷新", systemImage: "arrow.clockwise").font(.headline)
                }
                Text("保存 Key 后，WindDesk 会在运行期间按所选间隔取数。桌面小组件的更新时间由 macOS 决定。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            widgetSettings
            Divider()
            DisclosureGroup("连接诊断") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("单独查询 Wind 伦敦金，核对报价、行情时间和接口权限。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button(store.isCheckingWindGold ? "检查中…" : "检查伦敦金") {
                        Task { await store.checkWindGold() }
                    }
                    .controlSize(.small)
                    .disabled(!store.hasKey || requestInProgress)
                    ForEach(Array(store.windGoldCheckLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
        }
        .onDisappear { draft = "" }
    }

    private var widgetSettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("桌面小组件", systemImage: "square.grid.2x2").font(.headline)
            widgetCountRow("中号", capacity: WidgetDisplaySettings.mediumCapacity, keyPath: \.medium)
            widgetCountRow("大号", capacity: WidgetDisplaySettings.largeCapacity, keyPath: \.large)
            Text("数量设为 0 可隐藏对应类别。名额用满时，先减少另一类的数量。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("按住 Control 键点按桌面，选择「编辑小组件」，搜索 WindDesk 后添加。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = store.widgetError { PanelNotice(text: error) }
        }
    }

    private func widgetCountRow(
        _ size: String, capacity: Int,
        keyPath: WritableKeyPath<WidgetDisplaySettings, WidgetDisplaySettings.Counts>
    ) -> some View {
        let counts = Binding(
            get: { store.widgetDisplaySettings[keyPath: keyPath] },
            set: { counts in
                var settings = store.widgetDisplaySettings
                settings[keyPath: keyPath] = counts
                store.setWidgetDisplaySettings(settings)
            }
        )
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(size).font(.callout.weight(.medium))
                Text("最多 \(capacity) 项").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Picker("指数", selection: counts.indices) {
                ForEach(0...max(0, capacity - counts.stocks.wrappedValue), id: \.self) { count in
                    Text(count.formatted()).tag(count)
                }
            }
            .accessibilityLabel("\(size)指数显示数量")
            Picker("自选股", selection: counts.stocks) {
                ForEach(0...max(0, capacity - counts.indices.wrappedValue), id: \.self) { count in
                    Text(count.formatted()).tag(count)
                }
            }
            .accessibilityLabel("\(size)自选股显示数量")
        }
        .pickerStyle(.menu)
        .controlSize(.small)
    }

    private var requestInProgress: Bool {
        store.isRefreshing || store.isCheckingWindGold || store.isSearching
    }

    private func saveKey() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !requestInProgress else { return }
        if store.saveKey(key) {
            draft = ""
            editingKey = false
            saved = true
        }
    }
}
