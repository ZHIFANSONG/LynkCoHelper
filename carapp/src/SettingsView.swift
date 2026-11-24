//
//  SettingsView.swift
//  设置：粘贴凭据 / 连通性自检 / 外观模式 / 关于
//
//  凭据从哪来：领克 App 抓包（mobileCodeLogin 应答里的 token 与 deviceId），
//  或者用 app-services 的 refresh 接口换一个新的 token。
//

import SwiftUI

// MARK: - 本地持久化

enum Prefs {
    private static let d = UserDefaults.standard

    static var token: String {
        get { d.string(forKey: "car.token") ?? "" }
        set { d.set(newValue, forKey: "car.token") }
    }
    static var deviceID: String {
        get {
            let v = d.string(forKey: "car.deviceId") ?? ""
            return v.isEmpty ? "664EE307-36D3-49D8-99C0-21D7169CC38B" : v
        }
        set { d.set(newValue, forKey: "car.deviceId") }
    }

    /// 把粘贴进来的 token 洗干净：去掉所有空白/换行 + 误贴的 bearer 前缀。
    /// JWT 本身不含任何空白字符，多一个空格或换行都会让 HMAC 对不上，直接 400 00A06。
    static func sanitized(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("bearer") {
            t = String(t.dropFirst(6))
        }
        t = t.filter { !$0.isWhitespace && !$0.isNewline }
        return t
    }

    /// token 看起来像不像真的（JWT 三段，或者 36 位 UUID）
    static func looksValidToken(_ s: String) -> Bool {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("bearer") { t = String(t.dropFirst(6)) }
        if t.isEmpty { return false }
        if t.split(separator: ".").count == 3 { return true }   // JWT
        if t.count == 36 && t.filter({ $0 == "-" }).count == 4 { return true }
        return t.count > 40
    }
}

// MARK: - 设置页

