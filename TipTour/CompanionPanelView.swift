//
//  CompanionPanelView.swift
//  TipTour
//
//  SwiftUI content hosted inside the menu bar panel. Minimal layout:
//  status header, permissions setup or hotkey hint, optional workflow
//  checklist, neko toggle, developer section, footer. Dark aesthetic via DS.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var workflowRunner: WorkflowRunner = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if let activePlan = workflowRunner.activePlan,
               !activePlan.steps.isEmpty {
                Spacer().frame(height: 12)
                planChecklistSection(plan: activePlan)
                    .padding(.horizontal, 16)
            }

            if !companionManager.allPermissionsGranted {
                Spacer().frame(height: 16)
                permissionsListSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer().frame(height: 16)
                startButton
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer().frame(height: 14)
                nekoModeToggleRow
                    .padding(.horizontal, 16)

                Spacer().frame(height: 12)
                developerSection
                    .padding(.horizontal, 16)
            }

            Spacer().frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("TipTour")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            pinToggleButton

            Button(action: {
                NotificationCenter.default.post(name: .tipTourDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// Pushpin toggle. When on, the panel stays visible regardless of
    /// outside clicks. When off (default), the panel behaves like a
    /// standard menu bar popover.
    private var pinToggleButton: some View {
        Button(action: {
            companionManager.setPanelPinned(!companionManager.isPanelPinned)
        }) {
            Image(systemName: companionManager.isPanelPinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(
                    companionManager.isPanelPinned
                        ? DS.Colors.accent
                        : DS.Colors.textTertiary
                )
                .rotationEffect(.degrees(companionManager.isPanelPinned ? 0 : 45))
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(
                            companionManager.isPanelPinned
                                ? DS.Colors.accent.opacity(0.15)
                                : Color.white.opacity(0.08)
                        )
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(companionManager.isPanelPinned
            ? "Unpin: panel will close when you click outside"
            : "Pin: panel will stay open when you click outside")
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control + Option to talk.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet TipTour.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant the four below to keep using TipTour.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm TipTour.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Hold Control+Option, ask anything about what's on your screen, and I'll point right at it.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Grant the permissions below to get started.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Button(action: {
                companionManager.triggerOnboarding()
            }) {
                Text("Start")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Permissions List

    private var permissionsListSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow
            accessibilityPermissionRow
            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

            if !companionManager.allPermissionsGranted {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.top, 1)
                    Text("Everything stays on your Mac. Screenshots and audio are only sent to Gemini when you hold ⌃⌥ to talk.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            }
        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Accessibility")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("So I can move the cursor and read what's on screen.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if isGranted {
                grantedPill
            } else {
                HStack(spacing: 6) {
                    grantButton {
                        WindowPositionManager.requestAccessibilityPermission()
                    }
                    Button(action: {
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(isGranted
                         ? "So I can see your screen when you ask for help."
                         : "Quit and reopen after granting.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                grantedPill
            } else {
                grantButton {
                    WindowPositionManager.requestScreenRecordingPermission()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Content")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("Lets me read the screen continuously without picking a window each time.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if isGranted {
                grantedPill
            } else {
                grantButton {
                    companionManager.requestScreenContentPermission()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Microphone")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("So you can hold ⌃⌥ and talk to me.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if isGranted {
                grantedPill
            } else {
                grantButton {
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var grantedPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(DS.Colors.success)
                .frame(width: 6, height: 6)
            Text("Granted")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.success)
        }
    }

    private func grantButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Grant")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(DS.Colors.accent)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Neko Mode Toggle

    /// Whimsical toggle that swaps the blue triangle cursor for a
    /// pixel-art cat (classic oneko sprites).
    private var nekoModeToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cat.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(
                        companionManager.isNekoModeEnabled
                            ? DS.Colors.accent
                            : DS.Colors.textTertiary
                    )
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Neko mode")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("replace cursor with a pixel cat")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isNekoModeEnabled },
                set: { companionManager.setNekoModeEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Plan Checklist

    /// Minimal checklist shown while a workflow plan is active. Lists every
    /// step with the current one highlighted.
    private func planChecklistSection(plan: WorkflowPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                Text(plan.goal)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                if let app = plan.app, !app.isEmpty {
                    Text(app)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.06))
                        )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    planChecklistRow(
                        step: step,
                        index: index,
                        isCurrent: index == workflowRunner.activeStepIndex
                    )
                }
            }

            if let failureLabel = workflowRunner.currentStepResolutionFailureLabel {
                planResolutionFailurePrompt(failureLabel: failureLabel)
            }

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.top, 2)

            planControlsRow

            advanceOnAnyClickDebugToggleRow
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    /// Debug switch that tells ClickDetector to advance on any click.
    private var advanceOnAnyClickDebugToggleRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "ladybug")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            Text("Advance on any click")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            Spacer()
            Toggle("", isOn: Binding(
                get: { companionManager.advanceOnAnyClickEnabled },
                set: { companionManager.setAdvanceOnAnyClickEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.7)
        }
    }

    private struct PlanControlButtonStyle: ButtonStyle {
        let isPrimary: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundColor(isPrimary ? .white : DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isPrimary
                              ? DS.Colors.accent.opacity(configuration.isPressed ? 0.7 : 1.0)
                              : Color.white.opacity(configuration.isPressed ? 0.14 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
        }
    }

    private func planChecklistRow(step: WorkflowStep, index: Int, isCurrent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(isCurrent ? .white : DS.Colors.textTertiary)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(isCurrent ? DS.Colors.accent : Color.white.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(step.label ?? "(unlabeled)")
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundColor(isCurrent ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .lineLimit(1)

                    if isCurrent && workflowRunner.isResolvingCurrentStep {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                }
                if !step.hint.isEmpty {
                    Text(step.hint)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func planResolutionFailurePrompt(failureLabel: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.orange)

            Text("Can't find \"\(failureLabel)\"")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)

            Spacer()

            Button("Retry") {
                workflowRunner.retryCurrentStep()
            }
            .buttonStyle(PlanControlButtonStyle(isPrimary: false))

            Button("Skip") {
                workflowRunner.skipCurrentStep()
            }
            .buttonStyle(PlanControlButtonStyle(isPrimary: true))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
    }

    private var planControlsRow: some View {
        HStack(spacing: 8) {
            Button(role: .destructive) {
                workflowRunner.stop()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Stop")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(PlanControlButtonStyle(isPrimary: false))

            Spacer()

            Button {
                workflowRunner.skipCurrentStep()
            } label: {
                HStack(spacing: 4) {
                    Text("Skip step")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(PlanControlButtonStyle(isPrimary: true))
        }
    }

    // MARK: - Developer (bring-your-own-key)

    /// Collapsible section for source builds. Paste a Gemini API key and
    /// the app uses it directly via Keychain instead of hitting the Worker.
    @State private var isDeveloperSectionExpanded: Bool = false
    @State private var developerGeminiKeyInput: String = ""
    @State private var developerKeyStatus: String = ""

    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isDeveloperSectionExpanded.toggle()
                }
                if isDeveloperSectionExpanded {
                    developerGeminiKeyInput = KeychainStore.geminiAPIKey ?? ""
                    developerKeyStatus = ""
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "hammer")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)
                    Text("Developer")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Image(systemName: isDeveloperSectionExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isDeveloperSectionExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bring your own Gemini key")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.top, 8)

                    Text("For source builds. Paste a Gemini API key and TipTour uses it directly instead of the Cloudflare Worker proxy. Stored in macOS Keychain, never synced.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    SecureField("AIzaSy...", text: $developerGeminiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))

                    HStack(spacing: 6) {
                        Button("Save") {
                            KeychainStore.geminiAPIKey = developerGeminiKeyInput
                            developerKeyStatus = "Saved"
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .pointerCursor()
                        .disabled(developerGeminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Clear") {
                            developerGeminiKeyInput = ""
                            KeychainStore.geminiAPIKey = nil
                            developerKeyStatus = "Cleared"
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()

                        Text(developerKeyStatus)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)

                        Spacer()

                        Link(destination: URL(string: "https://aistudio.google.com/apikey")!) {
                            Text("Get a key ↗")
                                .font(.system(size: 10))
                                .foregroundColor(DS.Colors.accent)
                        }
                        .pointerCursor()
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Footer

    private var feedbackButton: some View {
        Button(action: {
            if let url = URL(string: "https://x.com/milindlabs") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 10))
                Text("Feedback")
                    .font(.system(size: 11))
            }
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var footerSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                feedbackButton

                #if DEBUG
                footerButton("Dev", systemImage: "wrench", toggled: showDevTools) {
                    showDevTools.toggle()
                }
                #endif

                Spacer()

                footerButton("Quit", systemImage: "power") {
                    NSApp.terminate(nil)
                }
            }

            #if DEBUG
            if showDevTools {
                devToolsSection
                    .padding(.top, 8)
            }
            #endif
        }
    }

    private func footerButton(
        _ title: String,
        systemImage: String,
        toggled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundColor(toggled ? DS.Colors.textSecondary : DS.Colors.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Dev Tools (DEBUG only)

    #if DEBUG
    @State private var showDevTools: Bool = false

    private var devToolsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            devToolRow("Detection Overlay", systemImage: "square.grid.3x3") {
                companionManager.showDetectionOverlay.toggle()
                if companionManager.showDetectionOverlay {
                    companionManager.startDetectionOverlayFeeding()
                } else {
                    NativeElementDetector.shared.stopLiveFeeding()
                }
                NotificationCenter.default.post(name: .tipTourDismissPanel, object: nil)
            } trailing: {
                Text(companionManager.showDetectionOverlay ? "On" : "Off")
                    .foregroundColor(companionManager.showDetectionOverlay ? DS.Colors.textSecondary : DS.Colors.textTertiary)
            }

            devToolRow("Test Cursor Flight", systemImage: "arrow.up.right") {
                let s = NSScreen.main!
                companionManager.detectedElementScreenLocation = CGPoint(x: s.frame.midX, y: s.frame.midY)
                companionManager.detectedElementDisplayFrame = s.frame
                companionManager.detectedElementBubbleText = "Test"
                NotificationCenter.default.post(name: .tipTourDismissPanel, object: nil)
            }

            devToolRow("Reset All", systemImage: "xmark.circle", destructive: true) {
                companionManager.clearDetectedElementLocation()
                companionManager.onboardingPromptText = ""
                companionManager.onboardingPromptOpacity = 0.0
                companionManager.showOnboardingPrompt = false
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DS.Colors.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
        )
    }

    private func devToolRow(
        _ title: String,
        systemImage: String,
        destructive: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundColor(destructive ? .red.opacity(0.7) : DS.Colors.textTertiary)
                    .frame(width: 16)

                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(destructive ? .red.opacity(0.7) : DS.Colors.textSecondary)

                Spacer()

                trailing()
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(DevToolRowButtonStyle())
        .pointerCursor()
    }

    private struct DevToolRowButtonStyle: ButtonStyle {
        @State private var isHovered = false

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(configuration.isPressed
                              ? DS.Colors.surface4
                              : isHovered ? DS.Colors.surface3 : Color.clear)
                )
                .onHover { isHovered = $0 }
        }
    }
    #endif

    // MARK: - Visuals

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }
}
