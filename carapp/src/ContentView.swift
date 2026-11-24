//
//  ContentView.swift
//  主界面：按参考图一比一复刻
//    · 顶部：车名 + 展开箭头 ｜ 右侧 空调/锁/后备箱/P+车牌
//    · 大号续航数字 + 双色续航条
//    · 中部整块 3D 车模（可单指拖动旋转、双指缩放）
//    · 四个圆形按钮
//    · 短发条指示器
//    · 两张并排大卡片（充电/车位 ｜ 车内温度/预设温度）
//    · 「车窗微开 / 寻车」功能行
//    · 底部「预约」「钥匙」两行
//

import SwiftUI
import UIKit
import SceneKit

final class CarStore: ObservableObject {
    @Published var status = VehicleStatus()
    @Published var loading = false
    @Published var lastError: String?
    @Published var busyAction: String?
    @Published var toast: Toast?
    @Published var paintIndex = 0
    @Published var loaded = false

    private var timer: Timer?

    var paint: Color { paintOptions[min(paintIndex, paintOptions.count - 1)].color }
    var hasToken: Bool { !CarSession.shared.token.isEmpty }

    func refresh(silent: Bool = false) {
        guard hasToken else {
            lastError = "还没填 accessToken"
            return
        }
        if !silent { loading = true }
        CarApi.vehicleStatus { [weak self] r in
            guard let self = self else { return }
            self.loading = false
            switch r {
            case .success(let s):
                withAnimation(.easeOut(duration: 0.35)) { self.status = s }
                self.lastError = nil
                self.loaded = true
            case .failure(let e):
                self.lastError = e.message
                if !silent { self.show(e.message, ok: false) }
            }
        }
    }

    func startAutoRefresh() {
        stopAutoRefresh()
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh(silent: true)
        }
        t.tolerance = 6
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    func run(_ name: String, _ payload: [String: Any], successText: String) {
        guard hasToken else {
            show("请先在设置里填入 accessToken", ok: false)
            Haptics.error()
            return
        }
        busyAction = name
        CarApi.control(payload) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let res):
                self.busyAction = nil
                self.show(successText, ok: true)
                Haptics.success()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    CarApi.processResult(sessionID: res.sessionID) { d in
                        if let d = d { self.show(d, ok: true) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh(silent: true) }
                }
            case .failure(let e):
                self.busyAction = nil
                self.show(e.message, ok: false)
                Haptics.error()
            }
        }
    }

    func show(_ text: String, ok: Bool) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            toast = Toast(text: text, ok: ok)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            withAnimation(.easeOut(duration: 0.25)) {
                if self.toast?.text == text { self.toast = nil }
            }
        }
    }

    /// 充电指令下发（走 /ms-charge-manage 充电域，不是 /remoteControl）
    func runCharge(_ name: String, _ payload: [String: Any], successText: String) {
        guard hasToken else {
            show("请先在设置里填入 accessToken", ok: false)
            Haptics.error()
            return
        }
        busyAction = name
        CarApi.chargeControl(payload) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let res):
                self.busyAction = nil
                self.show(successText, ok: true)
                Haptics.success()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    CarApi.processResult(sessionID: res.sessionID) { d in
                        if let d = d { self.show(d, ok: true) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh(silent: true) }
                }
            case .failure(let e):
                self.busyAction = nil
                self.show(e.message, ok: false)
                Haptics.error()
            }
        }
    }
}

