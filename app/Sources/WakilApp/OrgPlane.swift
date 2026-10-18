import Foundation
import WakilKit
import SwiftUI

/// ⌘⇧O's org plane (spec §8). An organisation is a credential boundary
/// (Invariant 4); this is the one surface an operator uses to see every
/// organisation on this machine, create one, adopt an existing account into
/// one, and switch between them.
///
/// **Composed on `design-language.md` §3's near plane, exactly as
/// `ConfirmationPlane` is** — full scale, brightest, no dimming modifiers on
/// the plane's own content. Read that file first; this one matches its
/// structure (a `black.opacity(0.86)` slab, `cornerRadius: 12`, `width: 520`,
/// `shadow(radius: 30)`) rather than re-deriving §3 from scratch. The one
/// deliberate difference: `ConfirmationPlane` is edged in §5's destructive
/// red because it confirms a destructive act; an org switch is not
/// destructive, so this is edged in the ordinary half-pixel luminous slab
/// border instead (`OrgPlane.dc.html`'s own comment).
///
/// **Five states, all local `@State`** (brief §2, `OrgStates.dc.html`):
/// Choosing, Creating, Adopting, Switching, Error. The state machine
/// lives here, in the view, because almost none of it is state `WakilKit`
/// owns — except `switching` (Task 10), which genuinely is window state, and
/// is read directly rather than mirrored, so a plane closed and reopened
/// mid-switch still shows the truth (`effectivePhase` below). There is no
/// Queued state any more (background agents 3 of 4): a switch never waits
/// on a turn, because it stops nothing.
///
/// **Invariant 2.** Nothing here mutates organisation/provider/account state
/// except by calling a `WindowModel` method that itself dispatches through
/// the registry (`listOrgs`, `createOrg`, `listMachineProviders`,
/// `adoptProvider`, `requestOrganizationSwitch`) — the same path the command palette dispatches
/// every other control through. `phase`/`switchTarget`/the form fields below
/// are presentation state only, the same status the open palette (`palette`)
/// has in `WakilWindow`.
struct OrgPlane: View {
    let model: WindowModel

    private enum Phase: Equatable {
        case choosing
        case creating
        case adopting(org: String)
        case switching(target: String)
        case error(target: String, reason: String)
    }

    @State private var phase: Phase = .choosing
    /// The org this plane most recently asked `requestOrganizationSwitch`
    /// for — set the instant the operator picks a row, before the model has
    /// said whether it switched or refused.
    @State private var switchTarget: String?
    @State private var orgs: [WindowModel.OrgListing] = []
    @State private var machineProviders: [WindowModel.MachineProviderListing] = []
    @State private var creatingName = ""
    @State private var creatingId = ""
    /// Latches `true` the moment the operator types into the Identifier
    /// field directly (`identifierBinding`'s setter, below). Once true, the
    /// Name field stops proposing a slug over whatever the operator typed
    /// by hand — spec §8.1.1 / §9: "once the operator edits the identifier
    /// by hand, stop overwriting it from the name."
    @State private var identifierManuallyEdited = false
    @State private var creatingJiraBase = ""
    @State private var creatingError: String?
    @State private var adoptError: String?
    /// Whether this plane has itself driven a switch attempt this session.
    /// Distinguishes a genuinely org-less LAUNCH (§8.5 — `WAKIL_ORG` unset,
    /// or naming an org that does not exist) from a window that reached
    /// `organization == ""` a completely different way, mid-session: a
    /// switch this very plane attempted whose `orgSwitcher` failed
    /// (`setOrganization`'s own doc comment on that branch). Both leave
    /// `model.organization` empty; only the first is a launch fact, and
    /// only the first should show the amber "WAKIL_ORG named …" banner.
    @State private var hasAttemptedSwitchThisSession = false

