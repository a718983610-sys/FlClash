package core

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/config"
)

// The tolerant-load contract (1.0.3): an entry this core cannot use is
// dropped on its own and counted, the rest of the config loads and routes.
// Only a config with nothing usable at all is still an error.

func sanitizeForTest(t *testing.T, content string) (*config.RawConfig, *loadReport) {
	t.Helper()
	raw, err := unmarshalRawConfig([]byte(content))
	if err != nil {
		t.Fatalf("unmarshalRawConfig = %v", err)
	}
	return raw, sanitizeRawConfig(raw)
}

func parseAfterSanitize(t *testing.T, raw *config.RawConfig) *config.Config {
	t.Helper()
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatalf("ParseRawConfig after sanitize = %v", err)
	}
	return cfg
}

func TestSanitizeDropsBadProxiesKeepsGood(t *testing.T) {
	raw, report := sanitizeForTest(t, `
proxies:
  - {name: good-ss, type: ss, server: 127.0.0.1, port: 8388, cipher: aes-256-gcm, password: x}
  - {name: future-proto, type: vless2, server: 127.0.0.1, port: 443}
  - {name: bad-cipher, type: ss, server: 127.0.0.1, port: 8388, cipher: aes-999-gcm, password: x}
  - {name: anytls-node, type: anytls, server: 127.0.0.1, port: 443, password: secret}
proxy-groups:
  - {name: pick, type: select, proxies: [good-ss, future-proto, bad-cipher, anytls-node]}
rules:
  - MATCH,pick
`)
	cfg := parseAfterSanitize(t, raw)
	if _, ok := cfg.Proxies["good-ss"]; !ok {
		t.Error("good-ss should survive")
	}
	if _, ok := cfg.Proxies["anytls-node"]; !ok {
		t.Error("anytls-node should survive: the core parses anytls")
	}
	if _, ok := cfg.Proxies["future-proto"]; ok {
		t.Error("future-proto should have been dropped")
	}
	if report.Proxies != 2 || report.Total != 2 {
		t.Errorf("report = %d kept / %d skipped, want 2 / 2", report.Proxies, report.Total)
	}
}

// Display pseudo-nodes are dropped wherever they arrive, but the rule is
// narrow on purpose: a deliberate local proxy on a working port with a
// working name is a real outbound and stays, and so does a public node
// that merely mentions traffic in its name.
func TestSanitizeDropsLoopbackDisplayPseudoNodes(t *testing.T) {
	raw, report := sanitizeForTest(t, `
proxies:
  - {name: "📊 流量：已用约 9.22G", type: ss, server: 127.0.0.1, port: 1, cipher: aes-256-gcm, password: x}
  - {name: "到期提醒", type: ss, server: 127.0.0.1, port: 9999, cipher: aes-256-gcm, password: x}
  - {name: local-socks, type: socks5, server: 127.0.0.1, port: 1080}
  - {name: "大流量套餐·东京", type: ss, server: 192.0.2.9, port: 8388, cipher: aes-256-gcm, password: x}
proxy-groups:
  - {name: pick, type: select, proxies: ["📊 流量：已用约 9.22G", "到期提醒", local-socks, "大流量套餐·东京"]}
rules:
  - MATCH,pick
`)
	_ = parseAfterSanitize(t, raw)
	if report.Proxies != 2 {
		t.Errorf("kept = %d, want 2 (local-socks and the public node)", report.Proxies)
	}
	if report.Total != 2 {
		t.Errorf("skipped = %d, want the 2 display pseudo-nodes; skips: %+v", report.Total, report.Skipped)
	}
	keptNames := map[string]bool{}
	for _, mapping := range raw.Proxy {
		if name, ok := mapping["name"].(string); ok {
			keptNames[name] = true
		}
	}
	if !keptNames["local-socks"] || !keptNames["大流量套餐·东京"] {
		t.Errorf("kept = %v, want local-socks and the public traffic-named node", keptNames)
	}
}

func TestSanitizeDuplicateProxyDropped(t *testing.T) {
	raw, report := sanitizeForTest(t, `
proxies:
  - {name: node, type: ss, server: 127.0.0.1, port: 8388, cipher: aes-256-gcm, password: x}
  - {name: node, type: ss, server: 127.0.0.2, port: 8388, cipher: aes-256-gcm, password: y}
proxy-groups:
  - {name: pick, type: select, proxies: [node]}
rules:
  - MATCH,pick
`)
	parseAfterSanitize(t, raw)
	if report.Proxies != 1 || report.Total != 1 {
		t.Errorf("report = %d kept / %d skipped, want 1 / 1", report.Proxies, report.Total)
	}
}

