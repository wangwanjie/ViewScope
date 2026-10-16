# 客户端核心审计（2026-10-16，静态阅读）

路径相对 `ViewScope/ViewScope/`。

## 连接与请求
1. 请求与建连无超时（ClientSession `pendingRequests` 只在断开时失败）；`handle(state:)` 不处理 `.waiting`，连接被拒绝的端口时 readyContinuation 永不恢复。
2. 回复解码失败直接丢弃 → continuation 泄漏；encode 失败直接 return；发送错误被忽略。
3. 宿主断开后 Store 收不到通知（`L10n.connectedHostDisappeared` 文案存在但未使用），没有自动重连。
4. 任意一次刷新失败（含服务端业务错误）就断开整个连接并置为 `.failed`（WorkspaceStore refreshCapture catch）。
5. `connect(using:)` 找不到宿主时直接 `.failed`，不断开当前 session，定时器还在跑。
6. `connect` 中 `try database.recordConnection` 抛错会断开已握手成功的连接。

## 自动刷新与选中
7. 自动刷新请求可重叠，旧结果覆盖新结果（同一 generation 内无序号保护），定时器在首次 capture 前就启动。
8. refreshCapture 在 await 前拍选中快照，`preferredNodeID` 优先级高于当前选中 → 请求期间用户换选中会被改回。
9. 选中为空时刷新会自动选中根节点（WorkspaceSelectionController `targetNodeID = rootNodeIDs.first`）。
10. 自动刷新 `forceReloadDetail = false` 且选中不变时不重新拉 detail → Inspector 数据过期。

## Console
11. 每次 capture 新 captureID，`reconcileForLatestCapture` 清掉 currentTarget 并置 `isLoadingTarget = true`，但第 10 条导致 selectNode 不调用 → 输入框永久禁用；手动选的目标、recent 对象也被清空。
12. `selectNode` catch：高亮失败也进入 catch 并清空 consoleCandidateTargets；不检查 `selectedNodeID == nodeID`；失败时不清 selectedNodeDetail。

## Inspector
13. 会把 A 节点属性写到 B 节点：`InspectorPanelModelBuilder.makeModel` 不检查 `detail.nodeID == node.id`，提交用 `selectedNodeID`。
14. 每次 capture/detail 发布都重建整个面板，自动刷新时正在编辑的文本框被移除，`textDidEndEditing` 把半截值提交。
15. 失焦就提交，不比较值是否变化。
16. NSColorWell 连续发 action，拖动取色盘时每帧一次 mutation + 完整刷新。
17. `applyMutation` 在刷新失败时仍返回 true（disconnectCurrentSession 不递增 generation）。

## 菜单、状态栏、Console 面板
18. Hide Others 未设置 `.option`，与 Hide 都是 ⌘H。
19. 状态栏 Refresh 一直可用（NSMenu autoenablesItems），主菜单 Refresh/Export 未 validate。
20. 导入/导出错误标题误用 `fatalLaunchTitle`（AppDelegate）。
21. Console 每次 capture 变化重建全部行并滚到底部。
22. submitConsole 不检查 generation；consoleRows 无上限；当前目标不在 options 时 popup 选中第 0 项。

## 文件、更新与杂项
23. 导入允许多选但只保留最后一个；不检查 formatVersion/archiveVersion。
24. `ViewScope-Info.plist` 的 `LSMinimumSystemVersion = 11.0` 与部署目标 12.0 不一致。
25. Sparkle 分支不写 `lastUpdateCheckKey`，“每天检查”失效。
26. DiscoveryCenter 6 秒过期，宿主停在断点超过 6 秒就从列表消失。
27. `setShowsSystemWrapperViews` 发起无意义的完整 capture；从偏好改动不整理选中。
28. JSON 解码与 SQLite 写入在主线程；每次自动刷新插入一条 capture_history。
29. 语言切换不同步到服务端；`backgroundString` 忽略 `VIEWSCOPE_LANGUAGE`。
- `IntegrationGuideView.swift:31` 硬编码“或者”；`IntegrationGuideView.swift:11` 与 ClientSession 回退版本硬编码 `1.2.2`。

## 半成品
- 最近宿主（recentHosts / connect(using:)）无 UI；captureInsight 无 UI。
- `showsSessionSidebar/showsInspector` 持久化但没人读，Inspector 不能隐藏。
- `contentInsets.*` 四元组服务端不下发；`stack.edgeInsets.*`、`contentOffset`、`contentSize`、`intercellSpacing` 没聚合。
- 枚举属性以裸数字编辑，无下拉。
- Console 只支持无参 selector，无历史；返回对象下一次刷新即失效。
- Undo/Redo 不覆盖 mutation；缺少断开、缩放、2D/3D、聚焦等菜单项。
- 导入模式下 Refresh/Disconnect 被禁用，无法关闭导入回到空闲。
- 状态栏连接计数只可能 0/1。
- Discovery 在 `MainViewController.viewDidLoad` 启动，依赖视图生命周期。

## 架构概要
WorkspaceStore 是唯一状态中心（@Published）；DiscoveryCenter 收集公告；WorkspaceConnectionCoordinator 管 session/generation/自动刷新；WorkspaceSelectionController 整理选中；WorkspaceConsoleController 计算 console 状态；WorkspaceCaptureCoordinator + WorkspaceArchiveCodec 负责导入导出。协议为换行分隔 JSON，requestID 匹配 continuation。Inspector 行：toggle/number/text/quad（frame.*、bounds.*、contentInsets.* 聚合）/color（text 且 key 为 backgroundColor、以 color 结尾或值形如 #hex）/readOnly/list；提交统一走 InspectorPropertyCommitCoordinator。