    /// §5's reserved destructive red — the same idiom `ConfirmationPlane`
    /// and `WakilWindow` already use for it (`Color(hex:)` does not exist in
    /// this target).
    private var destructive: Color { Color(red: 0.910, green: 0.361, blue: 0.361) }   // #e85c5c
    /// §5's reserved amber — pending/caution, used here for the `--share`
    /// warning and the "WAKIL_ORG named an unknown org" banner, exactly as
    /// both artboards draw it.
    private var caution: Color { Color(red: 0.910, green: 0.706, blue: 0.353) }       // #e8b45a
    /// The current-row / queued-row accent violet the artboards use for the
    /// left-edge tick (`OrgPlane.dc.html`, `OrgStates.dc.html`).
    private var accent: Color { Color(VoidPalette.accent) }  // #9e82ff
    private var coolWhite: Color { Color(red: 0.910, green: 0.925, blue: 0.965) }     // #e8ecf6

    /// The phase actually drawn — `phase` itself, unless the window's own
    /// switch state disagrees, which it can when this plane is reopened
    /// mid-switch (Task 14 ruling T14-R2: the plane must read `switching`,
    /// not merely hold a local copy of what it thinks is happening).
    private var effectivePhase: Phase {
        if model.switching {
            return .switching(target: switchTarget ?? "")
        }
        return phase
    }

    /// Whether Esc may dismiss the whole plane — spec §8.5: only once an
    /// organisation is open. An org-less window has nothing behind the
    /// plane to return to; `OrgFirstRun.dc.html`'s own comment is "there is
    /// nothing behind it to use".
    private var canDismiss: Bool { !model.organization.isEmpty }

    private var phaseKey: String {
        switch effectivePhase {
        case .choosing: return "choosing"
        case .creating: return "creating"
        case .adopting(let org): return "adopting:\(org)"
        case .switching(let target): return "switching:\(target)"
        case .error(let target, _): return "error:\(target)"
        }
    }

