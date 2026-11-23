# WindDesk

WindDesk 是 macOS 14 及以上的个人行情应用。菜单栏面板和桌面小组件显示 Wind Alice Market 的黄金、指数和自选股行情。

## 下载与安装

预构建版适用于配备 Apple 芯片且运行 macOS 14 或更新版本的 Mac，解压即可安装。 [下载 WindDesk 0.3.0（ZIP）](https://github.com/QrsWhut/WindDesk/releases/download/v0.3.0/WindDesk-0.3.0-macos-arm64.zip)

1. 在访达中解压 ZIP，将 `WindDesk.app` 拖到个人应用程序目录 `~/Applications` 或系统应用程序目录 `/Applications`。可以按 `⌘⇧G` 输入目录路径。若个人目录还不存在，可先在自己的主目录下新建 `Applications` 文件夹。
2. 从安装目录双击打开 `WindDesk.app`，在菜单栏找到 WindDesk 的折线图标。

预构建版采用临时签名（ad hoc），尚未经过 Apple 公证。若首次打开时 macOS 无法验证开发者，确认下载来源后可在「系统设置 → 隐私与安全性」选择「仍要打开」。 [Apple 的打开说明](https://support.apple.com/zh-cn/102445)

## 获取并配置 Wind API Key

1. 从 [Wind Alice Market 首页](https://market.windalice.com/#/home) 登录自己的 Wind 账号。
2. 进入「使用方法」，选择「统一 MCP」并点「一键配置」。Wind 会在配置中填入当前账号的 API Key，复制 Key 本身即可。 [Wind Alice 使用文档](https://market.windalice.com/#/faq)
3. 点击菜单栏的 WindDesk 图标，打开「设置」，把 Key 粘贴到「Wind Alice API Key」并保存。然后点击「刷新」或按 `⌘R` 获取行情。
4. 如需添加自选股，在「自选」页按名称或证券代码搜索并加入列表。

## 菜单栏

旧版用户可在设置中点击「从旧钥匙串迁移」，按 macOS 提示一次性授权读取之前的钥匙串条目。

API Key 在运行时填写。应用将它以原文保存到当前用户的 `~/Library/Application Support/WindDesk/wind-api-key`，目录权限为 `0700`，文件权限为 `0600`。调用行情时，Key 通过 HTTPS 请求头传给 `mcp.wind.com.cn`。

「行情」显示双币金价、四个指数和最前面的三只自选股。「自选」支持按名称或 Wind 代码搜索，以及添加、排序和移除。「设置」管理 Wind Key、钥匙串迁移、小组件说明和连接诊断。

点击「刷新」或按 `⌘R`，面板按伦敦金、指数、自选股的顺序更新。每条报价显示 Wind 的行情时间，底部显示本机上次成功取数的时间。

## 桌面小组件

打开 WindDesk 并刷新行情。在桌面空白处右键选择「编辑小组件」，搜索 WindDesk，添加「黄金与市场指数」。中号显示两种单位的伦敦金和四个指数，大号加上自选列表前 3 只股票。

自选股超过 3 只时，可在「自选」页查看完整列表。点击「编辑」调整顺序，把想显示在大号组件上的股票移到前三。

小组件读取菜单栏应用最近保存的行情快照。点击「刷新」后，WindDesk 从 Wind 获取行情并通知 WidgetKit 更新。调整自选也会同步到小组件。小组件的显示时机由 macOS 调度，报价旁会显示行情时间。

## 登录启动与行情刷新

WindDesk 默认不会在登录 Mac 时自动打开。需要时，可在「系统设置 → 通用 → 登录项与扩展 → 登录时打开」中点「＋」，选择已安装的 `WindDesk.app`。 [Apple 的登录项说明](https://support.apple.com/zh-sg/guide/mac-help/mh15189/mac)

当前版本在手动点击「刷新」或按 `⌘R` 时获取新行情。登录时自动打开只负责启动应用，取数仍需手动刷新。应用未启动或已退出时，桌面小组件继续显示最近保存的报价和时间，直到菜单栏应用再次刷新。

## 报价口径

- 伦敦现货金美元价用 `SPTAUUSDOZ.IDC`，单位为美元/金衡盎司。人民币价用 `XAUCNY.IDC`，单位为元/克。两条原报价各有自己的行情时间。
- 人民币报价缺失且本次取得美元金价时，才尝试用美元兑人民币即期汇率折算。折算按 31.1034768 克/金衡盎司计算，并标出汇率口径。
- 四个指数为纳斯达克 100 `NDX.GI`、科创 50 `000688.SH`、创业板 50 `399673.SZ`、上证指数 `000001.SH`。有前收盘价时按最新价计算涨跌幅，缺少前收盘价时使用 Wind 返回的涨跌幅。
- 取数失败时保留最近报价及其原行情时间，菜单栏显示当次错误。

## 从源码构建

构建脚本使用 Xcode Command Line Tools 和 macOS SDK。首次安装命令行工具可运行 `xcode-select --install`。

```sh
git clone https://github.com/QrsWhut/WindDesk.git
cd WindDesk
./scripts/build-app.sh
```

构建后，将包含 WidgetKit 扩展的 `dist/WindDesk.app` 移到 `~/Applications` 或 `/Applications`，再从访达打开。当前版本已在 Apple Silicon、macOS 15.5 和 Swift 6.1.2 下构建验证。

运行 `swift run WindDeskChecks` 可使用合成样例检查行情解析、缓存迁移、人民币报价优先级和小组件快照。Wind Alice 的可用行情与额度以账号权益为准。

本机签名版本把行情和自选股快照写到 `~/Library/Application Support/WindDeskWidget/market-snapshot.json`，只为小组件授予这个文件的读取权限。

使用开发者证书进行构建时，应用和扩展共用 App Group `group.com.winddesk.market`。分别用 `WINDDESK_APP_PROVISIONING_PROFILE` 和 `WINDDESK_WIDGET_PROVISIONING_PROFILE` 提供授权该 App Group 的描述文件，并设置 `WINDDESK_SIGN_IDENTITY`。

[Wind Alice 使用文档](https://market.windalice.com/#/faq) · [Wind 官方工具包](https://market.windalice.com/resources/skill-pro-1.0.0.zip) · [Apple App Group 容器规则](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)
