#!/bin/sh
# Итоги прогона для run: ранжирование рабочих стратегий, класс DPI по
# диагностическому корпусу (cls01..cls34 из gen-strategies) и лестница
# circular из лучших. POSIX sh + busybox awk; читает log.ndjson раннера.

# bc_ranked LOG [TYPE] → TSV, лучшие сверху:
#   full pass cost name proto fail flaky skip detail args
# full=1 — ни одной неудачной и нестабильной пробы. Порядок: full, затем
# больше прошедших проб, затем дешевле (проще и легче для роутера).
# Стратегии без единой прошедшей пробы не выводятся.
bc_ranked() {
  awk -v want="${2:-strategy}" '
    function jget(line, key,   p, s, e) {
      p = index(line, "\"" key "\":\"")
      if (!p) return ""
      s = substr(line, p + length(key) + 4)
      e = index(s, "\"")
      return substr(s, 1, e - 1)
    }
    function cost(a,   c, n, t, i, k, v, r) {
      n = split(a, t, " ")
      c = 0
      for (i = 1; i <= n; i++) {
        if (t[i] ~ /^--lua-desync=/) {
          c += 10
          k = split(t[i], v, ":")
          for (r = 1; r <= k; r++) {
            if (v[r] ~ /^repeats=[0-9]+$/) c += substr(v[r], 9) + 0
            else if (v[r] ~ /^seqovl=/) c += 2
            else if (v[r] ~ /^pos=/) c += gsub(/,/, ",", v[r])
          }
          if (t[i] ~ /fake|blob=/) c += 3
        } else if (t[i] == "--payload=all") c += 8
        else if (t[i] ~ /^--blob=/) c += 2
      }
      return c
    }
    index($0, "\"type\":\"" want "\"") {
      pass = jget($0, "pass") + 0
      if (pass < 1) next
      fail = jget($0, "fail") + 0; flaky = jget($0, "flaky") + 0
      args = jget($0, "args")
      printf "%d\t%d\t%d\t%s\t%s\t%d\t%d\t%d\t%s\t%s\n", (fail == 0 && flaky == 0), pass, cost(args), \
        jget($0, "name"), jget($0, "proto"), fail, flaky, jget($0, "skip") + 0, jget($0, "detail"), args
    }
  ' "$1" | sort -t "$(printf '\t')" -k1,1nr -k2,2nr -k3,3n -k4,4
}

# bc_best RANKED PROTO… → args лучшей стратегии с proto из списка.
bc_best() {
  local f="$1"; shift
  awk -F'\t' -v protos=" $* " 'index(protos, " " $5 " ") { print $10; exit }' "$f"
}

# bc_class LOG → по строке на версию TLS, где корпус что-то показал:
#   ver  class  verdict  rec_num  rec_name  rec_args  stable_nums
# (пустые rec_name/rec_args/stable_nums — «-»)
# Строка корпуса «стабильна» на версии, если все её пробы этой версии (по
# всем доменам) прошли. Классы — как в tspu-class-test: L0- (нарезка без
# фейков, любой порядок), L0 (только обратный), anomaly (только прямой),
# L2 (нарезка только с фейком), fake (голый фейк), new (только 32-34),
# sld (только разрез на границе SLD), none.
bc_class() {
  awk '
    function jget(line, key,   p, s, e) {
      p = index(line, "\"" key "\":\"")
      if (!p) return ""
      s = substr(line, p + length(key) + 4)
      e = index(s, "\"")
      return substr(s, 1, e - 1)
    }
    index($0, "\"type\":\"strategy\"") {
      name = jget($0, "name")
      if (name !~ /^cls[0-9][0-9]_/) next
      k = substr(name, 4, 2) + 0
      NAME[k] = name; ARGS[k] = jget($0, "args")
      n = split(jget($0, "detail"), d, ",")
      for (i = 1; i <= n; i++) {
        for (q = 1; q <= 2; q++) {
          v = (q == 1 ? "tls12" : "tls13")
          if (index(d[i], "/" v "-")) {
            seen[v] = 1; tot[v, k]++
            if (d[i] ~ /=ok$/) ok[v, k]++
          }
        }
      }
    }
    function has(v, k) { return tot[v, k] > 0 && ok[v, k] == tot[v, k] }
    END {
      split("1 4 6 5 22 17 2 18 19 20 21 24 25 26 27 28 29 30 31 11 12 13 14 15 16 23 32 33 34 7 8 9 10 3", PRI, " ")
      for (q = 1; q <= 2; q++) {
        v = (q == 1 ? "tls12" : "tls13")
        if (!seen[v]) continue
        st = ""; dis = spl = fk = cb = nw = 0
        for (k = 1; k <= 34; k++) {
          if (!has(v, k)) continue
          st = st (st == "" ? "" : " ") k
          if (k == 1 || k == 4 || k == 6 || k == 19) dis = 1
          else if (k == 2 || k == 5 || k == 17 || k == 18 || k == 22 || k == 23) spl = 1
          else if (k >= 7 && k <= 10) fk = 1
          else if (k >= 32) nw = 1
          else if (k != 3) cb = 1
        }
        if (st == "") { c = "none"; t = "ни одна строка корпуса не прошла стабильно" }
        else if (dis && spl) { c = "L0-"; t = "нарезка пробивает без фейков, в прямом и обратном порядке" }
        else if (dis) { c = "L0"; t = "пробивает обратный порядок (multidisorder), прямой DPI собирает" }
        else if (spl) { c = "anomaly"; t = "пробивает прямой разрез (multisplit/seqovl), обратный порядок DPI собирает" }
        else if (cb) { c = "L2"; t = "нарезка проходит только вместе с фейком" }
        else if (fk) { c = "fake"; t = "DPI верит голому фейку, а нарезку режет" }
        else if (nw) { c = "new"; t = "прошли только клон-фейк или эхо (строки 32-34)" }
        else { c = "sld"; t = "прошёл только разрез на границе SLD (pos=sld)" }
        if (fk && c != "fake") t = t "; голый фейк тоже проходит"
        rec = 0
        for (i = 1; i <= 34 && !rec; i++) if (has(v, PRI[i] + 0)) rec = PRI[i] + 0
        # пустые поля — «-»: в sh read с IFS=таб соседние табы схлопываются
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", v, c, t, rec, (rec ? NAME[rec] : "-"), (rec ? ARGS[rec] : "-"), (st == "" ? "-" : st)
      }
    }
  ' "$1"
}

