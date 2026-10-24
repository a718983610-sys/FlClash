package core

// Rule-mode egress reproduction: a standard airport-style config must
// route domestic traffic DIRECT and foreign traffic through the selected
// group, with the MATCH fallback landing on a usable outbound. Everything
// is local: a fake SOCKS5 node records every connection it carries, and
// HTTP targets answer on distinct loopback addresses.

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

// ---- fake SOCKS5 node --------------------------------------------------

type fakeNode struct {
	hits atomic.Int32
	mu   sync.Mutex
	seen []string
}

func startFakeNode(t *testing.T) (*fakeNode, int) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("node listen: %v", err)
	}
	node := &fakeNode{}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go node.serve(conn)
		}
	}()
	t.Cleanup(func() { _ = ln.Close() })
	return node, ln.Addr().(*net.TCPAddr).Port
}

func (n *fakeNode) serve(conn net.Conn) {
	defer conn.Close()
	buf := make([]byte, 512)
	if _, err := io.ReadFull(conn, buf[:2]); err != nil {
		return
	}
	nMethods := int(buf[1])
	if _, err := io.ReadFull(conn, buf[:nMethods]); err != nil {
		return
	}
	if _, err := conn.Write([]byte{0x05, 0x00}); err != nil {
		return
	}
	if _, err := io.ReadFull(conn, buf[:4]); err != nil {
		return
	}
	var host string
	switch buf[3] {
	case 0x01:
		if _, err := io.ReadFull(conn, buf[:4]); err != nil {
			return
		}
		host = net.IP(buf[:4]).String()
	case 0x03:
		if _, err := io.ReadFull(conn, buf[:1]); err != nil {
			return
		}
		l := int(buf[0])
		if _, err := io.ReadFull(conn, buf[:l]); err != nil {
			return
		}
		host = string(buf[:l])
	default:
		return
	}
	if _, err := io.ReadFull(conn, buf[:2]); err != nil {
		return
	}
	port := binary.BigEndian.Uint16(buf[:2])
	n.hits.Add(1)
	n.mu.Lock()
	n.seen = append(n.seen, fmt.Sprintf("%s:%d", host, port))
	n.mu.Unlock()

	dialHost := host
	switch host {
	case "foreign.test", "prov.test":
		dialHost = "127.0.0.2"
	case "cn.test":
		dialHost = "127.0.0.1"
	}
	upstream, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", dialHost, port), 5*time.Second)
	if err != nil {
		_, _ = conn.Write([]byte{0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	defer upstream.Close()
	if _, err := conn.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0}); err != nil {
		return
	}
	go func() { _, _ = io.Copy(upstream, conn) }()
	_, _ = io.Copy(conn, upstream)
}

func (n *fakeNode) seenTargets() []string {
	n.mu.Lock()
	defer n.mu.Unlock()
	return append([]string(nil), n.seen...)
}

// ---- HTTP targets ------------------------------------------------------

func startTarget(t *testing.T, addr, body string) {
	t.Helper()
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatalf("target listen %s: %v", addr, err)
	}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, body)
	})}
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() { _ = srv.Close() })
}

// ---- minimal DNS server --------------------------------------------------

func startTestDNS(t *testing.T, port int, answers map[string]net.IP) {
	t.Helper()
	// This sandbox drops loopback UDP replies before they reach the
	// client (proven by a raw UDP round-trip probe), so the server also
	// speaks TCP and the test configs point at tcp:// — the resolver and
	// rule paths under test are identical, only the transport differs.
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatalf("dns tcp listen: %v", err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				for {
					var lenBuf [2]byte
					if _, err := io.ReadFull(conn, lenBuf[:]); err != nil {
						return
					}
					msg := make([]byte, binary.BigEndian.Uint16(lenBuf[:]))
					if _, err := io.ReadFull(conn, msg); err != nil {
						return
					}
					resp := dnsAnswer(msg, answers)
					if resp == nil {
						return
					}
					binary.BigEndian.PutUint16(lenBuf[:], uint16(len(resp)))
					if _, err := conn.Write(append(lenBuf[:], resp...)); err != nil {
						return
					}
				}
			}(conn)
		}
	}()
	pc, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: port})
	if err != nil {
		t.Fatalf("dns listen: %v", err)
	}
	go func() {
		buf := make([]byte, 1024)
		for {
			n, addr, err := pc.ReadFromUDP(buf)
			if err != nil {
				return
			}
			if resp := dnsAnswer(buf[:n], answers); resp != nil {
				_, _ = pc.WriteToUDP(resp, addr)
			}
		}
	}()
	t.Cleanup(func() { _ = pc.Close() })
}

