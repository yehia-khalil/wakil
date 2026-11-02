import Foundation
import Testing
@testable import WakilKit

// The Running settings' decisions (workspaces, piece 2): the list's groups, where each field comes
// from, and how an edit becomes the repo's override.

private let listed: JSONValue = {
    let json = """
    {"project":"estate","problems":[],
     "recipes":{
       "laravel-sail":{"services":["sail up -d mysql redis"],"setup":["sail composer install"],
         "processes":[{"name":"app","command":"sail up laravel.test"}],"env":{"APP_ENV":"local"},
         "ready":{"url":"http://localhost:$WAKIL_PORT/up"},"notes":{"setup":"README § Getting started"}},
       "core-services":{"services":["docker compose up -d mysql"],"in":"core"}},
     "repos":[
       {"repo":"api","path":"/p/api","recipe":"laravel-sail","doesntRun":false,
        "overrides":{"processes":[{"name":"queue","command":"sail artisan queue:work"}],
                     "env":{"STRIPE_SECRET":{"secret":"run:estate:api:STRIPE_SECRET"}}}},
       {"repo":"rewards","path":"/p/rewards","recipe":"laravel-sail","doesntRun":false},
       {"repo":"components","path":"/p/components","doesntRun":true},
       {"repo":"core","path":"/p/core"}]}
    """
    return try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
}()

@Test func theListGroupsSharedServicesThenRecipesThenRepoWithNone() throws {
    let s = try RunningSettings.decode(listed)
    #expect(s.groups.map(\.title) == ["Shared services", "Recipe · laravel-sail", "No recipe"])
    #expect(s.groups[0].repos == ["core-services"])
    #expect(s.groups[1].repos == ["api", "rewards"])
    #expect(s.groups[2].repos == ["components", "core"])
}

@Test func aFieldSaysWhereItCameFromAndCarriesItsNote() throws {
    let s = try RunningSettings.decode(listed)
    let setup = s.field(.setup, of: "api")
    #expect(setup.text == "sail composer install" && setup.source == .recipe && setup.note == "README § Getting started")
    let procs = s.field(.processes, of: "api")
    #expect(procs.text == "queue: sail artisan queue:work" && procs.source == .repo)
    #expect(s.field(.build, of: "api").source == FieldSource.none)
    let env = s.env(of: "api")
    #expect(env.map(\.name) == ["APP_ENV", "STRIPE_SECRET"])
    #expect(env[0].source == .recipe && env[1].source == .repo && env[1].value.isSecret)
}

@Test func anEditInARepoFormBecomesItsOverrideAndTheRecipesOwnValueClearsIt() throws {
    let s = try RunningSettings.decode(listed)
    let patch = try #require(s.savingField(.setup, "sail composer install\nsail artisan migrate --seed", of: "rewards"))
    #expect(patch == .object(["repos": .object(["rewards": .object([
        "recipe": .string("laravel-sail"),
        "overrides": .object(["setup": .array([.string("sail composer install"), .string("sail artisan migrate --seed")])]),
    ])])]))
    // Typing the recipe's own value back inherits again: no override kept.
    let back = try #require(s.savingField(.processes, "app: sail up laravel.test", of: "api"))
    guard case .object(let o) = back, case .object(let repos)? = o["repos"], case .object(let api)? = repos["api"],
          case .object(let over)? = api["overrides"] else { Issue.record("no overrides: \(back)"); return }
    #expect(over["processes"] == nil && over["env"] != nil)
}

@Test func fieldTextParsesWithoutRefusing() {
    var r = RecipeField.processes.set("api: php artisan serve --port=$WAKIL_PORT\nphp artisan queue:work\n\n", in: Recipe())
    #expect(r.processes == [RecipeProcess(name: "api", command: "php artisan serve --port=$WAKIL_PORT"),
                            RecipeProcess(name: "app", command: "php artisan queue:work")])
    r = RecipeField.ports.set("APP_PORT=$WAKIL_PORT\nJOUD_URL → http://localhost:$WAKIL_PORT_CORE\nnonsense", in: r)
    #expect(r.ports == ["APP_PORT": "$WAKIL_PORT", "JOUD_URL": "http://localhost:$WAKIL_PORT_CORE"])
    r = RecipeField.ready.set("http://localhost:$WAKIL_PORT/up", in: r)
    #expect(r.ready == RecipeReady(url: "http://localhost:$WAKIL_PORT/up"))
    r = RecipeField.ready.set("Local:", in: r)
    #expect(r.ready == RecipeReady(output: "Local:"))
    r = RecipeField.copy.set("", in: r)
    #expect(r.copy == [])
}

