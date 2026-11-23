import SwiftUI

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
            DisclosureGroup("桌面小组件") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("按住 Control 键点按桌面，选择「编辑小组件」，搜索 WindDesk 后添加。")
                    Text("在菜单栏刷新后，小组件会读取最新快照。中号显示金价与指数，大号还显示前三只自选股。")
                    if let error = store.widgetError { PanelNotice(text: error) }
                }
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
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
