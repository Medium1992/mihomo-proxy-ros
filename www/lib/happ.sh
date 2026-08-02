#!/bin/sh
# Расшифровка happ://crypt … happ://crypt5.
#   . /www/lib/happ.sh; happ_decrypt "happ://crypt5/..."
# Ключи читаются из happ.js — того же, что использует панель.
#
# crypt5: перестановка блоков по 4 [2,3,0,1]; маркер = первые 4 + последние 4;
# тело = nonce(12) [+ тег(2) + соль(8) в salted] + длина + сегмент + RSA-блоб.
# RSA даёт ключ ChaCha20 (в salted — XOR с солью), затем обмен пар и base64.

HAPP_JS="${HAPP_JS:-/www/assets/happ.js}"

happ_err() { echo "happ: $*" >&2; }

# $1 = размер блока, $2 = порядок индексов; хвост короче блока не трогаем
happ_shuffle() {
  awk -v size="$1" -v ord="$2" '
    {
      n = split(ord, o, ",")
      full = int(length($0) / size) * size
      out = ""
      for (i = 1; i <= full; i += size) {
        part = substr($0, i, size)
        for (k = 1; k <= n; k++) out = out substr(part, o[k] + 1, 1)
      }
      printf "%s%s", out, substr($0, full + 1)
    }
  '
}

happ_swap_pairs() { happ_shuffle 2 "1,0"; }
happ_permute4()   { happ_shuffle 4 "2,3,0,1"; }
happ_hex()        { od -An -v -tx1 | tr -d ' \n'; }

# в ссылках встречается url-safe base64 без padding
happ_b64d() {
  awk '{ gsub(/-/, "+"); gsub(/_/, "/"); gsub(/[ \t\r\n]/, ""); printf "%s", $0 }' \
    | awk '{ n = length($0) % 4; if (n == 2) $0 = $0 "=="; else if (n == 3) $0 = $0 "="; printf "%s", $0 }' \
    | base64 -d 2>/dev/null
}

