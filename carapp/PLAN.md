# 领克 07 车控 App（iOS 原生）— 计划与记忆

最后更新：2026-11-20

## 目标（用户 m05311 / m05401）

做一个 iOS 原生风格的车控 App，**产出未签名 IPA**，签名用户自己解决。

第一行四个按钮，从左到右：
1. 解锁 / 关锁
2. 能源管理界面
3. 寻车
4. 车窗微开

其他硬要求：
- 充分调用 iOS SDK / API（原生 SwiftUI + SceneKit + Haptic + Swift Charts 等）
- 顶部 1/3 是车辆 3D 建模，模型来自用户自己的 07 展示站 `https://ssongg.xyz/07/`
- 场景环境参照小米汽车 App 车控页（深色：暗背景 + 地面反射 + 续航条 + 圆形按钮）
- 深色 / 浅色两种模式

## 已握在手里的关键资产

### 车控协议（已完全打通，实测成功）

| 项 | 值 |
|---|---|
| HMAC 密钥 | `e70024ed24bda3cbd4a6295ed3fac5aa`（GRIEnvs 里 XOR 0xFF 解出的 aesKey 候选第一条，ASCII 原文即密钥） |
| 车控网关 | `https://gric-g-api.geely.com` |
| 车辆状态 | `GET /ms-vehicle-status/api/v2.0/vehicle/status/latest` |
| 能力集 | `GET /ms-vehicle-capability-set/api/app/v1/vehicle/capability/available` |
| 指令下发 | `POST /ms-remote-control/api/v1.0/remoteControl/control` |
| 回执查询 | `GET /ms-remote-control/api/v1.0/remoteControl/queryProcessResult?sessionId=` |
| 设备 ID | `664EE307-36D3-49D8-99C0-21D7169CC38B` |
| 车辆标识 | `bFYun+sZis2ZA1UykL2EL6UoxdMg+4mPLnWM+0M10+0=` |
| 车系 | `TDc0Mw==` |
| 车型码 | DS11（= 07） |

### 签名算法（canonical，已 4/4 回归验证）

```
s = ""
for k in sorted(白名单头, 剔除 X-SIGNATURE 自身):
    s += k.lower() + ":" + value + "\n"
if url 有 query:   s += query + "\n"
elif body 非空:    s += base64(md5(body)) + "\n"
# 否则什么都不加（不是 md5("")）
s += METHOD.upper() + "\n" + url.path
sig = base64(hmac_sha256(KEY, s))
```

白名单 25 个头：X-APP-ID / ACCEPT-LANGUAGE / AUTHORIZATION / X-API-SIGNATURE-VERSION /
X-API-SIGNATURE-NONCE / X-TIMESTAMP / X-APP-VERSION / X-OTA-VERSION / X-VEHICLE-IDENTIFIER /
X-DEVICE-BRAND / X-DEVICE-MODEL / X-DEVICE-ID / X-DEVICE-OS-VERSION / X-DEVICE-IDENTIFIER /
X-VEHICLE-BRAND / X-VEHICLE-SERIES / X-VEHICLE-MODEL / X-TSP-PLATFORM / X-TENANT-ID /
X-SIGNATURE / X-PLATFORM / X-SALES-PLATFORM / X-REQUEST-SOURCE / X-REGION-ID / X-REQUEST-ID。
实际参与签名 21 个（剔除 X-SIGNATURE）。

**Authorization 必须裸 JWT，不能带 `bearer` 前缀**（带前缀 → `00A12 Invalid token`）。

### 已知指令报文（都实测过）

