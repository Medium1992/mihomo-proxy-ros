#!/bin/sh
# upstream.patch доводит MetaCubeX/utls v1.9.0-mod-meta (89a07ad: нативный
# JLS и прочие добавки MetaCubeX) до refraction-networking/utls master
# (a13c59f): слияние go 1.27 с ML-DSA в crypto/tls, отпечаток Chrome 155
# (он же теперь HelloChrome_Auto, то есть "chrome" в client-fingerprint),
# Trust Anchors и исправления сжатия сертификатов. Разрешение конфликтов
# слияния взято из legiz-ru/prizrak-utls (v1.9.0-mod-meta-mldsa-chr155), без
# их ML-DSA-65 для REALITY. Сверху их же фикс key share: у отпечатков с
# двумя классическими key share (Firefox: X25519 и P-256) хранится ключ и
# второго, иначе рукопожатие падает, если сервер выбрал P-256
# (refraction-networking/utls#402). andybalholm/brotli остаётся вместо
# go-brrr апстрима: тот требует Go 1.22, а модуль держит go 1.20.
#
# Своё сверху апстрима:
#   - отпечаток Firefox 156 (он же HelloFirefox_Auto, "firefox"): без
#     ECDSA CBC и FFDHE, с session_ticket и psk_key_exchange_modes. Сверен
#     по захватам Firefox 160: совпадают шифры, порядок и содержимое всех
#     расширений, кроме случайных, и длина hello;
#   - равномерная перестановка расширений Chrome. ShuffleChromeTLSExtensions
#     пропускал обмены с GREASE, и крайние в спецификации расширения
#     оставались с краю вдвое чаще: SNI первым в 11% hello вместо 6%.
#     Теперь подвижные расширения переставляются между собой, как в
#     BoringSSL.
#
# В патче только исходники: без тестов, testdata, CI и документации.
# Когда MetaCubeX сольёт апстрим сам, патч удаляется, а Dockerfile-release
# возвращается на их ветку.
#
# Запуск из корня исходников utls на коммите 89a07ad: sh apply.sh. Вызывает
# Dockerfile-release.
set -eu
dir=$(dirname "$0")

git apply "$dir/upstream.patch"

grep -Fq 'HelloChrome_Auto        = HelloChrome_155' u_common.go \
  || { echo "utls: Chrome 155 is not HelloChrome_Auto after the patch" >&2; exit 1; }
grep -Fq 'HelloFirefox_Auto = HelloFirefox_156' u_common.go \
  || { echo "utls: Firefox 156 is not HelloFirefox_Auto after the patch" >&2; exit 1; }
echo "utls: refraction-networking/utls a13c59f on top of MetaCubeX 89a07ad"
