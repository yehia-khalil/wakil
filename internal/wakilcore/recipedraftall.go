package wakilcore

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// Draft all (workspaces piece 2, step 0): many repos' detected drafts grouped into shared recipes
// with per-repo differences, shared services proposed from the hosts several repos' example env
// files point at, and what could not be decided listed as questions. Nothing is saved (Rule 9).

// DraftAll is the proposal for a whole project.
type DraftAll struct {
	Recipes        map[string]Recipe       `json:"recipes"`
	Repos          map[string]RepoRun      `json:"repos"`
	Groups         []DraftGroup            `json:"groups"`
	SharedServices []SharedServiceProposal `json:"sharedServices"`
	NothingToRun   []NothingToRun          `json:"nothingToRun"`
	Questions      []string                `json:"questions"`
}

// DraftGroup is one proposed recipe and the repos that use it.
type DraftGroup struct {
	Recipe string   `json:"recipe"`
	Repos  []string `json:"repos"`
	// Differences names, per repo, the fields it keeps as its own.
	Differences map[string][]string `json:"differences"`
}

// SharedServiceProposal is a service several repos point at, run once per workspace.
type SharedServiceProposal struct {
	Name  string   `json:"name"`
	Host  string   `json:"host"`
	In    string   `json:"in"`
	Repos []string `json:"repos"`
	From  string   `json:"from"`
}

// NothingToRun is a repo that looks like it does not run, and why.
type NothingToRun struct {
	Repo string `json:"repo"`
	Why  string `json:"why"`
}

// DraftAllRecipes groups drafts. Repos of one kind share a recipe whose values are what most of
// them hold; each repo keeps what differs as its overrides.
func DraftAllRecipes(drafts []Draft) DraftAll {
	out := DraftAll{
		Recipes: map[string]Recipe{}, Repos: map[string]RepoRun{}, Groups: []DraftGroup{},
		SharedServices: []SharedServiceProposal{}, NothingToRun: []NothingToRun{}, Questions: []string{},
	}
	drafts = append([]Draft{}, drafts...)
	sort.SliceStable(drafts, func(i, j int) bool { return drafts[i].Repo < drafts[j].Repo })
	byRepo := map[string]*Draft{}
	for i := range drafts {
		byRepo[drafts[i].Repo] = &drafts[i]
		out.Questions = append(out.Questions, drafts[i].Questions...)
	}

	// Shared services: hosts two or more repos point at that their own compose files do not define.
	ownsHost := func(d *Draft, host string) bool {
		if d.Compose == nil {
			return false
		}
		for _, s := range append(append([]string{}, d.Compose.Services...), d.Compose.AppServices...) {
			if s == host {
				return true
			}
		}
		for _, c := range d.Compose.ContainerNames {
			if c.Name == host {
				return true
			}
		}
		return false
	}
	pointing := map[string][]string{}
	keys := map[string][]string{}
	for i := range drafts {
		d := &drafts[i]
		if d.DoesntRun {
			continue
		}
		seen := map[string]bool{}
		for _, h := range d.Hosts {
			if ownsHost(d, h.Host) || seen[h.Host] {
				continue
			}
			seen[h.Host] = true
			pointing[h.Host] = append(pointing[h.Host], d.Repo)
			keys[h.Host] = append(keys[h.Host], d.Repo+"/"+h.File+" "+h.Key)
		}
	}
	hosts := sortedKeys(pointing)
	sharedOf := map[string]string{} // owner repo → shared service name
	hostOwner := map[string]string{}
	for _, host := range hosts {
		repos := pointing[host]
		if len(repos) < 2 {
			continue
		}
		owner := ""
		for i := range drafts {
			if ownsHost(&drafts[i], host) {
				owner = drafts[i].Repo
				break
			}
		}
		if owner == "" || len(byRepo[owner].Compose.Services) == 0 {
			out.Questions = append(out.Questions, fmt.Sprintf(
				"%d repos point at %s (%s), but no repo's compose file starts it; which repo runs it, or is it outside the workspace?",
				len(repos), host, strings.Join(keys[host], ", ")))
			continue
		}
		hostOwner[host] = owner
		name, ok := sharedOf[owner]
		if !ok {
			name = uniqueName(owner+"-services", out.Recipes)
			sharedOf[owner] = name
			od := byRepo[owner]
			svc := Recipe{
				Services: []string{"docker compose up -d " + strings.Join(od.Compose.Services, " ")},
				Teardown: []string{"docker compose down"},
				In:       ptr(owner),
				Notes:    map[string]string{"services": owner + "/" + od.Compose.File, "in": owner + " defines " + host},
			}
			if len(od.Recipe.Ports) > 0 {
				svc.Ports = od.Recipe.Ports
			}
			out.Recipes[name] = svc
			out.SharedServices = append(out.SharedServices, SharedServiceProposal{Name: name, Host: host, In: owner, From: owner + "/" + od.Compose.File})
		}
		for i := range out.SharedServices {
			if out.SharedServices[i].Name == name {
				out.SharedServices[i].Repos = dedupeStrings(append(out.SharedServices[i].Repos, repos...))
				if out.SharedServices[i].Host != host && !strings.Contains(out.SharedServices[i].Host, host) {
					out.SharedServices[i].Host += ", " + host
				}
				out.SharedServices[i].From += " · " + strings.Join(keys[host], ", ")
			}
		}
		for _, repo := range repos {
			d := byRepo[repo]
			if repo == owner {
				continue
			}
			if !containsString(d.Recipe.Needs, name) {
				d.Recipe.Needs = append(d.Recipe.Needs, name)
				if d.Recipe.Notes == nil {
					d.Recipe.Notes = map[string]string{}
				}
				d.Recipe.Notes["needs"] = strings.TrimPrefix(d.Recipe.Notes["needs"]+"; ", "; ") + fmt.Sprintf("%s reads %s", repo, host)
			}
		}
	}

	// Group by kind.
	groups := map[string][]*Draft{}
	var kinds []string
	for i := range drafts {
		d := &drafts[i]
		switch {
		case d.DoesntRun:
			out.NothingToRun = append(out.NothingToRun, NothingToRun{d.Repo, d.Why})
			out.Repos[d.Repo] = RepoRun{DoesntRun: true}
			continue
		case sharedOf[d.Repo] != "" && len(d.Recipe.Processes) == 0:
			// A repo that only hosts the services is the shared service.
			out.Repos[d.Repo] = RepoRun{Recipe: sharedOf[d.Repo]}
			continue
		case d.Kind == "unknown":
			out.Repos[d.Repo] = RepoRun{}
			continue
		}
		if _, ok := groups[d.Kind]; !ok {
			kinds = append(kinds, d.Kind)
		}
		groups[d.Kind] = append(groups[d.Kind], d)
	}
	for _, kind := range kinds {
		members := groups[kind]
		name := uniqueName(kind, out.Recipes)
		recipes := make([]Recipe, len(members))
		for i, m := range members {
			recipes[i] = m.Recipe
		}
		shared, overrides := splitShared(recipes)
		out.Recipes[name] = shared
		g := DraftGroup{Recipe: name, Differences: map[string][]string{}}
		for i, m := range members {
			g.Repos = append(g.Repos, m.Repo)
			run := RepoRun{Recipe: name}
			if fields := overrideFields(overrides[i]); len(fields) > 0 {
				o := overrides[i]
				run.Overrides = &o
				g.Differences[m.Repo] = fields
			}
			out.Repos[m.Repo] = run
		}
		out.Groups = append(out.Groups, g)
	}
	return out
}

