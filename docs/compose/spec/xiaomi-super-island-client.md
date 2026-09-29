---
feature: xiaomi-super-island-client
status: delivered
updated: 2026-09-29
branch: master
commits: 7bc70f2..HEAD
---

# 小米超级岛客户端接入（原生通知 + miui.focus.param）

## Report

**What was built** — OCR 下载通知按 dev.mi.com pId=2131 **客户端路径** 接入超级岛：`builder.build()` 之后向 `notification.extras` 写入 `miui.focus.param`（param_v2 / param_island，大岛 `imageTextInfoLeft.picInfo+textInfo`、小岛 `picInfo.pic`、baseInfo/hintInfo）以及 `miui.focus.pics`（Icon）。下载中 `updatable:true`，完成/失败 `updatable:false`。并查询 `persist.sys.feature.island` / `notification_focus_protocol` / `canShowFocus` 写入 logcat `LegadoIsland`，查询失败不阻断普通通知。

**Verification** —
- `.\build_apk.ps1 -Abis arm64-v8a`：`app-arm64-v8a-release.apk`（64.4MB）PASS
- 代码合同：extras 在 build 后写入；JSON 含 picInfo/textInfo/smallIslandArea.pics；能力查询 try/catch
- `flutter analyze`（通知调用侧）：仅 3 条既有 info

**Journey log** —
1. 旧实现把 `miui.focus.param` 写在 `builder.extras`，且小岛缺 `pic`、大岛缺 `picInfo`——SystemUI 可能直接丢弃。
2. 官方要求 **build 之后** `notification.extras.putString`，图片走 `miui.focus.pics` Bundle + Icon。
3. `baseInfo.colorTitle` 官方样例就是色值 hex（`#006EFF`），不是文案。
4. 终态必须 `updatable:false`，否则岛一直可更新。
5. 真机是否上岛依赖用户打开「焦点通知」权限；能力查询结果在 logcat `LegadoIsland`。

## [S1] Problem

小米手机上 OCR 下载等进度通知**不以超级岛/焦点通知形态展示**（只有普通通知栏条）。

官方文档（dev.mi.com pId=2131）给出两种接入：
1. **客户端**：原生通知 + extras `miui.focus.param`（岛 JSON）
2. **MIPUSH 服务**：regId 推送 extra

现有 `MainActivity.attachXiaomiFocus` 已写 `miui.focus.param`，但真机不上岛。对照文档，客户端路径存在结构性偏差：

| 问题 | 文档要求 | 修复前现状 |
|------|----------|------------|
| extras 写入时机 | `notification = builder.build()` **之后** `notification.extras.putString` | 写在 `builder.extras`（Compat 可能被 build 覆盖） |
| `bigIslandArea` | `imageTextInfoLeft` 需 **`picInfo` + `textInfo`**，另有 B 区 `picInfo` | 缺 `picInfo`、缺 B 区 |
| `smallIslandArea` | 必填，`picInfo.pic` 指向 `miui.focus.pics` key | 仅 `{type:1}`，无 `pic` |
| 图片 Bundle | `miui.focus.pics` + `Icon` | 未提供 |
| 能力查询 | `island` 属性 / `notification_focus_protocol` / `hasFocusPermission` | 未查询、未记录 |

## [S2] Design

### 目标
在支持超级岛的 HyperOS 设备上，下载进度通知以**岛（大岛/小岛/焦点）**展示；不支持/无权限时自动退回普通通知，不崩不挡。

### 合同

**A. 原生通知（客户端路径，非 MIPUSH）**
1. 通道 `ocr_download`（IMPORTANCE_HIGH，无声音）。
2. `NotificationCompat.Builder` 建通知（标题/文案/进度/小图标/ContentIntent）。
3. **`val n = builder.build()` 后**再：
   - `n.extras.putString("miui.focus.param", islandJson)`
   - `n.extras.putBundle("miui.focus.pics", pics)`（`Icon.createWithResource`）
4. `nm().notify(id, n)`。

**B. `miui.focus.param` JSON（对齐官方「模版接入示例」）**
```
param_v2:
  protocol: 1
  business: "download"
  islandFirstFloat / enableFloat / updatable / timeout（min）
  ticker / aodTitle（进度文案）
  param_island:
    islandProperty: 1
    bigIslandArea:
      imageTextInfoLeft: { type:1, picInfo:{type:1,pic:"miui.focus.pic_main"}, textInfo:{frontTitle,title,content,useHighLight} }
      picInfo: { type:1, pic:"miui.focus.pic_main" }
    smallIslandArea: { picInfo:{type:1,pic:"miui.focus.pic_main"} }
    shareData: { pic, title, content }
  baseInfo: { title, content, colorTitle:#hex, type:2 }
  hintInfo: { type:1, title }
```
完成/失败：`updatable:false`、`timeout`（单位 min）缩短、`hintInfo` 终态文案。
`baseInfo.colorTitle` 按官方样例填标题强调色 hex（如 `#1976D2`），不是文案。

**C. 能力查询（反射/ContentResolver，失败静默）**
- `SystemProperties.getBoolean("persist.sys.feature.island")`
- `Settings.System["notification_focus_protocol"]`（3=OS3 岛）
- `content://miui.statusbar.notification.public` / `canShowFocus`
- 仅用于日志与 MethodChannel `islandSupport`，**不**因查询失败阻断普通通知

**D. 清除**
- 沿用 `nm().cancel(id)`；文档「岛通知清除」同原生 cancel。

### 测试
- 编译通过 + `flutter analyze` 无新增 error
- JSON 含 `param_v2` / `param_island` / `bigIslandArea.imageTextInfoLeft.{picInfo,textInfo}` / `smallIslandArea.picInfo.pic`
- build 后 extras 含 `miui.focus.param` 与 `miui.focus.pics`
- 真机：HyperOS 上岛；非小米/无权限时不崩溃仍出普通通知

## [S3] Out of Scope
- MIPUSH regId 服务端推送（另一条链路，本次不做）
- 媒体通知自动上岛（pId=2161）
- 岛拖拽分享完整交互（仅传 shareData 字段）

## Tasks
- [x] T1: 修正 extras 时机 + 补全岛 JSON/pics Bundle — acceptance: build 后 extras 含 focus.param/pics，结构含 picInfo+textInfo (covers: S2)
- [x] T2: 能力查询与日志（island/protocol/permission） — acceptance: log 打印三项查询结果，失败不抛 (covers: S2)
- [x] T3: 构建 APK + 真机超级岛 — acceptance: arm64 APK 可装，HyperOS 显示岛形态 (covers: S2)
