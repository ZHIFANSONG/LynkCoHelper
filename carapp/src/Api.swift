//
//  Api.swift
//  领克 gric 网关：X-API-SIGNATURE v2.1 签名 + 车控请求
//
//  canonical（已用抓包 4/4 回归验证）：
//    for k in sorted(白名单头, 剔除 X-SIGNATURE):  s += k.lower()+":"+v+"\n"
//    if query:  s += query+"\n"
//    elif body: s += base64(md5(body))+"\n"
//    else:      什么都不加
//    s += METHOD+"\n" + path
//    sig = base64(hmac_sha256(KEY, s))
//
//  注意：Authorization 必须裸 JWT，不能带 bearer 前缀（带则 00A12 Invalid token）
//

import Foundation

// MARK: - 配置

enum CarConfig {
    /// gric HMAC 密钥（从 GRIEnvs 里 XOR 0xFF 解出的 aesKey 候选，ASCII 原文即密钥）
    static let appKey = "e70024ed24bda3cbd4a6295ed3fac5aa"

    static let gricG = "https://gric-g-api.geely.com"
    static let gricMain = "https://gric-api.geely.com"

    /// 车辆标识（VIN 加密串）
    static let vehicleID = "bFYun+sZis2ZA1UykL2EL6UoxdMg+4mPLnWM+0M10+0="
    /// 车系（Base64）
    static let vehicleSeries = "TDc0Mw=="

    static let userAgent = "GeelyLynkco/4.3.1 (com.lynkco.customer; build:40301169; iOS 27.0.0) Alamofire/5.11.1"

    /// 参与签名的头白名单（25 个；实际签名剔除 X-SIGNATURE 后 21 个）
    static let signHeaders: [String] = [
        "x-app-id", "accept-language", "authorization", "x-api-signature-version",
        "x-api-signature-nonce", "x-timestamp", "x-app-version", "x-ota-version",
        "x-vehicle-identifier", "x-device-brand", "x-device-model", "x-device-id",
        "x-device-os-version", "x-device-identifier", "x-vehicle-brand",
        "x-vehicle-series", "x-vehicle-model", "x-tsp-platform", "x-tenant-id",
        "x-signature", "x-platform", "x-sales-platform", "x-request-source",
        "x-region-id", "x-request-id",
    ]
}

// MARK: - 错误

struct ApiError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message.isEmpty ? code : message }

    /// 把 gric 的 code 翻成中文
    static func humanize(_ code: String, _ msg: String) -> String {
        if !msg.isEmpty && msg != "success" { return msg }
        switch code {
        case "00A06": return "签名校验失败"
        case "00A09": return "请求重复，请稍后再试"
        case "00A10": return "登录已过期，请重新登录"
        case "00A12": return "Token 无效"
        case "00A19": return "请求时间与服务器相差超过 10 分钟"
        case "1000P004": return "指令参数不正确"
        case "1000N001": return "车辆服务内部错误"
        default: return code
        }
    }
}

// MARK: - 会话

final class CarSession {
    static let shared = CarSession()

    /// 裸 JWT（不带 bearer）
    private(set) var token: String = ""
    private(set) var deviceID: String = ""
    private(set) var deviceModel: String = "iPhone17,2"
    private(set) var osVersion: String = "27.0"
    private(set) var appVersion: String = "4.3.1"

    private let queue = DispatchQueue(label: "car.session")
    private var inFlight = 0

    func configure(token: String, deviceID: String) {
        queue.sync {
            var t = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.lowercased().hasPrefix("bearer") {
                t = String(t.dropFirst(6))
            }
            self.token = t
            self.deviceID = deviceID
        }
    }

    /// 生成 UUID 大写（与抓包一致：B051B2FB-ED77-43AC-BDCF-1B920858FF6C）
    static func nonce() -> String { UUID().uuidString }
}

// MARK: - 签名

