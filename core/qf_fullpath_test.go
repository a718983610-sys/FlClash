package core

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
)

// Full app path for the rule-mode report: a minimal subscription goes
// through handleGetProfileBase + mergeProfileBase (the base path the
// app actually runs, with a host-style overlay) and must still expose
// its group, visible and pre-selected, via handleGetProxies.
const qfSyntheticSubscription = `
mode: rule
proxies:
  - {name: "节点甲", type: ss, server: 192.0.2.1, port: 8388, cipher: aes-256-gcm, password: "test-password", udp: true}
  - {name: "节点乙", type: ss, server: 192.0.2.2, port: 8388, cipher: aes-256-gcm, password: "test-password", udp: true}
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "节点甲"
      - "节点乙"
      - DIRECT
      - REJECT
rules:
  - MATCH,PROXY
`

const qfHostOverlay = `
mode: rule
mixed-port: 7890
allow-lan: false
log-level: info
dns:
  enable: true
  nameserver:
    - 223.5.5.5
profile:
  store-selected: false
rules: []
`

func TestQfFullPathRuleMode(t *testing.T) {
	home := t.TempDir()
	previous := constant.Path.HomeDir()
	constant.SetHomeDir(home)
	t.Cleanup(func() { constant.SetHomeDir(previous) })
	profilePath := filepath.Join(home, "profiles", "1.yaml")
	if err := os.MkdirAll(filepath.Dir(profilePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(profilePath, []byte(qfSyntheticSubscription), 0o644); err != nil {
		t.Fatal(err)
	}
	base, err := handleGetProfileBase(profilePath)
	if err != nil {
		t.Fatalf("getProfileBase: %v", err)
	}
	if base.Proxies != 2 || base.ProxyGroups != 1 || base.Rules != 1 {
		t.Fatalf("base counts = %d/%d/%d, want 2/1/1", base.Proxies, base.ProxyGroups, base.Rules)
	}
	setup := &SetupBase{Path: profilePath, Overlay: qfHostOverlay}
	cfg, err := loadConfigWithBase(setup, filepath.Join(home, "config.yaml"))
	if err != nil {
		t.Fatalf("loadConfigWithBase: %v", err)
	}
	if len(cfg.Rules) == 0 {
		t.Fatal("merged config carries no rules")
	}
	currentConfig = cfg
	hub.ApplyConfig(cfg)
	data := handleGetProxies()
	raw, ok := data.Proxies["PROXY"]
	if !ok {
		t.Fatalf("PROXY group missing from getProxies, all=%v", data.All)
	}
	view, _ := raw.(map[string]any)
	if view["hidden"] != false {
		t.Fatalf("PROXY hidden = %v, want false", view["hidden"])
	}
	if view["now"] != "节点甲" {
		t.Fatalf("PROXY now = %v, want the first member 节点甲", view["now"])
	}
}