func dnsAnswer(query []byte, answers map[string]net.IP) []byte {
	if len(query) < 12 {
		return nil
	}
	i := 12
	var labels []string
	for {
		if i >= len(query) {
			return nil
		}
		l := int(query[i])
		i++
		if l == 0 {
			break
		}
		if i+l > len(query) {
			return nil
		}
		labels = append(labels, string(query[i:i+l]))
		i += l
	}
	if i+4 > len(query) {
		return nil
	}
	ip, ok := answers[strings.Join(labels, ".")]
	// Only an A query gets the A record; any other qtype (AAAA, HTTPS)
	// gets an empty NOERROR answer, as a real resolver would send.
	if binary.BigEndian.Uint16(query[i:]) != 1 {
		ok = false
	}
	resp := make([]byte, 0, i+20)
	resp = append(resp, query[:2]...)
	resp = append(resp, 0x81, 0x80)
	resp = append(resp, 0x00, 0x01)
	if ok {
		resp = append(resp, 0x00, 0x01)
	} else {
		resp = append(resp, 0x00, 0x00)
	}
	resp = append(resp, 0x00, 0x00, 0x00, 0x00)
	resp = append(resp, query[12:i+4]...)
	if ok {
		resp = append(resp, 0xc0, 0x0c)
		resp = append(resp, 0x00, 0x01)
		resp = append(resp, 0x00, 0x01)
		resp = append(resp, 0x00, 0x00, 0x00, 60)
		resp = append(resp, 0x00, 0x04)
		resp = append(resp, ip.To4()...)
	}
	return resp
}

// ---- core plumbing -------------------------------------------------------

func freeTCPPort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("free port: %v", err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

func freeUDPPort(t *testing.T) int {
	t.Helper()
	pc, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatalf("free udp port: %v", err)
	}
	defer pc.Close()
	return pc.LocalAddr().(*net.UDPAddr).Port
}

func applyYaml(t *testing.T, yaml string, extraFiles map[string]string) {
	t.Helper()
	applyYamlParams(t, yaml, extraFiles, defaultSetupParams())
}

func applyYamlParams(t *testing.T, yaml string, extraFiles map[string]string, params *SetupParams) {
	t.Helper()
	home := t.TempDir()
	previous := constant.Path.HomeDir()
	constant.SetHomeDir(home)
	t.Cleanup(func() { constant.SetHomeDir(previous) })
	// The app ships geodata with the binary; mirror that so GEOIP/GEOSITE
	// rules evaluate the same way they do on a phone.
	for _, name := range []string{"GEOIP.dat", "GEOSITE.dat", "GEOIP.metadb", "ASN.mmdb"} {
		src := filepath.Join("..", "assets", "data", name)
		if data, err := os.ReadFile(src); err == nil {
			_ = os.WriteFile(filepath.Join(home, name), data, 0o644)
		}
	}
	for rel, content := range extraFiles {
		p := filepath.Join(home, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", rel, err)
		}
	}
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), []byte(yaml), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	if err := applyConfig(params); err != nil {
		t.Fatalf("applyConfig: %v", err)
	}
	// Listeners are a separate host step: applyConfig alone leaves them
	// down (updateListeners gates on isRunning), exactly as on device,
	// where the service calls startListener after setup.
	handleStartListener()
	t.Cleanup(func() {
		handleStopListener()
		settleMessageBatcher()
	})
}

func fetchVia(t *testing.T, mixedPort int, target string) (int, string) {
	t.Helper()
	proxyURL, err := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", mixedPort))
	if err != nil {
		t.Fatalf("proxy url: %v", err)
	}
	client := &http.Client{
		Timeout:   8 * time.Second,
		Transport: &http.Transport{Proxy: http.ProxyURL(proxyURL)},
	}
	var lastErr error
	for deadline := time.Now().Add(12 * time.Second); time.Now().Before(deadline); {
		resp, err := client.Get(target)
		if err != nil {
			lastErr = err
			time.Sleep(200 * time.Millisecond)
			continue
		}
		body, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		return resp.StatusCode, string(body)
	}
	t.Fatalf("fetch %s through core: %v", target, lastErr)
	return 0, ""
}

// ---- phases ---------------------------------------------------------------