struct SettingsView: View {
    @ObservedObject var store: CarStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @AppStorage("appearance") private var appearance = "auto"
    @State private var token = Prefs.token
    @State private var deviceID = Prefs.deviceID
    @State private var showToken = false
    @State private var diag = ""
    @State private var diagBusy = false
    @State private var diagOK = false

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.bg(scheme).ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        credCard
                        diagCard
                        appearanceCard
                        aboutCard
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.sub(scheme))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.brand)
                }
            }
        }
    }

    // MARK: 凭据

    private var credCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.brand)
                    Text("登录凭据")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Palette.text(scheme))
                    Spacer()
                    Text(Prefs.looksValidToken(token) ? "格式看起来对" : "还没填")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Prefs.looksValidToken(token)
                                         ? Palette.brand : Palette.sub(scheme))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(
                            (Prefs.looksValidToken(token) ? Palette.brand : Palette.sub(scheme))
                                .opacity(0.12)))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("accessToken")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.sub(scheme))
                    ZStack(alignment: .topLeading) {
                        if token.isEmpty {
                            Text("粘贴 JWT（不带 bearer）")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Palette.sub(scheme).opacity(0.6))
                                .padding(.horizontal, 10).padding(.vertical, 11)
                        }
                        TextEditor(text: $token)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.text(scheme))
                            .scrollContentBackground(.hidden)
                            .frame(height: showToken ? 130 : 74)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .opacity(showToken ? 1 : 0.55)
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Palette.card2(scheme)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Palette.line(scheme), lineWidth: 1))
                    .onTapGesture { showToken = true }

                    HStack(spacing: 14) {
                        Button(showToken ? "收起" : "展开") { showToken.toggle() }
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.brand)
                        Button("粘贴") { paste() }
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.brand)
                        Button("清空") { token = "" }
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.sub(scheme))
                        Spacer()
                        Text("\(token.count) 字符")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.sub(scheme))
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("deviceId")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.sub(scheme))
                    TextField("36 位 UUID", text: $deviceID)
                        .font(.system(size: 11, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(Palette.text(scheme))
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Palette.card2(scheme)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Palette.line(scheme), lineWidth: 1))
                    Text("必须与签发 token 的那台设备一致，否则签名能过但网关判 token 无效")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.sub(scheme).opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 外观

    private var appearanceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.brand)
                    Text("外观")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Palette.text(scheme))
                }
                Picker("", selection: $appearance) {
                    Text("跟随系统").tag("auto")
                    Text("深色").tag("dark")
                    Text("浅色").tag("light")
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: 连通性自检

    private var diagCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.brand)
                    Text("连通性自检")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Palette.text(scheme))
                    Spacer()
                    if diagBusy { ProgressView().scaleEffect(0.7) }
                }

                Text("用一个只读请求测 token 和签名是否被网关接受，不会给车发任何指令。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.sub(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    runDiag()
                } label: {
                    Text(diagBusy ? "测试中…" : "测试连接")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Palette.brand.opacity(0.15)))
                        .foregroundStyle(Palette.brand)
                }
                .buttonStyle(.plain)
                .disabled(diagBusy)

                if !diag.isEmpty {
                    Text(diag)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(diagOK ? Palette.brand : Color(red: 0.95, green: 0.36, blue: 0.32))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Palette.card2(scheme)))
                }

                VStack(alignment: .leading, spacing: 4) {
                    row("token 长度", "\(Prefs.sanitized(token).count)")
                    row("含空白字符", token.filter { $0.isWhitespace || $0.isNewline }.isEmpty ? "无" : "有（已自动清理）")
                    row("bearer 前缀", token.lowercased().hasPrefix("bearer") ? "有（已自动去掉）" : "无")
                    row("deviceId 合法", Prefs.looksValidToken(deviceID) ? "是" : "否")
                }
            }
        }
    }

    private func runDiag() {
        let clean = Prefs.sanitized(token)
        token = clean
        CarSession.shared.configure(token: clean, deviceID: deviceID)
        diagBusy = true
        diag = ""
        CarApi.vehicleStatus { r in
            diagBusy = false
            switch r {
            case .success(let st):
                diagOK = true
                diag = "连接正常。\n电量 \(Int(st.chargeLevel))% · 纯电 \(Int(st.distanceToEmpty)) km · 燃油 \(Int(st.fuelRange)) km\n综合 \(Int(st.totalRange)) km · 总里程 \(Int(st.odometer)) km · 车锁\(st.doorLocked ? "已上锁" : "已解锁")\n数据更新于 \(st.updatedAgo)"
            case .failure(let e):
                diagOK = false
                diag = "失败 [\(e.code)] \(e.message)\n\n" + Self.hint(e.code)
            }
        }
    }

    private static func hint(_ code: String) -> String {
        switch code {
        case "00A06": return "签名不匹配：token 里混进了空白字符，或 deviceId 与 token 不一致。"
        case "00A12": return "token 被网关判为无效：带了 bearer 前缀，或已过期。"
        case "00A10": return "登录会话已失效，需要重新抓包取新 token。"
        case "00A09": return "同一请求短时间内重复，等 10 分钟再试。"
        case "00A19": return "手机系统时间与服务器差超过 10 分钟，请校准时间。"
        case "NETWORK": return "网络不通：确认手机能访问 gric-g-api.geely.com。"
        default: return "把这个 code 发我，我对回来。"
        }
    }

    // MARK: 关于

    private var aboutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 7) {
                Text("关于")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.text(scheme))
                row("版本", "0.8.0")
                row("车型", "领克 07 EM-P（DS11）")
                row("网关", "gric-g-api.geely.com")
                Text("本 App 通过抓包还原的接口与车辆通信，不是官方客户端。凭据过期（约 7 天）需重新获取。")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.sub(scheme).opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 11.5)).foregroundStyle(Palette.sub(scheme))
            Spacer()
            Text(v).font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Palette.text(scheme))
        }
    }

    // MARK: 动作

    private func paste() {
        if let s = UIPasteboard.general.string, !s.isEmpty {
            token = Prefs.sanitized(s)
            Haptics.tap()
        }
    }

    private func save() {
        let clean = Prefs.sanitized(token)
        token = clean
        Prefs.token = clean
        Prefs.deviceID = deviceID
        CarSession.shared.configure(token: clean, deviceID: deviceID)
        store.refresh()
        Haptics.success()
        store.show("已保存，正在读取车辆状态…", ok: true)
        dismiss()
    }
}
