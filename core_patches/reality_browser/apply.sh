#!/bin/sh
# REALITY browser mode, клиентская роль "browser": "auto" из
# Medium1992/Xray-core-fork v26.11.9-h2Flow-7 (Jolymmiles/Xray-core#87).
# Включается у прокси полем reality-opts.browser: auto, в ссылке vless:// —
# параметром browser=auto. Без него всё как в апстриме.
#
# С ним клиент ведёт себя как браузер своего отпечатка:
#   - возобновляет сессии по тикетам сервера (pre_shared_key), не больше
#     двух тикетов на сервер, каждый один раз; Firefox — со своим хелло
#     возобновления (без session_ticket, GREASE ECH длиннее);
#   - полное рукопожатие ждёт столько, сколько браузер проверяет цепочку
#     (Chrome 15–48 мс, Edge 25–50, Firefox 1–5; повтор в течение 30 минут —
#     1 мс), а первые данные Chrome и Edge уходят через 0,25–1,2 мс после
#     Finished;
#   - XHTTP по HTTP/2 (если стоит патч xhttp_flow): подтверждение SETTINGS
#     сервера уходит отдельной записью, как у Chrome, а пинги регулятора
#     ждут первого ответа сервера.
# Тикеты выдаёт только сервер форка с "browser": "auto" на inbound; старый
# сервер их не выдаёт, и клиент работает полными рукопожатиями. Safari, iOS
# и randomized не возобновляют — для них режим ничего не меняет.
#
# Нужен uTLS из core_patches/utls (тикеты, UTLSIdToSpec, PatchBuiltHello);
# Dockerfile-release ставит этот патч только вместе с ним.
#
# Код — в component/tls/reality_browser.go и
# common/convert/convert_reality_browser.go. В апстриме меняется:
#   - component/tls/reality.go: GetRealityConn переименован в
#     getRealityConnStock, на его месте — наш, без режима зовёт прежний;
#     поле Browser в RealityConfig;
#   - adapter/outbound/reality.go: поле browser в RealityOptions и его разбор;
#   - common/convert/v.go: browser из ссылки в reality-opts;
#   - adapter/outbound/vless.go (только с xhttp_flow): H2Flow.Wrap ->
#     H2Flow.WrapBrowser с признаком режима.
#
# Запуск из корня исходников mihomo после xhttp_flow: sh apply.sh.
set -eu
dir=$(dirname "$0")

one() { # file anchor name
  n=$(grep -Fc "$2" "$1" || true)
  [ "$n" = "1" ] || { echo "reality_browser: anchor $3 found $n times in $1, expected 1" >&2; exit 1; }
}

rtls=component/tls/reality.go
getconn='func GetRealityConn(ctx context.Context, conn net.Conn, fingerprint UClientHelloID, serverName string, realityConfig *RealityConfig) (net.Conn, error) {'
cfgfield='	SupportX25519MLKEM768 bool'
one "$rtls" "$getconn" getconn
one "$rtls" "$cfgfield" cfgfield

ropt=adapter/outbound/reality.go
optfield='	SupportX25519MLKEM768 bool `proxy:"support-x25519mlkem768,omitempty"`'
optret='		return config, nil'
one "$ropt" "$optfield" optfield
one "$ropt" "$optret" optret

conv=common/convert/v.go
convset='proxy["reality-opts"] = realityOpts'
one "$conv" "$convset" convset

cp "$dir"/reality_browser*.go component/tls/
cp "$dir"/convert_reality_browser*.go common/convert/

sed -i 's|^func GetRealityConn(ctx context.Context, conn net.Conn, fingerprint UClientHelloID, serverName string, realityConfig \*RealityConfig) (net.Conn, error) {$|func getRealityConnStock(ctx context.Context, conn net.Conn, fingerprint UClientHelloID, serverName string, realityConfig *RealityConfig) (net.Conn, error) {|' "$rtls"
sed -i 's|^\(\t\)SupportX25519MLKEM768 bool$|&\n\n\1// Browser: reality-opts.browser auto, see reality_browser.go.\n\1Browser bool|' "$rtls"

sed -i 's|^\(\t\)SupportX25519MLKEM768 bool `proxy:"support-x25519mlkem768,omitempty"`$|&\n\n\1// browser: auto turns on browser mode, see component/tls/reality_browser.go.\n\1Browser string `proxy:"browser,omitempty"`|' "$ropt"
sed -i 's|^\t\treturn config, nil$|\t\tif config.Browser, err = tlsC.ParseRealityBrowser(o.Browser); err != nil {\n\t\t\treturn nil, err\n\t\t}\n\n&|' "$ropt"

sed -i 's|^\([[:space:]]*\)proxy\["reality-opts"\] = realityOpts$|\1parseRealityBrowser(query, realityOpts)\n&|' "$conv"

grep -Fq 'func getRealityConnStock(' "$rtls" \
  || { echo "reality_browser: GetRealityConn was not renamed ($rtls)" >&2; exit 1; }
grep -Fq '	Browser bool' "$rtls" \
  || { echo "reality_browser: Browser field did not apply ($rtls)" >&2; exit 1; }
grep -Fq 'Browser string `proxy:"browser,omitempty"`' "$ropt" \
  || { echo "reality_browser: browser option did not apply ($ropt)" >&2; exit 1; }
grep -Fq 'tlsC.ParseRealityBrowser(o.Browser)' "$ropt" \
  || { echo "reality_browser: browser parse did not apply ($ropt)" >&2; exit 1; }
grep -Fq 'parseRealityBrowser(query, realityOpts)' "$conv" \
  || { echo "reality_browser: share-link hook did not apply ($conv)" >&2; exit 1; }

vless=adapter/outbound/vless.go
wrap='v.option.XHTTPOpts.H2Flow.Wrap(makeTransport), v.option.XHTTPOpts.H2Flow.Wrap(makeDownloadTransport)'
if grep -Fq "$wrap" "$vless"; then
  one "$vless" "$wrap" wrap
  sed -i 's|v.option.XHTTPOpts.H2Flow.Wrap(makeTransport), v.option.XHTTPOpts.H2Flow.Wrap(makeDownloadTransport)|v.option.XHTTPOpts.H2Flow.WrapBrowser(makeTransport, v.realityConfig.UsesBrowser(v.option.ClientFingerprint)), v.option.XHTTPOpts.H2Flow.WrapBrowser(makeDownloadTransport, v.realityConfig.UsesBrowser(v.option.ClientFingerprint))|' "$vless"
  grep -Fq 'H2Flow.WrapBrowser(makeTransport, v.realityConfig.UsesBrowser(v.option.ClientFingerprint))' "$vless" \
    || { echo "reality_browser: XHTTP hook did not apply ($vless)" >&2; exit 1; }
  echo "REALITY browser mode: included, with XHTTP HTTP/2 startup"
else
  echo "REALITY browser mode: included, XHTTP HTTP/2 startup off (no xhttp_flow)"
fi
