# 超级岛（客户端）真机验收清单

对应实现：`MainActivity.attachXiaomiIsland`（dev.mi.com pId=2131 客户端路径）  
提交：`56222a6` / 后续 `7d938aa` 通知终态修复。

## 前置

1. 小米手机 + HyperOS（建议 OS3，`notification_focus_protocol=3`）
2. 系统设置 → 通知 → 本应用 → 打开 **焦点通知 / 超级岛**
3. `adb logcat -s LegadoIsland` 可看能力查询

## 用例

| # | 步骤 | 期望 |
|---|------|------|
| 1 | 设置里下载 OCR 语言包 | 进度通知出现；若支持岛，应有岛/焦点形态而非仅通知栏条 |
| 2 | 下载过程中看状态栏 ticker | `OCR 下载 x%` |
| 3 | 下载完成 | **「OCR 模型已就绪（无需再下载）」**，不是继续进度条 |
| 4 | 约 5s 后 | 通知自动消失（cancel 收岛） |
| 5 | 关焦点通知权限再下载 | 普通通知仍显示，不崩溃 |
| 6 | 非小米/模拟器 | 只有普通通知，logcat 无岛 |

## logcat 关键字

```
adb logcat -s LegadoIsland
support={"island":true,"protocol":3,"focusPermission":true} title=OCR 模型下载 ...
```

- `island=false` 或 `protocol<3`：系统不支持岛，属正常降级
- `focusPermission=false`：引导用户开权限

## 已知边界

- MIPUSH 服务端推送未做（仅客户端 extras）
- 媒体通知自动上岛未做（pId=2161）