- 解锁：`{"command":"start","serviceId":"RDU","setting":{"serviceParameters":[{"key":"door","value":"all"}]}}`
- 上锁：`{"command":"start","serviceId":"RDL","setting":{"serviceParameters":[{"key":"door","value":"all"}]}}`
- 空调开（20℃/90min）：`rce.conditioner=1` + `rce.temp=20` + `operationScheduling.duration=90`，serviceId `RCE`
- 空调关：`{"command":"stop","serviceId":"RCE","setting":{"serviceParameters":[{"key":"rce.conditioner","value":"1"}]}}`
- 极速升温：`POST /remoteControl/setSmartTemp`，`serviceId=PAA`，body 含 `ac/duration/heat[]/paa/sw/temp/timerId/vlt`
- 方向盘加热：`rce.conditioner=5` + `rce.heat=steering_wheel`
- 座椅加热：`rce.conditioner=4` + `rce.heat=front-left|front-right` + `rce.level=0..3`

### 尚未解的（不阻塞第一版）

- **车窗微开**：`serviceId="RWS"` 是合法值（假参数返回 `1000P004 参数不正确`，而 RWN/RWC 返回 `1000N001 内部错误`）。
  但 `serviceParameters` 的 key 名与 `GRIRWSFunctionType` / `openType` / `cmdVersionType` 枚举值还没解出来。
  能力码确认该车支持：`C_RWS_1/2/3/4`、`C_RWS_1_1/1_2/1_3/1_5`、`C_RWS_3_2_1/2_2`、`C_RWS_4_2_1/2_2`。
- **寻车**：`FLH` / `FLC` / `HOR` / `LOC` / `PNV` 都返回 `1000N001`（不存在）。
  `GRIRemoteIOV` 里 `Horn` 83 处、`Flash` 79 处、`GRIFlashHornType` + `GRIFlashHornParams` 类存在 → 服务码还需再找。
  参考：`ms-ai-cloud/menu/list` 里没有车控定义，能力码里有 `C_RHL_1/2/3`（可能 = 喇叭闪灯）。

### 凭证（会过期，需重抓）

- gric accessToken：RS256 JWT，1151 字符，7 天有效期。取自 HAR entry 479 的 `POST gric-api.geely.com/ms-midground-user/api/v1.0/user/auth/get/token` 应答。
- 换票链路：`GET app-services.lynkco.com.cn/auth/oauth2/access-code?scope=1` → `accessCode` → `POST .../user/auth/get/token {"authCode":..,"identityType":"1"}`。
- 旧 token 已废；刷新后 `expireAt=1795070505747`。

## 模型

- 源：`work/car3d/srv/car.glb`（4,469,544 字节，meshopt 压缩）
- 解压后：`work/car3d/car_dec.glb`（9,302,148 字节，178 meshes / 186 nodes / 5 materials / 0 textures / 712 accessors / 279,316 顶点）
- 材质色：`work/car3d/srv/materials.json`（150 个材质，含 `colors._BaseColor` / `_Color` / `_EmissionColor`、`floats._Metallic` / `_Glossiness`、`texs`）
- 部件→材质槽：`work/car3d/srv/parts.json`（181 条 `{group, mesh, slots[]}`）
- 贴图映射：`work/car3d/srv/texmap.json`（73 条）
- 根节点名 `DS11_ROOT`

**转换策略**：SceneKit 不认 glTF。用 Python 把 GLB 转成自定义紧凑二进制
（顶点/法线/UV/索引 + 逐 primitive 材质色），Swift 侧用 `SCNGeometrySource` 手工装配。
理由：OBJ 文本 279k 顶点会到 30MB+，且丢失材质分组。

## 构建方案（无 Xcode，走 CommandLineTools + theos SDK）

- 编译机：黑苹果（`127.0.0.1:8022`，macos / 030401，**当前隧道已断，需用户重开 UU 端口映射**）
- 工具链：`/usr/bin/swiftc`（CommandLineTools 自带 Swift）+ `/opt/theos/sdks/iPhoneOS16.5.sdk`
- 签名：不需要（用户自己签），但 `codesign --force --sign -` 做 ad-hoc 以便 `ldid`/重签工具处理
- 打包：`Payload/CarCtrl.app` → `zip -qry out.ipa Payload`（**必须保留 Payload 层级**，踩过坑）

