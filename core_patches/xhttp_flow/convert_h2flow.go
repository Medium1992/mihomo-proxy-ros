package convert

import "strconv"

// parseXHTTPH2Flow carries "h2Flow" from a share link's xhttp extra JSON over
// to xhttp-opts.h2-flow, the block the mihomo-proxy-ros flow governor patch
// reads (Xray-core-fork mux-ka keeps the same block in xhttpSettings.extra):
//
//	"h2Flow": {"enabled": true, "maxStreamReceiveWindow": 16777216,
//	           "maxConnectionReceiveWindow": 33554432}
func parseXHTTPH2Flow(extra map[string]any, opts map[string]any) {
	hf, ok := extra["h2Flow"].(map[string]any)
	if !ok {
		return
	}
	out := make(map[string]any)
	if v, ok := hf["enabled"].(bool); ok {
		out["enabled"] = v
	}
	window := func(src, dst string) {
		switch v := hf[src].(type) {
		case float64:
			if v > 0 {
				out[dst] = int(v)
			}
		case string:
			if n, err := strconv.Atoi(v); err == nil && n > 0 {
				out[dst] = n
			}
		}
	}
	window("maxStreamReceiveWindow", "max-stream-receive-window")
	window("maxConnectionReceiveWindow", "max-connection-receive-window")
	if len(out) > 0 {
		opts["h2-flow"] = out
	}
}