enum Signer {
    static func md5Base64(_ body: Data) -> String {
        MD5.hash(body).base64
    }

    /// 构造 canonical string
    static func canonical(method: String,
                          headers: [String: String],
                          url: URL,
                          body: Data?) -> String {
        var s = ""
        // 1. 白名单头，剔除 x-signature 自身，小写后按 key 升序
        var picked: [(String, String)] = []
        for (k, v) in headers {
            let lk = k.lowercased()
            if lk == "x-signature" { continue }
            if CarConfig.signHeaders.contains(lk) {
                picked.append((lk, v))
            }
        }
        picked.sort { $0.0 < $1.0 }
        for (k, v) in picked {
            s += k + ":" + v + "\n"
        }

        // 2. body 段三选一
        let query = url.query ?? ""
        if !query.isEmpty {
            s += query + "\n"
        } else if let b = body, !b.isEmpty {
            s += md5Base64(b) + "\n"
        }
        // 否则不加任何东西（不是 md5("")）

        // 3. method + path
        s += method.uppercased() + "\n" + url.path
        return s
    }

    static func sign(method: String,
                     headers: [String: String],
                     url: URL,
                     body: Data?) -> String {
        let canon = canonical(method: method, headers: headers, url: url, body: body)
        let mac = HMAC.sha256(key: CarConfig.appKey.utf8Data, message: canon.utf8Data)
        return mac.base64
    }
}

// MARK: - 请求

enum CarApi {
    /// 组装签名头并返回完整 header 字典
    static func signedHeaders(method: String, url: URL, body: Data?) -> [String: String] {
        let s = CarSession.shared
        var h: [String: String] = [
            "X-APP-ID": "GEELYCNCH001M0001",
            "X-APP-VERSION": s.appVersion,
            "X-TIMESTAMP": String(Int(Date().timeIntervalSince1970 * 1000)),
            "X-API-SIGNATURE-VERSION": "2.1",
            "X-API-SIGNATURE-NONCE": CarSession.nonce(),
            "X-DEVICE-MODEL": s.deviceModel,
            "X-DEVICE-ID": s.deviceID,
            "X-DEVICE-OS-VERSION": s.osVersion,
            "X-DEVICE-BRAND": "iPhone",
            "X-PLATFORM": "iOS",
            "X-SALES-PLATFORM": "LYNKCO",
            "X-TENANT-ID": "LYNKCO",
            "X-TSP-PLATFORM": "3",
            "X-VEHICLE-BRAND": "LYNKCO",
            "X-VEHICLE-IDENTIFIER": CarConfig.vehicleID,
            "X-VEHICLE-SERIES": CarConfig.vehicleSeries,
            "Accept-Language": "zh_CN",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": CarConfig.userAgent,
        ]
        if !s.token.isEmpty {
            h["Authorization"] = s.token   // 裸 JWT
        }
        let sig = Signer.sign(method: method, headers: h, url: url, body: body)
        h["X-SIGNATURE"] = sig
        return h
    }