func TestSanitizeGroupAndRuleCleanup(t *testing.T) {
	raw, report := sanitizeForTest(t, `
proxies:
  - {name: good, type: ss, server: 127.0.0.1, port: 8388, cipher: aes-256-gcm, password: x}
  - {name: bad, type: nosuchtype, server: 127.0.0.1, port: 1}
proxy-groups:
  - {name: mixed, type: select, proxies: [good, bad]}
  - {name: only-bad, type: select, proxies: [bad]}
rules:
  - DOMAIN-SUFFIX,example.com,mixed
  - DOMAIN-SUFFIX,example.org,only-bad
  - MATCH,mixed
`)
	cfg := parseAfterSanitize(t, raw)
	if _, ok := cfg.Proxies["mixed"]; !ok {
		t.Error("mixed group should survive with its good member")
	}
	if _, ok := cfg.Proxies["only-bad"]; ok {
		t.Error("only-bad group should have been dropped with its only member")
	}
	if len(cfg.Rules) != 2 {
		t.Errorf("kept rules = %d, want 2 (the one targeting only-bad dropped)", len(cfg.Rules))
	}
	if report.Total != 3 { // bad proxy, only-bad group, its rule
		t.Errorf("skipped = %d, want 3", report.Total)
	}
}

func TestSanitizeDialerProxyChain(t *testing.T) {
	raw, report := sanitizeForTest(t, `
proxies:
  - {name: front, type: ss, server: 127.0.0.1, port: 8388, cipher: aes-256-gcm, password: x, dialer-proxy: tail}
  - {name: tail, type: ss, server: 127.0.0.2, port: 8388, cipher: aes-256-gcm, password: y}
  - {name: stranded, type: ss, server: 127.0.0.3, port: 8388, cipher: aes-256-gcm, password: z, dialer-proxy: gone}
  - {name: gone, type: nosuchtype, server: 127.0.0.4, port: 1}
proxy-groups:
  - {name: pick, type: select, proxies: [front, tail, stranded]}
rules:
  - MATCH,pick
`)
	parseAfterSanitize(t, raw)
	if report.Proxies != 2 {
		t.Errorf("kept proxies = %d, want 2 (front via forward reference, tail)", report.Proxies)
	}
}

func TestSanitizeGroupForwardReferenceAndCycle(t *testing.T) {
	raw, _ := sanitizeForTest(t, `
proxies:
  - {name: good, type: ss, server: 127.0.0.1, port: 8388, cipher: aes-256-gcm, password: x}
proxy-groups:
  - {name: outer, type: select, proxies: [inner]}
  - {name: inner, type: select, proxies: [good]}
  - {name: cycle-a, type: select, proxies: [cycle-b]}
  - {name: cycle-b, type: select, proxies: [cycle-a]}
rules:
  - MATCH,outer
`)
	cfg := parseAfterSanitize(t, raw)
	if _, ok := cfg.Proxies["outer"]; !ok {
		t.Error("outer should survive: forward references to later groups are legal")
	}
	if _, ok := cfg.Proxies["cycle-a"]; ok {
		t.Error("cycle-a should have been dropped")
	}
	if _, ok := cfg.Proxies["cycle-b"]; ok {
		t.Error("cycle-b should have been dropped")
	}
}

func TestSanitizeAllBadIsUnusable(t *testing.T) {
	raw, report := sanitizeForTest(t, `
proxies:
  - {name: bad, type: nosuchtype, server: 127.0.0.1, port: 1}
proxy-groups:
  - {name: pick, type: select, proxies: [bad]}
rules:
  - MATCH,pick
`)
	if usableAfterSanitize(report, raw) {
		t.Error("a config whose only proxy is unusable must stay an error")
	}
}

func TestLoadConfigWithBaseNothingUsableFails(t *testing.T) {
	path := writeBaseProfile(t, `
proxies:
  - {name: bad, type: nosuchtype, server: 127.0.0.1, port: 1}
rules:
  - MATCH,DIRECT
`)
	base, err := handleGetProfileBase(path)
	if err != nil {
		t.Fatalf("handleGetProfileBase = %v", err)
	}
	_, err = loadConfigWithBase(
		&SetupBase{Path: path, Overlay: overlayOf(t, base, nil, nil)},
		filepath.Join(t.TempDir(), "config.yaml"),
	)
	if err != errNoUsableOutbounds {
		t.Fatalf("loadConfigWithBase = %v, want errNoUsableOutbounds", err)
	}
}

