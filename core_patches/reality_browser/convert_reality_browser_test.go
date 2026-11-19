package convert

import (
	"encoding/base64"
	"testing"
)

func TestRealityBrowserFromLink(t *testing.T) {
	for link, want := range map[string]any{
		"vless://b9ab3d76-f055-4827-bec4-7f1f5a2f6c43@example.com:443?security=reality&pbk=Oy-KYHVomYTYXEKS6O9fKmRb9-PcvGq0JYxFo-U9CRY&sid=ab&fp=chrome&type=tcp&browser=auto#a": "auto",
		"vless://b9ab3d76-f055-4827-bec4-7f1f5a2f6c43@example.com:443?security=reality&pbk=Oy-KYHVomYTYXEKS6O9fKmRb9-PcvGq0JYxFo-U9CRY&sid=ab&fp=chrome&type=tcp&browser=Auto#b": "auto",
		"vless://b9ab3d76-f055-4827-bec4-7f1f5a2f6c43@example.com:443?security=reality&pbk=Oy-KYHVomYTYXEKS6O9fKmRb9-PcvGq0JYxFo-U9CRY&sid=ab&fp=chrome&type=tcp&browser=off#c":  nil,
		"vless://b9ab3d76-f055-4827-bec4-7f1f5a2f6c43@example.com:443?security=reality&pbk=Oy-KYHVomYTYXEKS6O9fKmRb9-PcvGq0JYxFo-U9CRY&sid=ab&fp=chrome&type=tcp#d":              nil,
	} {
		proxies, err := ConvertsV2Ray([]byte(base64.StdEncoding.EncodeToString([]byte(link))))
		if err != nil || len(proxies) != 1 {
			t.Fatalf("%s: %v %v", link, proxies, err)
		}
		opts, _ := proxies[0]["reality-opts"].(map[string]any)
		if opts == nil {
			t.Fatalf("%s: no reality-opts", link)
		}
		if got := opts["browser"]; got != want {
			t.Errorf("%s: browser %v, want %v", link, got, want)
		}
	}
}
