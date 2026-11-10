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
# В апстриме меняется одна строка transport/xhttp/client.go: NewClient
# оборачивает обе фабрики транспорта. Обёртка внешняя по отношению к
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
echo "XHTTP dial coalescing: included"