    var body: some View {
        ZStack {
            // The dimmer: `rgba(3,4,8,0.58)` in `OrgPlane.dc.html`, over the
            // void's own field colour. A real (if near-transparent) view, so
            // it also swallows clicks meant for whatever is behind it —
            // `ConfirmationPlane`'s backdrop in `Canvas.swift` does the same
            // with no extra modifier needed.
            Color(red: 0.012, green: 0.016, blue: 0.031).opacity(0.58)
                .ignoresSafeArea()

            planeContent

            // **Esc, and the reason it is a button.** §8.5 gives this plane
            // an Esc affordance once an organisation is open, and the
            // footer below promises one in so many words ("Esc to
            // dismiss"). `.onExitCommand` was that mechanism and never
            // fired: on macOS it delivers only to a view in the key
            // window's first-responder chain, and this plane is an ordinary
            // `ZStack` child of `WakilWindow` (`WakilWindow.swift`) that
            // never takes focus — nothing in the Choosing state is
            // focusable at all. The handler was correct and simply never
            // received the key, so the acceptance walk found a plane whose
            // own footer said "Esc to dismiss" over an org that Esc would
            // not leave.
            //
            // `.keyboardShortcut(.cancelAction)` binds Escape through the
            // window's key-equivalent path instead, which does not depend
            // on focus — the same reason it keeps working while a TextField
            // in the Creating or Adopting form holds it.
            //
            // **Rendered, not `.hidden()`.** A hidden view is removed from
            // the window's key-equivalent search along with everything
            // else, which would reintroduce the bug in a quieter form; a
            // zero-size transparent button stays in it and draws nothing.
            // `canDismiss` is checked in the action rather than by omitting
            // the button, so an org-less plane swallows Esc deliberately
            // (§8.5: there is nothing behind it to return to) instead of
            // letting it fall through to whatever is underneath.
            Button("") {
                guard canDismiss else { return }
                model.showOrgPlane = false
            }
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .task(id: phaseKey) {
            // Fix 2: a stale adopt error must not survive a change of
            // target org, nor outlive the Adopting phase itself. `phaseKey`
            // already encodes the target org for `.adopting` and changes on
            // every phase transition, so clearing here — the same
            // phase-scoped hook `refreshOrgs()`/`refreshMachineProviders()`
            // below already use — covers both without a second mechanism.
            adoptError = nil
            switch effectivePhase {
            case .choosing:
                await refreshOrgs()
            case .adopting:
                await refreshOrgs()
                await refreshMachineProviders()
            default:
                break
            }
        }
        // Kept alongside the `.cancelAction` button above rather than
        // replaced by it: this is the path that fires when the plane's own
        // content DOES hold focus, and the two agree on both the guard and
        // the effect, so whichever arrives first is the same dismissal.
        .onExitCommand {
            guard canDismiss else { return }
            model.showOrgPlane = false
        }
    }

    @ViewBuilder
    private var planeContent: some View {
        switch effectivePhase {
        case .choosing:
            choosingPlane
        case .creating:
            creatingPlane
        case .adopting(let org):
            adoptingPlane(org: org)
        case .switching(let target):
            switchingPlane(target: target)
        case .error(let target, let reason):
            errorPlane(target: target, reason: reason)
        }
    }

    // MARK: - Data

    private func refreshOrgs() async {
        orgs = await model.listOrgs()
    }

    private func refreshMachineProviders() async {
        machineProviders = await model.listMachineProviders()
    }

    // MARK: - Switching

    /// Starts a switch to `org` — the one entry point every row that can
    /// initiate one (Choosing's row list, Adopting's offer) calls.
    private func beginSwitch(to org: String) {
        switchTarget = org
        phase = .switching(target: org)
        Task {
            await model.requestOrganizationSwitch(org)
            resolveSwitch(target: org)
        }
    }

    /// Reads what happened to a switch to `target`, once
    /// `requestOrganizationSwitch` has returned: it switched, or an early
    /// guard refused it or the restart failed. Nothing is asked first and
    /// nothing queues, so the switch's own return is the whole outcome.
    private func resolveSwitch(target: String) {
        // A later switch from this plane has taken over: its own call resolves it.
        guard switchTarget == target else { return }
        if model.organization == target {
            switchTarget = nil
            phase = .choosing
            // T14-R1: a SUCCESSFUL switch dismisses the plane. Nothing in
            // any of the three artboards draws a "success" state — the
            // honest reading is that this plane's job was to get the
            // window to the new organisation, and it just did.
            model.showOrgPlane = false
        } else if !model.switching {
            // Not running any more, and not the target: refused (an early
            // guard) or failed (`orgSwitcher` came back with diagnostics).
            // Either way `status` names it.
            hasAttemptedSwitchThisSession = true
            phase = .error(target: target, reason: model.status)
            switchTarget = nil
        }
    }

    // MARK: - Choosing

    private var launchReason: String? {
        guard model.organization.isEmpty, !hasAttemptedSwitchThisSession else { return nil }
        guard let named = ProcessInfo.processInfo.environment["WAKIL_ORG"], !named.isEmpty else {
            return nil
        }
        guard !orgs.contains(where: { $0.name == named }) else { return nil }
        return named
    }

    private var choosingPlane: some View {
        plane {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    microLabel("Organisation")
                    Spacer()
                    Text("⌘⇧O")
                        .font(.system(size: 9, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(coolWhite.opacity(0.52))
                }

                // `OrgFirstRun.dc.html`: the primary sentence is always
                // drawn for an org-less window, and the amber banner is
                // ADDITIONAL to it, not a replacement for it (fix round 1,
                // Minor 4 — this used to show one or the other, which
                // dropped the "or create it" sentence entirely on exactly
                // the launch this banner exists to explain).
                if model.organization.isEmpty {
                    Text(
                        launchReason != nil
                            ? "Wakil could not open the organisation it was launched with. "
                                + "Choose one, or create it."
                            : "Wakil holds one organisation at a time. Choose the one to open."
                    )
                    .font(.system(size: 15))
                    .foregroundStyle(coolWhite.opacity(0.86))
                }
                if let named = launchReason {
                    warningBox(
                        icon: "exclamationmark.triangle",
                        color: caution,
                        text: "WAKIL_ORG named \(named), which is not a registered organisation")
                }

                scrollingWhenTall {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(orgs) { org in
                        let isCurrent = org.name == model.organization
                        OrgRow(
                            name: org.name, displayName: org.displayName,
                            jiraBase: org.jiraBase, accounts: org.accounts,
                            isCurrent: isCurrent, accent: accent, coolWhite: coolWhite,
                            onSwitch: {
                                // §8.6.1: the row's PRIMARY action is the
                                // switch, through the one path every
                                // switch-initiating row uses.
                                guard !isCurrent else { return }
                                beginSwitch(to: org.name)
                            },
                            onAdopt: {
                                // §8.6: adoption is reachable from the row
                                // even when it names the CURRENT org — no
                                // switch is involved there at all, the
                                // account just becomes available to ⌘P.
                                phase = .adopting(org: org.name)
                            }
                        )
                    }
                    ActionRow(
                        title: "New organisation", identifier: "org.plane.create",
                        coolWhite: coolWhite
                    ) {
                        creatingName = ""
                        creatingId = ""
                        identifierManuallyEdited = false
                        creatingJiraBase = ""
                        creatingError = nil
                        phase = .creating
                    }
                }
                }

                HStack {
                    microLabel(canDismiss ? "Esc to dismiss" : "No organisation is open \u{00b7} nothing behind this plane")
                    Spacer()
                    if canDismiss {
                        microLabel("Panes, drafts and the thread are cleared")
                    }
                }
            }
        }
    }