func containsString(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func uniqueName(base string, taken map[string]Recipe) string {
	name := base
	for i := 2; ; i++ {
		if _, ok := taken[name]; !ok {
			return name
		}
		name = fmt.Sprintf("%s-%d", base, i)
	}
}

func jsonKey(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// majority returns the index of the first member holding the most common value of key(i).
func majority(n int, key func(i int) string) (string, int) {
	count := map[string]int{}
	first := map[string]int{}
	best, bestKey := -1, ""
	for i := 0; i < n; i++ {
		k := key(i)
		count[k]++
		if _, ok := first[k]; !ok {
			first[k] = i
		}
	}
	for i := 0; i < n; i++ {
		k := key(i)
		if count[k] > best || (count[k] == best && first[k] < first[bestKey]) {
			best, bestKey = count[k], k
		}
	}
	return bestKey, first[bestKey]
}

// splitShared picks, per field, what most recipes hold as the shared value, and for each recipe the
// overrides that give it back exactly its own (except a Ready a repo lacks, which it inherits).
func splitShared(rs []Recipe) (Recipe, []Recipe) {
	n := len(rs)
	shared := Recipe{}
	over := make([]Recipe, n)

	lists := []struct {
		get func(*Recipe) *[]string
	}{
		{func(r *Recipe) *[]string { return &r.Needs }},
		{func(r *Recipe) *[]string { return &r.Copy }},
		{func(r *Recipe) *[]string { return &r.Clone }},
		{func(r *Recipe) *[]string { return &r.Services }},
		{func(r *Recipe) *[]string { return &r.Setup }},
		{func(r *Recipe) *[]string { return &r.Teardown }},
	}
	for _, l := range lists {
		k, at := majority(n, func(i int) string { return jsonKey(*l.get(&rs[i])) })
		*l.get(&shared) = *l.get(&rs[at])
		for i := range rs {
			if jsonKey(*l.get(&rs[i])) != k {
				v := *l.get(&rs[i])
				if v == nil {
					v = []string{}
				}
				*l.get(&over[i]) = v
			}
		}
	}
	if k, at := majority(n, func(i int) string { return jsonKey(rs[i].Build) }); true {
		shared.Build = rs[at].Build
		for i := range rs {
			if jsonKey(rs[i].Build) != k {
				over[i].Build = rs[i].Build
				if over[i].Build == nil {
					over[i].Build = ptr("")
				}
			}
		}
	}
	if k, at := majority(n, func(i int) string { return jsonKey(rs[i].Ready) }); true {
		shared.Ready = rs[at].Ready
		for i := range rs {
			if jsonKey(rs[i].Ready) != k && rs[i].Ready != nil {
				over[i].Ready = rs[i].Ready
			}
		}
	}
	if k, at := majority(n, func(i int) string { return jsonKey(rs[i].AlsoWriteEnvFile) }); true {
		shared.AlsoWriteEnvFile = rs[at].AlsoWriteEnvFile
		for i := range rs {
			if jsonKey(rs[i].AlsoWriteEnvFile) != k {
				over[i].AlsoWriteEnvFile = rs[i].AlsoWriteEnvFile
				if over[i].AlsoWriteEnvFile == nil {
					over[i].AlsoWriteEnvFile = ptr(false)
				}
			}
		}
	}

	// Maps: a key is shared only when every recipe holds it with the same value, since an
	// override cannot take a key away.
	splitMap := func(get func(*Recipe) map[string]string, set func(*Recipe, string, string)) {
		all := map[string]bool{}
		for i := range rs {
			for k := range get(&rs[i]) {
				all[k] = true
			}
		}
		for _, k := range sortedKeys(all) {
			v0, ok0 := get(&rs[0])[k]
			same := ok0
			for i := 1; i < n && same; i++ {
				v, ok := get(&rs[i])[k]
				same = ok && v == v0
			}
			if same {
				set(&shared, k, v0)
				continue
			}
			for i := range rs {
				if v, ok := get(&rs[i])[k]; ok {
					set(&over[i], k, v)
				}
			}
		}
	}
	splitMap(func(r *Recipe) map[string]string { return r.Ports }, func(r *Recipe, k, v string) {
		if r.Ports == nil {
			r.Ports = map[string]string{}
		}
		r.Ports[k] = v
	})
	splitMap(func(r *Recipe) map[string]string { return r.Notes }, func(r *Recipe, k, v string) {
		if r.Notes == nil {
			r.Notes = map[string]string{}
		}
		r.Notes[k] = v
	})
	envAsStrings := func(r *Recipe) map[string]string {
		m := map[string]string{}
		for k, v := range r.Env {
			m[k] = jsonKey(v)
		}
		return m
	}
	splitMap(envAsStrings, func(r *Recipe, k, v string) {
		if r.Env == nil {
			r.Env = map[string]EnvValue{}
		}
		var e EnvValue
		json.Unmarshal([]byte(v), &e)
		r.Env[k] = e
	})

	// Processes by name: shared when most recipes run it with the same command.
	var names []string
	seen := map[string]bool{}
	for _, r := range rs {
		for _, p := range r.Processes {
			if !seen[p.Name] {
				seen[p.Name] = true
				names = append(names, p.Name)
			}
		}
	}
	cmdOf := func(r Recipe, name string) (string, bool) {
		for _, p := range r.Processes {
			if p.Name == name {
				return p.Command, true
			}
		}
		return "", false
	}
	for _, name := range names {
		k, at := majority(n, func(i int) string {
			c, ok := cmdOf(rs[i], name)
			return jsonKey([]any{ok, c})
		})
		cmd, ok := cmdOf(rs[at], name)
		if ok {
			shared.Processes = append(shared.Processes, Process{name, cmd})
		}
		for i := range rs {
			c, has := cmdOf(rs[i], name)
			if jsonKey([]any{has, c}) == k {
				continue
			}
			over[i].Processes = append(over[i].Processes, Process{name, c})
		}
	}
	if len(shared.Notes) == 0 {
		shared.Notes = nil
	}
	return shared, over
}

// overrideFields names the fields an override sets, in the recipe's field order.
func overrideFields(r Recipe) []string {
	var out []string
	add := func(set bool, name string) {
		if set {
			out = append(out, name)
		}
	}
	add(r.Needs != nil, "needs")
	add(len(r.Ports) > 0, "ports")
	add(len(r.Env) > 0, "env")
	add(r.AlsoWriteEnvFile != nil, "alsoWriteEnvFile")
	add(r.Copy != nil, "copy")
	add(r.Clone != nil, "clone")
	add(r.Services != nil, "services")
	add(r.Setup != nil, "setup")
	add(r.Processes != nil, "processes")
	add(r.Build != nil, "build")
	add(r.Ready != nil, "ready")
	add(r.Teardown != nil, "teardown")
	return out
}
