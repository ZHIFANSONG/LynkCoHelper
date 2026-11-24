# 领克 07 车控指令逆向结论与验证清单

> 生成时间：2026-11-24
> 状态口径：**确定** = 反汇编逐指令复核 + 至少两条独立证据；**待验证** = 静态证据充分但未闭环；**未找到** = 已排除。
> 全部结论来自离线静态分析（capstone 反汇编 + ARM64 模拟 + 字节扫描），**未向真实车辆发送任何请求**。

---

## 一、`GRIServiceIdType` 全表（53 项，已逐项解出）

反汇编位置 `work/ios_ext/bin/GRIRemoteIOV`：
- `GRIServiceIdType.desc` 入口 `0xf0eb0`，跳转表 `0x1ad86d`，case base `0xf0ee4`
- 函数序言 seed：`x0=0x4c4852`（`"RHL"`）、`x9=0x4c4452`（`"RDL"`）
- 自校验：已知可用值 RDU=8、RDL=6、RCE=37、PAA=42 **全部对上**

| index | 短码 | index | 短码 |
|---|---|---|---|
| 0 | RHL | 27 | ZBA |
| 1 | RWS_2 | 28 | ZBB |
| 2 | RWS | 29 | RQT |
| 3 | RDO | 30 | RWR |
| 4 | RDC | 31 | AVP |
| 5 | RDL_2 | 32 | HPP |
| 6 | RDL | 33 | RPP |
| 7 | RDU_2 | 34 | ZAB |
| 8 | RDU | 35 | RFD |
| 9 | RTL | 36 | RCE_2 |
| 10 | RTU | 37 | RCE |
| 11 | RLU | 38 | RSH |
| 12 | ZAE | 39 | RSV |
| 13 | PAE | 40 | RCC |
| 14 | ZAD | 41 | ZAF |
| 15 | ZAP | 42 | PAA |
| 16 | ZAG | 43 | PAP |
| 17 | ZAS | 44 | RSM |
| 18 | ZAJ | 45 | PAC |
| 19 | ZAH | 46 | JOU |
| 20 | ZAM | **47** | **RCS** |
| 21 | ZAN | **48** | **RCO** |
| 22 | ZAT | 49 | ZAZ |
| 23 | PAB | 50 | ZAU |
| 24 | PAH | 51 | PAM |
| 25 | PAI | 52 | ELS |
| 26 | RES | | |

**注意**：`RCH` / `RCG` / `ECH` **不存在**于该表。`RCC`(40) 是「预座椅加热」（键 `rcc.levl`），不是充电。

---

## 二、充电启停（新解，确定档）

### 2.1 serviceId

| 候选 | rawValue | 语义 | 证据 |
|---|---|---|---|
| **RCS** | 47 | 电池充电启停（`isRCO=false`） | `GRIChargeControlParams.init` @`0x3d5d8` `tbz w21,#0,#0x3d620` → `0x3d620 mov w8,#0x2f`(47) → `0x3d650 str x8,[x19,x10]` |
| **RCO** | 48 | RCO 模式（`isRCO=true`） | 同 init，`0x3d5dc cmp x20,#2` → `0x3d628 mov w8,#0x30`(48)；desc 表 @`0xf0fa4` 明文 `mov w0,#0x4352`(`RC`) + `movk w0,#0x4f,lsl16`(`O`) |

⚠️ **RCO 的坑**：`isRCO=true` + `commandType=.stop` 时，init 把 command 强制改写成 1（`"start"`）：
```
0x3d5f0 mov w9,#0x30   ; serviceId = 48 (RCO)
0x3d604 mov w9,#1      ; command 强制 = 1 ("start")
```
即 **RCO 模式下不存在 "stop"，停止充电只能走 RCS**。

### 2.2 serviceParameters 键（`GRIChargeControlParams.serviceParameters` getter @`0x3d98c`）

