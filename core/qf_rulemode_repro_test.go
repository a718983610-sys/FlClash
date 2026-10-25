package core

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/hub"
)

// Repro for the 1.1.3 rule-mode report: a minimal clash subscription whose
// only group is a select group ending in DIRECT/REJECT and whose only rule
// is MATCH,<group> must surface that group (not hidden) with all members
// after a config load, in the config's own mode (rule).
const qfRuleModeSubscription = `
mixed-port: 7890
mode: rule
proxies:
  - name: "🇹🇼台北（SS协议首选）"
    type: ss
    server: 192.0.2.11
    port: 8388
    cipher: 2022-blake3-aes-128-gcm
    password: "test-password-one"
    udp: true
  - name: "🇹🇼台北（Hy2协议备用）"
    type: hysteria2
    server: 192.0.2.12
    port: 443
    password: "test-password-two"
    sni: example.com
    skip-cert-verify: true
    ports: 20000-40000
  - name: "🇯🇵东京（SS协议首选）"
    type: ss
    server: 192.0.2.13
    port: 8388
    cipher: 2022-blake3-aes-128-gcm
    password: "test-password-three"
    udp: true
  - name: "🇯🇵东京（Hy2协议 备选）"
    type: hysteria2
    server: 192.0.2.14
    port: 443
    password: "test-password-four"
    sni: example.com
    skip-cert-verify: true
proxy-groups:
  - name: AWS组
    type: select
    proxies:
      - "🇹🇼台北（SS协议首选）"
      - "🇹🇼台北（Hy2协议备用）"
      - "🇯🇵东京（SS协议首选）"
      - "🇯🇵东京（Hy2协议 备选）"
      - DIRECT
      - REJECT
rules:
  - MATCH,AWS组
`

func TestQfRuleModeSubscriptionExposesGroup(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte(qfRuleModeSubscription), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	report := handleGetLoadReport()
	t.Logf("load report: total=%d proxies=%d groups=%d rules=%d skipped=%v",
		report.Total, report.Proxies, report.Groups, report.Rules, report.Skipped)
	hub.ApplyConfig(cfg)
	t.Cleanup(func() { hub.ApplyConfig(nil) })

	data := handleGetProxies()
	t.Logf("All names: %v", data.All)
	for name, view := range data.Proxies {
		if m, ok := view.(map[string]any); ok {
			t.Logf("view %q: type=%v hidden=%v all=%v now=%v",
				name, m["type"], m["hidden"], m["all"], m["now"])
		} else {
			t.Logf("view %q: %#v", name, view)
		}
	}
	raw, ok := data.Proxies["AWS组"]
	if !ok {
		t.Fatalf("AWS组 missing from getProxies views; All=%v", data.All)
	}
	view, ok := raw.(map[string]any)
	if !ok {
		t.Fatalf("AWS组 view is %T, want group map", raw)
	}
	if hidden, _ := view["hidden"].(bool); hidden {
		t.Errorf("AWS组 hidden=true, want false")
	}
	members, _ := view["all"].([]string)
	if len(members) != 6 {
		t.Errorf("AWS组 members = %v, want 6 entries", members)
	}
	found := false
	for _, n := range data.All {
		if n == "AWS组" {
			found = true
		}
	}
	if !found {
		t.Errorf("AWS组 missing from All list %v", data.All)
	}
	// The group must accept a selection change (dashboard pre-selection path).
	res := handleChangeProxy(&ChangeProxyParams{
		GroupName: "AWS组",
		ProxyName: "🇯🇵东京（SS协议首选）",
	})
	if res == nil || res.Message != "" {
		t.Errorf("changeProxy on AWS组: %+v", res)
	}
}
