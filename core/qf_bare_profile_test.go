package core

import (
	"encoding/base64"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/tunnel"
)

// A profile that declares proxies but no groups reaches the core with
// only the built-in GLOBAL group unless the host wraps it: the merge
// contract is that the overlay carries the synthesized group (and its
// MATCH rule) for such a profile, and the profile's own sections win
// whenever it declares them. These tests pin both halves end to end.

const qfBareTokyoSS = "🇯🇵东京（SS协议首选）"
const qfBareTokyoHy2 = "🇯🇵东京（Hy2协议 备选）"
const qfBareTaipeiSS = "🇹🇼台北（SS协议首选）"
const qfBareTaipeiHy2 = "🇹🇼台北（Hy2协议备用）"
const qfBareGroupName = "节点选择"

func qfBareLinkListBody() string {
	fragment := func(name string) string {
		return strings.ReplaceAll(url.QueryEscape(name), "+", "%20")
	}
	ss := func(userInfo, server string, port int, name string) string {
		return fmt.Sprintf("ss://%s@%s:%d#%s",
			base64.StdEncoding.EncodeToString([]byte(userInfo)),
			server, port, fragment(name))
	}
	hy2 := func(password, server string, name string) string {
		return fmt.Sprintf("hysteria2://%s@%s:443?insecure=1#%s",
			url.QueryEscape(password), server, fragment(name))
	}
	lines := []string{
		ss("aes-256-gcm:dummy", "127.0.0.1", 1, "📊 东京流量：已用约 14.94G ｜ 月包 3TB"),
		ss("aes-256-gcm:dummy", "127.0.0.1", 1, "📊 台北流量：已用约 16.06G ｜ 月免费 100G"),
		ss("2022-blake3-aes-128-gcm:MDEyMzQ1Njc4OWFiY2RlZg==", "192.0.2.21", 8000, qfBareTokyoSS),
		hy2("scratch-password-tokyo", "192.0.2.21", qfBareTokyoHy2),
		ss("2022-blake3-aes-128-gcm:ZmVkY2JhOTg3NjU0MzIxMA==", "192.0.2.22", 8000, qfBareTaipeiSS),
		hy2("scratch-password-taipei", "192.0.2.22", qfBareTaipeiHy2),
	}
	return base64.StdEncoding.EncodeToString([]byte(strings.Join(lines, "\n")))
}

// The overlay the host build emits for a bare profile: the synthesized
// group plus the default split rules ending in its MATCH rule, nothing
// else profile-shaped.
func qfBareSynthOverlay() string {
	members := []string{qfBareTokyoSS, qfBareTokyoHy2, qfBareTaipeiSS, qfBareTaipeiHy2}
	var b strings.Builder
	b.WriteString("mode: rule\nmixed-port: 7890\nallow-lan: false\nlog-level: info\n")
	b.WriteString("proxy-groups:\n  - name: " + qfBareGroupName + "\n    type: select\n    proxies:\n")
	for _, name := range members {
		b.WriteString("      - \"" + name + "\"\n")
	}
	b.WriteString("      - DIRECT\n")
	b.WriteString("rules:\n" +
		"  - GEOIP,LAN,DIRECT,no-resolve\n" +
		"  - GEOSITE,CN,DIRECT\n" +
		"  - GEOIP,CN,DIRECT,no-resolve\n" +
		"  - MATCH," + qfBareGroupName + "\n")
	return b.String()
}

func qfBareSetupHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	previous := constant.Path.HomeDir()
	constant.SetHomeDir(home)
	t.Cleanup(func() { constant.SetHomeDir(previous) })
	// Mirror production: CoreController.initGeo deploys the bundled
	// geodata into the home directory before the core starts, and the
	// split rules' GEOIP entries are built from it at load.
	for _, name := range []string{"GEOIP.dat", "GEOSITE.dat", "GEOIP.metadb", "ASN.mmdb"} {
		src := filepath.Join("..", "assets", "data", name)
		if data, err := os.ReadFile(src); err == nil {
			_ = os.WriteFile(filepath.Join(home, name), data, 0o644)
		}
	}
	return home
}