元素结构固定 `{"key":…,"value":…}`（`key` @`0x3de70`、`value` @`0x3dea8`）。

| 键 | 触发条件 | value | 字节依据 |
|---|---|---|---|
| `soc` | `soc != nil` 时先追加 | 目标电量字符串 | `0x3da0c mov w9,#0x6f73('so'); movk #0x63('c'),lsl16` |
| `rcs.setting` | `soc != nil` | `"1"`(充电) / `"2"`(放电) | `0x3dad4` + `0x6e69`，len 11 |
| `rcs.restart` | `soc == nil` 且 `commandType == .start` | `"1"` / `"2"` | `0x3dc40`，len 11 |
| `rcs.terminate` | `soc == nil` 且 `commandType == .stop` | `"1"` / `"2"` | `0x3dbb8`，len 13 |
| `rcs.immediately` | `soc == nil` 且 `commandType == .immediately` | **恒 `"1"`**（`0x3dccc mov w9,#0x31`） | `0x3dca0`，len 15 |
| `altCurrent` | `altCurrent != nil` 最后追加 | 电流值字符串 | `0x3dd7c`，len 10 |

**命名空间唯一性交叉验证**：全 `__text` 扫描 `movz w9,#0x6372` + `movk #0x2e73,lsl16`（即 `rcs.` 前缀），**仅命中 4 处，全部在 `GRIChargeControlParams` 内**（`0x3dad4`/`0x3dbb8`/`0x3dc40`/`0x3dca0`）。

同规则其它命名空间：`rce.` ↔ RCE(37)（`GRIEnvAirConditionerParams` @`0x6d2a0`）、`rcc.` ↔ RCC(40)（`0x6faa8`）、`rse.`（@`0x73558`/`0x7a358`）。`rce.` ↔ RCE 是已知可用链，`rcs.` ↔ RCS 完全同构 —— 第二重独立证据。

### 2.3 `command` 取值

`GRICommandType.desc` @`0xf0d40`：`1→"start"`、`2→"stop"`、`3→"requestCode"`、…、`12→"immediately"`。
`ChargeCommandType.cmd` @`0x3cce8`，指针表 @`0x1a6ae8` = `[1,2,12]` ⇒ `.start→"start"`、`.stop→"stop"`、`.immediately→"immediately"`。

`ChargeType.desc` @`0x3e934`：case1 = `"充电"`，case2 = `"放电"` ⇒ value `"1"`=充电、`"2"`=放电。
（注意：`ChargeType` 的 rawValue 是 **3、4**，`init(rawValue:)` @`0x31410` `sub x8,x0,#3; cmn x8,#2`；desc 的 case 序号 1/2 是另一套编号。）

`ChargeCommandType` rawValue = **4、5、6**（`0x3cdc4 sub x8,x0,#4; cmn x8,#3`）。

### 2.4 报文结构

基类 `parameters` getter @`0xf0864`：
```
外层键 "setting"(7)                      ← 0xf0b00 mov x1,#0x6573('se'); movk #0x7474('tt'); movk #0x6e69('in'); movk #0x67('g')
  └─ 内层键 "serviceParameters"(16)        ← 0xf09c8，串 @0x1b60a0
键 "serviceId"(9) → bl 0xf0eb0 (GRIServiceIdType.desc)
键 "command"(7)   → bl 0xf0d40 (GRICommandType.desc)
子类字段由 bl 0xf18c0 (merge 闭包) 合并
```
与已知报文 `{"command":"start","serviceId":"RDU","setting":{"serviceParameters":[…]}}` 逐字段吻合。

### 2.5 path（⚠️ 关键分歧）

充电指令的 path 指向 **`/ms-charge-manage/api/v1.0/charge/control`**（v1.1 同），**不是** `/remoteControl/control`。
证据：`GRIChargeControlParams.path` @`0x3e314`，字符串 @`0x1b60c0` / `0x1b60f0`；`bizName` @`0x3e3a4` = `"ChargePlan"`。

