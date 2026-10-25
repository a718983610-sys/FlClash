package core

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"testing"
	"time"
)

// Subscription downloads travel through the core's own HTTP proxy
// inbound while the core is running; the naming and usage headers the
// origin declares must survive that hop untouched.
func TestQfProfileTitleSurvivesCoreProxy(t *testing.T) {
	origin, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("origin listen: %v", err)
	}
	defer origin.Close()
	originPort := origin.Addr().(*net.TCPAddr).Port
	mux := http.NewServeMux()
	mux.HandleFunc("/sub/token", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("profile-title", "base64:QVdT57uE")
		w.Header().Set("subscription-userinfo", "upload=1; download=2; total=3; expire=0")
		w.Header().Set("content-disposition", "")
		_, _ = w.Write([]byte("proxies: []\n"))
	})
	go func() { _ = http.Serve(origin, mux) }()

	mixedPort := qfFreeTCPPort(t)
	cfg := fmt.Sprintf(`
mixed-port: %d
allow-lan: false
mode: rule
log-level: info
proxies: []
proxy-groups: []
rules:
  - MATCH,DIRECT
`, mixedPort)
	applyYaml(t, cfg, nil)

	proxyURL, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", mixedPort))
	client := &http.Client{
		Timeout:   8 * time.Second,
		Transport: &http.Transport{Proxy: http.ProxyURL(proxyURL)},
	}
	target := fmt.Sprintf("http://127.0.0.1:%d/sub/token", originPort)
	var resp *http.Response
	for deadline := time.Now().Add(12 * time.Second); time.Now().Before(deadline); {
		resp, err = client.Get(target)
		if err == nil {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("fetch through core proxy: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	t.Logf("status=%d body=%q", resp.StatusCode, string(body))
	t.Logf("headers through proxy: %v", resp.Header)
	if got := resp.Header.Get("profile-title"); got != "base64:QVdT57uE" {
		t.Errorf("profile-title through core proxy = %q, want base64:QVdT57uE", got)
	}
	if got := resp.Header.Get("subscription-userinfo"); got == "" {
		t.Errorf("subscription-userinfo missing through core proxy")
	}
}

func qfFreeTCPPort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("free port: %v", err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}