func qfBareWriteProfile(t *testing.T, home, name, body string) string {
	t.Helper()
	path := filepath.Join(home, "profiles", name)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func qfBareGroupView(t *testing.T, name string) map[string]any {
	t.Helper()
	data := handleGetProxies()
	raw, ok := data.Proxies[name]
	if !ok {
		t.Fatalf("group %q missing; All=%v", name, data.All)
	}
	view, ok := raw.(map[string]any)
	if !ok {
		t.Fatalf("group %q view is %T, want a group view", name, raw)
	}
	return view
}

func qfBareMembers(view map[string]any) []string {
	items, _ := view["all"].([]any)
	members := make([]string, 0, len(items))
	for _, item := range items {
		if name, ok := item.(string); ok {
			members = append(members, name)
		}
	}
	return members
}

// Mirrors what setupConfig does with a base once the core is
// initialized, without the init gate the handler enforces.
func qfBareApply(t *testing.T, home, profilePath, overlay string, selected map[string]string) {
	t.Helper()
	cfg, err := loadConfigWithBase(
		&SetupBase{Path: profilePath, Overlay: overlay},
		filepath.Join(home, "config.yaml"),
	)
	if err != nil {
		t.Fatalf("loadConfigWithBase: %v", err)
	}
	currentConfig = cfg
	hub.ApplyConfig(cfg)
	patchSelectGroup(selected)
}

func TestQfBareLinkListProfileWithSynthesizedOverlay(t *testing.T) {
	home := qfBareSetupHome(t)
	profilePath := qfBareWriteProfile(t, home, "bare.yaml", qfBareLinkListBody())

	base, err := handleGetProfileBase(profilePath)
	if err != nil {
		t.Fatalf("getProfileBase: %v", err)
	}
	if base.Proxies != 4 || base.ProxyGroups != 0 || base.Rules != 0 || !base.Converted {
		t.Fatalf("base = proxies %d groups %d rules %d converted %v, want 4/0/0/true",
			base.Proxies, base.ProxyGroups, base.Rules, base.Converted)
	}

	qfBareApply(t, home, profilePath, qfBareSynthOverlay(),
		map[string]string{qfBareGroupName: qfBareTaipeiSS})
	report := handleGetLoadReport()
	if report.Proxies != 4 || report.Groups != 1 || report.Rules != 4 {
		t.Fatalf("load report = %d proxies %d groups %d rules, want 4/1/4",
			report.Proxies, report.Groups, report.Rules)
	}
	view := qfBareGroupView(t, qfBareGroupName)
	if view["hidden"] != false {
		t.Errorf("synthesized group hidden = %v, want false", view["hidden"])
	}
	want := []string{qfBareTokyoSS, qfBareTokyoHy2, qfBareTaipeiSS, qfBareTaipeiHy2, "DIRECT"}
	if got := qfBareMembers(view); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("members = %v, want %v", got, want)
	}
	if view["now"] != qfBareTaipeiSS {
		t.Errorf("now = %v, want the saved selection %q", view["now"], qfBareTaipeiSS)
	}

	res := handleChangeProxy(&ChangeProxyParams{
		GroupName: qfBareGroupName,
		ProxyName: qfBareTokyoSS,
	})
	if !res.Changed {
		t.Fatalf("changeProxy on the synthesized group: %+v", res)
	}
	globalMode := tunnel.Global
	if err := updateConfig(&UpdateParams{Mode: &globalMode}); err != nil {
		t.Fatalf("updateConfig -> global: %v", err)
	}
	ruleMode := tunnel.Rule
	if err := updateConfig(&UpdateParams{Mode: &ruleMode}); err != nil {
		t.Fatalf("updateConfig -> rule: %v", err)
	}
	view = qfBareGroupView(t, qfBareGroupName)
	if got := qfBareMembers(view); len(got) != len(want) {
		t.Errorf("after a mode round trip members = %v, want %v", got, want)
	}
	if view["now"] != qfBareTokyoSS {
		t.Errorf("after a mode round trip now = %v, want %q", view["now"], qfBareTokyoSS)
	}
}

const qfBareProxiesOnlyYAML = `
proxies:
  - name: node-a
    type: ss
    server: 192.0.2.41
    port: 8388
    cipher: aes-256-gcm
    password: "scratch-a"
  - name: node-b
    type: ss
    server: 192.0.2.42
    port: 8388
    cipher: aes-256-gcm
    password: "scratch-b"
`