**风险点（第一步就要验证）**：theos 的 iPhoneOS16.5.sdk 是否包含 `SwiftUI.framework` 与
`usr/lib/swift/SwiftUI.swiftmodule`。theos SDK 是精简版，可能缺 SwiftUI/SceneKit。
- 若缺 → 退路 A：从 Xcode_26.1.1_Universal.xip 里抽 SDK（需开发者账号，已放弃）
- 退路 B：用 UIKit + Objective-C（theos SDK 一定有 UIKit）
- 退路 C：SceneKit 若也缺，3D 改用 Metal 手写渲染（可行但工作量大）

## 实施步骤

1. [x] 摸清模型结构与材质
2. [ ] GLB → `cardata.bin` + `carparts.json`（Python 转换器）
3. [ ] 写 Swift 源码（见下）
4. [ ] 写构建脚本 `build.sh`（swiftc 直编 + 组装 .app + zip 成 IPA）
5. [ ] 验证 SDK 是否含 SwiftUI / SceneKit（SSH 恢复后第一件事）
6. [ ] 编译、修错、产出未签名 IPA
7. [ ] 交付 IPA + 安装说明

## 源码结构（计划）

```
work/carapp/
  PLAN.md
  src/
    main.swift              # @main App 入口
    Design.swift            # 颜色/圆角/阴影/字体，深浅色
    Theme.swift             # ColorScheme 适配
    CarSceneView.swift      # SceneKit UIViewRepresentable，车 3D + 地面反射
    ModelLoader.swift       # 读 cardata.bin 装配 SCNGeometry
    Api.swift               # gric 签名 + 请求
    Models.swift            # VehicleStatus / Capability 解析
    ContentView.swift       # 主界面
    EnergyView.swift        # 能源管理页
    FindCarView.swift       # 寻车页
    Haptics.swift           # UIImpactFeedbackGenerator
  res/
    cardata.bin
    carparts.json
    AppIcon.png
  build.sh
  out/CarCtrl.ipa
```

## 界面设计（对照小米汽车 App）

- 顶部 1/3：SceneKit 车模，透视仰角，地面渐变 + 车底阴影，背景随深浅色切换
- 车名行：左「领克 07」+ 车牌，右「钥匙」图标
- 续航条：电量/续航 + 进度条（绿→黄→红）
- 四圆按钮：解锁/关锁（锁图标，点时 haptic + 呼吸动画）、能源管理（电池）、寻车（喇叭）、车窗微开（车窗）
- 下方两卡片：充电状态 / 车内温度
- 深浅色：`Color(uiColor:)` + `@Environment(\.colorScheme)`

## 记忆锚点（下次接着干要记得的）

- 车控签名密钥：`e70024ed24bda3cbd4a6295ed3fac5aa`
- 签名 canonical 的两个坑：**X-SIGNATURE 不自引用**、**空 body 不加 md5 段**
- Authorization **裸 JWT**
- RWS 是合法 serviceId（窗控），参数待解
- 寻车服务码未找到（FLH/FLC/HOR/LOC/PNV 都错）
- IPA 打包必须 `zip Payload`，不能用 `ditto --keepParent`
- 黑苹果隧道 `127.0.0.1:8022` 走 UU 远控端口映射，断了要用户重开


## 2026-11-20 15:56 状态更新（v0.1.0 完成）

### 已完成
- 3D 模型：07 车模 cardata.bin（280,287 顶点 / 412,293 三角 / 185 prim / 13 种材质风格），
  配色从 ssongg.xyz/07 的 parts.json + materials.json 还原；轮毂、内饰、玻璃、灯组已分对。
- 主界面：顶部 36% 屏高 SceneKit 车模（fov 34、三点布光、程序生成反射环境），
  续航条、四圆按钮（解锁/关锁、能源、寻车、车窗微开）、两张信息卡。