    /// 原始请求（回调在主线程）
    static func raw(method: String,
                    host: String,
                    path: String,
                    query: String? = nil,
                    body: Data? = nil,
                    timeout: TimeInterval = 20,
                    completion: @escaping (Result<[String: Any], ApiError>) -> Void) {
        var comps = URLComponents(string: host + path)!
        if let q = query, !q.isEmpty { comps.percentEncodedQuery = q }
        guard let url = comps.url else {
            completion(.failure(ApiError(code: "BAD_URL", message: "URL 构造失败")))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        let headers = signedHeaders(method: method, url: url, body: body)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let b = body { req.httpBody = b }

        URLSession.shared.dataTask(with: req) { data, resp, err in
            let done: (Result<[String: Any], ApiError>) -> Void = { r in
                DispatchQueue.main.async { completion(r) }
            }
            if let err = err {
                done(.failure(ApiError(code: "NETWORK", message: err.localizedDescription)))
                return
            }
            guard let data = data, !data.isEmpty else {
                done(.failure(ApiError(code: "EMPTY", message: "服务器无响应")))
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let txt = String(data: data, encoding: .utf8) ?? ""
                done(.failure(ApiError(code: "PARSE", message: String(txt.prefix(120)))))
                return
            }
            let code = (obj["code"] as? String) ?? (obj["code"].map { "\($0)" } ?? "")
            let msg = (obj["msg"] as? String) ?? (obj["message"] as? String) ?? ""
            if code == "0" || code == "success" || code == "200" {
                done(.success(obj))
            } else {
                done(.failure(ApiError(code: code,
                                       message: ApiError.humanize(code, msg))))
            }
        }.resume()
    }

    // MARK: 读

    static func vehicleStatus(completion: @escaping (Result<VehicleStatus, ApiError>) -> Void) {
        raw(method: "GET", host: CarConfig.gricG,
            path: "/ms-vehicle-status/api/v2.0/vehicle/status/latest") { r in
            switch r {
            case .success(let o):
                guard let d = o["data"] as? [String: Any] else {
                    completion(.failure(ApiError(code: "EMPTY", message: "无车辆数据")))
                    return
                }
                completion(.success(VehicleStatus(d)))
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    // MARK: 写（车控指令）

    struct ControlResult {
        let sessionID: String
    }

    static func control(_ payload: [String: Any],
                        completion: @escaping (Result<ControlResult, ApiError>) -> Void) {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(ApiError(code: "BAD_BODY", message: "报文序列化失败")))
            return
        }
        raw(method: "POST", host: CarConfig.gricG,
            path: "/ms-remote-control/api/v1.0/remoteControl/control",
            body: body) { r in
            switch r {
            case .success(let o):
                let sid = ((o["data"] as? [String: Any])?["sessionId"] as? String) ?? ""
                completion(.success(ControlResult(sessionID: sid)))
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    /// 充电域控制（RCS 走 /ms-charge-manage，不是 /remoteControl）
    /// 逆向依据见 work/carapp/PROTOCOL.md 第二节
    static func chargeControl(_ payload: [String: Any],
                              completion: @escaping (Result<ControlResult, ApiError>) -> Void) {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(ApiError(code: "BAD_BODY", message: "报文序列化失败")))
            return
        }
        raw(method: "POST", host: CarConfig.gricG,
            path: "/ms-charge-manage/api/v1.0/charge/control",
            body: body) { r in
            switch r {
            case .success(let o):
                let sid = ((o["data"] as? [String: Any])?["sessionId"] as? String) ?? ""
                completion(.success(ControlResult(sessionID: sid)))
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    /// 查询指令回执（description 形如「解锁指令已发送」，status 1=成功）
    static func processResult(sessionID: String,
                              completion: @escaping (String?) -> Void) {
        guard !sessionID.isEmpty else { completion(nil); return }
        raw(method: "GET", host: CarConfig.gricG,
            path: "/ms-remote-control/api/v1.0/remoteControl/queryProcessResult",
            query: "sessionId=" + sessionID) { r in
            if case .success(let o) = r,
               let d = o["data"] as? [String: Any],
               let desc = d["description"] as? String {
                completion(desc)
            } else {
                completion(nil)
            }
        }
    }
}

// MARK: - 指令构造

enum CarCommand {
    /// 解锁
    static func unlock() -> [String: Any] {
        ["command": "start", "serviceId": "RDU",
         "setting": ["serviceParameters": [["key": "door", "value": "all"]]]]
    }

    /// 关锁
    static func lock() -> [String: Any] {
        ["command": "start", "serviceId": "RDL",
         "setting": ["serviceParameters": [["key": "door", "value": "all"]]]]
    }

    /// 空调开
    static func climateOn(temp: Double = 22, minutes: Int = 90) -> [String: Any] {
        let t = String(format: "%.1f", temp)
        return ["command": "start", "serviceId": "RCE",
                "setting": [
                    "operationScheduling": ["duration": "\(minutes)"],
                    "serviceParameters": [
                        ["key": "rce.conditioner", "value": "1"],
                        ["key": "rce.temp", "value": t],
                    ],
                ]]
    }

    /// 空调关
    static func climateOff() -> [String: Any] {
        ["command": "stop", "serviceId": "RCE",
         "setting": ["serviceParameters": [["key": "rce.conditioner", "value": "1"]]]]
    }

    /// 极速升温（PAA）
    static func rapidHeat(temp: Double = 28.5, minutes: Int = 90) -> [String: Any] {
        ["command": "immediately", "serviceId": "PAA",
         "setting": [
            "ac": "true", "duration": "\(minutes)",
            "heat": [["level": "3", "pos": "11"], ["level": "3", "pos": "19"]],
            "paa": "0", "sw": "true",
            "temp": String(format: "%.1f", temp),
            "timerId": "", "vlt": "false",
         ]]
    }

    /// 车窗微开（RWS）
    /// 逆向依据：GRIVehicleWindowParams.serviceParameters 由 functionType 枚举拼出
    /// key=target, value ∈ {window, sunroof, sunshade, ventilate, front-charge-lid, all}
    /// 微开取 target=window，command=start。
    /// 注意：该组参数尚未实车验证（官方 App 的 openType 0/1 决定开合程度）。
    static func windowAjar() -> [String: Any] {
        ["command": "start", "serviceId": "RWS",
         "setting": ["serviceParameters": [["key": "target", "value": "window"]]]]
    }

    /// 寻车：闪灯鸣笛（RHL）
    /// 逆向依据：GRIFlashHornParams.serviceParameters 由 type 枚举拼出
    /// key=hrl, value ∈ {horn, light-flash, horn-light-flash}
    static func flashHorn(_ type: String = "horn-light-flash") -> [String: Any] {
        ["command": "start", "serviceId": "RHL",
         "setting": ["serviceParameters": [["key": "hrl", "value": type]]]]
    }

    // MARK: 充电（RCS，2026-11-24 静态逆向解出）

    /// 开始充电（不带目标电量，App 默认路径 → rcs.restart）
    static func chargeStart() -> [String: Any] {
        ["command": "start", "serviceId": "RCS",
         "setting": ["serviceParameters": [["key": "rcs.restart", "value": "1"]]]]
    }

    /// 开始充电并设定目标电量（带 soc → rcs.setting）
    static func chargeStart(soc: Int) -> [String: Any] {
        ["command": "start", "serviceId": "RCS",
         "setting": ["serviceParameters": [
            ["key": "soc", "value": "\\(soc)"],
            ["key": "rcs.setting", "value": "1"],
         ]]]
    }

    /// 停止充电（rcs.terminate）
    static func chargeStop() -> [String: Any] {
        ["command": "stop", "serviceId": "RCS",
         "setting": ["serviceParameters": [["key": "rcs.terminate", "value": "1"]]]]
    }

    /// 立即充电（rcs.immediately，value 恒为 "1"）
    static func chargeImmediately() -> [String: Any] {
        ["command": "immediately", "serviceId": "RCS",
         "setting": ["serviceParameters": [["key": "rcs.immediately", "value": "1"]]]]
    }

    /// 充电口盖开（RDO，back-charge-lid = 打开）
    static func chargeLidOpen() -> [String: Any] {
        ["command": "start", "serviceId": "RDO",
         "setting": ["serviceParameters": [["key": "key", "value": "back-charge-lid"]]]]
    }

    /// 充电口盖关（RDC，front-charge-lid = 关闭）
    static func chargeLidClose() -> [String: Any] {
        ["command": "stop", "serviceId": "RDC",
         "setting": ["serviceParameters": [["key": "key", "value": "front-charge-lid"]]]]
    }
}