@Test func anEnvSecretIsSavedAsItsRefAndRemovingOneDropsIt() throws {
    let s = try RunningSettings.decode(listed)
    let ref = runSecretRef(project: "estate", owner: "rewards", variable: "MAIL_KEY")
    #expect(ref == "run:estate:rewards:MAIL_KEY")
    let patch = try #require(s.savingEnv("MAIL_KEY", .secret(ref), of: "rewards"))
    #expect(patch == .object(["repos": .object(["rewards": .object([
        "recipe": .string("laravel-sail"), "overrides": .object(["env": .object(["MAIL_KEY": .object(["secret": .string(ref)])])]),
    ])])]))
    let removed = try #require(s.savingEnv("STRIPE_SECRET", nil, of: "api"))
    guard case .object(let o) = removed, case .object(let repos)? = o["repos"], case .object(let api)? = repos["api"],
          case .object(let over)? = api["overrides"] else { Issue.record("\(removed)"); return }
    #expect(over["env"] == nil)
}

@Test func doesntRunAndARecipeChoiceKeepTheOverrides() throws {
    let s = try RunningSettings.decode(listed)
    let p = try #require(s.savingRecipe(nil, doesntRun: true, of: "core"))
    #expect(p == .object(["repos": .object(["core": .object(["doesntRun": .bool(true)])])]))
}

// Piece 2's e2e run: Go refuses a repo marked doesn't run that still names a recipe or an override,
// so Doesn't run on a repo with overrides was refused whole. The patch carries the mark alone.
@Test func doesntRunOnARepoWithOverridesSendsTheMarkAlone() throws {
    let s = try RunningSettings.decode(listed)
    #expect(s.repo("api")?.overrides != nil)
    let p = try #require(s.savingRecipe(nil, doesntRun: true, of: "api"))
    #expect(p == .object(["repos": .object(["api": .object(["doesntRun": .bool(true)])])]))
}

@Test func detectSavesUnderItsKindUnlessADifferentRecipeHasTheName() throws {
    let json = """
    {"repo":"web","kind":"vite","doesntRun":false,"recipe":{"processes":[{"name":"dev","command":"pnpm dev"}],
     "notes":{"processes":"package.json scripts.dev"}},"questions":["Which port does the API use?"]}
    """
    let d = try JSONDecoder().decode(RunningDetected.self, from: Data(json.utf8))
    #expect(d.lines == ["Recipe vite for web", "Processes: dev: pnpm dev  (package.json scripts.dev)",
                        "Asks you: Which port does the API use?"])
    #expect(d.recipeName(existing: [:]) == "vite")
    var other = Recipe()
    other.build = "x"
    #expect(d.recipeName(existing: ["vite": other]) == "vite-web")
    guard case .object(let o) = d.saving(existing: [:]), case .object(let repos)? = o["repos"] else { Issue.record("no repos"); return }
    #expect(repos["web"] == .object(["recipe": .string("vite")]))
}

/// A process that starts once the app is ready (the walk: a Sail queue failed before laravel.test
/// was up): `(after ready)` at the end of its line in the Processes box, kept as `afterReady`.
@Test func aProcessLineMarkedAfterReadyKeepsItAndSaysIt() throws {
    let r = RecipeField.processes.set("app: ./vendor/bin/sail up laravel.test\nqueue: ./vendor/bin/sail artisan queue:work (after ready)", in: Recipe())
    #expect(r.processes == [RecipeProcess(name: "app", command: "./vendor/bin/sail up laravel.test"),
                            RecipeProcess(name: "queue", command: "./vendor/bin/sail artisan queue:work", afterReady: true)])
    #expect(RecipeField.processes.text(in: r)
        == "app: ./vendor/bin/sail up laravel.test\nqueue: ./vendor/bin/sail artisan queue:work (after ready)")
    let json = String(data: try JSONEncoder().encode(r.processes), encoding: .utf8) ?? ""
    #expect(json.contains("\"afterReady\":true") && !json.contains("\"afterReady\":false"))
}

@Test func theFormsSectionsHoldEveryFieldOnceInTheirOrder() {
    #expect(RecipeFieldSection.allCases.map(\.title)
        == ["New copy · runs once", "Every run", "Ports and environment", "On stop"])
    #expect(RecipeFieldSection.newCopy.fields == [.copy, .clone, .setup, .build])
    #expect(RecipeFieldSection.everyRun.fields == [.needs, .services, .processes, .ready])
    #expect(RecipeFieldSection.portsAndEnv.fields == [.ports])
    #expect(RecipeFieldSection.onStop.fields == [.teardown])
    let all = RecipeFieldSection.allCases.flatMap(\.fields)
    #expect(all.count == RecipeField.allCases.count)
    #expect(Set(all) == Set(RecipeField.allCases))
    #expect(RecipeFieldSection.allCases.filter(\.holdsEnv) == [.portsAndEnv])
    #expect(RecipeFieldSection.allCases.allSatisfy { !$0.hint.isEmpty })
}