// Phase 1: IP rules + MATCH + an emoji group name, no DNS involved.
func TestRuleModeIPRulesAndMatchEgress(t *testing.T) {
	node, nodePort := startFakeNode(t)
	startTarget(t, "127.0.0.1:18101", "CN-OK")
	startTarget(t, "127.0.0.2:18102", "FR-OK")
	startTarget(t, "127.0.0.3:18103", "MATCH-OK")
	mixed := freeTCPPort(t)
	applyYaml(t, fmt.Sprintf(`
mixed-port: %d
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: warning
proxies:
  - {name: node-a, type: socks5, server: 127.0.0.1, port: %d}
proxy-groups:
  - {name: "🚀 节点选择", type: select, proxies: [node-a, DIRECT]}
rules:
  - IP-CIDR,127.0.0.1/32,DIRECT
  - IP-CIDR,127.0.0.2/32,🚀 节点选择
  - MATCH,🚀 节点选择
`, mixed, nodePort), nil)

	if code, body := fetchVia(t, mixed, "http://127.0.0.1:18101/"); code != 200 || body != "CN-OK" {
		t.Errorf("domestic fetch = %d %q, want 200 CN-OK", code, body)
	}
	if got := node.hits.Load(); got != 0 {
		t.Errorf("node hits after domestic fetch = %d, want 0 (direct)", got)
	}
	if code, body := fetchVia(t, mixed, "http://127.0.0.2:18102/"); code != 200 || body != "FR-OK" {
		t.Errorf("foreign fetch = %d %q, want 200 FR-OK", code, body)
	}
	if code, body := fetchVia(t, mixed, "http://127.0.0.3:18103/"); code != 200 || body != "MATCH-OK" {
		t.Errorf("match fetch = %d %q, want 200 MATCH-OK", code, body)
	}
	if got := node.hits.Load(); got != 2 {
		t.Errorf("node hits at end = %d, want 2 (foreign + match); node saw %v", got, node.seenTargets())
	}
}

// Phase 2: fake-ip DNS + domain rules, airport style.
func TestRuleModeFakeIPDomainRulesEgress(t *testing.T) {
	node, nodePort := startFakeNode(t)
	startTarget(t, "127.0.0.1:18101", "CN-OK")
	startTarget(t, "127.0.0.2:18102", "FR-OK")
	dnsPort := freeUDPPort(t)
	startTestDNS(t, dnsPort, map[string]net.IP{
		"cn.test":      net.ParseIP("127.0.0.1"),
		"foreign.test": net.ParseIP("127.0.0.2"),
	})
	mixed := freeTCPPort(t)
	applyYaml(t, fmt.Sprintf(`
mixed-port: %d
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: warning
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver: ["tcp://127.0.0.1:%d"]
proxies:
  - {name: node-a, type: socks5, server: 127.0.0.1, port: %d}
proxy-groups:
  - {name: "🚀 节点选择", type: select, proxies: [node-a, DIRECT]}
rules:
  - DOMAIN,cn.test,DIRECT
  - DOMAIN,foreign.test,🚀 节点选择
  - MATCH,🚀 节点选择
`, mixed, dnsPort, nodePort), nil)

	if code, body := fetchVia(t, mixed, "http://cn.test:18101/"); code != 200 || body != "CN-OK" {
		t.Errorf("cn.test fetch = %d %q, want 200 CN-OK", code, body)
	}
	if got := node.hits.Load(); got != 0 {
		t.Errorf("node hits after cn.test = %d, want 0 (direct)", got)
	}
	if code, body := fetchVia(t, mixed, "http://foreign.test:18102/"); code != 200 || body != "FR-OK" {
		t.Errorf("foreign.test fetch = %d %q, want 200 FR-OK", code, body)
	}
	if got := node.hits.Load(); got != 1 {
		t.Errorf("node hits after foreign.test = %d, want 1; node saw %v", got, node.seenTargets())
	}
}