func TestSanitizeProviderOnlyConfigUsable(t *testing.T) {
	raw, report := sanitizeForTest(t, `
proxy-providers:
  airport:
    type: http
    url: "https://example.com/sub"
    interval: 3600
proxy-groups:
  - {name: pick, type: select, use: [airport]}
rules:
  - MATCH,pick
`)
	parseAfterSanitize(t, raw)
	if !usableAfterSanitize(report, raw) {
		t.Error("a provider-backed config with no inline proxies must be usable")
	}
}

func TestSanitizeRuleSetAndBadRuleDropped(t *testing.T) {
	raw, report := sanitizeForTest(t, `
proxies:
  - {name: good, type: ss, server: 127.0.0.1, port: 8388, cipher: aes-256-gcm, password: x}
proxy-groups:
  - {name: pick, type: select, proxies: [good]}
rules:
  - RULE-SET,missing-set,pick
  - IP-CIDR,999.999.0.0/16,pick
  - DOMAIN-SUFFIX,example.com,pick
  - MATCH,pick
`)
	parseAfterSanitize(t, raw)
	if report.Rules != 2 {
		t.Errorf("kept rules = %d, want 2", report.Rules)
	}
}

// A realistic airport profile with two entries this core cannot use must
// load in rule mode with the groups and rules intact.
func TestLoadConfigWithBaseTolerantAirport(t *testing.T) {
	profile := strings.Replace(
		airportProfile,
		`  - {name: "🇺🇸 美国01", type: hysteria2, server: us1.example.com, port: 443, password: "pass3"}`,
		`  - {name: "🇺🇸 美国01", type: hysteria2, server: us1.example.com, port: 443, password: "pass3"}
  - {name: "🇰🇷 韩国01", type: vless2, server: kr1.example.com, port: 443}
  - {name: "🇹🇼 台湾01", type: ss, server: tw1.example.com, port: 8388, cipher: aes-999-gcm, password: "pass4"}`,
		1,
	)
	profile = strings.Replace(
		profile,
		`proxies: ["♻️ 自动选择", "🇭🇰 香港01", "🇯🇵 日本01", "🇺🇸 美国01", "🇸🇬 新加坡01", DIRECT]`,
		`proxies: ["♻️ 自动选择", "🇭🇰 香港01", "🇯🇵 日本01", "🇺🇸 美国01", "🇸🇬 新加坡01", "🇰🇷 韩国01", "🇹🇼 台湾01", DIRECT]`,
		1,
	)
	path := writeBaseProfile(t, profile)
	base, err := handleGetProfileBase(path)
	if err != nil {
		t.Fatalf("handleGetProfileBase = %v", err)
	}
	cfg, err := loadConfigWithBase(
		&SetupBase{Path: path, Overlay: overlayOf(t, base, nil, nil)},
		filepath.Join(t.TempDir(), "config.yaml"),
	)
	if err != nil {
		t.Fatalf("loadConfigWithBase = %v", err)
	}
	if _, ok := cfg.Proxies["🇰🇷 韩国01"]; ok {
		t.Error("the unparseable node should have been dropped, not kept")
	}
	if _, ok := cfg.Proxies["🚀 节点选择"]; !ok {
		t.Error("the select group should survive without its bad members")
	}
	if len(cfg.Rules) == 0 {
		t.Error("rules should survive in rule mode")
	}
	if got := cfg.General.Mode.String(); got != "rule" {
		t.Errorf("mode = %q, want rule", got)
	}
	report := handleGetLoadReport()
	if report.Total != 2 || report.Proxies != 4 {
		t.Errorf("report = %d skipped / %d proxies, want 2 / 4", report.Total, report.Proxies)
	}
}

func TestLoadConfigSecondChanceDropsBrokenSections(t *testing.T) {
	yamlText := `
proxies:
  - {name: ok-node, type: ss, server: 127.0.0.1, port: 8388, cipher: aes-128-gcm, password: pw}
proxy-groups:
  - {name: main, type: select, proxies: [ok-node]}
listeners:
  - {name: bad-listener, type: definitely-not-a-listener, port: 9999}
rules:
  - MATCH,main
`
	raw, err := unmarshalRawConfig([]byte(yamlText))
	if err != nil {
		t.Fatalf("unmarshalRawConfig: %v", err)
	}
	if _, err := config.ParseRawConfig(raw); err == nil {
		t.Fatal("the poisoned config unexpectedly parses without the second chance")
	}
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte(yamlText), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatalf("loadConfig should survive a broken auxiliary section: %v", err)
	}
	if _, ok := cfg.Proxies["ok-node"]; !ok {
		t.Fatal("the usable proxy did not survive the second-chance load")
	}
	report := handleGetLoadReport()
	found := false
	for _, skip := range report.Skipped {
		if skip.Kind == "section" {
			found = true
		}
	}
	if !found {
		t.Fatal("the dropped section was not recorded in the load report")
	}
}