    // MARK: - Creating

    /// Writing through this binding (the Identifier field's own text
    /// binding, and ONLY that field's) is what latches
    /// `identifierManuallyEdited` — the Name field below assigns
    /// `creatingId` directly, bypassing this setter, so deriving a slug
    /// from a Name edit never itself counts as a manual edit.
    private var identifierBinding: Binding<String> {
        Binding(
            get: { creatingId },
            set: { newValue in
                identifierManuallyEdited = true
                creatingId = newValue
            })
    }

    private var creatingPlane: some View {
        plane {
            VStack(alignment: .leading, spacing: 18) {
                microLabel("New organisation")

                VStack(alignment: .leading, spacing: 9) {
                    microLabel("Name")
                    TextField("Initech Labs", text: $creatingName)
                        .accessibilityIdentifier("org.create.name")
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(coolWhite)
                        .padding(10)
                        .background(coolWhite.opacity(0.055))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onChange(of: creatingName) { _, newValue in
                            // §8.1.1 / §9: propose a slug from the name
                            // until the operator has edited the identifier
                            // by hand — never after.
                            guard !identifierManuallyEdited else { return }
                            creatingId = WindowModel.slugForOrgIdentifier(from: newValue) ?? ""
                        }
                }

                VStack(alignment: .leading, spacing: 9) {
                    microLabel("Identifier")
                    TextField("initech-labs", text: identifierBinding)
                        .accessibilityIdentifier("org.create.identifier")
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(coolWhite)
                        .padding(10)
                        .background(coolWhite.opacity(0.055))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline) {
                        microLabel("Jira site")
                        Spacer()
                        Text("Optional").font(.system(size: 9)).foregroundStyle(coolWhite.opacity(0.50))
                    }
                    TextField("https://your-site.atlassian.net/browse", text: $creatingJiraBase)
                        .accessibilityIdentifier("org.create.jiraBase")
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(coolWhite)
                        .padding(10)
                        .background(coolWhite.opacity(0.055))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    // §8.3: `ctx_create_org`'s own refusal (Go's
                    // `normaliseOrg` rule), rendered VERBATIM rather than a
                    // Swift re-implementation of the same rule —
                    // `OrgStates.dc.html`'s own comment names exactly the
                    // failure mode that guards against: two copies of one
                    // rule agreeing to stay in step until they quietly do
                    // not (`VoidPalette.forEnvironment`/`writeGate`'s prior
                    // drift).
                    if let creatingError {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "xmark.circle").foregroundStyle(destructive)
                            Text(creatingError)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(destructive)
                        }
                    }
                }

                // THERE IS DELIBERATELY NO "DEFAULT PROVIDER" FIELD HERE —
                // `OrgStates.dc.html`'s own comment on the Creating state:
                // Go refuses a default provider at creation by construction
                // (the id must already name a provider registered under an
                // org that does not exist yet), so this field would render
                // a refusal on every single use. It is settable later, via
                // `SaveOrg`, which belongs with Adopting.