// Phase 3: a file rule-provider plus GEOIP/GEOSITE rules in one config.
func TestRuleModeRuleSetAndGeoEgress(t *testing.T) {
	node, nodePort := startFakeNode(t)
	startTarget(t, "127.0.0.2:18102", "FR-OK")
	dnsPort := freeUDPPort(t)
	startTestDNS(t, dnsPort, map[string]net.IP{
		"prov.test": net.ParseIP("127.0.0.2"),
	})
	mixed := freeTCPPort(t)
	provider := "payload:\n  - 'DOMAIN,prov.test'\n"
	applyYaml(t, fmt.Sprintf(`
mixed-port: %d
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: warning
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver: ["tcp://127.0.0.1:%d"]
proxies:
  - {name: node-a, type: socks5, server: 127.0.0.1, port: %d}
proxy-groups:
  - {name: "🚀 节点选择", type: select, proxies: [node-a, DIRECT]}
rule-providers:
  prov:
    type: file
    behavior: classical
    path: ./providers/prov.yaml
rules:
  - RULE-SET,prov,🚀 节点选择
  - GEOIP,CN,DIRECT
  - GEOSITE,CN,DIRECT
  - MATCH,🚀 节点选择
`, mixed, dnsPort, nodePort), map[string]string{"providers/prov.yaml": provider})

	if code, body := fetchVia(t, mixed, "http://prov.test:18102/"); code != 200 || body != "FR-OK" {
		t.Errorf("prov.test fetch = %d %q, want 200 FR-OK", code, body)
	}
	if got := node.hits.Load(); got != 1 {
		t.Errorf("node hits after prov.test = %d, want 1; node saw %v", got, node.seenTargets())
	}
}

// Phase 5: the 1.0.0 defect shape — a saved selection naming a member a
// subscription refresh dropped. Routing must fall back, never blackhole.
func TestRuleModeStaleSelectionStaticGroup(t *testing.T) {
	node, nodePort := startFakeNode(t)
	startTarget(t, "127.0.0.2:18102", "FR-OK")
	mixed := freeTCPPort(t)
	params := defaultSetupParams()
	params.SelectedMap = map[string]string{"🚀 节点选择": "dropped-node"}
	applyYamlParams(t, fmt.Sprintf(`
mixed-port: %d
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: warning
proxies:
  - {name: node-a, type: socks5, server: 127.0.0.1, port: %d}
proxy-groups:
  - {name: "🚀 节点选择", type: select, proxies: [node-a, DIRECT]}
rules:
  - IP-CIDR,127.0.0.2/32,🚀 节点选择
  - MATCH,🚀 节点选择
`, mixed, nodePort), nil, params)

	if now := groupNow(t, tunnel.AllProxies()["🚀 节点选择"]); now != "node-a" {
		t.Errorf("group now = %q, want the fallback member node-a", now)
	}
	if code, body := fetchVia(t, mixed, "http://127.0.0.2:18102/"); code != 200 || body != "FR-OK" {
		t.Errorf("foreign fetch with stale selection = %d %q, want 200 FR-OK", code, body)
	}
	if got := node.hits.Load(); got != 1 {
		t.Errorf("node hits = %d, want 1; node saw %v", got, node.seenTargets())
	}
}

func TestRuleModeStaleSelectionProviderGroup(t *testing.T) {
	node, nodePort := startFakeNode(t)
	startTarget(t, "127.0.0.2:18102", "FR-OK")
	mixed := freeTCPPort(t)
	params := defaultSetupParams()
	params.SelectedMap = map[string]string{"🚀 节点选择": "dropped-node"}
	provider := fmt.Sprintf("proxies:\n  - {name: node-a, type: socks5, server: 127.0.0.1, port: %d}\n", nodePort)
	applyYamlParams(t, fmt.Sprintf(`
mixed-port: %d
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: warning
proxy-providers:
  airport:
    type: file
    path: ./providers/airport.yaml
    health-check: {enable: false}
proxy-groups:
  - {name: "🚀 节点选择", type: select, use: [airport]}
rules:
  - IP-CIDR,127.0.0.2/32,🚀 节点选择
  - MATCH,🚀 节点选择
`, mixed), map[string]string{"providers/airport.yaml": provider}, params)

	// A provider-backed group reports the COMPATIBLE placeholder until
	// the provider's content lands; what matters is that the dropped
	// name never becomes the effective pick once it has.
	group := tunnel.AllProxies()["🚀 节点选择"]
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if now := groupNow(t, group); now == "node-a" {
			break
		} else if now == "dropped-node" {
			t.Fatalf("provider group settled on the dropped selection")
		}
		time.Sleep(100 * time.Millisecond)
	}
	if now := groupNow(t, group); now != "node-a" {
		t.Errorf("provider group now = %q after load, want node-a", now)
	}
	if code, body := fetchVia(t, mixed, "http://127.0.0.2:18102/"); code != 200 || body != "FR-OK" {
		t.Errorf("foreign fetch with stale provider selection = %d %q, want 200 FR-OK", code, body)
	}
	if got := node.hits.Load(); got != 1 {
		t.Errorf("node hits = %d, want 1; node saw %v", got, node.seenTargets())
	}
}