struct ContentView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var phase
    @StateObject private var store = CarStore()
    @State private var sceneModel: CarModel?
    @State private var showEnergy = false
    @State private var showFindCar = false
    @State private var showSettings = false

    /// 车模动作状态：由按钮驱动，3D 车模随之做出反应
    @State private var carViewRef = CarViewModel()
    @State private var evMode = 0          // 0=百分比 1=剩余里程
    @State private var fuelMode = 0        // 0=百分比 1=剩余里程 2=剩余升数
    @State private var cloudCover = 0.3    // 云量 0..1，影响天空贴图与太阳强度

    private let fuelBlue = Color(red: 0.24, green: 0.55, blue: 0.98)
    private let accentBlue = Color(red: 0.16, green: 0.47, blue: 1.0)

    var body: some View {
        ZStack(alignment: .top) {
            // 页面底色：顶部与黄昏天空衔接（信息栏透出天空色，不再断层）
            LinearGradient(
                stops: [
                    .init(color: scheme == .dark
                          ? Color(red: 0.075, green: 0.065, blue: 0.16)
                          : Color(red: 0.55, green: 0.66, blue: 0.80), location: 0),
                    .init(color: scheme == .dark
                          ? Color(red: 0.12, green: 0.10, blue: 0.20)
                          : Color(red: 0.68, green: 0.76, blue: 0.86), location: 0.18),
                    .init(color: Palette.bg(scheme), location: 0.55),
                ],
                startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // ★ 场景 + 信息栏一体化：信息栏浮在天空上方（参考图构图），
                    //   不再是"深色信息栏 + 场景"两截断层。浮层只占场景上部，
                    //   车身区域留给 SCNView 手势拖动。
                    ZStack(alignment: .top) {
                        carStage
                        VStack(spacing: 0) {
                            topBar
                            rangeBlock
                            Spacer(minLength: 0)
                        }
                    }
                    actionRow
                    pager
                    bigCards
                    assistRow
                    listRows
                    Spacer(minLength: 30)
                }
            }
            .refreshable { store.refresh() }

            if let t = store.toast {
                ToastView(toast: t)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(9)
            }
        }
        .onAppear {
            let t = Prefs.token
            CarSession.shared.configure(token: t, deviceID: Prefs.deviceID)
            if sceneModel == nil,
               let u = Bundle.main.url(forResource: "cardata", withExtension: "bin") {
                sceneModel = CarModel.load(
                    binURL: u,
                    partsURL: Bundle.main.url(forResource: "carparts", withExtension: "json"))
            }
            store.refresh()
            store.startAutoRefresh()
        }
        .onDisappear { store.stopAutoRefresh() }
        .onChange(of: phase) { p in
            if p == .active {
                store.refresh(silent: true)
                store.startAutoRefresh()
                fetchCloud()
            } else {
                store.stopAutoRefresh()
            }
        }
        .onChange(of: store.status.latitude) { _ in fetchCloud() }
        .sheet(isPresented: $showEnergy) {
            EnergyView(store: store).presentationDetents([.large])
        }
        .sheet(isPresented: $showFindCar) {
            FindCarView(store: store).presentationDetents([.large])
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store).presentationDetents([.large])
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(alignment: .center, spacing: 6) {
            Button {
                Haptics.tap()
                showSettings = true
            } label: {
                HStack(spacing: 4) {
                    Text("领克 07")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Palette.text(scheme))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.sub(scheme))
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // 右侧状态图标组：空调 / 锁 / 后备箱 / 档位 + 车牌
            HStack(spacing: 14) {
                statusIcon(store.status.preClimateActive ? "fan.fill" : "fan",
                           on: store.status.preClimateActive,
                           dim: !store.status.preClimateActive)
                statusIcon(store.status.doorLocked ? "lock.fill" : "lock.open.fill",
                           on: false, dim: true)
                statusIcon(store.status.trunkOpen ? "car.side.rear.open" : "car.side.rear",
                           on: false, dim: true)
                Text("P")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.sub(scheme))
                Text("浙A·L07K")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.sub(scheme).opacity(0.8))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    private func statusIcon(_ name: String, on: Bool, dim: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(on ? Palette.brand : Palette.sub(scheme).opacity(dim ? 0.55 : 1))
    }

    // MARK: 续航大数字

    private var rangeBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(String(format: "%.0f", store.status.totalRange))
                    .font(.system(size: 46, weight: .light, design: .rounded))
                    .foregroundStyle(Palette.text(scheme))
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.4), value: store.status.totalRange)
                Text("km")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Palette.sub(scheme))
                    .padding(.bottom, 8)

                Spacer()

                Button {
                    Haptics.tap()
                    store.refresh()
                } label: {
                    HStack(spacing: 4) {
                        if store.loading {
                            ProgressView().scaleEffect(0.55).frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9, weight: .bold))
                        }
                        Text(store.status.updateTime == .distantPast
                             ? "读取中"
                             : "更新于 \(store.status.updatedAgo)")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(store.status.isStale ? Color.orange : Palette.sub(scheme))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(Palette.card2(scheme)))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
            }

            // ★ 上下两个横条（参考图 2）：电量绿条 + 油量蓝条，点击切换显示单位
            VStack(spacing: 9) {
                energyBar(tint: Palette.brand, icon: "bolt.fill", title: "电量",
                          fraction: store.status.chargeLevel / 100,
                          valueText: evMode == 0
                            ? String(format: "%.0f%%", store.status.chargeLevel)
                            : String(format: "%.0f km", store.status.distanceToEmpty),
                          mode: evMode, modes: 2) {
                    withAnimation(.easeInOut(duration: 0.25)) { evMode = (evMode + 1) % 2 }
                }
                energyBar(tint: fuelBlue, icon: "fuelpump.fill", title: "油量",
                          fraction: store.status.fuelLevelPct / 100,
                          valueText: fuelMode == 0
                            ? String(format: "%.0f%%", store.status.fuelLevelPct)
                            : (fuelMode == 1
                               ? String(format: "%.0f km", store.status.fuelRange)
                               : String(format: "%.1f L", store.status.fuelLevel)),
                          mode: fuelMode, modes: 3) {
                    withAnimation(.easeInOut(duration: 0.25)) { fuelMode = (fuelMode + 1) % 3 }
                }
            }

            HStack(spacing: 4) {
                Image(systemName: store.status.hasLocation ? "location.fill" : "location.slash.fill")
                    .font(.system(size: 9))
                Text(store.status.hasLocation
                     ? String(format: "%.3f, %.3f", store.status.latitude, store.status.longitude)
                     : "位置未知")
                    .font(.system(size: 10, design: .monospaced))
                Spacer()
            }
            .foregroundStyle(Palette.sub(scheme).opacity(0.75))
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    // ★ 参考图 2 的能量横条：点击切换显示单位（电量 %/km，油量 %/km/L）
    private func energyBar(tint: Color, icon: String, title: String,
                           fraction: Double, valueText: String,
                           mode: Int, modes: Int,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.sub(scheme))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.card2(scheme)).frame(height: 8)
                        Capsule().fill(tint)
                            .frame(width: max(6, geo.size.width * min(1, max(0, fraction))), height: 8)
                    }
                }
                .frame(height: 8)
                Text(valueText)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.text(scheme))
                    .frame(width: 72, alignment: .trailing)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.22), value: valueText)
                HStack(spacing: 3) {
                    ForEach(0..<modes, id: \.self) { i in
                        Circle().fill(i == mode ? tint : Palette.sub(scheme).opacity(0.32))
                            .frame(width: 4, height: 4)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card(scheme)))
        }
        .buttonStyle(.plain)
    }

    // MARK: 3D 车模（可拖动）

    // MARK: 天气云量（open-meteo 免费，按车辆位置取，失败回落默认值）
    private func fetchCloud() {
        let lat = store.status.latitude, lon = store.status.longitude
        guard lat != 0 || lon != 0 else { return }
        let s = String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current=cloud_cover", lat, lon)
        guard let url = URL(string: s) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cur = obj["current"] as? [String: Any],
                  let cc = cur["cloud_cover"] as? Double else { return }
            DispatchQueue.main.async {
                cloudCover = min(1, max(0, cc / 100.0))
            }
        }.resume()
    }

    private var carStage: some View {
        ZStack(alignment: .topLeading) {
            if let m = sceneModel {
                SceneKitCarView(model: m, paint: store.paint, ref: carViewRef,
                                lat: store.status.latitude, lon: store.status.longitude,
                                cloud: cloudCover)
                    // ★ 不能 allowsHitTesting(false)，否则手指拖不动
                    .allowsHitTesting(true)
            } else {
                ProgressView().tint(Palette.sub(scheme))
            }

            paintChip.padding(.leading, 20).padding(.top, 4)
        }
        .frame(height: UIScreen.main.bounds.height * 0.46)
        .contentShape(Rectangle())
    }

    private var paintChip: some View {
        Button {
            Haptics.tap()
            store.paintIndex = (store.paintIndex + 1) % paintOptions.count
        } label: {
            HStack(spacing: 5) {
                Circle().fill(store.paint).frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                Text(paintOptions[store.paintIndex].name)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Palette.sub(scheme))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Palette.card2(scheme).opacity(0.85)))
        }
        .buttonStyle(.plain)
    }

    // MARK: 四个圆按钮

    private var actionRow: some View {
        HStack(spacing: 0) {
            // 1 解锁 / 关锁 —— 同时让车模四门开合
            CircleAction(
                title: store.status.doorLocked ? "解锁" : "关锁",
                icon: store.status.doorLocked ? "lock.open.fill" : "lock.fill",
                tint: Palette.brand,
                busy: store.busyAction == "lock",
                filled: !store.status.doorLocked
            ) {
                let willUnlock = store.status.doorLocked
                carViewRef.setDoors(open: willUnlock)
                store.run("lock",
                          willUnlock ? CarCommand.unlock() : CarCommand.lock(),
                          successText: willUnlock ? "解锁指令已发送" : "关锁指令已发送")
            }

            // 2 能源
            CircleAction(
                title: "能源",
                icon: "bolt.fill",
                tint: accentBlue,
                busy: false,
                filled: store.status.chargeStatus == 1
            ) { showEnergy = true }

            // 3 寻车 —— 车模闪灯 + 下发 RHL
            CircleAction(
                title: "寻车",
                icon: "car.side.fill",
                tint: Palette.brand,
                busy: store.busyAction == "find",
                filled: false
            ) {
                carViewRef.flash()
                store.run("find", CarCommand.flashHorn("horn-light-flash"), successText: "寻车指令已发送")
            }

            // 4 后备箱 —— 车模尾门升起 + 下发
            CircleAction(
                title: "后备箱",
                icon: "car.side.rear.open",
                tint: Color(red: 1.0, green: 0.62, blue: 0.20),
                busy: store.busyAction == "trunk",
                filled: store.status.trunkOpen
            ) {
                let open = !store.status.trunkOpen
                carViewRef.setTrunk(open: open)
                store.show(open ? "已展开后备箱模型（实车指令服务码待确认）" : "已收起后备箱模型", ok: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    private var pager: some View {
        HStack(spacing: 5) {
            Capsule().fill(Palette.text(scheme).opacity(0.85)).frame(width: 18, height: 3)
            Circle().fill(Palette.sub(scheme).opacity(0.4)).frame(width: 3, height: 3)
            Circle().fill(Palette.sub(scheme).opacity(0.4)).frame(width: 3, height: 3)
        }
        .padding(.top, 14)
    }

    // MARK: 两张并排大卡

    private var bigCards: some View {
        HStack(spacing: 12) {
            // 左：充电
            BigCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(String(format: "%.0f", store.status.chargeLevel))
                                .font(.system(size: 30, weight: .regular, design: .rounded))
                                .foregroundStyle(Palette.text(scheme))
                            Text("%")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Palette.sub(scheme))
                        }
                        Spacer()
                        Image(systemName: store.status.chargeStatus == 1
                              ? "bolt.car.fill" : "bolt.slash")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Palette.sub(scheme))
                    }
                    Text(store.status.chargeStatus == 1 ? "正在充电" : "未充电")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.sub(scheme))
                        .padding(.top, 2)

                    Spacer(minLength: 8)

                    Text(store.status.chargeStatus == 1 && store.status.timeToFull > 0
                         ? "预计 \(store.status.timeToFull) 分钟充满"
                         : String(format: "纯电续航 %.0f km", store.status.distanceToEmpty))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.sub(scheme).opacity(0.85))
                }
                .frame(height: 96)
            }

            // 右：车内温度
            BigCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(String(format: "%.1f", store.status.interiorTemp))
                                .font(.system(size: 30, weight: .regular, design: .rounded))
                                .foregroundStyle(Palette.text(scheme))
                            Text("°")
                                .font(.system(size: 16, weight: .regular))
                                .foregroundStyle(Palette.sub(scheme))
                        }
                        Spacer()
                        Button {
                            Haptics.tap()
                            if store.status.preClimateActive {
                                store.run("climate", CarCommand.climateOff(), successText: "空调关闭指令已发送")
                            } else {
                                store.run("climate", CarCommand.climateOn(), successText: "空调开启指令已发送")
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(store.status.preClimateActive
                                          ? Palette.brand : accentBlue)
                                    .frame(width: 34, height: 34)
                                if store.busyAction == "climate" {
                                    ProgressView().tint(.white).scaleEffect(0.65)
                                } else {
                                    Image(systemName: "fan.fill")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Text("车内温度")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.sub(scheme))
                        .padding(.top, 2)

                    Spacer(minLength: 8)

                    Text(store.status.preClimateActive
                         ? "空调已开启 · 车外 \(String(format: "%.1f", store.status.exteriorTemp))°"
                         : "预设温度 22.0°")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.sub(scheme).opacity(0.85))
                }
                .frame(height: 96)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }

    // MARK: 车窗 / 天窗 功能行

    private var assistRow: some View {
        HStack(spacing: 12) {
            FunctionTile(icon: "rectangle.split.3x1.fill",
                         title: "车窗微开",
                         subtitle: store.status.windowClosed ? "全部关闭" : "已开启",
                         busy: store.busyAction == "window") {
                store.run("window", CarCommand.windowAjar(), successText: "车窗微开指令已发送")
            }
            FunctionTile(icon: "sun.max.fill",
                         title: "天窗",
                         subtitle: "轻触展开",
                         busy: false) {
                carViewRef.toggleSunroof()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: 底部两行

    private var listRows: some View {
        VStack(spacing: 0) {
            ListRow(icon: "clock", title: "预约",
                    value: store.status.chargeStatus == 1 ? "正在充电" : "未预约") {}
            Divider().overlay(Palette.line(scheme)).padding(.leading, 50)
            ListRow(icon: "key.fill", title: "钥匙",
                    value: store.hasToken ? "已连接" : "未连接") {
                showSettings = true
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Palette.card(scheme))
        )
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }
}

// MARK: - 组件

/// 圆形操作按钮（参考图那种：无底色圆 + 图标 + 下方说明）
struct CircleAction: View {
    let title: String
    let icon: String
    let tint: Color
    let busy: Bool
    let filled: Bool
    var action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var pressed = false

    var body: some View {
        Button {
            Haptics.tap()
            withAnimation(.spring(response: 0.2, dampingFraction: 0.55)) { pressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { pressed = false }
            }
            action()
        } label: {
            VStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(filled ? tint.opacity(0.22) : Palette.card2(scheme).opacity(0.7))
                        .frame(width: 58, height: 58)
                        .overlay(
                            Circle().strokeBorder(
                                filled ? tint.opacity(0.55) : Palette.line(scheme),
                                lineWidth: filled ? 1.2 : 0.8)
                        )
                    if busy {
                        ProgressView().progressViewStyle(.circular)
                            .tint(filled ? tint : Palette.text(scheme))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 21, weight: .regular))
                            .foregroundStyle(filled ? tint : Palette.text(scheme).opacity(0.9))
                    }
                }
                .scaleEffect(pressed ? 0.92 : 1.0)

                Text(title)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(Palette.sub(scheme))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

struct BigCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Palette.card(scheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Palette.line(scheme), lineWidth: 0.8)
                    )
            )
    }
}

