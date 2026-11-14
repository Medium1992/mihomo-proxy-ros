# YAML ключа ssconf (Outline и сервисы на нём) в строки JSON вида
# [["путь","к","ключу"],"значение"], из которых jq собирает объект.
# В таком YAML только вложенные словари по отступам, скаляры в кавычках или
# без и многострочные блоки «|» / «>» (в них лежит JSON sing-box). Списков нет.
# Пишется под busybox awk: без gensub и прочих расширений gawk.

# Экранирование для JSON посимвольно: обратная косая черта в замене gsub
# у busybox awk и у gawk/mawk понимается по-разному.
function jesc(s,   out, i, c) {
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\") out = out "\\\\"
    else if (c == "\"") out = out "\\\""
    else if (c == "\t") out = out "\\t"
    else out = out c
  }
  return out
}

function unq(v,   out, i, c) {
  sub(/^[ \t]+/, "", v)
  sub(/[ \t]+$/, "", v)
  if (v ~ /^".*"$/) {
    # \" и \\ внутри двойных кавычек YAML; прочих escape в ключах нет.
    v = substr(v, 2, length(v) - 2)
    out = ""
    for (i = 1; i <= length(v); i++) {
      c = substr(v, i, 1)
      if (c == "\\" && i < length(v)) { i++; c = substr(v, i, 1) }
      out = out c
    }
    return out
  }
  if (v ~ /^'.*'$/) {
    v = substr(v, 2, length(v) - 2)
    gsub(/''/, "'", v)
    return v
  }
  sub(/[ \t]+#.*$/, "", v)
  return v
}

function path(n, extra,   i, s) {
  s = ""
  for (i = 1; i <= n; i++) s = s (i > 1 ? "," : "") "\"" jesc(keys[i]) "\""
  if (extra != "") s = s (n > 0 ? "," : "") "\"" jesc(extra) "\""
  return "[" s "]"
}

function flush_block() {
  if (!inblock) return
  if (bfold) gsub(/\\n/, " ", blk)
  print "[" path(depth, bkey) ",\"" blk "\"]"
  inblock = 0
}

BEGIN { depth = 0; inblock = 0 }

{
  line = $0
  sub(/\r$/, "", line)
  if (inblock) {
    if (line ~ /^[ \t]*$/) {
      if (bstarted) bpending = bpending "\\n"
      next
    }
    match(line, /^ */)
    ind = RLENGTH
    if (ind > bind) {
      if (bcut < 0) bcut = ind
      blk = blk (bstarted ? bpending "\\n" : "") jesc(substr(line, bcut + 1))
      bpending = ""
      bstarted = 1
      next
    }
    flush_block()
  }
  if (line ~ /^[ \t]*(#.*)?$/) next
  match(line, /^ */)
  ind = RLENGTH
  t = substr(line, ind + 1)
  while (depth > 0 && ind <= inds[depth]) depth--
  if (match(t, /^"[^"]*"[ \t]*:/) || match(t, /^'[^']*'[ \t]*:/) || match(t, /^[^:]+:/)) {
    k = substr(t, 1, RLENGTH - 1)
    v = substr(t, RLENGTH + 1)
  } else {
    print "vanya-yaml: line " NR " is not key: value" > "/dev/stderr"
    exit 1
  }
  if (v != "" && v !~ /^[ \t]/) {
    # «host:port» без пробела после двоеточия — это значение, а не ключ.
    print "vanya-yaml: line " NR " is not key: value" > "/dev/stderr"
    exit 1
  }
  k = unq(k)
  sub(/^[ \t]+/, "", v)
  sub(/[ \t]+$/, "", v)
  if (v ~ /^[|>][+-]?$/) {
    inblock = 1
    bkey = k
    bind = ind
    bcut = -1
    blk = ""
    bpending = ""
    bstarted = 0
    bfold = (substr(v, 1, 1) == ">")
    next
  }
  if (v == "") {
    depth++
    keys[depth] = k
    inds[depth] = ind
    next
  }
  print "[" path(depth, k) ",\"" jesc(unq(v)) "\"]"
}

END { flush_block() }
