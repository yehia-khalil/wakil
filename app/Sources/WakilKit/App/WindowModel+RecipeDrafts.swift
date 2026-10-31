import Foundation

// Workspaces, piece 2, part three (decision 13): the drafting conversation of Detect's step 2 and
// Try's fix proposal. The conversation is an ordinary one in Main of the project, started off
// screen (`backgroundAgent`, as a hand-off is) so the operator stays in the Running settings
// (Rule 6); its chip shows it. It reads only, and answers with `running_draft_propose`, which
// lands in `recipeDraftBook` — never saved until the operator saves it (Rule 9).
extension WindowModel {
    /// The drafting of `repo` in the project file `projectPath`, as the form draws it.
    public func recipeDraft(projectPath: String, repo: String) -> RecipeDraft? {
        recipeDraftBook.draft(RecipeDraftKey(projectPath: projectPath, repo: repo))
    }

    /// Detect could not work out how `repo` runs: a conversation in Main of `project` drafts the
    /// rest from the repo's docs, its first message the brief with Detect's facts whole. A start
    /// that fails is said whole in the form (Rule 8).
    public func startRecipeDraft(project: SettingsProject, repo: String, root: String, detected: JSONValue, kind: String) async {
        let key = RecipeDraftKey(projectPath: project.path, repo: repo)
        if let live = recipeDraftBook.draft(key), conversation(id: live.conversation) != nil {
            // One conversation per repo: it drafts again in the same thread.
            recipeDraftBook.begin(key, conversation: live.conversation, title: live.title, kind: kind)
            await sendRecipeDraft(key, recipeDraftingBrief(repo: repo, root: root, detected: detected), to: live.conversation, root: root)
            return
        }
        await startRecipeConversation(key, project: project, root: root, kind: kind, failedAt: nil,
                                      brief: recipeDraftingBrief(repo: repo, root: root, detected: detected))
    }

    /// Try failed: the repo's drafting conversation is asked for a fix — started first when there
    /// is none — with the report whole and the recipe as tried.
    public func proposeRecipeFix(project: SettingsProject, repo: String, root: String, recipe: Recipe, report: RunTryResult) async {
        let key = RecipeDraftKey(projectPath: project.path, repo: repo)
        let brief = recipeFixBrief(repo: repo, recipe: recipe, report: report)
        let at = recipeTryFailedAt(report)
        if let live = recipeDraftBook.draft(key), conversation(id: live.conversation) != nil {
            recipeDraftBook.askFix(key, failedAt: at)
            await sendRecipeDraft(key, brief, to: live.conversation, root: root)
            return
        }
        await startRecipeConversation(key, project: project, root: root, kind: "", failedAt: at, brief: brief)
    }

    /// The proposal was saved or discarded: nothing pending, the conversation kept for a fix.
    public func settleRecipeDraft(projectPath: String, repo: String) {
        recipeDraftBook.settle(RecipeDraftKey(projectPath: projectPath, repo: repo))
    }

    /// Stop (Rule 4): the drafting conversation ends, and with it the drafting.
    public func stopRecipeDraft(projectPath: String, repo: String) async {
        let key = RecipeDraftKey(projectPath: projectPath, repo: repo)
        guard let d = recipeDraftBook.draft(key) else { return }
        if let agent = conversation(id: d.conversation) { await endConversation(agent) }
        recipeDraftBook.end(key)
    }

    /// The drafting line's conversation name, pressed: that conversation, in Main of its project.
    public func openRecipeDraftConversation(projectPath: String, repo: String) async {
        guard let d = recipeDraftBook.draft(RecipeDraftKey(projectPath: projectPath, repo: repo)),
              let agent = conversation(id: d.conversation) else { return }
        await switchToConversation(agent.id, in: agent.place)
    }

    /// Ask again: a turn that ended without a proposal is sent the same request once more.
    public func askRecipeDraftAgain(projectPath: String, repo: String) async {
        let key = RecipeDraftKey(projectPath: projectPath, repo: repo)
        guard let d = recipeDraftBook.draft(key), let agent = conversation(id: d.conversation),
              let text = recipeDraftBook.askAgain(key) else { return }
        await sendRecipeDraft(key, text, to: agent.id, root: d.root, place: agent.place)
    }

    /// `running_draft_propose`'s handler, through `RecipeDraftLookup`.
    func receiveRecipeDraft(conversation: String?, _ proposal: RunningDetected) throws {
        _ = try recipeDraftBook.propose(conversation: conversation, proposal)
    }

    private func startRecipeConversation(
        _ key: RecipeDraftKey, project: SettingsProject, root: String, kind: String, failedAt: String?, brief: String
    ) async {
        let place = recipeDraftPlace(project)
        let agent = backgroundAgent(in: place, providerId: providerId)
        let title = recipeDraftTitle(key.repo)
        agent.messageTitle = conversationTitle(title)
        agent.namingAsked = true
        recipeDraftBook.begin(key, conversation: agent.id, title: title, kind: kind, fixing: failedAt)
        await sendRecipeDraft(key, brief, to: agent.id, root: root, place: place)
    }

    private func sendRecipeDraft(_ key: RecipeDraftKey, _ text: String, to id: String, root: String, place: Place? = nil) async {
        guard let agent = conversation(id: id) else { return }
        recipeDraftBook.asked(key, text, root: root)
        let scope = TurnScope(place: place ?? agent.place, rootPath: root, providerId: agent.providerId, conversation: id)
        let before = status
        guard await send(text, scope: scope) else {
            let why = status.isEmpty || status == before ? "the agent did not start" : status
            recipeDraftBook.fail(key, "The conversation that drafts \(key.repo)'s recipe could not start: \(why)")
            if conversation(id: id) === agent, agent.sessionId == nil { await endConversation(agent) }
            // Kept failed after the close, so the form says why.
            if recipeDraftBook.draft(key) == nil {
                recipeDraftBook.begin(key, conversation: "", title: recipeDraftTitle(key.repo), kind: "")
                recipeDraftBook.fail(key, "The conversation that drafts \(key.repo)'s recipe could not start: \(why)")
            }
            return
        }
    }

    /// Main of the project: the screen's environment when the project is on screen, otherwise its
    /// first environment that is not production (production is never chosen unasked), else its first.
    private func recipeDraftPlace(_ project: SettingsProject) -> Place {
        if project.name == place.project { return place }
        let env = project.environments.first { !($0.production ?? true) } ?? project.environments.first
        return Place(organization: organization, project: project.name, environment: env?.name ?? place.environment)
    }
}