func TestQfBareProxiesOnlyYamlWithSynthesizedOverlay(t *testing.T) {
	home := qfBareSetupHome(t)
	profilePath := qfBareWriteProfile(t, home, "bare.yaml", qfBareProxiesOnlyYAML)
	base, err := handleGetProfileBase(profilePath)
	if err != nil {
		t.Fatalf("getProfileBase: %v", err)
	}
	if base.Proxies != 2 || base.ProxyGroups != 0 || base.Rules != 0 {
		t.Fatalf("base = %d/%d/%d, want 2/0/0", base.Proxies, base.ProxyGroups, base.Rules)
	}
	overlay := "mode: rule\nmixed-port: 7890\n" +
		"proxy-groups:\n  - name: " + qfBareGroupName + "\n    type: select\n" +
		"    proxies: [node-a, node-b, DIRECT]\n" +
		"rules:\n" +
		"  - GEOIP,LAN,DIRECT,no-resolve\n" +
		"  - GEOSITE,CN,DIRECT\n" +
		"  - GEOIP,CN,DIRECT,no-resolve\n" +
		"  - MATCH," + qfBareGroupName + "\n"
	cfg, err := loadConfigWithBase(
		&SetupBase{Path: profilePath, Overlay: overlay},
		filepath.Join(home, "config.yaml"),
	)
	if err != nil {
		t.Fatalf("loadConfigWithBase: %v", err)
	}
	currentConfig = cfg
	hub.ApplyConfig(cfg)
	view := qfBareGroupView(t, qfBareGroupName)
	if got := qfBareMembers(view); strings.Join(got, "|") != "node-a|node-b|DIRECT" {
		t.Errorf("members = %v, want [node-a node-b DIRECT]", got)
	}
	if view["now"] != "node-a" {
		t.Errorf("now = %v, want node-a (first member)", view["now"])
	}
}

// The current merged subscription shape pulled from the Tokyo host on
// 2026-10-26 (group members DIRECT and REJECT first, Hy2 without sni),
// credentials replaced with valid fakes. The rules block mirrors the
// host file after the 2026-10-26 split-rules patch (before it, the file
// carried only the MATCH line).
const qfMergedShape = `
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
proxies:
  - name: "🇯🇵东京（SS协议首选）"
    type: ss
    server: 192.0.2.21
    port: 8000
    cipher: 2022-blake3-aes-128-gcm
    password: "MDEyMzQ1Njc4OWFiY2RlZg=="
    udp: true
  - name: "🇯🇵东京（Hy2协议 备选）"
    type: hysteria2
    server: 192.0.2.21
    port: 443
    password: "scratch-password-tokyo"
    skip-cert-verify: true
  - name: "🇹🇼台北（SS协议首选）"
    type: ss
    server: 192.0.2.22
    port: 8000
    cipher: 2022-blake3-aes-128-gcm
    password: "ZmVkY2JhOTg3NjU0MzIxMA=="
    udp: true
  - name: "🇹🇼台北（Hy2协议备用）"
    type: hysteria2
    server: 192.0.2.22
    port: 443
    password: "scratch-password-taipei"
    skip-cert-verify: true
proxy-groups:
  - name: AWS组
    type: select
    proxies:
      - DIRECT
      - REJECT
      - "🇯🇵东京（SS协议首选）"
      - "🇯🇵东京（Hy2协议 备选）"
      - "🇹🇼台北（SS协议首选）"
      - "🇹🇼台北（Hy2协议备用）"
rules:
  - GEOIP,LAN,DIRECT,no-resolve
  - GEOSITE,CN,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,AWS组
`

// The owner's path on the current merged subscription shape: rule mode
// lists the group with every member, a pick sticks, and a re-apply with
// the saved selection restores it.
func TestQfGroupedProfileRuleModeOwnerPath(t *testing.T) {
	home := qfBareSetupHome(t)
	profilePath := qfBareWriteProfile(t, home, "merged.yaml", qfMergedShape)
	overlay := "mode: rule\nmixed-port: 7890\nallow-lan: false\nlog-level: info\nrules: []\n"

	qfBareApply(t, home, profilePath, overlay, nil)
	view := qfBareGroupView(t, "AWS组")
	want := []string{"DIRECT", "REJECT", qfBareTokyoSS, qfBareTokyoHy2, qfBareTaipeiSS, qfBareTaipeiHy2}
	if got := qfBareMembers(view); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("AWS组 members = %v, want %v", got, want)
	}
	res := handleChangeProxy(&ChangeProxyParams{
		GroupName: "AWS组",
		ProxyName: qfBareTokyoSS,
	})
	if !res.Changed {
		t.Fatalf("changeProxy: %+v", res)
	}
	qfBareApply(t, home, profilePath, overlay,
		map[string]string{"AWS组": qfBareTokyoSS})
	view = qfBareGroupView(t, "AWS组")
	if view["now"] != qfBareTokyoSS {
		t.Errorf("after re-apply now = %v, want the saved selection %q",
			view["now"], qfBareTokyoSS)
	}
	if got := qfBareMembers(view); len(got) != len(want) {
		t.Errorf("after re-apply members = %v, want %v", got, want)
	}
}