# bc_ladder RANKED [MAX] → одна строка nfqws2: оркестратор circular
# переключает стратегии по кругу, когда текущая перестаёт работать
# (входящий RST или повторы исходящих данных). Ступени — full TLS-стратегии:
# сначала по одной лучшей из каждого семейства (цепочка функций, payload),
# чтобы адаптивный DPI, выучив одну механику, не убил всю лестницу; потом
# добор по рангу. Порядок ступеней — по рангу, первая — лучшая.
# Берутся только стратегии вида [--blob…] --filter-tcp=… --payload=X
# --lua-desync=… (без инстансов до --payload: circular на SYN ещё не знает
# имени хоста). Имена блобов с файлов получают суффикс ступени, чтобы
# ступени не делили одно имя. Меньше двух ступеней — пусто.
bc_ladder() {
  awk -F'\t' -v max="${2:-6}" '
    $1 != 1 || $5 != "tls" { next }
    seen[$10]++ { next }
    {
      n = split($10, t, " ")
      ok = 1; havep = 0; fam = ""
      for (i = 1; i <= n; i++) {
        if (t[i] ~ /^--filter-tcp=/ || t[i] ~ /^--blob=/) continue
        if (t[i] ~ /^--payload=/) { havep = 1; fam = fam " " t[i]; continue }
        if (t[i] ~ /^--lua-desync=/ && havep && t[i] !~ /:strategy=|=circular/) {
          f = substr(t[i], 14); sub(/:.*/, "", f); fam = fam " " f
          continue
        }
        ok = 0
      }
      if (!ok || !havep) next
      nc++; CA[nc] = $10; CF[nc] = fam
    }
    END {
      for (c = 1; c <= nc && picked < max; c++)
        if (!usedf[CF[c]]++) { pick[c] = 1; picked++ }
      for (c = 1; c <= nc && picked < max; c++)
        if (!pick[c]) { pick[c] = 1; picked++ }
      if (picked < 2) exit
      B = ""; S = ""; step = 0; lastp = ""
      for (c = 1; c <= nc; c++) {
        if (!pick[c]) continue
        step++
        n = split(CA[c], t, " "); nb = 0
        for (i = 1; i <= n; i++) {
          if (t[i] ~ /^--blob=/) {
            a = substr(t[i], 8); a = substr(a, 1, index(a, ":") - 1)
            nb++; BA[nb] = a
            B = B " --blob=" a "_s" step substr(t[i], 8 + length(a))
          }
        }
        for (i = 1; i <= n; i++) {
          if (t[i] ~ /^--payload=/) {
            if (t[i] != lastp) S = S " " t[i]
            lastp = t[i]
          } else if (t[i] ~ /^--lua-desync=/) {
            x = t[i]
            for (b = 1; b <= nb; b++) {
              gsub("=" BA[b] ":", "=" BA[b] "_s" step ":", x)
              if (substr(x, length(x) - length(BA[b])) == "=" BA[b]) x = x "_s" step
            }
            S = S " " x ":strategy=" step
          }
        }
      }
      printf "--filter-tcp=0-65535%s --out-range=-s34228 --in-range=-s5556 --lua-desync=circular:fails=2:time=120:retrans=2:nld=2:reset --in-range=x%s\n", B, S
    }
  ' "$1"
}