                HStack(spacing: 10) {
                    Spacer()
                    quietButton("Cancel", id: "org.create.cancel") { phase = .choosing }
                    button(
                        "Create", id: "org.create.submit",
                        disabled: creatingId.trimmingCharacters(in: .whitespaces).isEmpty
                    ) {
                        Task {
                            creatingError = nil
                            let id = creatingId.trimmingCharacters(in: .whitespaces)
                            let displayName = creatingName.trimmingCharacters(in: .whitespaces)
                            let jiraBase = creatingJiraBase.trimmingCharacters(in: .whitespaces)
                            let succeeded = await model.createOrg(
                                id: id, displayName: displayName.isEmpty ? nil : displayName,
                                jiraBase: jiraBase.isEmpty ? nil : jiraBase)
                            if succeeded {
                                await refreshOrgs()
                                phase = .adopting(org: id)
                            } else {
                                creatingError = model.status
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Adopting

    private func adoptingPlane(org: String) -> some View {
        // The de-duplication and exclusion logic lives in `WakilKit`
        // now — `WindowModel.adoptionCandidates(from:excluding:)` — not
        // here (Task 14, fix round 1, Important 1): it is a pure function
        // of `[MachineProviderListing]` and a target org with no SwiftUI
        // dependency, it has had two identity bugs in this file, and only
        // `WakilKit` has a test target to pin it with.
        let rows = WindowModel.adoptionCandidates(from: machineProviders, excluding: org)
        return plane {
            VStack(alignment: .leading, spacing: 18) {
                microLabel("Adopt an account into \(org)")

                // Fix 3: an empty candidate list is a real, common state
                // (every account on this machine already registered in
                // `org`) — it must say so rather than render as a blank
                // gap. "Register a new account" and Done/"Switch to `org`
                // now" below stay visible and working either way.
                if rows.isEmpty {
                    Text("Every account on this machine is already registered in \(org). "
                        + "There is nothing left to adopt.")
                        .font(.system(size: 13))
                        .foregroundStyle(coolWhite.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    scrollingWhenTall {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { row in
                            MachineProviderRow(
                                homeName: row.homeOrg ?? row.org, providerId: row.providerId,
                                configDir: row.configDir, kind: row.kind, label: row.label,
                                coolWhite: coolWhite
                            ) { targetId in
                                Task {
                                    adoptError = nil
                                    let succeeded = await model.adoptProvider(
                                        org: org, id: targetId,
                                        configDir: row.configDir ?? "", kind: row.kind, label: row.label)
                                    if succeeded {
                                        await refreshMachineProviders()
                                        await refreshOrgs()
                                    } else {
                                        adoptError = model.status
                                    }
                                }
                            }
                        }
                    }
                    }
                }

                if let adoptError {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "xmark.circle").foregroundStyle(destructive)
                        Text(adoptError)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(destructive)
                    }
                }

                // §8.4: the `--share` warning the CLI already prints.
                // Hiding it would make `--share` feel like a MOVE rather
                // than a binding — the one genuinely surprising thing about
                // a shared account (T14-R3): a plain `claude` session
                // started in that config dir still runs as the account's
                // own organisation, never as `org`, and only inside Wakil
                // does it run as `org`. Shown whenever there is a candidate
                // to adopt, since adopting any one of them creates exactly
                // that binding.
                if !rows.isEmpty {
                    warningBox(
                        icon: "exclamationmark.triangle", color: caution,
                        text: "Adopting binds an account into \(org) without moving its "
                            + "credential home. A plain claude session in its config dir "
                            + "still runs as the account's own organisation \u{2014} only "
                            + "inside Wakil does it run as \(org).")
                }

                // **The session-based credential warning that stood here
                // is DELETED, not left alongside the settings pane's
                // check** (#200).
                //
                // It fired on "an adoption happened this session" and
                // named the id that adoption used. That made it right
                // about this machine by luck and SILENT ON RELAUNCH: the
                // three credential-less bindings that exist on this
                // machine today were adopted in earlier sessions, so
                // nothing has warned about them since, and an operator
                // relaunching Wakil saw a clean plane over a broken
                // binding. It also could not warn about a binding it had
                // not itself created, which is most of them.
                //
                // The settings pane (\u{2318},) asks the Keychain instead,
                // per (organisation, account id), on every read. That
                // answer is right after a relaunch and right about
                // bindings this plane never touched — so keeping a second,
                // weaker answer beside it would be keeping the one that is
                // wrong more often.
                //
                // The per-org credential fact itself has not gone away:
                // `ProviderTokenRef` is per-org by construction, so a
                // binding `initech-main` registered in `personal` reads
                // `wakil:personal:provider:initech-main`, an item that does not
                // exist merely because `wakil:initech:provider:main` does
                // (Invariant 4 working, not failing). The `--share`
                // warning above still states the surprising half, and the
                // settings pane names any binding actually missing its
                // credential and repairs it from the row.

                ActionRow(
                    title: "Register a new account",
                    identifier: "org.adopt.registerAccount",
                    subtitle: "wakil provider add \u{2014} not yet in-window",
                    coolWhite: coolWhite, isEnabled: false
                ) {}

                HStack(spacing: 10) {
                    Spacer()
                    quietButton("Done", id: "org.adopt.done") { phase = .choosing }
                    // Neither Creating nor Adopting switches the window;
                    // each OFFERS it, and only when the affected org is not
                    // already current (brief §2) — which, inside Adopting,
                    // is always true: `org` here is never the org Choosing's
                    // current-row guard would have refused to enter this
                    // state for in the first place.
                    if org != model.organization {
                        button("Switch to \(org) now", id: "org.adopt.switchNow") { beginSwitch(to: org) }
                    }
                }
            }
        }
    }

    // MARK: - Switching / Error

    private func switchingPlane(target: String) -> some View {
        plane {
            VStack(alignment: .leading, spacing: 18) {
                microLabel("Switching")
                Text(target.isEmpty ? "Switching organisation\u{2026}" : "Switching to \(target)\u{2026}")
                    .font(.system(size: 15))
                    .foregroundStyle(coolWhite.opacity(0.86))
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(accent)
            }
        }
    }

    private func errorPlane(target: String, reason: String) -> some View {
        plane {
            VStack(alignment: .leading, spacing: 18) {
                microLabel("Switch failed")

                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "xmark.circle").foregroundStyle(destructive)
                    Text(reason)
                        .font(.system(size: 15))
                        .foregroundStyle(destructive)
                }

                HStack(spacing: 10) {
                    Spacer()
                    quietButton("Cancel", id: "org.error.cancel") {
                        phase = .choosing
                    }
                    button("Retry", id: "org.error.retry") { beginSwitch(to: target) }
                }

                microLabel(
                    model.organization.isEmpty
                        ? "No organisation is open"
                        : "The window is still in \(model.organization)")
            }
        }
    }