struct FunctionTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let busy: Bool
    var action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Palette.text(scheme).opacity(0.9))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.text(scheme))
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.sub(scheme))
                }
                Spacer()
                if busy { ProgressView().scaleEffect(0.6) }
                else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.sub(scheme).opacity(0.7))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Palette.card(scheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Palette.line(scheme), lineWidth: 0.8)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct ListRow: View {
    let icon: String
    let title: String
    let value: String
    var action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Palette.text(scheme).opacity(0.85))
                    .frame(width: 26)
                Text(title)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Palette.text(scheme))
                Spacer()
                Text(value)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.sub(scheme))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.sub(scheme).opacity(0.6))
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 车模动作桥

/// 让 SwiftUI 按钮能驱动 SCNView 里的门/尾门/天窗/闪灯动画
final class CarViewModel: ObservableObject {
    fileprivate weak var view: CarSceneView?
    private var doorsOpen = false
    private var trunkOpen = false
    private var sunroofOpen = false

    func attach(_ v: CarSceneView) { view = v }

    func setDoors(open: Bool) {
        doorsOpen = open
        view?.setDoors(open: open)
    }
    func setTrunk(open: Bool) {
        trunkOpen = open
        view?.setTrunk(open: open)
    }
    func toggleSunroof() {
        sunroofOpen.toggle()
        view?.setSunroof(open: sunroofOpen)
    }
    func flash() { view?.flashLights() }
}

// MARK: - SceneKit 包装

struct SceneKitCarView: UIViewRepresentable {
    let model: CarModel
    let paint: Color
    let ref: CarViewModel
    var lat: Double = 0
    var lon: Double = 0
    var cloud: Double = 0.3
    @Environment(\.colorScheme) private var scheme

    func makeUIView(context: Context) -> CarSceneView {
        let v = CarSceneView(frame: .zero)
        v.sceneDayMode = (scheme != .dark)
        v.load(model, paint: UIColor(paint))
        v.startTurntable(false)
        v.applyEnvironment(lat: lat, lon: lon, cloud: cloud)
        ref.attach(v)
        return v
    }

    func updateUIView(_ uiView: CarSceneView, context: Context) {
        uiView.setPaint(UIColor(paint))
        uiView.sceneDayMode = (scheme != .dark)
        uiView.applyEnvironment(lat: lat, lon: lon, cloud: cloud)
    }
}
