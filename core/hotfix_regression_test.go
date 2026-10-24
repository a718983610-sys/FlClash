package core

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

// The 1.0.1 hotfix contract: a config that fails to load must fail the
// apply and leave the previously applied config untouched. It must never
// be swapped for the built-in default, which has no proxies: with the VPN
// up, that default captures every packet with nowhere to route it.
func TestApplyConfigFailureKeepsPreviousConfig(t *testing.T) {
	broken := map[string]string{
		"group referencing a missing proxy": "proxies:\n  - {name: a, type: ss, server: 127.0.0.1, port: 8388, cipher: aes-256-gcm, password: x}\nproxy-groups:\n  - {name: g, type: select, proxies: [missing-node]}\nrules:\n  - MATCH,g\n",
		"not yaml at all":                   "{{{\n",
	}
	for name, content := range broken {
		t.Run(name, func(t *testing.T) {
			home := t.TempDir()
			previous := constant.Path.HomeDir()
			constant.SetHomeDir(home)
			t.Cleanup(func() { constant.SetHomeDir(previous) })
			if err := os.WriteFile(filepath.Join(home, "config.yaml"), []byte(content), 0o600); err != nil {
				t.Fatalf("write config: %v", err)
			}
			sentinel, err := config.ParseRawConfig(config.DefaultRawConfig())
			if err != nil {
				t.Fatalf("parse sentinel: %v", err)
			}
			previousConfig := currentConfig
			currentConfig = sentinel
			t.Cleanup(func() { currentConfig = previousConfig })

			if err := applyConfig(defaultSetupParams()); err == nil {
				t.Fatal("applyConfig accepted a broken config")
			}
			if currentConfig != sentinel {
				t.Fatal("applyConfig replaced the running config after a failed load")
			}
		})
	}
}

// The selection-restore contract after the hotfix: a saved selection that
// is still a member is restored as-is; one the group no longer has falls
// back to the group's first member instead of lingering in Now().
func TestPatchSelectGroupSelectionContract(t *testing.T) {
	group := selectorGroup(t, "group", "node-a", "node-b")
	tunnel.UpdateProxies(map[string]constant.Proxy{"group": group}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	patchSelectGroup(map[string]string{"group": "node-b"})
	if got := groupNow(t, group); got != "node-b" {
		t.Fatalf("group resolved to %q, want the restored selection", got)
	}

	patchSelectGroup(map[string]string{"group": "a name the provider dropped"})
	if got := groupNow(t, group); got != "node-a" {
		t.Errorf("group resolved to %q after a stale selection, want the first member", got)
	}
}

// A realistic airport-style subscription must load through the profile
// base path (the path an upgraded install takes for its stored profile).
const airportProfile = `mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
dns:
  enable: true
  enhanced-mode: fake-ip
  nameserver: [https://doh.pub/dns-query, https://dns.alidns.com/dns-query]
proxies:
  - {name: "🇭🇰 香港01", type: ss, server: hk1.example.com, port: 8388, cipher: aes-256-gcm, password: "pass1"}
  - {name: "🇯🇵 日本01", type: trojan, server: jp1.example.com, port: 443, password: "pass2", sni: jp1.example.com}
  - {name: "🇺🇸 美国01", type: hysteria2, server: us1.example.com, port: 443, password: "pass3"}
  - name: "🇸🇬 新加坡01"
    type: vless
    server: sg1.example.com
    port: 443
    uuid: 2a70e3a9-b4ce-4f20-908d-e99950a0a611
    network: tcp
    tls: true
    flow: xtls-rprx-vision
    reality-opts: {public-key: SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc, short-id: 12ab}
proxy-groups:
  - {name: "🚀 节点选择", type: select, proxies: ["♻️ 自动选择", "🇭🇰 香港01", "🇯🇵 日本01", "🇺🇸 美国01", "🇸🇬 新加坡01", DIRECT]}
  - {name: "♻️ 自动选择", type: url-test, proxies: ["🇭🇰 香港01", "🇯🇵 日本01", "🇺🇸 美国01", "🇸🇬 新加坡01"], url: "http://www.gstatic.com/generate_204", interval: 300}
rules:
  - DOMAIN-SUFFIX,example.com,DIRECT
  - MATCH,🚀 节点选择
`

func TestLoadConfigWithBaseAirportStyleProfile(t *testing.T) {
	path := writeBaseProfile(t, airportProfile)
	base, err := handleGetProfileBase(path)
	if err != nil {
		t.Fatalf("handleGetProfileBase = %v", err)
	}
	if base.Proxies != 4 || base.ProxyGroups != 2 {
		t.Fatalf("base counts = %d proxies / %d groups, want 4 / 2", base.Proxies, base.ProxyGroups)
	}
	cfg, err := loadConfigWithBase(
		&SetupBase{Path: path, Overlay: overlayOf(t, base, nil, nil)},
		filepath.Join(t.TempDir(), "config.yaml"),
	)
	if err != nil {
		t.Fatalf("loadConfigWithBase = %v", err)
	}
	if len(cfg.Proxies) < 4 {
		t.Errorf("loaded %d proxies, want at least the 4 nodes", len(cfg.Proxies))
	}
}

func TestLoadSetupConfigAirportStyleProfile(t *testing.T) {
	home := t.TempDir()
	previous := constant.Path.HomeDir()
	constant.SetHomeDir(home)
	t.Cleanup(func() { constant.SetHomeDir(previous) })
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), []byte(airportProfile), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	cfg, err := loadSetupConfig(defaultSetupParams())
	if err != nil {
		t.Fatalf("loadSetupConfig = %v", err)
	}
	if len(cfg.Proxies) < 4 {
		t.Errorf("loaded %d proxies, want at least the 4 nodes", len(cfg.Proxies))
	}
}

