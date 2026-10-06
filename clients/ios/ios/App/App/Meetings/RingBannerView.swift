import SwiftUI

enum RingBannerCopy {
    static let subtitle = "Invites you to join"
    static let notNow = "Not now"
    static let switchCall = "Switch"
    /// The simulator's in-app incoming ring only (CallKit cannot show its
    /// incoming screen there; RingCenter.systemEndsIncomingCalls).
    static let decline = "Decline"
    static let answer = "Answer"
}

enum RingBannerStyle {
    /// The one cyan thing on the banner: the action that joins.
    static let switchFill: SuiteColor = .info
    static let switchLabel: SuiteColor = .onInfo
    static let notNowOutline: SuiteColor = .border
    static let fill: SuiteColor = .surfaceMuted
    static let edge: SuiteColor = .border
}

struct RingBanner: View {
    let invite: RingInvite
    var notNow: () -> Void = {}
    var switchCall: () -> Void = {}
    /// The outline (left) and filled (right) buttons' labels.
    var secondaryLabel = RingBannerCopy.notNow
    var primaryLabel = RingBannerCopy.switchCall

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(SuiteColor.surface.color)
                    Text(invite.initial)
                        .font(SuiteFont.body(.semibold))
                        .foregroundStyle(SuiteColor.onSurface.color)
                }
                .frame(width: 40, height: 40)
                .dynamicTypeSize(...InCallStyle.fixedGeometryCap)
                VStack(alignment: .leading, spacing: 2) {
                    Text(invite.title)
                        .font(SuiteFont.body(.semibold))
                        .foregroundStyle(SuiteColor.onSurface.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ring-banner-title")
                    Text(RingBannerCopy.subtitle)
                        .font(SuiteFont.caption())
                        .foregroundStyle(SuiteColor.muted.color)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button(action: notNow) {
                    Text(secondaryLabel)
                        .font(SuiteFont.body(.semibold))
                        .foregroundStyle(SuiteColor.onSurface.color)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: SuiteRadius.field, style: .continuous)
                                .strokeBorder(RingBannerStyle.notNowOutline.color, lineWidth: 1))
                }
                .accessibilityIdentifier("ring-banner-not-now")
                Button(action: switchCall) {
                    Text(primaryLabel)
                        .font(SuiteFont.body(.semibold))
                        .foregroundStyle(RingBannerStyle.switchLabel.color)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            RingBannerStyle.switchFill.color,
                            in: RoundedRectangle(cornerRadius: SuiteRadius.field, style: .continuous))
                }
                .accessibilityIdentifier("ring-banner-switch")
            }
            .buttonStyle(.plain)
        }
        .padding(InCallStyle.gutter)
        .background(RingBannerStyle.fill.color, in: RoundedRectangle(cornerRadius: SuiteRadius.box, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SuiteRadius.box, style: .continuous)
                .strokeBorder(RingBannerStyle.edge.color, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

/// The simulator's in-app incoming ring, full screen on `surface`.
struct IncomingRingPrompt: View {
    let invite: RingInvite
    var decline: () -> Void = {}
    var answer: () -> Void = {}

    var body: some View {
        VStack {
            Spacer()
            RingBanner(
                invite: invite, notNow: decline, switchCall: answer,
                secondaryLabel: RingBannerCopy.decline, primaryLabel: RingBannerCopy.answer
            )
            .frame(maxWidth: SuiteLayout.sheetWidth)
            Spacer()
        }
        .padding(InCallStyle.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SuiteColor.surface.color.ignoresSafeArea())
    }
}
