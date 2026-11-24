import SwiftUI
import NXCore
import NXLauncher
import NXModel

// The Builds page: the cards in the order a build goes, from the files to the progress. It only arranges them (CardPages.swift
// scrolls them). Each card observes the stores it shows (NXLauncher, and `FilesCard` here), so a change in one store redraws that
// card and no other.

struct BuildPage: View {
    let build: BuildStore
    let running: Bool
    /// An Apple Vision Pro is chosen: nothing hides while something runs, and the progress and the outcome show under the section
    /// they belong to, the launcher's or the games'.
    var vision = false
    var launcherOperation = false
    let repo: RepoStore
    let dependencies: DependencyStore
    let devices: DeviceStore
    @ObservedObject var queue: BuildQueueStore
    let transfers: TransferQueueStore
    var onSelectGames: () -> Void = {}
    @Binding var extrasOpen: Bool   // the optional input rows of the files card
    @Binding var logOpen: Bool   // the log card's disclosure
    @State private var showRunningSetup = false
    var onViewGame: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let stagingQueue = !running && queue.hasWaiting
        CardPageHeading(loc.t("build.heading"), note: loc.t("build.intro"))
        if running, !vision {
            ProgressCard(build: build)
            CardDisclosure(loc.t("section.setup"), detail: build.gameName, isOpen: showRunningSetup) { showRunningSetup.toggle() }
                .accessibilityLabel(loc.t("section.setup"))
                .accessibilityValue([build.gameName, loc.t(showRunningSetup ? "onboarding.expanded" : "onboarding.collapsed")]
                    .filter { !$0.isEmpty }.joined(separator: ", "))
                .onDisappear { showRunningSetup = false }
        }
        if !running || showRunningSetup || vision {
            EngineSwitcherCard(build: build)
            SetupHintCard(
                repo: repo,
                dependencies: dependencies,
                usesExternalUpstream: build.usesExternalUpstreamRepo,
                onOpenSettings: onOpenSettings
            )
            if stagingQueue {
                BuildQueueCard(queue: queue, onSelectGames: onSelectGames)
            } else if !queue.hasWaiting {
                FilesCard(build: build, extrasOpen: $extrasOpen)
            }
            TargetCard(build: build)
        }
        InstallCard(devices: devices, build: build, showLocked: showRunningSetup)
        VisionLauncherCard(devices: devices, build: build, showLocked: true)
        if vision, launcherOperation { results }
        // An Apple Vision Pro: Games is a section like the launcher's (the queue and the build button), what the build does
        // shows below it, and the log, which is the launcher's install's too, is the last section
        if !stagingQueue {
            BuildQueueCard(queue: queue, title: vision ? loc.t("shell.gamesStep") : nil, footnote: vision ? loc.t("shell.gamesStepNote") : "",
                           onSelectGames: onSelectGames)
        }
        if vision {
            ActionCard(build: build, dependencies: dependencies, repo: repo, devices: devices)
            if !launcherOperation { results }
            TransferCard(transfers: transfers) { build.revealTransfer($0) }
            logCard
        } else {
            TransferCard(transfers: transfers) { build.revealTransfer($0) }
            logCard
            ActionCard(build: build, dependencies: dependencies, repo: repo, devices: devices)
        }
        if !vision { results }
    }

    private var logCard: some View {
        LogCard(log: build.log, devices: devices, isOpen: $logOpen,
                showRequests: BuildNotifier.shared.$showLog.eraseToAnyPublisher(),   // a clicked notification of a failed build
                didShow: { BuildNotifier.shared.showLog = false })
    }

    /// What an operation asks and tells: the copy question, the failure, the outcome, and its stages (on top of the page while a
    /// Mac or iPhone build runs, so here only once it ended. For a Vision Pro always here, in its section).
    @ViewBuilder private var results: some View {
        if vision { ProgressCard(build: build) }   // what ran, then what came of it
        ShellCopyCard(devices: devices)
        BuildFailureCard(m: build)
        OutcomeCard(build: build, devices: devices, onViewGame: onViewGame)
        if !running, !vision { ProgressCard(build: build) }
    }
}
