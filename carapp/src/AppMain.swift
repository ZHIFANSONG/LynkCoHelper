//
//  AppMain.swift
//  App 入口
//

import SwiftUI

@main
struct CarCtrlApp: App {
    @AppStorage("appearance") private var appearance = "auto"

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(
                    appearance == "dark" ? .dark :
                    appearance == "light" ? .light : nil)
        }
    }
}

struct RootView: View {
    var body: some View {
        ContentView()
    }
}
