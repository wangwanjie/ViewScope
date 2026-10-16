# 客户端预览与层级树审计（2026-10-16，静态阅读）

路径前缀 `ViewScope/ViewScope/Modules/`。

## A. 渲染与性能
1. flat ↔ layered 切换动画失效且整棵重建：`setDimension` 里 `displayMode` didSet 触发 refreshScene，StructuralState 含 displayMode → rebuildScene 直接摆到终值。
2. 折叠（不可见层）节点也生成纹理（`PreviewLayeredScenePlan.visibleNodes` 递归所有非 hidden 节点，`resolvedTextureImage` 为每个 item lockFocus 裁图，随后 opacity = 0）。
3. 层间距、border 开关在 StructuralState 里，拖滑块每次全量重建；自动刷新新 captureID 也全量重建。
4. plan 构建 O(n²)：`canvasRect` 每次从根 DFS；`assignZIndexes`、`addOverlapPunchOuts` O(n²)；`nodePreviewScreenshots.first(where:)` 线性查找。
5. 选中变化时给所有节点重建 border geometry。

## B. 坐标与相机
6. 3D 下旋转支点固定画布中心，`translationForCentering` 只取 `-center`，有旋转时居中偏移、先平移再旋转内容甩出视野。修复：pivot 或把平移放到旋转之后的父节点。
7. 平移无边界；pitch 不限幅；平移速度与视图尺寸/缩放无关，未区分 `hasPreciseScrollingDeltas`；缩放不以光标为锚点。
8. `clippingEnabled` 被忽略，被裁剪子视图按完整 frame 建平面且可被点中。
9. 截图回退到 `previewBitmaps.first` 时选中框画在别的窗口上。
10. 选中 overlay `renderingOrder` 为 0 且关闭深度读写，flat 下可能被子层纹理盖住（推测）。
11. solo 截图纹理不做 punch-out；solo 尺寸取 bounds.size 与 frame 不同时被拉伸。
12. 层间距 10–16 无效（`zStep = max(0.08, spacing*0.005)`）。
13. 只能点中“独立显示”的层：折叠节点 categoryBitMask = 0；`ViewHierarchyGeometry.deepestNodeID` 只在测试里用；透明容器整个矩形可被点中。
14. focus 变化时居中执行两次；清除 focus 时 RecenterFullCanvas 实际居中到 selected 节点。

## C. 树与预览同步
15. （高优先级）`ViewTreeSelectionSynchronizer` 的 `deselectAll` 未包在 `withProgrammaticSelection` 里 → 触发 selectNode(nil) 清空用户选中（focus 外点选、搜索过滤中点选）。
16. 折叠后再展开，NSOutlineView 保留孙节点展开态而 store 已清除；树不订阅 `store.$expandedNodeIDs`。
17. 选中 hidden 节点后任意展开/折叠清空选中；“隐藏视图”后 refresh 把选中跳到父节点，无法立刻“显示”回来。
18. `expandAncestors` 由近到远逐级 setNodeExpanded，中途选中被判不可见置 nil；应使用 store 的原子 `expandAncestors(of:)`。
19. focus 下树根为 focused 节点并强制展开，但 store 不认为它已展开，预览子节点不分层。
20. 手动刷新（clearingVisibleState: true）清空全部展开状态和树滚动位置；服务端位置型节点 ID（1.3 起服务端改为地址型稳定 ID）。

## D. 搜索与菜单
21. 搜索结果停在折叠父节点下；`filtered()` 丢掉匹配节点下不匹配的子节点；每次按键全量重建无防抖。
22. 右键菜单 Focus/Highlight 作用于 selectedNodeID，隐藏/复制/展开作用于 clickedRow，不一致。
23. “展开/折叠子项”用原始 childIDs 判断；`expandRecursively` O(n²) 且 didExpand 回调重复调用。
24. 方向键导航每行发一次 detail 请求并让宿主闪烁，无防抖。

## 半成品
- 预览无 keyDown：缺 Esc 清 focus、+/- 缩放、方向键切换、Cmd+F 搜索；点击预览后 SCNView 抢焦点，树方向键失效。
- 两套灯光是死代码（材质为 `.constant`）；content-plane 标记节点为空；`legacyLocalFrames` 等死参数；注释引用不存在的 `PreviewLayeredRenderPlan`。
- flat 下层间距滑块无效果；flat 下拖拽不平移且松手触发选中。
- 视角无法复位（`hasUserRotated` 不重置，100% 只重置 zoom）。
- Focus 不隔离子树，只居中加蒙层。
- `groupPNGBase64`、`alphaValue`、`clippingEnabled` 未使用。

## 现有能力
预览：2D/3D 切换、3D 拖拽旋转、滚轮平移、Cmd+滚轮/捏合/±/100% 缩放（35%–400%）、单击选中、双击 focus、选中 overlay、展开节点子层独立（Lookin 式）+ punch-out、层间距/边框设置、Focus/清除 Focus/显示隐藏/宿主高亮/Console 开关。
缺：hover 联动、测量、线框模式、显示被裁剪内容、深度范围、仅预览隐藏、复位视角、光标锚点缩放、focus 隔离、快捷键、导出预览图。
树：搜索、系统 wrapper 开关、Focus 子树、隐藏节点半透明、类名图标、`VC.view` 标注、ivar 名、事件 handler 徽标与详情、右键菜单。
缺：搜索自动展开与高亮、上/下一个匹配、匹配计数、hover 联动、Cmd+F。