// Airports commonly share node fields through YAML anchors and merge
// keys; the merged document the base path produces must still parse, and
// the config.yaml it writes must load again on its own (the Android
// service reloads it without the profile).
func TestLoadConfigWithBaseAnchoredAirportProfile(t *testing.T) {
	profile := `x-base: &base {type: ss, server: hk1.example.com, port: 8388, cipher: aes-256-gcm, password: "pass1", udp: true}
proxies:
  - {<<: *base, name: "🇭🇰 香港01"}
  - {<<: *base, name: "🇭🇰 香港02", server: hk2.example.com}
proxy-groups:
  - {name: "🚀 节点选择", type: select, proxies: ["🇭🇰 香港01", "🇭🇰 香港02", DIRECT]}
rules:
  - MATCH,🚀 节点选择
`
	path := writeBaseProfile(t, profile)
	base, err := handleGetProfileBase(path)
	if err != nil {
		t.Fatalf("handleGetProfileBase = %v", err)
	}
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	cfg, err := loadConfigWithBase(
		&SetupBase{Path: path, Overlay: overlayOf(t, base, nil, nil)},
		configPath,
	)
	if err != nil {
		t.Fatalf("loadConfigWithBase with anchors = %v", err)
	}
	if cfg.Proxies["🇭🇰 香港01"] == nil || cfg.Proxies["🇭🇰 香港02"] == nil {
		t.Errorf("anchored nodes missing after merge: %v", cfg.Proxies)
	}
	reloaded, err := loadConfig(configPath)
	if err != nil {
		t.Fatalf("loadConfig(written config.yaml) = %v", err)
	}
	if len(reloaded.Proxies) != len(cfg.Proxies) {
		t.Errorf("reloaded %d proxies, want %d", len(reloaded.Proxies), len(cfg.Proxies))
	}
}

// A reality node whose short-id is written as a bare number (some airport
// generators emit it unquoted) must survive the base merge path.
func TestLoadConfigWithBaseNumericShortID(t *testing.T) {
	profile := `proxies:
  - name: r
    type: vless
    server: 127.0.0.1
    port: 443
    uuid: 2a70e3a9-b4ce-4f20-908d-e99950a0a611
    network: tcp
    tls: true
    reality-opts: {public-key: SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc, short-id: 8888}
proxy-groups:
  - {name: g, type: select, proxies: [r]}
rules:
  - MATCH,g
`
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
		t.Fatalf("loadConfigWithBase with a numeric short-id = %v", err)
	}
	if cfg.Proxies["r"] == nil {
		t.Error("the reality node is missing after the merge")
	}
}

// What a subscription refresh that saved an error page (or any non-config
// body) leaves behind: the profile file no longer parses, so the base
// lookup fails before any config can be built from it. This documents the
// trigger end of the outage chain; the fixes make it surface as a failed
// setup instead of an empty running config.
func TestGetProfileBaseRejectsAGarbageProfileFile(t *testing.T) {
	path := writeBaseProfile(t, "<html><head><title>502 Bad Gateway</title></head><body>nginx</body></html>\n")
	if _, err := handleGetProfileBase(path); err == nil {
		t.Fatal("handleGetProfileBase accepted an HTML error page as a profile")
	}
}