    // MARK: - Shared chrome

    /// §3's near plane, composed exactly as `ConfirmationPlane` is: full
    /// scale, no dimming modifiers of its own, a `black.opacity(0.86)` slab
    /// at 520 wide with the ordinary half-pixel luminous edge in place of a
    /// border (`OrgPlane.dc.html`'s own comment on why this one is not
    /// edged in destructive red).
    @ViewBuilder
    private func plane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(24)
            .frame(width: 520)
            .background(.black.opacity(0.86))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 30)
    }

    /// A list that is drawn as it stands while it fits, and scrolls inside
    /// the plane when it does not.
    ///
    /// **The plane had no height of its own.** Both lists sat in a plain
    /// `VStack`, so a machine with forty organisations — measured on the
    /// operator's, most of them left behind by test runs — grew the plane
    /// past the bottom of the window with the footer and "New organisation"
    /// out of reach. `ViewThatFits` keeps a short list exactly as drawn and
    /// only a long one pays for a scroll view.
    private func scrollingWhenTall<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let list = content()
        return ViewThatFits(in: .vertical) {
            list
            ScrollView(.vertical) { list }
                .scrollIndicators(.automatic)
        }
    }

    private func microLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(coolWhite.opacity(0.52))
    }

    private func warningBox(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// `id` is not defaulted, and deliberately so: this plane draws four
    /// different "Cancel" buttons across four phases, and a defaulted or
    /// title-derived name would give all four the same one. Making it a
    /// required argument turns "an actionable control without an identifier"
    /// from something a gate has to notice into something that does not
    /// compile.
    private func button(_ title: String, id: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .accessibilityIdentifier(id)
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(coolWhite)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(coolWhite.opacity(disabled ? 0.05 : 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .disabled(disabled)
    }

    /// See `button(_:id:disabled:action:)` for why `id` is required.
    private func quietButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .accessibilityIdentifier(id)
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(coolWhite.opacity(0.62))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
    }
}

/// One row of the Choosing state's list. Leads with the display name,
/// falling back to the id when there is none (§8.1.1) — the thing an
/// operator recognises is the thing they read first. When there IS a
/// display name, the id rides along as secondary detail beside the Jira
/// site or "no Jira site" (§8.2 — a flag cannot show what the operator did
/// not type; the row does) and the account count. The current org is
/// marked with the accent tick and "Current", and is not selectable
/// (`OrgPlane.dc.html`'s own `.row.current` rule).
///
/// **§8.6.1.** The row's PRIMARY action is the switch (`onSwitch`) — as
/// first built, the whole row dispatched adoption instead, and the operator
/// who walked the runbook clicked an org row to OPEN it and landed on
/// "adopt an account into it" instead, exactly the objection they raised
/// during design. Adoption is now a SEPARATE, quieter control (`onAdopt`):
/// its own `Button`, sized and coloured down to the same register as the
/// "CURRENT" microlabel beside it, so the switch still reads as the row's
/// one obvious action. It is a sibling of the switch button rather than
/// nested inside it — nesting a `Button` inside a `Button`'s label is the
/// one shape that risks the outer button swallowing the inner one's
/// clicks; two buttons side by side in the same `HStack` have no such
/// ambiguity.
///
/// `onAdopt` is never gated on `isCurrent`: §8.6 is explicit that adopting
/// into the CURRENT org is legal and has a use — "the account simply
/// becomes available to ⌘P" — so a current row offers adoption without
/// offering a switch (the switch button stays `.disabled(isCurrent)`,
/// unchanged from before this row grew a second action).
private struct OrgRow: View {
    let name: String
    let displayName: String?
    let jiraBase: String?
    let accounts: Int
    let isCurrent: Bool
    let accent: Color
    let coolWhite: Color
    let onSwitch: () -> Void
    let onAdopt: () -> Void

    @State private var isHovered = false
    @State private var isAdoptHovered = false

    /// The primary line: the display name, falling back to the id when
    /// there is none (§8.1.1).
    private var primaryText: String {
        guard let displayName, !displayName.isEmpty else { return name }
        return displayName
    }

    /// The secondary line. The id rides along here ONLY when the primary
    /// line is already showing the display name instead — when there is no
    /// display name, `primaryText` already reads as the id, and repeating
    /// it here would say the same thing twice.
    private var secondaryParts: [String] {
        var parts: [String] = []
        if let displayName, !displayName.isEmpty {
            parts.append(name)
        }
        parts.append(jiraBase ?? "no Jira site")
        parts.append(accounts == 1 ? "1 account" : "\(accounts) accounts")
        return parts
    }

    var body: some View {
        HStack(spacing: 16) {
            Rectangle()
                .fill(isCurrent ? accent : .clear)
                .frame(width: 2, height: 30)

            Button(action: onSwitch) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(primaryText)
                            .font(.system(size: 15))
                            .foregroundStyle(isCurrent ? coolWhite.opacity(0.58) : coolWhite)
                            // One line, truncated: inside the plane's scroll
                            // view a row is offered unlimited height, and a
                            // long id would otherwise wrap rather than elide.
                            .lineLimit(1)
                            .truncationMode(.tail)
                        HStack(spacing: 12) {
                            ForEach(Array(secondaryParts.enumerated()), id: \.offset) { _, part in
                                Text(part)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(coolWhite.opacity(0.50))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if isCurrent {
                        Text("CURRENT")
                            .font(.system(size: 9, weight: .medium))
                            .tracking(1.6)
                            .foregroundStyle(coolWhite.opacity(0.52))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isCurrent)
            .accessibilityIdentifier("org.row.\(name).switch")

            // The secondary adopt affordance (§8.6.1). Deliberately quiet:
            // same size register as the "CURRENT" label above, brightening
            // only on its own hover, so it never competes with the switch
            // for attention but is still legible as its own control.
            Button(action: onAdopt) {
                Text("ADOPT")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.4)
                    .foregroundStyle(coolWhite.opacity(isAdoptHovered ? 0.80 : 0.42))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(isAdoptHovered ? coolWhite.opacity(0.08) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isAdoptHovered = $0 }
            .help("Adopt an account into \(name)")
            // `.help` is AXHelp, which is neither spoken first nor carried
            // by every reader — the four-letter glyph ADOPT is all a
            // VoiceOver user gets without this.
            .accessibilityLabel("Adopt an account into \(name)")
            .accessibilityIdentifier("org.row.\(name).adopt")
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
        .background(isHovered && !isCurrent ? coolWhite.opacity(0.055) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
    }
}

/// One row of the Adopting state's candidate list: `homeName/providerId`
/// (the account's real home, never the org this view is adopting into —
/// showing that org back would say nothing the operator does not already
/// know from the plane's own title), config dir, kind and the human label.
///
/// **Fix 1.** The whole row used to BE the button, dispatching adoption
/// under the source row's own id verbatim — unreachable the moment the
/// target org already has a provider by that id (`ctx_adopt_provider`
/// refuses the collision by design; the CLI's own `wakil provider add <id>
/// --share` has always let the operator pick a different one). So this row
/// now carries its own editable id — defaulted to `providerId`, but scoped
/// to THIS org, not the account's home — and an explicit "Adopt" control
/// fires it. `action` takes that id, not the source row's, and the Go side
/// / the action itself are untouched (`OrgPlane.swift`'s own doc comment on
/// this fix): the id was always a plain parameter, this only lets the
/// operator set it.
private struct MachineProviderRow: View {
    let homeName: String
    let providerId: String
    let configDir: String?
    let kind: String
    let label: String?
    let coolWhite: Color
    let action: (String) -> Void

    @State private var targetId: String
    @State private var isHovered = false

    init(
        homeName: String, providerId: String, configDir: String?, kind: String, label: String?,
        coolWhite: Color, action: @escaping (String) -> Void
    ) {
        self.homeName = homeName
        self.providerId = providerId
        self.configDir = configDir
        self.kind = kind
        self.label = label
        self.coolWhite = coolWhite
        self.action = action
        self._targetId = State(initialValue: providerId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(homeName)/\(providerId)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(coolWhite)
                    Text("\(configDir ?? "?") \u{00b7} \(kind)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(coolWhite.opacity(0.50))
                }
                Spacer(minLength: 0)
                if let label, !label.isEmpty {
                    Text(label.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .tracking(1.6)
                        .foregroundStyle(coolWhite.opacity(0.52))
                }
            }

            // The id under which this account will be registered IN THIS
            // ORG — not a rename at its home. Same labelled-`TextField`
            // pattern the Creating state's "Identifier" field uses
            // (`OrgPlane.swift`, the `creatingPlane` property).
            VStack(alignment: .leading, spacing: 9) {
                Text("REGISTER AS, IN THIS ORG")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.6)
                    .foregroundStyle(coolWhite.opacity(0.52))
                HStack(spacing: 10) {
                    TextField(providerId, text: $targetId)
                        .accessibilityLabel("Register \(providerId) as")
                        .accessibilityIdentifier("org.adopt.row.\(providerId).targetId")
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(coolWhite)
                        .padding(10)
                        .background(coolWhite.opacity(0.055))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button("Adopt") {
                        action(targetId.trimmingCharacters(in: .whitespaces))
                    }
                    .accessibilityIdentifier("org.adopt.row.\(providerId).adopt")
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(coolWhite)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(coolWhite.opacity(targetId.trimmingCharacters(in: .whitespaces).isEmpty ? 0.05 : 0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .disabled(targetId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(isHovered ? coolWhite.opacity(0.055) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
    }
}

/// The "New organisation" / "Register a new account" row — a `+` glyph and
/// a title, always the last row of its list (brief §2: Choosing "always
/// ends with New organisation, even when orgs already exist").
private struct ActionRow: View {
    let title: String
    /// Required rather than derived from `title`: this row is drawn once in
    /// Choosing and once in Adopting, and a title-derived name would make
    /// the two indistinguishable the moment they read alike.
    let identifier: String
    var subtitle: String?
    let coolWhite: Color
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: subtitle == nil ? .center : .top, spacing: 11) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(coolWhite.opacity(0.72))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14))
                        .foregroundStyle(coolWhite.opacity(0.72))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(coolWhite.opacity(0.50))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 14)
            .background(isHovered && isEnabled ? coolWhite.opacity(0.055) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier(identifier)
    }
}
