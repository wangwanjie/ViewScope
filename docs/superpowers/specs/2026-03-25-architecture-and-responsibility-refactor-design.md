# ViewScope 全仓结构与职责重构设计

## 摘要

这次重构覆盖 `ViewScope` 客户端与 `ViewScopeServer` 宿主端两个子系统，目标不是只调整目录名字，而是把当前已经明显过载的超大文件拆回清晰、稳定、可测试的职责边界。

当前仓库的主要问题有三类：

1. 少数核心文件承担了过多职责，目录分层无法真实反映代码边界。
2. 状态同步、错误处理、请求校验、截图构建、属性变更等逻辑存在重复或近似重复实现。
3. 复杂渲染与遍历规则缺少足够的中文说明，后续维护门槛偏高。

本次设计的重点是按“会一起变化的功能”组织文件，并把真正复杂的规则沉淀为可独立阅读、可独立测试的小单元。

## Goals

- 让客户端与宿主端都按功能域组织代码，而不是继续把多类逻辑堆进少数入口文件。
- 拆分 `WorkspaceStore.swift`、`InspectorPanelController.swift`、`ViewTreePanelController.swift`、`PreviewPanelController.swift`、`PreviewLayeredSceneView.swift`、`ViewScopeInspector.swift`、`ViewScopeSnapshotBuilder.swift` 等高复杂度文件。
- 消除重复的状态校验、属性提交流程、mutation 分发、节点遍历、截图分支选择等逻辑。
- 让复杂逻辑拥有必要的中文注释，尤其是预览几何、截图合成、节点树构建、引用上下文和 mutation 路由。
- 通过测试与现有行为对齐，保证重构后功能不倒退。

## Non-Goals

- 不追求一次性重写所有 UI 控件或完全重塑产品交互。
- 不为了“绝对干净”而强行改动所有对外 API；只有在收益足够明确时才调整公开接口。
- 不在这轮把客户端和宿主端拆成更多独立 package。
- 不改动与本次边界重构无关的发布脚本和资源目录。

## 重构原则

### 1. 按功能聚合，不按技术层散落

状态、规则、视图、适配器、辅助类型如果围绕同一功能一起变化，就应该放在同一个功能域下，而不是继续分散在 `UI`、`Services`、`Support` 多个平铺目录里。

### 2. 入口薄、实现厚

保留少量稳定入口，例如：

- 客户端的 workspace 对外状态入口
- 宿主端的 `ViewScopeInspector.start()`

但这些入口只负责编排，不再承担大段业务细节。

### 3. 一个文件只解释一类问题

单一职责不只针对类，也针对文件。一个文件如果同时包含：

- UI 组装
- 状态订阅
- 输入校验
- 网络请求
- 数据转换
- 业务规则

那它就已经超出合理边界，应该拆分。

### 4. 注释只写在“阅读成本高”的地方

简单 setter、显而易见的视图拼装、基础模型定义不补注释。注释集中放在：

- 坐标系转换
- 预览图像来源与回退策略
- 节点树遍历与补充子节点策略
- capture/reference 生命周期
- mutation 属性路由与安全约束

且全部使用中文注释。

## 当前问题总结

### 客户端 `ViewScope`

- `WorkspaceStore.swift` 同时负责 discovery、连接生命周期、capture 刷新、选中态、预览状态、展开状态、console 状态、导入导出、错误处理，已经是典型“上帝对象”。
- `InspectorPanelController.swift` 同时负责面板拼装、数据订阅、属性提交、输入解析和多种 row view 定义，文件边界已经失真。
- `ViewTreePanelController.swift`、`PreviewPanelController.swift`、`PreviewLayeredSceneView.swift` 都同时承担渲染、状态推导和交互编排，导致修改一个行为时需要跨越过多上下文。
- `Services`、`UI`、`Support` 的目录划分过于平铺，很多同一功能的代码被分散到多个目录。

### 宿主端 `ViewScopeServer`

- `ViewScopeInspector.swift` 同时负责自动启动、监听器、发现广播、请求调度、mutation 执行、错误映射，职责明显过宽。
- `ViewScopeSnapshotBuilder.swift` 同时负责节点树构建、ivar 追踪、子视图补全、截图、detail 构造、console target 构造，是当前最需要拆解的文件。
- `ViewScopeBridge.swift` 承载过多公共模型，文件增长后会降低协议演进效率。

## 目标结构

### 客户端 `ViewScope`

客户端不再只保留宽泛的 `UI / Services / Support` 平铺目录，而是朝以下结构收敛：

- `Application/`
- `Localization/`
- `Shared/`
- `Persistence/`
- `Preferences/`
- `StatusItem/`
- `Workspace/Core/`
- `Workspace/Connection/`
- `Workspace/Capture/`
- `Workspace/Hierarchy/`
- `Workspace/Inspector/`
- `Workspace/Preview/`
- `Workspace/Console/`

目录含义：

