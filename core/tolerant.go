package core

import (
	"errors"
	"fmt"
	"net"
	"regexp"
	"strings"
	"sync"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/log"
	R "github.com/metacubex/mihomo/rules"
	RC "github.com/metacubex/mihomo/rules/common"
)

// Display pseudo-nodes ride along in subscription bodies (Shadowrocket
// style): they point at a loopback address and exist only so a client
// can render account info - remaining traffic, expiry, the panel site -
// as a fake node entry. They can never carry traffic, and presented as
// real nodes they crowd out the usable ones, so conversion and
// sanitizing both drop them. A proxy counts as one when its server is a
// loopback address AND either its port is a privileged display port
// (< 100, e.g. the canonical 127.0.0.1:1) or its name is an info label.
// A deliberate local proxy (127.0.0.1:1080 and the like, with a working
// name) matches neither condition and is kept.
var displayNodeNamePattern = regexp.MustCompile(`剩余|剩餘|流量|到期|过期|過期|有效期|官网|官網|公告|套餐|重置`)

func isDisplayPseudoProxy(mapping map[string]any) bool {
	server, _ := mapping["server"].(string)
	if !isLoopbackServer(server) {
		return false
	}
	if port, ok := proxyPortOf(mapping["port"]); ok && port < 100 {
		return true
	}
	name, _ := mapping["name"].(string)
	return displayNodeNamePattern.MatchString(name)
}