- 深/浅色：Palette 全量分派 + 设置页 auto/dark/light。
- 设置页：粘贴 accessToken（JWT）+ deviceId，演示模式开关，外观切换。
- 能源页：电量环、充电控制、7 天电耗手绘柱状图（原 Swift Charts 因 SDK tbd 空壳移除）、四轮胎压。
- 寻车页：MKMapView（绕开 _MapKit_SwiftUI 空壳）+ 坐标卡 + 闪灯鸣笛 + 步行导航。
- 图标：11 个尺寸全出。

### 协议层（实车已验证）
- 解锁 RDU / 关锁 RDL：{"key":"door","value":"all"} ✅ 已验证
- 空调 RCE：
ce.conditioner + 
ce.temp + operationScheduling.duration ✅ 已验证
- 极速升温 PAA：c/duration/heat[]/paa/sw/temp/timerId/vlt ✅ 抓包有

### 协议层（静态逆向，未实车验证 —— 这是唯一的不确定项）
- 车窗微开 RWS：{"key":"target","value":"window"}（getter @0x40518 反汇编）
  functionType: 0=window 1=sunroof 2=sunshade 3=ventilate 4=front-charge-lid 5=all
- 闪灯鸣笛 RHL：{"key":"hrl","value":"horn-light-flash"}（getter @0x3fd04 反汇编）
  type: 0=horn 1=light-flash 2=horn-light-flash
- 若下发返回 1000P004，说明参数名对但取值不被接受，需再试 openType 组合
  （GRICmdOpenType.init 只接受 0/1，0=开 1=关 推断）。

### 签名与鉴权要点
- HMAC key = e70024ed24bda3cbd4a6295ed3fac5aa
- Authorization 必须裸 JWT，不能带 bearer
- canonical：白名单头（剔除 X-SIGNATURE）小写升序 k:v\\n → query 或 base64(md5(body)) 或空
  → METHOD\\n → path

### 产物
- out/CarCtrl.ipa 6,268,568 字节，MD5 812F463DC152AA759DFE37C5B571F694（未签名）
- bundle id app.snow8459.moonstone4810，MinimumOSVersion 16.0，arm64

### 待办
1. 用户签名后在真车上验证 RWS / RHL 两条指令
2. 若 RWS 失败，试 openType 组合与 command=stop 语义
3. 能源页的充电控制仍用 RCE 同一端点，需确认 C_CHARGE 能力码对应服务码

## v0.2.0（2026-11-20 20:50）按用户 6 条反馈改造

1. 车模"液态金属"根因：glTF NORMAL accessor 是 componentType=5120(BYTE) + normalized=true，
   convert_model.py 的 read_accessor 未做归一化，法线长度是 127 而不是 1 → SceneKit PBR 全车乱反射。
   已加归一化分支（5120/127, 5121/255, 5122/32767, 5123/65535），重跑后法线长度 mean=1.0003。
2. 位置恒 0：Models.swift 读 pos["lat"]/pos["lon"]，真实键是 latitude/longitude。已改。
3. 总续航 489 错：旧式 distanceToEmpty + fuelLevel/8.5*100；真实口径
   basic.combinedDistanceToEmpty=783 = basic.distanceToEmpty(710 燃油) + ev.distanceToEmptyOnBatteryOnly(73 纯电)。
4. 首页左上角加"油/电"双芯片：油=蓝(0.24,0.55,0.98)，电=品牌绿，各显示百分比+剩余里程；续航条改双色分段。
5. 数据更新慢：CarStore 加 30s Timer 自动刷新（tolerance 6，RunLoop .common），scenePhase 驱动启停；
   加"更新于 x 分钟前"徽章（>600s 转橙，可点立即刷新）。
6. 删演示模式：Prefs.demo / CarStore.demoMode / SettingsView.demoCard / 齿轮橙点 全删。
7. App 图标换官方 LYNK & CO 车标：make_appicon.py 读 lynkco-logo-grey.svg 单 path，
   自写 path 解析+贝塞尔展平+even-odd 扫描线填充，深色径向底+品牌绿发光，标志宽占 80%。
