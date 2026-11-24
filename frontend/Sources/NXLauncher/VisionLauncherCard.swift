import SwiftUI
import NXCore
import NXModel

/// The Build page for an Apple Vision Pro, in two steps, in place of the iPhone's Install card. Step 1 puts the app (the
/// launcher) on the headset, once, with no game: it needs the headset and a signing team. Step 2 is the build itself: it needs
/// the team only (it signs the game's code) and ends on this Mac, where the app on the headset downloads the game from.
package struct VisionLauncherCard: View {
    @ObservedObject var devices: DeviceStore
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer
    @State private var firstTimeOpen = false

    let showLocked: Bool

    package init(devices: DeviceStore, build: BuildStore, showLocked: Bool = true) {
        self.showLocked = showLocked
        self.devices = devices
        self.build = build
    }

    package var body: some View {
        if build.target != BuildTarget.mac, build.visionTarget, !build.running || showLocked {
            cards.disabled(build.running)
                .onAppear { prepare() }
                .onChange(of: build.visionTarget) { _ in prepare() }
        }
    }

    /// The IPA export is the iPhone's: a headset is never built for it. And a device of the other kind is not kept.
    private func prepare() {
        guard build.visionTarget else { return }
        if devices.exportIPA { devices.exportIPA = false }
        if let chosen = devices.devices.first(where: { $0.id == devices.installDevice }), chosen.platform != .visionos { devices.installDevice = "" }
        if !devices.checked { _ = devices.refresh() }
        build.syncShelf()
    }

    @ViewBuilder private var cards: some View {
        let options = [(value: "", label: loc.t("dev.none"))] + devices.devices.filter { $0.platform == .visionos }.map { d in
            (value: d.id, label: d.name + (d.reachable ? "" : " (" + loc.t("dev.notConnected") + ")"))
        }
        let teams = devices.teams.map { (value: $0.id, label: $0.label(personalTeam: loc.t("dev.personalTeam"))) }
        // What the launcher's install and a game's build share, in a section of its own: the headset and the team
        CardGroup(loc.t("shell.visionSetup"), footnote: loc.t("shell.visionSetupNote")) {
            CardRow(loc.t("shell.headset"), detail: devices.checked && options.count == 1 ? loc.t("dev.noDevices") : "") {
                RefreshDevicesButton(devices: devices)
                LauncherDropdown(options: options, selection: devices.installDevice, label: loc.t("shell.headset")) { devices.installDevice = $0 }
            }
            CardDivider()
            if teams.isEmpty {
                CardRow(loc.t("dev.team"), detail: loc.t("dev.noTeam"), dot: LauncherPalette.building) { EmptyView() }
            } else {
                CardRow(loc.t("dev.team")) {
                    LauncherDropdown(options: teams, selection: devices.signingTeam, label: loc.t("dev.team")) { devices.signingTeam = $0 }
                }
            }
            // What a headset needs before its first install, here with the settings and not after the install it would have stopped
            CardDivider()
            CardDisclosure(loc.t("shell.headsetFirstTime"), detail: loc.t("dev.firstInstallGuide.subtitle"), isOpen: firstTimeOpen) {
                withAnimation(.easeInOut(duration: 0.18)) { firstTimeOpen.toggle() }
            }
            if firstTimeOpen {
                VStack(alignment: .leading, spacing: 10) {
                    step("1", loc.t("dev.firstInstallGuide.devModeTitle"), loc.t("shell.headsetDevMode"))
                    step("2", loc.t("dev.firstInstallGuide.trustTitle"), loc.t("shell.headsetTrust"))
                }
                .padding(.horizontal, 18).padding(.top, 2).padding(.bottom, 14)
            }
        }
        CardGroup(loc.t("shell.launcherStep"), footnote: loc.t("shell.launcherNote")) {
            CardRow(loc.t("shell.launcherTitle")) {
                Button(loc.t("shell.installLauncher")) { build.installLauncher() }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .disabled(!build.canInstallLauncher)
            }
        }
    }

    private func step(_ index: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(index).font(.manrope(11.5, .bold)).monospacedDigit().foregroundStyle(LauncherPalette.cream)
                .frame(width: 20, height: 20).background(LauncherPalette.ink(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.manrope(13, .semibold))
                Text(text).font(.manrope(12.5)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