- `Workspace/Core` 放 workspace 聚合状态、公共上下文、跨面板共享类型。
- `Workspace/Connection` 放 discovery、session、连接有效性与 host 切换逻辑。
- `Workspace/Capture` 放 capture 刷新、导入导出、selection normalization、history insight。
- `Workspace/Hierarchy` 放树模型、过滤、搜索、outline 展示适配。
- `Workspace/Inspector` 放 inspector model builder、commit coordinator、row views。
- `Workspace/Preview` 放预览图像解析、几何模式、渲染上下文、平面/3D 渲染器。
- `Workspace/Console` 放 console target、rows、提交与返回值处理。

### 宿主端 `ViewScopeServer`

宿主端按职责拆成：

- `PublicAPI/`
- `Bootstrap/`
- `Discovery/`
- `Transport/`
- `Inspection/`
- `Snapshot/`
- `Mutation/`
- `Console/`
- `Support/`

目录含义：

- `PublicAPI` 放用户接入宿主 SDK 时直接面对的入口与公开模型。
- `Bootstrap` 放自动启动桥接和启动生命周期。
- `Discovery` 放 announcement/request/termination 广播。
- `Transport` 放监听器、连接、消息编解码。
- `Inspection` 放 inspector runtime 总控与请求分发。
- `Snapshot` 放节点树构建、截图、detail、reference context。
- `Mutation` 放属性修改映射与执行规则。
- `Console` 放 console target 和调用响应。
- `Support` 放颜色解析、类名格式化、图像编码、运行时辅助工具。

## 重点文件拆分设计

### 1. `WorkspaceStore.swift`

保留为对 UI 暴露的主状态门面，但内部拆分为若干协作者。目标不是机械拆类，而是按状态域收敛：

- `WorkspaceConnectionCoordinator`
  - 负责 discovery 绑定、连接代次、会话打开/关闭、host 切换安全性判断。
- `WorkspaceCaptureCoordinator`
  - 负责 capture 拉取、capture insight、导入导出、selection normalization。
- `WorkspaceSelectionController`
  - 负责 selected/focused/expanded 状态与可见祖先回退。
- `WorkspacePreviewState`
  - 负责 zoom、display mode、layer spacing、preview settings 持久化。
- `WorkspaceConsoleController`
  - 负责 target 候选、recent target、history rows、submit/invoke 生命周期。

`WorkspaceStore` 自己只保留：

- `@Published` 对外状态
- 高层用户意图入口
- 组件组装与跨域编排

### 2. `InspectorPanelController.swift`

拆分目标：

- `InspectorPanelController`
  - 只负责订阅 store、切换空态、装配 sections。
- `InspectorPropertyCommitCoordinator`
  - 负责属性提交、输入解析、失败回滚。
- `InspectorSectionCardView`
  - 独立成文件。
- 各种 `Inspector...RowView`
  - 各自成文件或按类型分组文件。

这样可以避免控制器文件同时包含几十个 UI 子类定义。

### 3. `ViewTreePanelController.swift`

拆分目标：

- `ViewTreePanelController`
  - 只负责驱动 outline 与用户交互。
- `ViewTreePresentationBuilder`
  - 负责 wrapper 过滤、搜索匹配、root 展示模型生成。
- `ViewTreeSelectionSynchronizer`
  - 负责 store 与 outline 的选中同步、程序化选中保护。

### 4. `PreviewPanelController.swift` 与 `PreviewLayeredSceneView.swift`

拆分目标：

- `PreviewPanelController`
  - 只负责工具栏状态与两套预览视图之间的编排。
- `PreviewRenderContextBuilder`
  - 负责把 capture、detail、selection、settings 解析为统一渲染上下文。
- `PreviewToolbarState`
  - 负责缩放、console 展开、focus 按钮可用性等派生状态。
- `PreviewLayeredSceneView`
  - 保留为 SceneKit 容器，但把节点布局、纹理裁剪、选区覆盖、交互状态进一步下沉。
- `PreviewLayeredSceneRenderer`
  - 负责结构状态对比、场景节点增量更新。
- `PreviewLayeredSceneInteraction`
  - 负责拖拽、旋转、缩放和进入 layered 模式时的视角处理。

### 5. `ViewScopeInspector.swift`

拆分目标：

- `ViewScopeInspector`
  - 保留对外入口。
- `ViewScopeInspectorLifecycle`
  - 继续负责自动启动开关，但独立到 `Bootstrap/`。
- `InspectorRuntime`
  - 负责运行时总控。
- `InspectorDiscoveryPublisher`
  - 负责 announcement 广播、request 回应、termination。
- `InspectorRequestRouter`
  - 负责把连接请求分发到 capture/detail/highlight/mutation/console 各处理器。
- `ViewMutationExecutor`
  - 负责属性 key 到实际 AppKit 改动的映射。

### 6. `ViewScopeSnapshotBuilder.swift`

拆分目标：

- `SnapshotCaptureBuilder`
  - 负责完整 capture 构建。
- `SnapshotTreeBuilder`
  - 负责 window/view 节点树与 reference context。
