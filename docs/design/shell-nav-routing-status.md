# 壳层底栏路由现状梳理（只读 · 下轮改）

> 2026-09-21 ｜ 对应代码：`app_router.dart` / `app_shell.dart` / `expandable_glass_nav.dart`  
> 本轮 **不改行为**，只固化现状与疑似 bug，供下一轮修复。

## 分支契约（现状）

| index | path | 页 | 底栏入口 |
|-------|------|-----|----------|
| 0 | `/home` | HomePage | 主胶囊「首页」 |
| 1 | `/bookshelf` | BookshelfPage | 主胶囊「书架」 |
| 2 | `/sources` | BookSourcesPage | **仅**更多展开面板「书源」 |
| 3 | `/settings` | SettingsHubPage + 子页 | 更多圆键默认直达；面板「设置」 |

`appRouterProvider.initialLocation = '/home'`。  
Tab `pageBuilder` 均为 `NoTransitionPage`；页间观感动画在 `AppShell._playTabTransition`。

## goBranch 现状

```dart
navigationShell.goBranch(i, initialLocation: i == from);
_playTabTransition(from, i);
if (i == 0) homeIntroTick.value++; // 回首页重播入场
```

- **`initialLocation: i == from`**：点**当前** Tab 会重置到该分支根位置（设置子页会被 pop 回 hub）。
- 点其它 Tab：不强制回根，保留该分支栈（例如设置子页深度）。

## 疑似问题清单（按优先级）

### P0 · 书源几乎不可达（IA/路由）

1. 主胶囊只有「首页 | 书架」。
2. 更多圆键：`selectedIndex == 3` 才展开面板，否则 **永远去设置**。
3. 展开面板才有「书源」。  
⇒ 从首页/书架/书源，**无法一步到书源**；必须：更多 → 设置 →（已在设置）更多 → 书源。  
书源 Tab 在玻璃底栏上等于隐藏入口。

### P1 · 同 Tab 重置 / 子页被踢回

- 在 `/settings/glass` 等子页再触发 `goBranch(3, initialLocation: true)` 会回 hub。  
- solid 底栏四键并列时，点当前「设置」同样 reset。  
- 首页：`goBranch(0, initialLocation: true)` + `homeIntroTick++` 可能造成滚动位置丢失 + 动画重播连击。

### P1 · 选中态与展开面板

- 主胶囊在 index 2/3 时不高亮（已按 `selectedIndex == i` 修正）。
- 展开面板 `selectedIndex: 0` 硬编码，选中靠 builder 映射；包 pill 动画可能仍按 0 高亮「书源」。

### P2 · 玻璃底栏 vs Solid 不一致

| | 玻璃 ExpandableGlassNav | 减弱动态 _SolidBottomNav |
|--|-------------------------|---------------------------|
| 结构 | 主 2 段 + 更多圆键 | 四键并列 |
| 书源 | 埋在设置态面板 | 直接可点 |

### P2 · 其它

- `onImport` 仍挂在 ExpandableGlassNav，但 more 面板已改成「书源|设置」，**添加书籍**从底栏消失（书架 FAB/空态仍可导入）。
- Tab 切换动画与 `homeIntroTick` 同时触发，回首页时可能「页滑 + 入场」叠加。
- 更多在 sources（index 2）时走「去设置」而非展开，与「在设置才展开」规则一致，但用户在书源时无法展开找书源（已在书源）或导入。

## 下一轮修复建议（待拍板）

1. **书源入口**：主胶囊改三段 `[首页|书架|书源]`，更多仅设置/导入；或更多恒展开面板且包含书源。  
2. **同 Tab 策略**：仅当 `i == from && from == 3` 且在子页时 `initialLocation: true`；其它同 Tab 只 scroll top 或 no-op。  
3. **统一 Solid/玻璃 IA**（或 solid 也收成 2+更多）。  
4. 恢复导入入口（更多长按 / 面板第三项 / 书架内）。

## 现象对照（真机反馈「切换路由 bug」）

| 可能现象 | 对应项 |
|----------|--------|
| 点不到书源 / 要绕设置 | P0 书源不可达 |
| 设置子页突然回列表 | P1 同 Tab initialLocation |
| 回首页闪一下或滚回顶 | P1 homeTick + reset |
| 选中高亮不对 | P1 面板 selectedIndex |
| 减弱动态下底栏长相不同 | P2 Solid 不一致 |