happ_native_key() {
  awk -v idx="$1" '
    /const NATIVE_KEYS = \[/ {
      s = $0
      sub(/^.*const NATIVE_KEYS = \[/, "", s)
      sub(/\].*$/, "", s)
      n = split(s, a, ",")
      if (idx + 1 > n) exit 1
      k = a[idx + 1]
      gsub(/^[ \t]*"|"[ \t]*$/, "", k)
      print k
      exit 0
    }
  ' "$HAPP_JS"
}

happ_crypt5_key() {
  awk -v m="$1" '
    /const CRYPT5_KEYS = \{/ {
      needle = "\"" m "\": \""
      p = index($0, needle)
      if (p == 0) exit 1
      rest = substr($0, p + length(needle))
      q = index(rest, "\"")
      if (q == 0) exit 1
      print substr(rest, 1, q - 1)
      exit 0
    }
  ' "$HAPP_JS"
}

# $1 = base64 шифротекста, $2 = base64 DER ключа, $3 = рабочий каталог.
# Шифротекст может быть склейкой нескольких RSA-блоков.
happ_rsa_decrypt() {
  _ct_b64="$1"; _key_b64="$2"; _dir="$3"
  printf '%s' "$_key_b64" | happ_b64d > "$_dir/key.der" || return 1
  [ -s "$_dir/key.der" ] || return 1
  printf '%s' "$_ct_b64" | happ_b64d > "$_dir/ct.bin"
  [ -s "$_dir/ct.bin" ] || return 1

  _bits=$(openssl pkey -inform DER -in "$_dir/key.der" -noout -text_pub 2>/dev/null \
          | sed -n 's/.*Public-Key: (\([0-9]*\) bit).*/\1/p' | head -n1)
  case "$_bits" in ''|*[!0-9]*) _bits=0 ;; esac
  _k=$((_bits / 8))
  _total=$(wc -c < "$_dir/ct.bin" | tr -d ' ')
  if [ "$_k" -le 0 ] || [ "$_total" -le "$_k" ]; then
    openssl pkeyutl -decrypt -inkey "$_dir/key.der" -keyform DER -in "$_dir/ct.bin" 2>/dev/null
    return $?
  fi
  _off=0
  while [ "$_off" -lt "$_total" ]; do
    dd if="$_dir/ct.bin" of="$_dir/blk.bin" bs="$_k" skip=$((_off / _k)) count=1 2>/dev/null
    openssl pkeyutl -decrypt -inkey "$_dir/key.der" -keyform DER -in "$_dir/blk.bin" 2>/dev/null || return 1
    _off=$((_off + _k))
  done
}

# $1 = тело, $2 = base64 ключа, $3 = 1 для salted, $4 = каталог
happ_crypt5_body() {
  _body="$1"; _key="$2"; _salted="$3"; _dir="$4"
  _nonce=$(printf '%s' "$_body" | cut -c1-12)
  if [ "$_salted" = "1" ]; then
    [ "${#_body}" -ge 22 ] || return 1
    _salt=$(printf '%s' "$_body" | cut -c15-22)
    _rest=$(printf '%s' "$_body" | cut -c23-)
  else
    _salt=""
    _rest=$(printf '%s' "$_body" | cut -c13-)
  fi

  _digits=$(printf '%s' "$_rest" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')
  [ -n "$_digits" ] || return 1
  _packed=$(printf '%s' "$_rest" | cut -c$((${#_digits} + 1))-)
  [ "${#_packed}" -gt "$_digits" ] || return 1
  _segment=$(printf '%s' "$_packed" | cut -c2-$((1 + _digits)))
  _rsa_ct=$(printf '%s' "$_packed" | cut -c$((2 + _digits))-)

  _rsa_plain=$(happ_rsa_decrypt "$_rsa_ct" "$_key" "$_dir") || return 1
  printf '%s' "$_rsa_plain" | happ_swap_pairs | happ_b64d > "$_dir/rsaval.bin"
  [ "$(wc -c < "$_dir/rsaval.bin" | tr -d ' ')" = "32" ] || return 1
  _key_hex=$(happ_hex < "$_dir/rsaval.bin")

  if [ -n "$_salt" ]; then
    _salt_hex=$(printf '%s' "$_salt" | happ_hex)
    [ "${#_salt_hex}" = "16" ] || return 1
    _key_hex=$(awk -v k="$_key_hex" -v s="$_salt_hex" '
      BEGIN {
        for (i = 0; i < 32; i++)
          printf "%02x", xor(strtonum("0x" substr(k, i * 2 + 1, 2)),
                             strtonum("0x" substr(s, (i % 8) * 2 + 1, 2)))
      }')
  fi

  # последние 16 байт — тег Poly1305; openssl enc умеет только сырой ChaCha20,
  # подделку всё равно отсечёт следующий base64
  printf '%s' "$_segment" | happ_b64d > "$_dir/sealed.bin"
  _sealed_len=$(wc -c < "$_dir/sealed.bin" | tr -d ' ')
  [ "$_sealed_len" -gt 16 ] || return 1
  dd if="$_dir/sealed.bin" of="$_dir/ct2.bin" bs=1 count=$((_sealed_len - 16)) 2>/dev/null

  # IV openssl: счётчик 4 байта little-endian + nonce
  _nonce_hex=$(printf '%s' "$_nonce" | happ_hex)
  [ "${#_nonce_hex}" = "24" ] || return 1
  openssl enc -chacha20 -d -K "$_key_hex" -iv "01000000$_nonce_hex" \
    -in "$_dir/ct2.bin" -out "$_dir/mid.bin" 2>/dev/null || return 1

  happ_swap_pairs < "$_dir/mid.bin" | happ_b64d
}

happ_decrypt() {
  _link=$(printf '%s' "$1" | tr -d ' \t\r\n')
  case "$_link" in
    happ://crypt5/*) _mode=4; _payload="${_link#happ://crypt5/}" ;;
    happ://crypt4/*) _mode=3; _payload="${_link#happ://crypt4/}" ;;
    happ://crypt3/*) _mode=2; _payload="${_link#happ://crypt3/}" ;;
    happ://crypt2/*) _mode=1; _payload="${_link#happ://crypt2/}" ;;
    happ://crypt/*)  _mode=0; _payload="${_link#happ://crypt/}" ;;
    *) happ_err "not a happ://crypt* link"; return 1 ;;
  esac
  [ -r "$HAPP_JS" ] || { happ_err "key file not found: $HAPP_JS"; return 1; }
  command -v openssl >/dev/null 2>&1 || { happ_err "openssl not found"; return 1; }

  # tmpfs: во временных файлах лежит расшифрованный ключ ChaCha20
  _dir=$(mktemp -d /dev/shm/happ.XXXXXX 2>/dev/null) || { happ_err "cannot create a directory in /dev/shm"; return 1; }
  chmod 700 "$_dir" 2>/dev/null

  _rc=1
  if [ "$_mode" != "4" ]; then
    _key=$(happ_native_key "$_mode")
    if [ -n "$_key" ]; then
      happ_rsa_decrypt "$_payload" "$_key" "$_dir" && _rc=0 || happ_err "RSA decryption failed"
    else
      happ_err "no key for mode $_mode"
    fi
    rm -rf "$_dir"
    return "$_rc"
  fi

  _shuffled=$(printf '%s' "$_payload" | happ_permute4)
  _len=${#_shuffled}
  [ "$_len" -ge 8 ] || { happ_err "payload shorter than 8 chars"; rm -rf "$_dir"; return 1; }
  _marker="$(printf '%s' "$_shuffled" | cut -c1-4)$(printf '%s' "$_shuffled" | cut -c$((_len - 3))-)"
  _body=$(printf '%s' "$_shuffled" | cut -c5-$((_len - 4)))
  [ "${#_body}" -ge 13 ] || { happ_err "body shorter than 13 chars"; rm -rf "$_dir"; return 1; }
  _key=$(happ_crypt5_key "$_marker")
  if [ -z "$_key" ]; then
    happ_err "unknown crypt5 marker: $_marker (refresh HAPP1..HAPP4)"
    rm -rf "$_dir"; return 1
  fi

  # цифра сразу после nonce = legacy; вторая раскладка остаётся запасной
  case "$(printf '%s' "$_body" | cut -c13-13)" in
    [0-9]) _order="0 1" ;;
    *)     _order="1 0" ;;
  esac
  for _salted in $_order; do
    _out=$(happ_crypt5_body "$_body" "$_key" "$_salted" "$_dir" 2>/dev/null)
    if [ -n "$_out" ]; then
      printf '%s' "$_out"
      _rc=0
      break
    fi
  done
  [ "$_rc" = "0" ] || happ_err "cannot decrypt crypt5 body (marker $_marker)"
  rm -rf "$_dir"
  return "$_rc"
}
