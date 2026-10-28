import Foundation
import WakilKit
import WebKit

/// 3d-iv: what the passwords' page script (`BrowserPasswordScript`) tells Wakil.
///
/// **One handler per configuration, holding nothing.** It resolves its tab by `message.webView`
/// (the web view's own `BrowserTabDelegate` names its place, pane and tab), so a pop-up — whose
/// configuration is WebKit's copy of its opener's, handler included — is heard as itself, never as
/// its opener.
///
/// **It drops** any message not from the main frame, not from the `wakil.passwords` world (a page's
/// own script cannot reach that world's handler, and anything else is not Wakil's), or from a web
/// view no tab owns yet (a pop-up's placeholder). The origin and the site come from
/// `message.frameInfo.securityOrigin`, never from the page's words (ruling 13).
///
/// Nothing a message carries is printed, logged or written: a field report is a rect, and a sent
/// form's password lives in memory only, on the host (`passwordOffers`), until the bar is answered.
@MainActor
final class BrowserPasswordMessages: NSObject, WKScriptMessageHandler {
    /// Adds the script and this handler, in `wakil.passwords`, to a new tab's configuration.
    static func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.addUserScript(BrowserPasswordScript.userScript())
        controller.add(BrowserPasswordMessages(), contentWorld: BrowserPasswordScript.world,
                       name: BrowserPasswordScript.handlerName)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.world.name == BrowserPasswordScript.world.name,
              let view = message.webView, let delegate = view.navigationDelegate as? BrowserTabDelegate,
              let host = delegate.host, !delegate.tab.isEmpty
        else { return }
        let key = BrowserTabHost.Key(scope: delegate.scope, pane: delegate.pane, tab: delegate.tab)
        guard host.existing(scope: key.scope, pane: key.pane, tab: key.tab) === view else { return }
        let origin = message.frameInfo.securityOrigin
        guard let page = BrowserPasswordPageMessage.origin(protocol: origin.protocol, host: origin.host, port: origin.port),
              let site = BrowserPasswords.siteKey(page),
              let parsed = BrowserPasswordPageMessage.parse(message.body)
        else { return }
        switch parsed {
        case .field(let role, let rect):
            host.passwordFieldReported(key, BrowserPasswordField(role: role, rect: rect, origin: page, site: site))
        case .blur:
            host.passwordFieldBlurred(key)
        case .submit(let username, let password, _):
            host.passwordFormSent(key, site: site, username: username, password: password)
        }
    }
}

/// The focused login field of a tab, as its page reported it.
struct BrowserPasswordField: Equatable {
    let role: BrowserPasswordFieldRole
    /// CSS pixels from the viewport's top left.
    var rect: BrowserPasswordRect
    /// `location.origin` from the frame's security origin, and its site key.
    let origin: String
    let site: String
    /// Whether the site has a saved login in the place's organisation: nil while it is read, and
    /// when it could not be read (the key then shows, and its list says why).
    var hasLogins: Bool?
    var read = false
}

/// A sent form's question for the bar (ruling 14): the host's, in memory only, never the store's.
struct BrowserPasswordOfferState: Equatable {
    let id: Int
    let offer: BrowserPasswordOffer
    let org: String
    let site: String
    /// The username the login is saved under: the typed one, or the saved one an update names.
    let username: String
    let password: String
    let question: String
}

extension BrowserTabHost {
    // MARK: The field

    /// A login field took focus or moved. A new field or site reads whether the site has a saved
    /// login — attributes only, so it never asks the Keychain for permission.
    func passwordFieldReported(_ key: Key, _ field: BrowserPasswordField) {
        passwordBlurs.removeValue(forKey: key)?.cancel()
        if var known = passwordFields[key], known.role == field.role, known.origin == field.origin {
            if known.rect != field.rect {
                known.rect = field.rect
                passwordFields[key] = known
            }
            return
        }
        passwordFields[key] = field
        guard let store = passwordStore else { return }
        let org = key.scope.organization, site = field.site
        Task { [weak self] in
            let has: Bool? = await Task.detached {
                (try? store.logins(org: org, site: site)).map { !$0.isEmpty }
            }.value
            guard let self, var now = self.passwordFields[key], now.origin == field.origin else { return }
            now.hasLogins = has
            now.read = true
            self.passwordFields[key] = now
        }
    }

