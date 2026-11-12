#!/bin/sh
# Склейка dial'ов HTTP/2-транспорта XHTTP. С MetaCubeX/mihomo bb2f57b0 клиент
# работает через net/http.Transport, а тот начинает свой dial для каждого
# запроса, не нашедшего готового соединения. На холодном пуле и при
# рукопожатии, заблокированном после ClientHello, это TCP-соединение на сессию,
# и max-connections в reuse-settings сокеты больше не ограничивает (тот же
# класс бага, что XTLS/Xray-core#6797). Склейка — по образцу x/net CL 845005,
# см. transport/xhttp/dial_coalesce.go; заодно dial получает срок, которого на
# этом пути не было.
#
# В апстриме меняются две строки transport/xhttp/client.go: NewClient
# оборачивает обе фабрики транспорта, а DialTLSContext h2 отмечает
# установленный TCP. Вторая правка, GetBody для packet-up в
# config.go, описана ниже. Обёртка внешняя по отношению к
# xhttp_flow (тот оборачивает фабрики раньше, в vless.go), поэтому патчи
# ложатся в любом порядке и независимо друг от друга.
#
# Запуск из корня исходников mihomo: sh apply.sh. Вызывают Dockerfile-release
# и проверка в CI, поэтому якорь и проверки живут в одном месте.
set -eu
dir=$(dirname "$0")
target=transport/xhttp/client.go
anchor='func NewClient(cfg *Config, makeTransport TransportMaker, makeDownloadTransport TransportMaker, hasReality bool) (*Client, error) {'

# Ровно одно вхождение: если апстрим поменял сигнатуру, молча не обернуть
# фабрики хуже, чем упасть.
n=$(grep -Fc "$anchor" "$target" || true)
[ "$n" = "1" ] || { echo "xhttp_dial: anchor NewClient found $n times in $target, expected 1" >&2; exit 1; }

cp "$dir"/dial_coalesce*.go transport/xhttp/
sed -i 's|^func NewClient(cfg \*Config, makeTransport TransportMaker, makeDownloadTransport TransportMaker, hasReality bool) (\*Client, error) {$|&\n\tmakeTransport, makeDownloadTransport = CoalesceDials(makeTransport), CoalesceDials(makeDownloadTransport)|' "$target"

grep -Fq 'makeTransport, makeDownloadTransport = CoalesceDials(makeTransport), CoalesceDials(makeDownloadTransport)' "$target" \
  || { echo "xhttp_dial: NewClient hook did not apply ($target)" >&2; exit 1; }

# Отметка «TCP установлен» в DialTLSContext h2-транспорта, между dialRaw и
# wrapTLS: запасной dial склейки, как у браузеров, бывает только пока TCP
# ведущего не установлен, а на повисшее рукопожатие второго ClientHello нет.
# Строка с wrapTLS(..., true) — только на пути h2.
tls='wrapped, err := wrapTLS(ctx, raw, true)'
n=$(grep -Fc "$tls" "$target" || true)
[ "$n" = "1" ] || { echo "xhttp_dial: h2 wrapTLS found $n times in $target, expected 1" >&2; exit 1; }
sed -i 's|^\(\t*\)wrapped, err := wrapTLS(ctx, raw, true)$|\1DialTCPUp(ctx)\n&|' "$target"
grep -B1 -F "$tls" "$target" | grep -Fq 'DialTCPUp(ctx)' \
  || { echo "xhttp_dial: DialTCPUp hook did not apply ($target)" >&2; exit 1; }

# GetBody для тела packet-up. Сервер с MAX_CONCURRENT_STREAMS меньше 100
# отбивает потоки, которые клиент шлёт до его SETTINGS, а склейка сгоняет залп
# на одно свежее соединение. Отбитый поток (REFUSED_STREAM) сервер не
# обрабатывал, и net/http повторяет его сам, но только если тело можно
# перемотать. Тело packet-up — готовые байты, перемотка безопасна. Без неё
# POST падает, ошибка ждёт следующего Write, а GET сессии висит до тайм-аута.
# data — буфер писателя, но GetBody зовётся только внутри RoundTrip, а flush
# держит замок, пока RoundTrip не вернулся: копировать не нужно. Тела
# stream-up и stream-one — поток, его не перемотать.
config=transport/xhttp/config.go
body='request.ContentLength = int64(len(data))'
n=$(grep -Fc "$body" "$config" || true)
[ "$n" = "1" ] || { echo "xhttp_dial: packet-up body found $n times in $config, expected 1" >&2; exit 1; }
sed -i 's|^\(\t*\)request\.ContentLength = int64(len(data))$|&\n\1request.GetBody = func() (io.ReadCloser, error) { return io.NopCloser(bytes.NewReader(data)), nil }|' "$config"
grep -Fq 'request.GetBody = func() (io.ReadCloser, error) { return io.NopCloser(bytes.NewReader(data)), nil }' "$config" \
  || { echo "xhttp_dial: packet-up GetBody did not apply ($config)" >&2; exit 1; }
echo "XHTTP dial coalescing: included"
