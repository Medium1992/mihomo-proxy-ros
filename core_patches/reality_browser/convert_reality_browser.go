package convert

import (
	"net/url"
	"strings"
)

// parseRealityBrowser carries "browser" of a vless:// link into
// reality-opts.browser: "auto" turns on REALITY browser mode, as
// "browser": "auto" in realitySettings of Xray-core-fork does. Anything else
// is left out, so a link that says "off" or nothing builds what it built.
func parseRealityBrowser(query url.Values, realityOpts map[string]any) {
	if strings.EqualFold(strings.TrimSpace(query.Get("browser")), "auto") {
		realityOpts["browser"] = "auto"
	}
}
