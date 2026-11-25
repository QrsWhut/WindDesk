# WindDesk

WindDesk 是 macOS 14 及以上的个人行情应用。菜单栏面板和桌面小组件显示 Wind Alice Market 的黄金、指数和自选股行情。

## 获取 Wind Alice API Key

请在 Wind Alice Market 官网获取个人账号的 API Key。 [https://market.windalice.com/#/home](https://market.windalice.com/#/home)

1. 在首页右上角点击「登录」，登录后点击同一位置的「我的账户」。
2. 在「我的套餐」页面找到「API 密钥」，点击「复制」，即可复制完整的 API Key。

## 从源码构建与安装

在运行 macOS 14 或更新版本的 Mac 上，使用 Xcode Command Line Tools 从源码构建 WindDesk。如果还没有安装命令行工具，请先运行 `xcode-select --install`，等安装完成后执行以下命令。

```sh
git clone https://github.com/QrsWhut/WindDesk.git
cd WindDesk
./scripts/build-app.sh
```

1. 构建完成后，将生成的 `dist/WindDesk.app` 拖到个人应用程序目录 `~/Applications` 或系统应用程序目录 `/Applications`。在访达按 `⌘⇧G` 可输入目录路径。如果个人目录还不存在，先在自己的主目录下新建 `Applications` 文件夹。
2. 从安装目录双击打开 `WindDesk.app`，在菜单栏找到 WindDesk 的折线图标。

构建脚本会为应用和内嵌的小组件生成本机使用的临时签名（ad hoc）。当前版本已在 Apple Silicon、macOS 15.5 和 Swift 6.1.2 下构建验证。

## 首次运行

1. 点击菜单栏的 WindDesk 图标，打开「设置」，将从 Wind Alice Market 复制的 Key 粘贴到「Wind Alice API Key」并保存。
2. 点击「刷新」或按 `⌘R` 获取行情。
3. 在「指数」页管理关注的指数，在「自选」页管理股票。初次使用时，指数列表已包含纳斯达克 100、科创 50、创业板 50 和上证指数。

## 菜单栏

旧版用户可在设置中点击「从旧钥匙串迁移」，按 macOS 提示一次性授权读取之前的钥匙串条目。

API Key 在运行时填写。应用将它以原文保存到当前用户的 `~/Library/Application Support/WindDesk/wind-api-key`，目录权限为 `0700`，文件权限为 `0600`。调用行情时，Key 通过 HTTPS 请求头传给 `mcp.wind.com.cn`。

「行情」显示双币金价、关注的指数和前三只自选股。在「指数」页或「自选」页按名称或 Wind 代码搜索，点击「添加」加入相应列表，点击「编辑」排序或移除。新加入的标的会在下次取数时更新报价。「设置」可配置 Wind Key 和自动刷新，也提供钥匙串迁移、小组件说明和连接诊断。

点击「刷新」或按 `⌘R`，面板按伦敦金、指数、自选股的顺序更新。每条报价显示 Wind 的行情时间，底部显示本机上次成功取数的时间。

## 桌面小组件

打开 WindDesk 并刷新行情。在桌面空白处右键选择「编辑小组件」，搜索 WindDesk，添加「黄金与市场指数」。

在「设置 → 桌面小组件」可分别设置中号和大号组件显示的指数与自选股数量。中号合计最多 4 项，默认显示 4 个指数。大号合计最多 7 项，默认显示 4 个指数和 3 只自选股。数量设为 0 可隐藏对应类别，两类都设为 0 时只显示黄金区域。

小组件取各列表最前面的标的。在「指数」页或「自选」页调整顺序，可优先显示你关注的标的。名额用满时，先减少其中一类的数量，再增加另一类。

菜单栏应用手动或定时取得新行情后，会保存快照并通知 WidgetKit。调整指数或自选股列表也会同步到小组件。小组件顶部显示快照的最近取数时间，各条报价旁显示 Wind 的行情时间。启用自动刷新后，小组件也会按该间隔请求重读本地快照，实际显示时间由 macOS 调度。

## 登录启动与行情刷新

本机尚未设置刷新间隔时，默认每 10 分钟刷新一次。可在「设置 → 行情自动刷新」选择「关闭」，或选择 5、10、15、30、60 分钟。已有设置会保留，包括此前选择的「关闭」。

保存 Wind Key 后，开启自动刷新或重开 WindDesk 时，如果距离上次取数已超过所选间隔，会立即取数。也可以点击「刷新」或按 `⌘R` 手动取数。

WindDesk 默认不会在登录 Mac 时自动打开。需要时，可在「系统设置 → 通用 → 登录项与扩展 → 登录时打开」中点「＋」，选择已安装的 `WindDesk.app`。 [Apple 的登录项说明](https://support.apple.com/zh-sg/guide/mac-help/mh15189/mac)

启用自动刷新后，只需让 WindDesk 在菜单栏运行，面板可以关闭。退出应用后，自动取数暂停，小组件继续显示最后保存的报价和时间。

## 报价口径

- 伦敦现货金美元价用 `SPTAUUSDOZ.IDC`，单位为美元/金衡盎司。人民币价用 `XAUCNY.IDC`，单位为元/克。两条原报价各有自己的行情时间。
- 人民币报价缺失且本次取得美元金价时，才尝试用美元兑人民币即期汇率折算。折算按 31.1034768 克/金衡盎司计算，并标出汇率口径。
- 默认指数为纳斯达克 100 `NDX.GI`、科创 50 `000688.SH`、创业板 50 `399673.SZ`、上证指数 `000001.SH`。有前收盘价时按最新价计算涨跌幅，缺少前收盘价时使用 Wind 返回的涨跌幅。
- 取数失败时保留最近报价及其原行情时间，菜单栏显示当次错误。

## 开发与签名

运行 `swift run WindDeskChecks` 可使用合成样例检查行情解析、缓存迁移、人民币报价优先级和小组件快照。Wind Alice 的可用行情与额度以账号权益为准。

本机签名版本把行情、指数和股票列表写到 `~/Library/Application Support/WindDeskWidget/market-snapshot.json`，只为小组件授予这个文件的读取权限。

使用开发者证书进行构建时，应用和扩展共用 App Group `group.com.winddesk.market`。分别用 `WINDDESK_APP_PROVISIONING_PROFILE` 和 `WINDDESK_WIDGET_PROVISIONING_PROFILE` 提供授权该 App Group 的描述文件，并设置 `WINDDESK_SIGN_IDENTITY`。

[Wind Alice 使用文档](https://market.windalice.com/#/faq) · [Wind 官方工具包](https://market.windalice.com/resources/skill-pro-1.0.0.zip) · [Apple App Group 容器规则](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)
