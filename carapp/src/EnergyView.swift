//
//  EnergyView.swift
//  能源管理：电量环 + 油电双色条 + 充电状态 + 真实能耗 + 里程构成 + 轮胎
//

import SwiftUI

struct EnergyView: View {
    @ObservedObject var store: CarStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var soc: Double { min(1, max(0, store.status.chargeLevel / 100)) }
    private let fuelBlue = Color(red: 0.24, green: 0.55, blue: 0.98)

    private var s: VehicleStatus { store.status }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.bg(scheme).ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        ringCard
                        splitCard
                        chargeRow
                        realConsumptionCard
                        mileageCard
                        tyreCard
                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                }
                .refreshable { store.refresh() }
            }
            .navigationTitle("能源管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.brand)
                }
            }
        }
    }

    // MARK: 电量环（数值全部来自服务端原始字段）

    private var ringCard: some View {
        GlassCard {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Palette.card2(scheme), lineWidth: 16)
                        .frame(width: 168, height: 168)
                    Circle()
                        .trim(from: 0, to: max(0.02, soc))
                        .stroke(
                            AngularGradient(
                                colors: [Palette.range(soc), Palette.range(soc).opacity(0.65), Palette.range(soc)],
                                center: .center),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round))
                        .frame(width: 168, height: 168)
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.7, dampingFraction: 0.8), value: soc)

                    VStack(spacing: 2) {
                        Text(String(format: "%.0f", s.chargeLevel))
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.text(scheme))
                        Text("% 电量").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.sub(scheme))
                    }
                }
                .padding(.top, 4)

                // 全部为服务端字段：纯电 / 燃油 / 综合
                HStack(spacing: 0) {
                    stat("纯电续航", String(format: "%.0f km", s.distanceToEmpty), Palette.brand)
                    divider
                    stat("燃油续航", String(format: "%.0f km", s.fuelRange), fuelBlue)
                    divider
                    stat("综合续航", String(format: "%.0f km", s.totalRange), Palette.text(scheme))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.line(scheme)).frame(width: 1, height: 26)
    }

    private func stat(_ k: String, _ v: String, _ c: Color) -> some View {
        VStack(spacing: 3) {
            Text(v).font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(c)
            Text(k).font(.system(size: 10.5)).foregroundStyle(Palette.sub(scheme))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 油电占比（真实百分比）

    private var splitCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("油电构成")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Palette.text(scheme))
                    Spacer()
                    Text(String(format: "电 %.0f%% · 油 %.0f%%",
                                pct(s.distanceToEmpty), pct(s.fuelRange)))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.sub(scheme))
                }
                GeometryReader { geo in
                    let w = geo.size.width
                    let ev = pct(s.distanceToEmpty) / 100
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Palette.brand)
                            .frame(width: max(4, w * ev - 1))
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(fuelBlue)
                    }
                }
                .frame(height: 10)
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                    Text(String(format: "油箱 %.1f L · 电池 %.0f%%",
                                s.fuelLevel, s.chargeLevel))
                        .font(.system(size: 10.5))
                }
                .foregroundStyle(Palette.sub(scheme).opacity(0.85))
            }
        }
    }

    private func pct(_ part: Double) -> Double {
        let t = s.distanceToEmpty + s.fuelRange
        guard t > 0 else { return 0 }
        return min(100, max(0, part / t * 100))
    }

    // MARK: 充电

    private var chargeRow: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "bolt.car.fill")
                        .foregroundStyle(s.chargeStatus == 1 ? Palette.brand : Palette.sub(scheme))
                    Text(s.chargeStatus == 1 ? "正在充电" : "未充电")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Palette.text(scheme))
                    Spacer()
                    if s.chargeStatus == 1 && s.timeToFull > 0 {
                        Text("\(s.timeToFull) 分钟充满")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.sub(scheme))
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        Haptics.tap()
                        store.show("充电启停的服务码还在确认中，暂不会下发", ok: false)
                    } label: {
                        Text("开始充电")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Palette.brand.opacity(0.14)))
                            .foregroundStyle(Palette.brand)
                    }
                    .buttonStyle(.plain)

                    Button {
                        Haptics.tap()
                        store.show("充电启停的服务码还在确认中，暂不会下发", ok: false)
                    } label: {
                        Text("停止充电")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Palette.card2(scheme)))
                            .foregroundStyle(Palette.text(scheme))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 真实平均能耗（不再编造七天曲线）

    private var realConsumptionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("平均能耗")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Palette.text(scheme))
                    Spacer()
                    Text("来自车端实时数据")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.sub(scheme).opacity(0.7))
                }
                HStack(spacing: 10) {
                    metricBox(icon: "bolt.fill",
                              value: String(format: "%.1f", s.avgPowerConsumption),
                              unit: "kWh/100km",
                              label: "平均电耗",
                              tint: Palette.brand)
                    metricBox(icon: "fuelpump.fill",
                              value: String(format: "%.1f", s.avgFuelConsumption),
                              unit: "L/100km",
                              label: "平均油耗",
                              tint: fuelBlue)
                }
                HStack(spacing: 10) {
                    metricBox(icon: "gauge.with.dots.needle.50percent",
                              value: String(format: "%.0f", s.avgSpeed),
                              unit: "km/h",
                              label: "平均车速",
                              tint: Palette.text(scheme))
                    metricBox(icon: "road.lanes",
                              value: String(format: "%.0f", s.trip2),
                              unit: "km",
                              label: "本次行程",
                              tint: Palette.text(scheme))
                }
            }
        }
    }

    private func metricBox(icon: String, value: String, unit: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(label).font(.system(size: 10.5))
            }
            .foregroundStyle(tint.opacity(0.9))

            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.text(scheme))
                Text(unit)
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.sub(scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Palette.card2(scheme)))
    }

    // MARK: 里程构成

    private var mileageCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("里程")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Palette.text(scheme))
                    Spacer()
                    Text(String(format: "总计 %.0f km", s.odometer))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.sub(scheme))
                }
                mileageRow("纯电行驶", s.odoEv, Palette.brand, s.odometer)
                mileageRow("燃油行驶", s.odoFuel, fuelBlue, s.odometer)
                HStack(spacing: 18) {
                    smallStat("小计里程 A", String(format: "%.1f km", s.trip1))
                    smallStat("小计里程 B", String(format: "%.1f km", s.trip2))
                }
                .padding(.top, 2)
            }
        }
    }

    private func mileageRow(_ name: String, _ v: Double, _ c: Color, _ total: Double) -> some View {
        VStack(spacing: 5) {
            HStack {
                Circle().fill(c).frame(width: 7, height: 7)
                Text(name).font(.system(size: 11.5)).foregroundStyle(Palette.sub(scheme))
                Spacer()
                Text(String(format: "%.0f km", v))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.text(scheme))
            }
            GeometryReader { geo in
                let ratio = total > 0 ? min(1, max(0, v / total)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.card2(scheme)).frame(height: 5)
                    Capsule().fill(c).frame(width: max(2, geo.size.width * ratio), height: 5)
                }
            }
            .frame(height: 5)
        }
    }

    private func smallStat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.system(size: 10)).foregroundStyle(Palette.sub(scheme))
            Text(v).font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.text(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 轮胎

    private var tyreCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("胎压")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.text(scheme))
                HStack(spacing: 10) {
                    tyre("左前", s.tyreFL, s.tyreTempFL)
                    tyre("右前", s.tyreFR, s.tyreTempFR)
                }
                HStack(spacing: 10) {
                    tyre("左后", s.tyreRL, s.tyreTempRL)
                    tyre("右后", s.tyreRR, s.tyreTempRR)
                }
            }
        }
    }

    private func tyre(_ name: String, _ kpa: Double, _ temp: Double) -> some View {
        let ok = kpa >= 260 && kpa <= 300
        return VStack(spacing: 3) {
            Text(name).font(.system(size: 10.5)).foregroundStyle(Palette.sub(scheme))
            Text(String(format: "%.0f", kpa))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(ok ? Palette.text(scheme) : Color.orange)
            Text("kPa · \(Int(temp))°")
                .font(.system(size: 9.5)).foregroundStyle(Palette.sub(scheme).opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Palette.card2(scheme)))
    }
}