`/ms-remote-control/api/v1.0/remoteControl/control` 来自基类 @`0xf0cdc`（同族串 @`0x1c1f70`）。两者请求体结构完全同构，所以套网关是「结构性可行、语义未证实」。

### 2.6 可直接试的报文

**开始充电（不带 SOC，App 默认路径）**
```json
POST /ms-charge-manage/api/v1.0/charge/control
{"serviceId":"RCS","command":"start","setting":{"serviceParameters":[{"key":"rcs.restart","value":"1"}]}}
```

**开始充电（带目标电量 SOC）**
```json
POST /ms-charge-manage/api/v1.0/charge/control
{"serviceId":"RCS","command":"start","setting":{"serviceParameters":[{"key":"soc","value":"80"},{"key":"rcs.setting","value":"1"}]}}
```

**停止充电**
```json
POST /ms-charge-manage/api/v1.0/charge/control
{"serviceId":"RCS","command":"stop","setting":{"serviceParameters":[{"key":"rcs.terminate","value":"1"}]}}
```

**立即充电**
```json
POST /ms-charge-manage/api/v1.0/charge/control
{"serviceId":"RCS","command":"immediately","setting":{"serviceParameters":[{"key":"rcs.immediately","value":"1"}]}}
```

**套 gric 网关**（结构同构，语义待验证）：把 path 换成 `/ms-remote-control/api/v1.0/remoteControl/control`，body 一字不改。

---

## 三、车窗微开 RWS（待验证）

- `GRIRWSFunctionType` rawValue = **0..5**（6 个 case），`init(rawValue:)` @`0x4a558` `cmp x0,#5; cset w1,hi`。enum 描述符 @`0x1e57bc`，+0x18 NumCases=6。
- **无 desc 属性**，case 名不在二进制里。语义靠 `GRIVehicleWindowParams` 参数反推。
- 已知（上一轮）：参数 `{"key":"target","value":"window"}`（getter @`0x40518` 反汇编）
- functionType 推断：`0=window 1=sunroof 2=sunshade 3=ventilate 4=front-charge-lid 5=all`
- `GRIVehicleWindowParams`：`_TtC12GRIRemoteIOV22GRIVehicleWindowParams` @strs 1370，属性 `openType` / `cmdVersionType` / `functionType`（`Tq,N,VopenType`、`Tq,N,VcmdVersionType`、`Tq,N,VfunctionType`），另有 `windowStatus`
- 报文：`{"command":"start","serviceId":"RWS","setting":{"serviceParameters":[{"key":"target","value":"window"}]}}`
- 若返回 `1000P004` → 参数名对但取值不被接受，试 `openType` 组合（`GRICmdOpenType.init` 只接受 0/1，0=开 1=关）

---

## 四、寻车/闪灯鸣笛 RHL（待验证）

- `GRIFlashHornType` rawValue = **0..2**（3 case），`init(rawValue:)` @`0x46ae0`（thunk @`0x4bc98`）`cmp x0,#2; cset w1,hi`。**无 desc**。
- 语义从 `GRIFlashHornParams` 参数反推：`0→"horn"`、`1→"light-flash"`、`2→"horn-light-flash"`
- 参数：`{"key":"key","value":"rhl"}`（`rhl` @`0x3fd94` `mov w9,#0x6872('hr'); movk #0x6c('l')`），serviceId = `RHL`（index 0）
- 报文：`{"command":"start","serviceId":"RHL","setting":{"serviceParameters":[{"key":"key","value":"rhl"}]}}`
- 另有字符串 `horn-light-flash`（`GRIRemoteIOV.strs.txt:1438`）、`sunroofVentilate`(:1437)、`front-charge-lid`(:1436)、`charge`(:1335 附近)

---

## 五、充电口盖（确定档，与启停不共用 serviceId）