    /// The field lost focus: held 300 ms (a press on the key blurs the page first), and kept when the
    /// key's list opened meanwhile.
    func passwordFieldBlurred(_ key: Key) {
        passwordBlurs.removeValue(forKey: key)?.cancel()
        passwordBlurs[key] = Task { [weak self] in
            try? await Task.sleep(for: BrowserPasswordKeyLayout.blurHold)
            guard let self, !Task.isCancelled, !self.passwordListOpen.contains(key) else { return }
            self.passwordFields[key] = nil
            self.passwordBlurs[key] = nil
        }
    }

    /// A new document in the tab: its field report and any press go; the bar stays (ruling 14).
    func passwordPageCommitted(_ key: Key) {
        passwordBlurs.removeValue(forKey: key)?.cancel()
        if passwordFields[key] != nil { passwordFields[key] = nil }
        passwordPress[key] = nil
    }

    // MARK: The key's list

    /// The key was pressed: the origin of the field it was pressed in is the one a fill may land on.
    func passwordListOpened(_ key: Key, origin: String) {
        passwordListOpen.insert(key)
        passwordPress[key] = origin
    }

    /// The list closed: no fill without a press after this. The field goes unless the page reports it
    /// again — as it does when it takes the keyboard back — within the blur's hold.
    func passwordListClosed(_ key: Key) {
        guard passwordListOpen.remove(key) != nil else { return }
        passwordPress[key] = nil
        passwordFieldBlurred(key)
    }

    // MARK: A sent form

    /// A form was sent with a password (ruling 7's order, through `BrowserPasswords.offer`). The
    /// password the operator chose from *Suggest Strong Password* is saved with no bar. Otherwise the
    /// site's logins are read, and the saved password of a matching one, and the bar asks — a newer
    /// sent form replacing an older question.
    func passwordFormSent(_ key: Key, site: String, username: String, password: String) {
        guard !password.isEmpty, let model, let store = passwordStore else { return }
        let org = key.scope.organization
        let suggested = pendingSuggestion[key]
        passwordSubmits += 1
        let id = passwordSubmits
        passwordLatestSubmit[key] = id
        if let suggested, suggested == password {
            pendingSuggestion[key] = nil
            let params: JSONValue = .object([
                "org": .string(org), "site": .string(site), "username": .string(username),
                "password": .string(password), "pane": .string(key.pane), "tab": .string(key.tab)])
            // A refusal is the window's status line, whole (Rule 8).
            Task { await model.dispatchFromSurface("browser_password_save", params) }
            return
        }
        let home = model.browserHome
        Task { [weak self] in
            let known = await Task.detached { () -> (names: [String], saved: String?, never: Set<String>) in
                let names = ((try? store.logins(org: org, site: site)) ?? []).map(\.username)
                let match = names.contains(username) ? username : (username.isEmpty && names.count == 1 ? names[0] : nil)
                let saved = match.flatMap { try? store.password(org: org, site: site, username: $0) }
                let never = home.flatMap { try? BrowserOrgFiles(home: $0, org: org).neverSave() } ?? []
                return (names, saved, Set(never))
            }.value
            guard let self, self.passwordLatestSubmit[key] == id else { return }
            let offer = BrowserPasswords.offer(
                password: password, username: username, site: site, savedUsernames: known.names,
                savedPassword: known.saved, never: known.never, suggested: suggested)
            let saveAs: String
            switch offer {
            case .nothing, .saveQuietly: return
            case .askSave: saveAs = username
            case .askUpdate(let saved): saveAs = saved
            }
            guard let question = BrowserPasswords.barQuestion(offer, username: username, site: site) else { return }
            self.passwordOffers[key] = BrowserPasswordOfferState(
                id: id, offer: offer, org: org, site: site, username: saveAs, password: password, question: question)
        }
    }

    /// The bar was answered: its question goes, unless a newer one replaced it meanwhile.
    func passwordOfferAnswered(_ key: Key, id: Int) {
        if passwordOffers[key]?.id == id { passwordOffers[key] = nil }
    }

    // MARK: Leaving

    /// The tab's web view goes; with `tabClosed`, its question and suggestion go too.
    func forgetPasswords(_ key: Key, tabClosed: Bool) {
        passwordPageCommitted(key)
        passwordListOpen.remove(key)
        guard tabClosed else { return }
        passwordOffers[key] = nil
        pendingSuggestion[key] = nil
        passwordLatestSubmit[key] = nil
    }
}