func isLoopbackServer(server string) bool {
	host := strings.TrimSpace(strings.ToLower(server))
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func proxyPortOf(raw any) (int, bool) {
	switch value := raw.(type) {
	case int:
		return value, true
	case int64:
		return int(value), true
	case float64:
		return int(value), true
	case string:
		var port int
		if _, err := fmt.Sscanf(value, "%d", &port); err == nil {
			return port, true
		}
	}
	return 0, false
}

// A single bad entry in a subscription must not reject the whole config:
// panels emit entries this core cannot parse (a newer protocol revision, a
// mistyped field, a duplicated name), and mihomo's parser aborts on the
// first one. Sanitizing drops the unusable entries instead and keeps the
// rest, so the profile still routes. Only a config with nothing usable at
// all stays an error, which keeps the fail-closed behaviour for the case
// that used to blackhole the device.

type loadSkip struct {
	Kind   string `json:"kind"`
	Name   string `json:"name"`
	Reason string `json:"reason"`
}

type loadReport struct {
	Skipped []loadSkip `json:"skipped"`
	Total   int        `json:"total"`
	Proxies int        `json:"proxies"`
	Groups  int        `json:"groups"`
	Rules   int        `json:"rules"`

	declaredProxies   int
	declaredProviders int
}

const maxRecordedSkips = 200

var errNoUsableOutbounds = errors.New("no usable proxies or proxy providers in the config")

var builtinOutbounds = map[string]bool{
	"DIRECT": true, "REJECT": true, "REJECT-DROP": true,
	"COMPATIBLE": true, "PASS": true, "PASS-RULE": true, "GLOBAL": true,
}

var knownGroupTypes = map[string]bool{
	"select": true, "url-test": true, "fallback": true,
	"load-balance": true, "relay": true,
}

var (
	lastLoadReportMu sync.Mutex
	lastLoadReport   = &loadReport{Skipped: []loadSkip{}}
)

func handleGetLoadReport() *loadReport {
	lastLoadReportMu.Lock()
	defer lastLoadReportMu.Unlock()
	return lastLoadReport
}

func setLoadReport(report *loadReport) {
	lastLoadReportMu.Lock()
	defer lastLoadReportMu.Unlock()
	lastLoadReport = report
}

type sanitizer struct {
	report  *loadReport
	proxies map[string]bool
	groups  map[string]bool
}

func (s *sanitizer) skip(kind, name, reason string) {
	s.report.Total++
	if len(s.report.Skipped) < maxRecordedSkips {
		s.report.Skipped = append(s.report.Skipped, loadSkip{Kind: kind, Name: name, Reason: reason})
	}
	log.Warnln("config entry skipped (%s %q): %s", kind, name, reason)
}

func mappingName(mapping map[string]any) string {
	name, _ := mapping["name"].(string)
	return name
}

func stringList(value any) []string {
	items, ok := value.([]any)
	if !ok {
		return nil
	}
	names := make([]string, 0, len(items))
	for _, item := range items {
		if name, ok := item.(string); ok {
			names = append(names, name)
		}
	}
	return names
}

func (s *sanitizer) dropBadProviders(raw *config.RawConfig) map[string]bool {
	kept := make(map[string]bool, len(raw.ProxyProvider))
	for name, mapping := range raw.ProxyProvider {
		usable := false
		for _, key := range []string{"url", "path", "payload"} {
			if value, ok := mapping[key].(string); ok && value != "" {
				usable = true
			}
		}
		if usable {
			kept[name] = true
		} else {
			s.skip("proxy-provider", name, "provider has no url, path or payload")
			delete(raw.ProxyProvider, name)
		}
	}
	return kept
}

// Proxies and groups validate against each other (a dialer-proxy may name a
// group, a group lists proxies), so both passes repeat until neither drops
// anything new.
func (s *sanitizer) dropBadProxiesAndGroups(raw *config.RawConfig, providers map[string]bool) {
	groupNames := make(map[string]bool, len(raw.ProxyGroup))
	for _, mapping := range raw.ProxyGroup {
		if name := mappingName(mapping); name != "" {
			groupNames[name] = true
		}
	}
	for {
		proxiesChanged := s.dropBadProxies(raw, groupNames)
		groupsChanged := s.dropBadGroups(raw, providers)
		groupNames = make(map[string]bool, len(s.groups))
		for name := range s.groups {
			groupNames[name] = true
		}
		if !proxiesChanged && !groupsChanged {
			return
		}
	}
}

func (s *sanitizer) dropBadProxies(raw *config.RawConfig, groupNames map[string]bool) bool {
	changed := false
	kept := make([]map[string]any, 0, len(raw.Proxy))
	names := make(map[string]bool, len(raw.Proxy))
	for _, mapping := range raw.Proxy {
		name := mappingName(mapping)
		switch {
		case name == "":
			s.skip("proxy", "", "missing name")
			changed = true
			continue
		case builtinOutbounds[name] || groupNames[name]:
			s.skip("proxy", name, "name conflicts with a built-in outbound or a proxy group")
			changed = true
			continue
		case names[name]:
			s.skip("proxy", name, "duplicate name")
			changed = true
			continue
		}
		if isDisplayPseudoProxy(mapping) {
			s.skip("proxy", name, "loopback display pseudo-node (info entry, not a usable proxy)")
			changed = true
			continue
		}
		if _, err := adapter.ParseProxy(mapping); err != nil {
			s.skip("proxy", name, err.Error())
			changed = true
			continue
		}
		names[name] = true
		kept = append(kept, mapping)
	}
	// A dialer-proxy may name any entry in the file, in any order, so the
	// reference check runs over the whole surviving set and cascades: losing
	// a chain's tail drops every link above it.
	for {
		dropped := false
		surviving := make([]map[string]any, 0, len(kept))
		for _, mapping := range kept {
			dialer, ok := mapping["dialer-proxy"].(string)
			if ok && dialer != "" && !names[dialer] && !groupNames[dialer] && !builtinOutbounds[dialer] {
				s.skip("proxy", mappingName(mapping), fmt.Sprintf("dialer-proxy %q not found", dialer))
				delete(names, mappingName(mapping))
				changed, dropped = true, true
				continue
			}
			surviving = append(surviving, mapping)
		}
		kept = surviving
		if !dropped {
			break
		}
	}
	raw.Proxy = kept
	s.proxies = names
	return changed
}

func (s *sanitizer) dropBadGroups(raw *config.RawConfig, providers map[string]bool) bool {
	changed := false
	candidates := make([]map[string]any, 0, len(raw.ProxyGroup))
	names := make(map[string]bool, len(raw.ProxyGroup))
	for _, mapping := range raw.ProxyGroup {
		name := mappingName(mapping)
		kind, _ := mapping["type"].(string)
		switch {
		case name == "":
			s.skip("proxy-group", "", "missing name")
			changed = true
			continue
		case builtinOutbounds[name] || s.proxies[name]:
			s.skip("proxy-group", name, "name conflicts with a built-in outbound or a proxy")
			changed = true
			continue
		case names[name]:
			s.skip("proxy-group", name, "duplicate name")
			changed = true
			continue
		case !knownGroupTypes[kind]:
			s.skip("proxy-group", name, fmt.Sprintf("unsupported type %q", kind))
			changed = true
			continue
		case !validGroupFilter(mapping):
			s.skip("proxy-group", name, "invalid filter expression")
			changed = true
			continue
		}
		names[name] = true
		candidates = append(candidates, mapping)
	}
	// Members may name groups defined later in the file, so filtering runs
	// against the full candidate set; dropping an emptied group can empty
	// the groups that named only it, which the loop cascades through.
	for {
		dropped := false
		surviving := make([]map[string]any, 0, len(candidates))
		for _, mapping := range candidates {
			members := filterNames(mapping["proxies"], func(member string) bool {
				return s.proxies[member] || names[member] || builtinOutbounds[member]
			})
			if _, has := mapping["proxies"]; has {
				mapping["proxies"] = members
			}
			uses := filterNames(mapping["use"], func(provider string) bool {
				return providers[provider]
			})
			if _, has := mapping["use"]; has {
				mapping["use"] = uses
			}
			if len(members) == 0 && len(uses) == 0 && !includesAll(mapping) {
				s.skip("proxy-group", mappingName(mapping), "no usable members")
				delete(names, mappingName(mapping))
				changed, dropped = true, true
				continue
			}
			surviving = append(surviving, mapping)
		}
		candidates = surviving
		if !dropped {
			break
		}
	}
	raw.ProxyGroup = candidates
	s.groups = names
	return changed
}

func validGroupFilter(mapping map[string]any) bool {
	for _, key := range []string{"filter", "exclude-filter"} {
		if pattern, ok := mapping[key].(string); ok && pattern != "" {
			if _, err := regexp.Compile(pattern); err != nil {
				return false
			}
		}
	}
	return true
}

func includesAll(mapping map[string]any) bool {
	for _, key := range []string{"include-all", "include-all-proxies", "include-all-providers"} {
		if flag, ok := mapping[key].(bool); ok && flag {
			return true
		}
	}
	return false
}

func filterNames(value any, keep func(string) bool) []any {
	items, ok := value.([]any)
	if !ok {
		return nil
	}
	filtered := make([]any, 0, len(items))
	for _, item := range items {
		if name, ok := item.(string); ok && keep(name) {
			filtered = append(filtered, item)
		}
	}
	return filtered
}

// Groups naming each other in a cycle make mihomo's DAG sort reject the
// whole config; dropping the cycle members keeps the rest.
func (s *sanitizer) dropCyclicGroups(raw *config.RawConfig) {
	for {
		cycle := findGroupCycle(raw.ProxyGroup)
		if cycle == "" {
			return
		}
		kept := raw.ProxyGroup[:0]
		for _, mapping := range raw.ProxyGroup {
			if mappingName(mapping) == cycle {
				s.skip("proxy-group", cycle, "circular group reference")
				continue
			}
			kept = append(kept, mapping)
		}
		raw.ProxyGroup = kept
		delete(s.groups, cycle)
	}
}

func findGroupCycle(groups []map[string]any) string {
	const (
		white = 0
		gray  = 1
		black = 2
	)
	colors := make(map[string]int, len(groups))
	members := make(map[string][]string, len(groups))
	for _, mapping := range groups {
		name := mappingName(mapping)
		members[name] = stringList(mapping["proxies"])
	}
	var visit func(name string) string
	visit = func(name string) string {
		colors[name] = gray
		for _, member := range members[name] {
			if _, isGroup := members[member]; !isGroup {
				continue
			}
			switch colors[member] {
			case gray:
				return member
			case white:
				if found := visit(member); found != "" {
					return found
				}
			}
		}
		colors[name] = black
		return ""
	}
	for _, mapping := range groups {
		if name := mappingName(mapping); colors[name] == white {
			if found := visit(name); found != "" {
				return found
			}
		}
	}
	return ""
}

func (s *sanitizer) outboundNames() map[string]bool {
	names := make(map[string]bool, len(s.proxies)+len(s.groups)+len(builtinOutbounds))
	for name := range builtinOutbounds {
		names[name] = true
	}
	for name := range s.proxies {
		names[name] = true
	}
	for name := range s.groups {
		names[name] = true
	}
	return names
}

// A rule whose payload is mistyped (a bad CIDR, a bad port range) fails
// mihomo's rule parse just like a bad proxy fails its proxy parse, so the
// same per-entry trial applies. Logic rules are exempt: their nested
// payloads can reference sub-rules this trial cannot see.
func parsesAsRule(tp, payload, target string, params []string) bool {
	_, err := R.ParseRule(tp, payload, target, params, nil)
	return err == nil
}

func (s *sanitizer) dropBadRules(raw *config.RawConfig) {
	outbounds := s.outboundNames()
	raw.Rule = s.filterRules(raw.Rule, "rule", outbounds, raw)
	for name, lines := range raw.SubRules {
		raw.SubRules[name] = s.filterRules(lines, "sub-rule "+name, outbounds, raw)
	}
}

func (s *sanitizer) filterRules(lines []string, kind string, outbounds map[string]bool, raw *config.RawConfig) []string {
	kept := make([]string, 0, len(lines))
	subRuleNames := make(map[string]bool, len(raw.SubRules))
	for name := range raw.SubRules {
		subRuleNames[name] = true
	}
	for _, line := range lines {
		tp, payload, target, params := RC.ParseRulePayload(line, true)
		switch {
		case target == "":
			s.skip(kind, line, "malformed rule")
		case tp == "SUB-RULE":
			if subRuleNames[target] {
				kept = append(kept, line)
			} else {
				s.skip(kind, line, fmt.Sprintf("sub-rule %q not found", target))
			}
		case !outbounds[target]:
			s.skip(kind, line, fmt.Sprintf("outbound %q not found", target))
		case tp == "RULE-SET" && raw.RuleProvider[payload] == nil:
			s.skip(kind, line, fmt.Sprintf("rule set %q not found", payload))
		case tp != "AND" && tp != "OR" && tp != "NOT" && !parsesAsRule(tp, payload, target, params):
			s.skip(kind, line, "invalid rule")
		default:
			kept = append(kept, line)
		}
	}
	return kept
}

// sanitizeRawConfig drops every entry mihomo would reject the whole config
// for, mutating raw in place, and returns what was dropped and what remains.
func sanitizeRawConfig(raw *config.RawConfig) *loadReport {
	s := &sanitizer{
		report:  &loadReport{Skipped: []loadSkip{}},
		proxies: map[string]bool{},
		groups:  map[string]bool{},
	}
	s.report.declaredProxies = len(raw.Proxy)
	s.report.declaredProviders = len(raw.ProxyProvider)
	providers := s.dropBadProviders(raw)
	s.dropBadProxiesAndGroups(raw, providers)
	s.dropCyclicGroups(raw)
	// Losing the cycle members can empty out groups that named only them.
	s.dropBadProxiesAndGroups(raw, providers)
	s.dropBadRules(raw)
	s.report.Proxies = len(raw.Proxy)
	s.report.Groups = len(raw.ProxyGroup)
	s.report.Rules = len(raw.Rule)
	if s.report.Total > 0 {
		log.Warnln(
			"tolerant config load: skipped %d unusable entries, keeping %d proxies, %d groups, %d rules",
			s.report.Total, s.report.Proxies, s.report.Groups, s.report.Rules,
		)
	}
	return s.report
}

func (r *loadReport) noteSkip(kind, name, reason string) {
	r.Total++
	if len(r.Skipped) < maxRecordedSkips {
		r.Skipped = append(r.Skipped, loadSkip{Kind: kind, Name: name, Reason: reason})
	}
	log.Warnln("config entry skipped (%s %q): %s", kind, name, reason)
}

// Sections outside the outbound set (dns, tun, sniffer, listeners and the
// like) must not sink a config whose proxies, groups and rules are fine:
// when the full parse fails, retry once with only the routing essentials
// kept and the rest reset to defaults.
func parseRawConfigTolerant(raw *config.RawConfig, report *loadReport) (*config.Config, error) {
	cfg, err := config.ParseRawConfig(raw)
	if err == nil {
		return cfg, nil
	}
	stripped := config.DefaultRawConfig()
	stripped.Proxy = raw.Proxy
	stripped.ProxyGroup = raw.ProxyGroup
	stripped.ProxyProvider = raw.ProxyProvider
	stripped.RuleProvider = raw.RuleProvider
	stripped.Rule = raw.Rule
	stripped.SubRules = raw.SubRules
	stripped.Mode = raw.Mode
	stripped.LogLevel = raw.LogLevel
	stripped.IPv6 = raw.IPv6
	stripped.Port = raw.Port
	stripped.SocksPort = raw.SocksPort
	stripped.MixedPort = raw.MixedPort
	stripped.AllowLan = raw.AllowLan
	stripped.BindAddress = raw.BindAddress
	stripped.UnifiedDelay = raw.UnifiedDelay
	stripped.GlobalUA = raw.GlobalUA
	stripped.TCPConcurrent = raw.TCPConcurrent
	retry, retryErr := config.ParseRawConfig(stripped)
	if retryErr != nil {
		return nil, err
	}
	report.noteSkip("section", "advanced", fmt.Sprintf("unsupported sections reset to defaults: %v", err))
	return retry, nil
}

// A profile that declares no proxies and no providers at all is an empty
// profile: it loads onto the defaults, as it always has (and the host's
// own health gate still refuses to start a VPN on it). The error is for a
// profile that declared entries and lost every one of them: starting on
// that would blackhole the device behind an empty exit set.
func usableAfterSanitize(report *loadReport, raw *config.RawConfig) bool {
	if report.Proxies > 0 || len(raw.ProxyProvider) > 0 {
		return true
	}
	return report.declaredProxies == 0 && report.declaredProviders == 0
}