- `ChargeLidServiceType.desc` @`0x407a0`：case1 = `"RDO/RDC"`、case2 = `"RDU/RDL"`
  - `mov x0,#0x4452('RD'); movk #0x2f4f('O/'); movk #0x4452; movk #0x43('C')` @`0x407a8`
- 参数 getter `GRIVehicleChargeLidParams.serviceParameters` @`0x40d54`：键 `"key"`（tag 0xE3），值由 `open` ivar(@`0x3059d8`) 决定
  - `open=true` → 内联小字符串 `back-charge-lid`(14B)
  - `open=false` → immortal 串 @`0x1b7080` = `front-charge-lid`(14B)

```json
{"serviceId":"RDO","command":"start","setting":{"serviceParameters":[{"key":"key","value":"back-charge-lid"}]}}
{"serviceId":"RDC","command":"stop", "setting":{"serviceParameters":[{"key":"key","value":"front-charge-lid"}]}}
```

---

## 六、验证方法（拿到有效 gric token 后）

### 6.1 单条验证流程

1. **先只发 serviceId、不发参数**，用最小化探针判定短码合法性：
```bash
curl -s -X POST 'https://<gric-host>/ms-remote-control/api/v1.0/remoteControl/control' \
  -H 'Content-Type: application/json' -H 'Authorization: <token>' \
  -d '{"serviceId":"RCS","command":"start","setting":{"serviceParameters":[]}}'
```
2. **按返回码分流**：

| 返回码 | 含义 | 下一步 |
|---|---|---|
| `1000P004` 参数不正确 | serviceId **合法**，参数缺失/键名错 | 短码确认命中，试键名 |
| `1000N001` 内部错误/不存在 | serviceId **不合法**（或该车不支持） | 换 RCO，或怀疑网关白名单 |
| `1000` 成功 / 有 processId | 指令已下发 | 轮询 `queryProcessResult` 取结果 |

3. **键名二分**：依次单独发 `rcs.restart` → `rcs.terminate` → `rcs.setting`（配 `soc`）→ `rcs.immediately`，每次只带一个键。
4. **能力码前置校验（强烈建议）**：先查车辆能力码里有无 `C_RCS_*` / `V_RCS_*`
   - `C_RCS_1` @`0x1ca818`
   - `V_RCS_1..V_RCS_5` @`0x1ca621`–`0x1ca64b`
   - `V_RCS_6_5` @`0x1ca80e`、`V_RCS_8_1` @`0x1ca820`、`V_RCS_10_1_1..4` @`0x1ca82a`–`0x1ca851`
   - 没有就别发，转 RCO 或走预约充电接口

### 6.2 替代线路：预约/计划充电（不经 serviceId 短码）

- `/ms-charge-manage/api/v2.0|v2.1/charge/setBookingCharge`（`GRIChargePlanSetting`：`recurrentOperation` / `interval` / `occurs` / `bizType` / `start` / `targetSoc` / `isCycle` / `soc` / `altCurrent` / `timerId` / `scheduleList`）
  - v2.0 @`0x1c5d40`、v2.1 @`0x1c5d80`
- `/ms-charge-manage/api/v1.0|v1.1/charge/setChargingPlan`（v1.0 @`0x1c5a00`、v1.1 @`0x1c5a40`）
- `setTravelPlan` v1.0 @`0x1c5b50` / v1.1 @`0x1c5b80` / v2.0 @`0x1c5e90` / v2.1 @`0x1c5ec0`
- `setBookingVtm` @`0x1c5fe0`
- 这些接口 `command`/`serviceId` 都不参与，`bizName` = `"ChargePlan"`

### 6.3 已知签名/鉴权约束

- HMAC key `e70024ed24bda3cbd4a6295ed3fac5aa`；canonical：白名单头（剔除 X-SIGNATURE）小写升序 `k:v\n` → query 或 `base64(md5(body))` 或空 → `METHOD\n` → path
- Authorization **裸 JWT**，不能带 bearer
- X-SIGNATURE 不自引用；空 body 不加 md5 段

