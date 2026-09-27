#!/bin/sh
# Регулятор окон HTTP/2 для XHTTP-клиента (клиентская роль из
# Medium1992/Xray-core-fork, ветка feat/xhttp-mux-cool). Go по умолчанию даёт
# серверу окно 4 МиБ на стрим, и при медленном читателе в локальной сети столько
# непрочитанного копится на роутере на каждый стрим. Регулятор показывает
# серверу окно 64 КиБ и возвращает кредит, только пока непрочитанное меньше
# двух RTT чтения. Сервер не меняется, подойдёт любой.
#
# Запуск из корня исходников mihomo: sh apply.sh. Вызывают Dockerfile-release
# и проверка в CI, поэтому якорь и проверки живут в одном месте.
set -eu
dir=$(dirname "$0")
target=transport/xhttp/client.go
anchor='wrapped, err := wrapTLS(ctx, raw, true)'

# Ровно одно вхождение: это h2-ветка NewTransport. Если апстрим заведёт второй
# такой вызов, молча закрыть один путь из двух хуже, чем упасть.
n=$(grep -Fc "$anchor" "$target" || true)
[ "$n" = "1" ] || { echo "xhttp_flow: anchor found $n times in $target, expected 1" >&2; exit 1; }

cp "$dir"/h2flow*.go transport/xhttp/
sed -i 's|wrapped, err := wrapTLS(ctx, raw, true)|wrapped, err := flowDial(wrapTLS(ctx, raw, true))|' "$target"
grep -Fq 'flowDial(wrapTLS(ctx, raw, true))' "$target" \
  || { echo "xhttp_flow: hook did not apply ($target)" >&2; exit 1; }
echo "XHTTP flow governor: included"
