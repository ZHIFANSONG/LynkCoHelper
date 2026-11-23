//
//  FindCarView.swift
//  寻车：地图定位 + 闪灯鸣笛 + 步行导航入口
//  说明：SDK 里 _MapKit_SwiftUI.tbd 是空壳，SwiftUI 版 Map 链接不过，
//        这里用 MKMapView + UIViewRepresentable 走 UIKit 路线。
//

import SwiftUI
import MapKit
import UIKit

struct FindCarView: View {
    @ObservedObject var store: CarStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.bg(scheme).ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        mapCard
                        addressCard
                        actionCard
                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                }
            }
            .navigationTitle("寻车")
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

    private var carCoordinate: CLLocationCoordinate2D {
        store.status.hasLocation
            ? store.status.location
            : CLLocationCoordinate2D(latitude: 34.795616, longitude: 113.802925)
    }

    private var mapCard: some View {
        GlassCard(radius: 20) {
            if store.status.hasLocation {
                CarMapView(coordinate: carCoordinate)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .allowsHitTesting(true)
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "location.slash")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Palette.sub(scheme))
                    Text("车辆暂未上报位置")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.text(scheme))
                    Text("车机处于休眠或地库无信号时会缺失，唤醒车辆后再刷新")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.sub(scheme))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.card2(scheme)))
            }
        }
    }

    private var addressCard: some View {
        GlassCard {
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.brand)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.status.hasLocation
                         ? String(format: "%.5f, %.5f", store.status.latitude, store.status.longitude)
                         : "车辆位置暂未上报")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(store.status.hasLocation ? Palette.text(scheme) : Palette.sub(scheme))
                    Text(store.status.hasLocation
                         ? (store.status.posTrusted ? "定位可信" : "定位精度较低")
                         : "车机熄火或在地库时可能无定位")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.sub(scheme))
                }
                Spacer()
                Button {
                    Haptics.tap()
                    openInMaps()
                } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Palette.brand)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actionCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                Button {
                    Haptics.rigid()
                    store.run("find", CarCommand.flashHorn("horn-light-flash"),
                              successText: "寻车指令已发送")
                } label: {
                    HStack(spacing: 8) {
                        if store.busyAction == "find" {
                            ProgressView().tint(Palette.brand)
                        } else {
                            Image(systemName: "light.beacon.max.fill")
                        }
                        Text("闪灯鸣笛")
                            .font(.system(size: 14.5, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Palette.brand.opacity(0.15)))
                    .foregroundStyle(Palette.brand)
                }
                .buttonStyle(.plain)
                .disabled(store.busyAction != nil)

                HStack(spacing: 10) {
                    hornButton("只闪灯", "light-flash")
                    hornButton("只鸣笛", "horn")
                }

                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                    Text("车辆最后更新时间 \(store.status.updatedAgo)")
                        .font(.system(size: 11))
                }
                .foregroundStyle(store.status.isStale ? Color.orange : Palette.sub(scheme))
            }
        }
    }

    private func hornButton(_ title: String, _ value: String) -> some View {
        Button {
            Haptics.tap()
            store.run("find", CarCommand.flashHorn(value), successText: "\(title)指令已发送")
        } label: {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Palette.line(scheme), lineWidth: 1))
                .foregroundStyle(Palette.text(scheme))
        }
        .buttonStyle(.plain)
        .disabled(store.busyAction != nil)
    }

    private var timeText: String { store.status.updatedAgo }

    private func openInMaps() {
        guard store.status.hasLocation else { return }
        let p = store.status.location
        let item = MKMapItem(placemark: MKPlacemark(coordinate: p))
        item.name = "我的车"
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking,
        ])
    }
}

/// UIKit 版地图，绕开 SDK 里残缺的 _MapKit_SwiftUI
struct CarMapView: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> MKMapView {
        let v = MKMapView()
        v.delegate = context.coordinator
        v.isRotateEnabled = false
        v.isPitchEnabled = false
        v.showsCompass = false
        v.showsUserLocation = false
        v.pointOfInterestFilter = .excludingAll
        return v
    }

    func updateUIView(_ v: MKMapView, context: Context) {
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006))
        v.setRegion(region, animated: false)

        let old = v.annotations.compactMap { $0 as? MKPointAnnotation }
        if let first = old.first, old.count == 1,
           abs(first.coordinate.latitude - coordinate.latitude) < 1e-9,
           abs(first.coordinate.longitude - coordinate.longitude) < 1e-9 {
            return
        }
        v.removeAnnotations(v.annotations)
        let a = MKPointAnnotation()
        a.coordinate = coordinate
        a.title = "我的车"
        v.addAnnotation(a)
    }

    final class Coord: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is MKPointAnnotation else { return nil }
            let id = "carPin"
            let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            v.annotation = annotation
            v.markerTintColor = UIColor(red: 0.32, green: 0.78, blue: 0.45, alpha: 1.0)
            v.glyphImage = UIImage(systemName: "car.fill")
            v.displayPriority = .required
            v.canShowCallout = false
            return v
        }
    }
}