- `SnapshotChildViewCollector`
  - 负责 `capturedChildViews(of:)` 的系统容器补全策略。
- `SnapshotIvarTraceBuilder`
  - 负责 direct subview ivar trace。
- `SnapshotDetailBuilder`
  - 负责 detail payload、sections、ancestry、constraints。
- `SnapshotScreenshotRenderer`
  - 负责 window/view/solo/composite screenshot。
- `SnapshotConsoleTargetBuilder`
  - 负责 detail 中 console targets。

其中“坐标统一到左上角画布”的语义必须集中到少数类型里，不能散落在多个 helper 函数里。

### 7. `ViewScopeBridge.swift`

公共模型按主题拆分：

- `ViewScopeBridge+Discovery.swift`
- `ViewScopeBridge+Geometry.swift`
- `ViewScopeBridge+Hierarchy.swift`
- `ViewScopeBridge+Capture.swift`
- `ViewScopeBridge+Inspector.swift`
- `ViewScopeBridge+Console.swift`
- `ViewScopeBridge+Mutation.swift`

这样协议演进时能更清楚地知道自己在改哪一层契约。

## 冗余移除策略

本轮重构会主动清理以下冗余：

- 重复的 session/generation 有效性判断，统一收敛为可复用校验入口。
- 重复的属性提交包装逻辑，例如 text/number/toggle/color 提交前后的共同行为。
- 重复的 preview 图片回退和 cache key 生成逻辑。
- 重复的 mutation 参数取值与错误抛出模式。
- 重复的 capture 后 selection/console 对齐逻辑。
- 能通过纯函数统一表达的 UI 派生状态，不再在多个控制器里各算一遍。

以下内容不会盲目移除：

- 为了兼容 AppKit 特殊容器而存在的显式分支
- 为了可读性保留的轻量薄包装
- 与测试夹具、预览 fixture 直接相关的兼容逻辑

## 注释策略

复杂逻辑统一补充中文注释，重点包括：

- 为什么某些系统容器需要补采子节点
- 为什么某些视图必须走 composite screenshot 路径
- capture / detail / preview root 三者的关系
- connection generation 用来解决什么竞争问题
- mutation 中哪些属性允许修改、为什么要限制
- 3D 预览中平面层级、纹理裁切和选中覆盖的关键约束

注释要求解释“为什么”，不是重复代码字面意思。

## API 调整策略

用户已明确允许对 `ViewScopeServer` 公开 API 做必要调整，但这次仍采用“保守公开面、积极整理内部结构”的策略：

- 尽量保留 `ViewScopeInspector.start()`、`disableAutomaticStart()`、`stop()` 这些稳定主入口。
- 公共模型可以重新分文件，但不为目录整洁而随意改名。
- 只有当 API 现状会明显导致重复、歧义或错误用法时，才进行命名或签名调整。

## 测试与验证要求

重构必须补足或更新以下验证：

- `WorkspaceStore` 拆分后的连接生命周期测试
- capture 刷新与 selection normalization 测试
- inspector property commit 成功/失败回滚测试
- hierarchy 过滤与搜索模型测试
- preview render context / image resolver / layered plan 测试
- `ViewScopeServer` snapshot tree、detail、mutation、console 相关测试
- 工程级构建与现有测试套件回归

如果某块重构无法先有针对性测试，就不应该贸然大拆。

## 实施顺序

建议按以下顺序实施：

1. 先拆公共协议与功能目录，不改变关键行为。
2. 再拆客户端 `WorkspaceStore` 与 inspector/console 相关状态流。
3. 再拆 hierarchy 与 preview 的展示/渲染协作者。
4. 最后拆宿主端 `ViewScopeInspector` 与 `ViewScopeSnapshotBuilder`，并同步补测试。

原因：

- 先收拢协议与目录，后续文件移动的语义更清楚。
- 先处理客户端状态流，可以尽早降低 UI 侧耦合。
- 宿主端快照与 mutation 风险最高，放在已有验证基础后再动更稳妥。

## 风险与缓解

### 风险 1：文件移动过多导致回归面扩大

缓解方式：

- 分阶段重构，不一次性改完所有大文件。
- 每个阶段都要有可单独运行的测试与构建验证。

### 风险 2：状态拆分后造成 UI 同步顺序变化

缓解方式：

- 保持 `WorkspaceStore` 作为单一对外可观察入口。
- 用测试锁定 host 切换、capture 更新、selection 恢复、console target 重建这些时序行为。

### 风险 3：宿主端截图和节点树构建在拆分时出现语义偏移

缓解方式：

- 优先提炼纯函数与 builder，不先改规则。
- 对复杂几何和截图合成补中文注释与测试，再考虑进一步瘦身。

## 决策结论

本次重构采用“平衡式重构”路线：

- 不做表面化目录整理。
- 不做高风险全盘重写。
- 以功能域重组 + 超大文件拆分 + 冗余逻辑清理 + 中文注释补齐为核心目标。

这条路线可以在可控风险下，显著改善仓库可维护性、代码可读性和后续继续演进的效率。
