#!/bin/sh
# Регулятор окон HTTP/2 для XHTTP-клиента (клиентская роль из
# Medium1992/Xray-core-fork, ветка feat/xhttp-mux-cool). Go по умолчанию даёт
# серверу окно 4 МиБ на стрим, и при медленном читателе в локальной сети столько
# непрочитанного копится на роутере на каждый стрим. Регулятор держит окно по
# тому, что читатель реально забирает; на Linux — по min_rtt ядра. Сервер не
# меняется, подойдёт любой.
#
# Как в форке, регулятор по умолчанию выключен: его включает переменная
# MIHOMO_XHTTP_FLOW=on или блок h2-flow в xhttp-opts конкретного прокси
# (он же задаёт окна приёма HTTP/2). Код — в transport/xhttp/h2flow*.go,
# в апстриме меняются две строки adapter/outbound/vless.go: поле h2-flow в
# XHTTPOptions и обёртка фабрик транспорта при создании XHTTP-клиента, и одна
# строка common/convert/v.go: h2Flow из extra в ссылках vless:// попадает в
# xhttp-opts.h2-flow (код — в common/convert/convert_h2flow.go).
#
# Запуск из корня исходников mihomo: sh apply.sh. Вызывают Dockerfile-release
# и проверка в CI, поэтому якоря и проверки живут в одном месте.
set -eu
dir=$(dirname "$0")
target=adapter/outbound/vless.go
field='DownloadSettings     *XHTTPDownloadSettings `proxy:"download-settings,omitempty"`'
client='v.xhttpClient, err = xhttp.NewClient(cfg, makeTransport, makeDownloadTransport, v.realityConfig != nil)'

# Ровно одно вхождение каждого якоря: если апстрим заведёт второй такой
# вызов, молча закрыть один путь из двух хуже, чем упасть.
one() {
  n=$(grep -Fc "$2" "$target" || true)
  [ "$n" = "1" ] || { echo "xhttp_flow: anchor $1 found $n times in $target, expected 1" >&2; exit 1; }
}
one field "$field"
one client "$client"
conv=common/convert/v.go
convcall='parseXHTTPExtra(extraMap, xhttpOpts)'
n=$(grep -Fc "$convcall" "$conv" || true)
[ "$n" = "1" ] || { echo "xhttp_flow: anchor convert found $n times in $conv, expected 1" >&2; exit 1; }

cp "$dir"/h2flow*.go transport/xhttp/
cp "$dir"/convert_h2flow*.go common/convert/
sed -i 's|parseXHTTPExtra(extraMap, xhttpOpts)|parseXHTTPExtra(extraMap, xhttpOpts); parseXHTTPH2Flow(extraMap, xhttpOpts)|' "$conv"
sed -i 's|^\([[:space:]]*\)DownloadSettings     \*XHTTPDownloadSettings `proxy:"download-settings,omitempty"`$|&\n\1H2Flow               *xhttp.H2FlowOptions   `proxy:"h2-flow,omitempty"`|' "$target"
sed -i 's|v.xhttpClient, err = xhttp.NewClient(cfg, makeTransport, makeDownloadTransport, v.realityConfig != nil)|v.xhttpClient, err = xhttp.NewClient(cfg, v.option.XHTTPOpts.H2Flow.Wrap(makeTransport), v.option.XHTTPOpts.H2Flow.Wrap(makeDownloadTransport), v.realityConfig != nil)|' "$target"

grep -Fq '*xhttp.H2FlowOptions   `proxy:"h2-flow,omitempty"`' "$target" \
  || { echo "xhttp_flow: h2-flow field did not apply ($target)" >&2; exit 1; }
grep -Fq 'H2Flow.Wrap(makeTransport), v.option.XHTTPOpts.H2Flow.Wrap(makeDownloadTransport)' "$target" \
  || { echo "xhttp_flow: transport hook did not apply ($target)" >&2; exit 1; }
grep -Fq 'parseXHTTPExtra(extraMap, xhttpOpts); parseXHTTPH2Flow(extraMap, xhttpOpts)' "$conv" \
  || { echo "xhttp_flow: share-link hook did not apply ($conv)" >&2; exit 1; }
echo "XHTTP flow governor: included"
