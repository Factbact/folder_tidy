import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct FolderTidyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var organizer = FileOrganizer()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(organizer)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Folder Tidy", systemImage: "folder.badge.gearshape") {
            MenuBarContentView()
                .environmentObject(organizer)
        }
        .menuBarExtraStyle(.window)
    }
}