---

## 七、未找到 / 已排除

1. `RCH` / `RCG` / `ECH` / `RCC`(充电) —— 不存在于 `GRIServiceIdType` 53 项表。`RCC`(40) 是预座椅加热。
2. `stopCharge` 这个 selector 在主二进制中不存在 —— `__objc_methname` 里只有 `stopChargeButton`、`canStopCharge`、`isAbleToRestartCharging`。
3. `GRIRemoteIOV` 内**没有** BL 调用 `GRIChargeControlParams` 三个 init 的地方（`0x3d4fc`/`0x3d2f8` total 0），业务调用全在 ObjC runtime 层（主 App 经 `initWithCommandType:type:soc:altCurrent:isRCO:` 构造）。
4. `serviceId` 与 `C_CHARGE_x` 能力码的映射未找到 —— 能力码只是字符串常量（`C_CHARGE_1` @`0x1ca731`、`C_CHARGE_2` @`0x1ca73c`、`C_CHARGE_3` @`0x1ca747`），无 switch 表。
5. `GRIChargeServiceParams` 只是 `{key, value}` 元素类（两个 String 属性 @`0x3e9a0` / `0x3ea10`）。
6. `altCurrent` 取值域未约束（只知是字符串，来自用户输入）。

---

## 八、关键地址索引

| 内容 | GRIRemoteIOV 地址 |
|---|---|
| `GRIServiceIdType.desc` 入口 / 跳转表 / case base | `0xf0eb0` / `0x1ad86d` / `0xf0ee4` |
| `GRICommandType.desc` 入口 / 跳转表 / case base | `0xf0d40` / `0x1ad860` / `0xf0d74` |
| `ChargeCommandType.desc` / `.cmd` 指针表 | `0x3cd34` / `0x3cce8` → `0x1a6ae8` = [1,2,12] |
| `ChargeType.desc` / `.init(rawValue:)` | `0x3e934` / `0x31410` |
| `GRIChargeControlParams.init(...isRCO:)` | `0x3d4fc`(cfC) / `0x3d6cc`(cfc) / `0x3d884`(ObjC thunk) |
| serviceId 写死处 | `0x3d5d8`(分支) / `0x3d620`(47) / `0x3d628`(48) / `0x3d650`(落盘) |
| `serviceParameters` getter | `0x3d98c` |
| `path` / `bizName` | `0x3e314` / `0x3e3a4` |
| convenience init `init(chargeType:soc:altCurrent:)` | `0x3d3d4`（前半 `0x3d2f8`） |
| 基类 `parameters` / `path` / `init` | `0xf0864` / `0xf0cdc` / `0xf07e0` |
| ivar 全局量 | serviceId `0x3065b0`、command `0x3065b8`、commandType `0x305988`、type `0x305990`、soc `0x305998`、altCurrent `0x3059a0`、isRCO `0x3059a8`、口盖 open `0x3059d8`、FlashHorn type `0x3059b0` |
| `ChargeLidServiceType.desc` / 口盖参数 getter | `0x407a0` / `0x40d54` |
| `GRIFlashHornParams.serviceParameters` | `0x3fd04` |
| `GRIRWSFunctionType.init(rawValue:)` | `0x4a558`（描述符 `0x1e57bc`） |
| `GRIFlashHornType.init(rawValue:)` | `0x46ae0`（thunk `0x4bc98`） |

`work/ios_ext/GRIRemoteIOV.strs.txt` 行号：1329 `/ms-charge-manage/api/v1.0/charge/control`、1330 v1.1、1328 `serviceParameters`、1331/1332 `GRIChargeServiceParams`、27696–27700 mangled 初始化器、3060/3061 `setBookingCharge` v2.0/v2.1。
