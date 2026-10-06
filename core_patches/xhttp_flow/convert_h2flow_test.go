package convert

import (
	"net/url"
	"reflect"
	"testing"
)

func TestConvertsV2RayVlessXHTTPH2Flow(t *testing.T) {
	link := func(extra string) []byte {
		return []byte("vless://11111111-2222-3333-4444-555555555555@example.com:443?encryption=none&security=tls&sni=example.com&type=xhttp&path=%2Fxh&mode=stream-up&extra=" +
			url.QueryEscape(extra) + "#n")
	}
	for _, tc := range []struct {
		name, extra string
		want        map[string]any
	}{
		{"full", `{"h2Flow":{"enabled":true,"maxStreamReceiveWindow":16777216,"maxConnectionReceiveWindow":"33554432"},"xPaddingBytes":"100-1000"}`,
			map[string]any{"enabled": true, "max-stream-receive-window": 16777216, "max-connection-receive-window": 33554432}},
		{"disabled", `{"h2Flow":{"enabled":false}}`, map[string]any{"enabled": false}},
		{"absent", `{"xPaddingBytes":"100-1000"}`, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			proxies, err := ConvertsV2Ray(link(tc.extra))
			if err != nil || len(proxies) != 1 {
				t.Fatalf("convert: %v %v", proxies, err)
			}
			opts, _ := proxies[0]["xhttp-opts"].(map[string]any)
			if opts == nil {
				t.Fatalf("no xhttp-opts: %v", proxies[0])
			}
			got, _ := opts["h2-flow"].(map[string]any)
			if tc.want == nil {
				if got != nil {
					t.Fatalf("unexpected h2-flow %v", got)
				}
				return
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("h2-flow %v, want %v", got, tc.want)
			}
			if opts["x-padding-bytes"] == nil && tc.name == "full" {
				t.Fatal("the rest of extra was lost")
			}
		})
	}
}