8. 能源页：三数改真实口径；删掉编造的"近 7 天电耗"柱状图（HAR 里根本没有能耗历史接口），
   换成平均电耗/平均油耗/平均车速/本次行程 的真实四宫格 + 纯电里程/燃油里程比例条。
9. 寻车页：无定位时不再画 0,0 的地图，改空态提示；胎压正常区间 220-260 改 260-300 kPa。

产物：out/CarCtrl.ipa 6,330,599 字节，MD5 9EF9750338B637D6D825E5245FEDCA7D，v0.2.0(2)。

## 2026-11-21 12:30  v0.4.0 —— 3D 渲染三根因全修 + 拖动 + 交互

用户第三次打回（m07329）：「车漆乱七八糟并且不能用手拖动视角，我让你一比一复刻这个界面还有车辆相机视角车辆可以用手指转动并且会根据操作做出反应」

### 车漆斑块的三层根因（逐层实测）
1. **AO 图被当成 multiply 叠到 diffuse 上**（v0.3.0 的 bug）
   `DS11_carpaint_ao002.jpg` 不是车漆颜色图，是烘焙 AO 图。实测车漆顶点采样：
   `Paint01` 均值 0.281、53.0% < 0.1；`Paint02` 均值 0.189、56.6% < 0.1。
   乘上去等于把半台车刷黑。→ 改走 `mat.ambientOcclusion`。
2. **贴图 UV 越界**（本版新发现）
   车漆 UV 的 v 范围是 **-0.994 .. 1.000**，超出 [0,1]。SceneKit 默认 `clampToEdge`
   会把越界部分拉成边缘色块。→ 所有贴图属性设 `wrapS/wrapT = .repeat`。
3. **AO 原图本身太暗**
   2048x2048 全图均值 0.394、41.2% 像素 < 0.3。即使只当 AO 也会把车漆压成脏灰。
   → 生成 `res/cartex/paint_ao_lift.png`（`0.62 + 0.38*a`，均值 0.770、最低 0.620）。

### 交互
- `CarSceneView` 自建 orbit 相机：`yaw/pitch/radius`，`UIPanGestureRecognizer` 单指旋转
  （带松手惯性）、`UIPinchGestureRecognizer` 双指缩放（`extent*0.72 .. extent*2.6`）。
- `gestureRecognizerShouldBegin` 里横向速度大于纵向 1.05 倍才接管，纵向留给外层 ScrollView。
- SwiftUI 侧不能用 `.allowsHitTesting(false)`，否则手指拖不动。

### 车辆随操作反应（新能力）
`convert_model.py` 新增 `compute_parts()`，从节点 bbox + 铰链试探算出 6 个可动部件：
`Trunk`(node 89)、`Sunproof_main`(119)、`LBDoor`(125)、`RBDoor`(167)、`LFDoor`(145)、`RFDoor`(188)。
每个部件有 `hinge` / `axis` / `sign` / `maxAngle`，写进 `carparts.json` 的 `parts`。
`ModelLoader.buildTree` 把它们组装成 `pivot(铰链) -> inner(-hinge) -> 几何` 结构，
几何虽是世界坐标烘焙的，绕 pivot 旋转也会正确绕铰链转。
- 点「解锁」-> 四门开合 + 下发 RDU
- 点「后备箱」-> 尾门升起（实车服务码未解，只动模型）
- 点「天窗」-> 天窗展开
- 点「寻车」-> 大灯/尾灯 emission 闪三下 + 下发 RHL

### 界面按参考图重排
顶栏（车名+chevron ｜ 空调/锁/后备箱/P/车牌）-> 46pt 续航大字 + 更新时间徽章 -> 双色续航条 ->
油电明细 -> 40% 屏高 3D 车模 -> 四个圆按钮 -> 短线分页器 -> 两张并排大卡（充电 ｜ 车内温度+风扇按钮）->
车窗/天窗功能行 -> 预约/钥匙两行列表。
