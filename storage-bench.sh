#!/usr/bin/env bash
#
# storage-bench.sh — Storage Performance- & Latenztests unter Linux (fio-basiert)
#
# Subcommands:
#   run      Führt eine Testsuite aus und speichert Ergebnisse unter einem Label
#   compare  Vergleicht zwei zuvor gespeicherte Ergebnis-Labels (z.B. vor/nach Upgrade)
#   watch    Durchgehender Messlauf WÄHREND eines Storage-Umschwenks/Failovers
#            (ein einzelner ununterbrochener fio-Job + unabhängiger
#            Heartbeat-Check, um Latenzspitzen/Stalls im Moment des
#            Umschwenks zu erfassen — nicht nur davor/danach)
#   report   Erzeugt einen HTML-Report (Diagramme + Tabellen) aus den
#            gespeicherten run/compare-Ergebnissen (benötigt python3)
#
# Beispiele:
#   ./storage-bench.sh run --target /mnt/test --label baseline
#   ./storage-bench.sh run --target /mnt/test --label after-upgrade
#   ./storage-bench.sh compare baseline after-upgrade
#
#   ./storage-bench.sh run --device /dev/nvme1n1 --label baseline --confirm-destructive
#
#   ./storage-bench.sh watch --target /mnt/test --label switchover-2026-07-24 --duration 1800
#
#   ./storage-bench.sh report baseline after-upgrade --out results/report.html
#
# Standardmäßig wird NICHT auf ein rohes Blockgerät geschrieben (destruktiv!).
# Getestet wird über eine Testdatei in --target. Nur mit --device UND
# --confirm-destructive wird direkt auf ein Gerät getestet.
#
# --dry-run zeigt alle fio-Kommandos an, ohne sie auszuführen (Simulation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_ROOT="${SCRIPT_DIR}/results"

# ---- Defaults ----
TARGET_DIR=""
DEVICE=""
LABEL=""
SIZE="4G"
RUNTIME=30
RAMP_TIME=5
DRY_RUN=0
CONFIRM_DESTRUCTIVE=0
FORCE=0
IOENGINE="libaio"

# Bewusst globale (nicht 'local') Variablen für alles, was EXIT/INT/TERM-Traps in
# cmd_run/cmd_watch referenzieren: Schlägt z.B. fio fehl, lösen set -e/pipefail den
# EXIT-Trap sofort aus — zu dem Zeitpunkt hat Bash die lokale Funktions-Scope aber
# bereits verlassen. Ein 'local testfile' im Trap-Body wäre dann unter set -u
# "unbound variable" und der Trap crasht, BEVOR er aufräumen kann — genau im
# Fehlerfall, für den er gedacht ist. Als globale (immer definierte, ggf. leere)
# Variable bleibt sie im Trap in jedem Fall gültig.
TESTFILE=""
HB_PID=""

# ---- watch-spezifische Defaults ----
DURATION=1800          # Gesamtdauer des Beobachtungsfensters (Sek.), z.B. Dauer des Umschwenks
STATUS_INTERVAL=5      # wie oft fio einen Live-Status ausgibt (Sek.)
WATCH_BS="4k"
WATCH_IODEPTH=4         # bewusst niedrig: soll den Umschwenk nicht selbst belasten
WATCH_RWMIXREAD=70
HEARTBEAT_INTERVAL=1    # unabhängiger Puls-Check alle N Sekunden
HEARTBEAT_TIMEOUT=2     # ab wann ein einzelner Heartbeat als "hängt" gilt
SPIKE_THRESHOLD_MS=100  # Latenz oberhalb dessen als Anomalie markiert wird

usage() {
  cat <<'EOF'
Verwendung:
  storage-bench.sh run --target <dir> --label <name> [Optionen]
  storage-bench.sh run --device <dev> --label <name> --confirm-destructive [Optionen]
  storage-bench.sh compare <label1> <label2>
  storage-bench.sh watch --target <dir> --label <name> [Optionen]
  storage-bench.sh report [label ...] [--out <pfad>]

Optionen für 'run':
  --target <dir>            Verzeichnis für Testdatei (nicht destruktiv, empfohlen)
  --device <dev>             Rohes Blockgerät (z.B. /dev/nvme1n1) — DESTRUKTIV
  --confirm-destructive       Erforderlich, um --device tatsächlich zu nutzen
  --label <name>              Name für diesen Testlauf (z.B. baseline, after-upgrade)
  --size <size>                Testdatei-/Testbereichsgröße, Default: 4G
  --runtime <sekunden>       Laufzeit pro Teiltest, Default: 30
  --ioengine <engine>        fio ioengine, Default: libaio
  --force                       Vorhandenes Label überschreiben (Ordner wird geleert);
                                 ohne dieses Flag bricht das Skript bei existierendem
                                 Label ab, um alte Ergebnisse nicht versehentlich zu verlieren
  --dry-run                    Nur anzeigen was ausgeführt würde, nichts starten
  -h, --help                    Diese Hilfe anzeigen

Optionen für 'watch' (Messung WÄHREND eines Umschwenks/Failovers):
  --target <dir>            Verzeichnis für Testdatei (kein --device, siehe unten)
  --label <name>              Name für dieses Beobachtungsfenster (z.B. switchover-2026-07-24)
  --duration <sekunden>      Gesamtdauer des durchgehenden Laufs, Default: 1800
  --status-interval <sek>    Live-Status-Ausgabe alle N Sek., Default: 5
  --heartbeat-interval <sek> unabhängiger Puls-Check alle N Sek., Default: 1
  --heartbeat-timeout <sek>  ab wann ein Puls als hängend gilt, Default: 2
  --spike-threshold <ms>     Latenzschwelle für Anomalie-Markierung, Default: 100
  --force                       Vorhandenes Label überschreiben (Ordner wird geleert);
                                 ohne dieses Flag bricht das Skript bei existierendem
                                 Label ab, um alte Ergebnisse nicht versehentlich zu verlieren
  --dry-run                    Nur anzeigen was ausgeführt würde, nichts starten
  Hinweis: 'watch' schreibt bewusst nur in eine Testdatei (--target), nicht auf
  ein rohes --device — während eines echten Umschwenks soll der Messlauf das
  Storage nicht zusätzlich belasten oder ein zweites Risiko einführen.

Optionen für 'report':
  [label ...]     welche Labels einbeziehen (Default: alle in results/ gefundenen)
  --out <pfad>    Ausgabedatei, Default: results/report.html
  Hinweis: ein einzelnes watch-Label erzeugt automatisch einen eigenen
  Zeitreihen-Report (Latenzverlauf + Stalls) statt des run/compare-Reports.

Voraussetzungen (werden NICHT automatisch installiert):
  fio      (Benchmark-Tool)
  jq       (für Auswertung/Vergleich der JSON-Ergebnisse)
  python3  (für 'report' — HTML-Report-Generierung)
  smartctl (optional, für SMART-Health-Check bei --device)
EOF
}

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

# --label landet direkt (unverändert) im Ergebnispfad results/<label>/, der bei
# run/watch per --force mit 'rm -rf' geleert wird. Ohne diese Prüfung würde z.B.
# --label "../../etc" den Ergebnisordner nach außerhalb von results/ verlegen —
# und zwar schon beim allerersten Aufruf, nicht erst mit --force (rm -rf/mkdir -p
# laufen unconditional, sobald der Zielpfad noch nicht existiert oder leer ist).
validate_label() {
  case "$1" in
    */*|.|..) die "--label darf kein '/' enthalten und nicht '.' oder '..' sein: '$1'" ;;
  esac
}

# Prüft freien Platz in $1 gegen die Testdateigröße $2 (fio-Größenangabe wie
# "4G"/"512M"), BEVOR fio läuft — sonst scheitert fio selbst mitten im
# Vorbelegen der Testdatei mit dem kryptischen "err=28 ... No space left on
# device", ohne zu sagen, wie viel eigentlich gebraucht/frei war. numfmt
# --from=iec versteht dieselben Suffixe (k/M/G/T = *1024), die fio für --size
# akzeptiert. Kein Sicherheitsabstand über die reine Größe hinaus — reicht,
# um den mit Abstand häufigsten Fall (--size deutlich zu groß fürs Ziel) klar
# zu melden, ohne beim exakten Grenzfall selbst noch mitzuraten.
check_free_space() {
  local dir="$1" size="$2" size_bytes avail_bytes
  size_bytes=$(numfmt --from=iec "$size" 2>/dev/null) || die "Ungültiger --size Wert: $size"
  avail_bytes=$(df --output=avail -B1 "$dir" 2>/dev/null | tail -1 | tr -d ' ')
  [ -n "$avail_bytes" ] || return 0
  if [ "$size_bytes" -gt "$avail_bytes" ]; then
    die "Zu wenig freier Platz in $dir: --size=$size (${size_bytes} Bytes) benötigt, verfügbar nur $(numfmt --to=iec "$avail_bytes") (${avail_bytes} Bytes). --size verkleinern oder anderes --target wählen."
  fi
}

# Prüft fio/jq und bricht ab (außer im --dry-run, wo fehlende Tools nur gewarnt
# werden, da ohnehin nichts ausgeführt wird).
check_deps() {
  local missing=()
  command -v fio >/dev/null 2>&1 || missing+=("fio")
  command -v jq  >/dev/null 2>&1 || missing+=("jq")
  if [ ${#missing[@]} -gt 0 ]; then
    log "Fehlende Abhängigkeiten: ${missing[*]}"
    log "Installation liegt bei dir, z.B.: sudo apt install ${missing[*]}"
    if [ "$DRY_RUN" -eq 0 ]; then
      die "Bitte Abhängigkeiten installieren oder --dry-run verwenden."
    fi
  fi
}

# Baut und startet (oder loggt im --dry-run) einen einzelnen fio-Teiltest für
# 'run'. $1=Testname (bestimmt Ausgabedateinamen), $2=Ergebnisverzeichnis,
# Rest=fio-Extra-Argumente (--rw, --bs, --iodepth, ...) für diesen Teiltest.
run_fio_job() {
  local name="$1"; shift
  local outdir="$1"; shift
  local extra_args=("$@")

  # Als Array statt als String gebaut (nicht mehr über eine fio_target_args()-
  # Funktion mit echo + unquoted Re-Expansion) — sonst würden ein --target- oder
  # --size-Wert mit Leerzeichen durch Word-Splitting/Globbing beim Einsetzen in
  # das cmd-Array kaputtgehen (z.B. ein Mountpoint wie "/mnt/my data").
  local target_args=()
  if [ -n "$DEVICE" ]; then
    target_args=(--filename="$DEVICE")
  else
    target_args=(--filename="${TARGET_DIR%/}/fio-testfile" --size="$SIZE")
  fi

  local json_out="${outdir}/${name}.json"
  local log_out="${outdir}/${name}.log"

  # --direct=1 (O_DIRECT) umgeht den Linux-Page-Cache — ohne das würden schnelle,
  # kleine Testdateien teils nur RAM-Geschwindigkeit statt echter Storage-Performance
  # zeigen, sobald die Datei komplett im Cache liegt.
  local cmd=(fio
    --name="$name"
    "${target_args[@]}"
    --direct=1
    --time_based
    --runtime="$RUNTIME"
    --ramp_time="$RAMP_TIME"
    --group_reporting
    --output-format=json
    --output="$json_out"
    "${extra_args[@]}"
  )

  log "Test: $name"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [DRY-RUN] %s\n' "${cmd[*]}"
    return 0
  fi

  # --output oben leitet fios GESAMTE reguläre Ausgabe (den JSON-Report) in
  # "$json_out" um -- stdout ist bei --output-format=json daher immer leer,
  # ein "tee stdout" wie früher hier hätte nie etwas in "$log_out" geschrieben
  # (0 Bytes, ungeprüft so gebaut). fio schreibt Warnungen/Fehler dagegen immer
  # nach stderr, unabhängig von --output -- das ist die eigentlich sinnvolle
  # Quelle für "$log_out": leer im Erfolgsfall, gefüllt genau dann, wenn beim
  # Teiltest etwas schiefging. "2>&1" vor der Pipe holt stderr dafür ab, ohne
  # es vom Terminal fernzuhalten (kein abschließendes ">/dev/null" mehr).
  "${cmd[@]}" 2>&1 | tee "$log_out"
}

# Liest bw/iops/Latenz aus einer fio-JSON-Datei und formatiert sie für die
# Terminal-Zusammenfassung (Menschen-lesbar, gerundet). $1 = json file, $2 = read|write.
parse_metric() {
  local json="$1" rw="$2"
  jq -r --arg rw "$rw" '
    .jobs[0][$rw] |
    "\((.bw/1024)|round) MB/s  \(.iops|round) IOPS  avg_lat=\((.clat_ns.mean/1000000)*100|round/100) ms  p99=\(((.clat_ns.percentile["99.000000"] // 0)/1000000)*100|round/100) ms"
  ' "$json" 2>/dev/null || echo "n/a"
}

# Rohe Zahlenwerte (unformatiert) für CSV-Export, volle Nachkommastellen erhalten
csv_metric_values() {
  # $1 = json file, $2 = read|write
  local json="$1" rw="$2"
  jq -r --arg rw "$rw" '
    .jobs[0][$rw] |
    [ (.bw/1024), .iops, (.clat_ns.mean/1000000), ((.clat_ns.percentile["99.000000"] // 0)/1000000) ]
    | @csv
  ' "$json" 2>/dev/null
}

# Druckt die Terminal-Zusammenfassung für 'run' und schreibt dabei parallel
# summary.csv (eine Zeile pro Test×Richtung) — die einzige Stelle, die diese
# CSV erzeugt. $1 = Ergebnisverzeichnis (results/<label>).
print_summary() {
  local outdir="$1"
  local csv_file="${outdir}/summary.csv"
  echo "label,test,direction,bw_MBps,iops,avg_lat_ms,p99_lat_ms" > "$csv_file"
  echo ""
  echo "=== Zusammenfassung: $(basename "$outdir") ==="
  printf '%-16s %-10s %s\n' "Test" "Richtung" "Ergebnis"
  for json in "$outdir"/*.json; do
    [ -e "$json" ] || continue
    local name; name=$(basename "$json" .json)
    local has_read has_write
    has_read=$(jq -r '.jobs[0].read.io_bytes // 0' "$json")
    has_write=$(jq -r '.jobs[0].write.io_bytes // 0' "$json")
    if [ "$has_read" != "0" ]; then
      printf '%-16s %-10s %s\n' "$name" "read" "$(parse_metric "$json" read)"
      echo "$(basename "$outdir"),${name},read,$(csv_metric_values "$json" read)" >> "$csv_file"
    fi
    if [ "$has_write" != "0" ]; then
      printf '%-16s %-10s %s\n' "$name" "write" "$(parse_metric "$json" write)"
      echo "$(basename "$outdir"),${name},write,$(csv_metric_values "$json" write)" >> "$csv_file"
    fi
  done
  log "CSV geschrieben: $csv_file"
}

# Subcommand 'run': validiert Optionen, führt die sieben fio-Teiltests
# (seq/rand/latency/mixed) nacheinander aus und schreibt Zusammenfassung + CSV.
cmd_run() {
  [ -n "$LABEL" ] || die "--label ist erforderlich"
  validate_label "$LABEL"

  # --device misst die rohe Hardware-Grenze ohne Dateisystem-Overhead (z.B. um eine
  # neue SSD vor dem Formatieren gegen die Herstellerspec zu prüfen, oder um den
  # Overhead eines Dateisystems zu isolieren: einmal --device, einmal --target auf
  # derselben Platte, Differenz = Preis des Dateisystems). Da fio dabei direkt auf
  # die Sektoren schreibt (keine Datei-Abstraktion), zerstört das jede Partition/
  # jedes Dateisystem auf dem Gerät unwiderruflich — daher der Zwang zu
  # --confirm-destructive. Für "wie schnell ist es für meine echte Anwendung"
  # (die ja auch über ein Dateisystem läuft) ist --target die richtige Wahl.
  if [ -n "$DEVICE" ]; then
    [ "$CONFIRM_DESTRUCTIVE" -eq 1 ] || die "--device erfordert zusätzlich --confirm-destructive (überschreibt Daten auf dem Gerät!)"
    [ -n "$TARGET_DIR" ] && die "--target und --device schließen sich aus"
    # Letzte Sicherung gegen einen vertippten/falschen Gerätepfad, bevor es zum
    # eigentlichen (unwiderruflichen) fio-Aufruf kommt — ohne diese Prüfung würde
    # ein Tippfehler erst auffallen, wenn fio selbst mit einem kryptischeren Fehler
    # abbricht (oder schlimmer: ein falsches, aber existierendes Gerät trifft).
    if [ "$DRY_RUN" -eq 0 ]; then
      [ -b "$DEVICE" ] || die "Kein Blockgerät gefunden: $DEVICE (Pfad prüfen — existiert es? richtiges Gerät?)"
    fi
  else
    [ -n "$TARGET_DIR" ] || die "Entweder --target <dir> oder --device <dev> angeben"
    if [ "$DRY_RUN" -eq 0 ]; then
      [ -d "$TARGET_DIR" ] || die "Zielverzeichnis existiert nicht: $TARGET_DIR"
      # Beschreibbarkeit separat prüfen (nicht nur Existenz) — sonst scheitert erst
      # fio selbst mitten im Lauf mit einer kryptischen fstat/Permission-Fehlermeldung
      # (typisch bei NFS-Freigaben mit falschen Berechtigungen/UID-Mapping).
      [ -w "$TARGET_DIR" ] || die "Zielverzeichnis nicht beschreibbar: $TARGET_DIR (Berechtigungen/Mount prüfen, z.B. NFS root_squash/UID-Mapping)"
      check_free_space "$TARGET_DIR" "$SIZE"
    fi
  fi

  check_deps

  local outdir="${RESULTS_ROOT}/${LABEL}"

  # Existiert das Label schon und enthält Ergebnisse, nur mit --force überschreiben
  # — schützt davor, einen früheren Lauf durch ein wiederverwendetes/verwechseltes
  # Label versehentlich zu verlieren. Beim tatsächlichen Überschreiben wird der
  # Ordner komplett geleert statt nur gleichnamige Dateien zu ersetzen, damit keine
  # Datei von einem alten Lauf mit anderem Testumfang (z.B. nach einem Skript-Update)
  # liegen bleibt.
  if [ -d "$outdir" ] && [ -n "$(ls -A "$outdir" 2>/dev/null)" ] && [ "$FORCE" -ne 1 ]; then
    die "Label '$LABEL' existiert bereits und enthält Ergebnisse ($outdir). Mit --force überschreiben (Ordner wird geleert) oder ein anderes --label wählen."
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    rm -rf "$outdir"
    mkdir -p "$outdir"
  elif [ -d "$outdir" ] && [ -n "$(ls -A "$outdir" 2>/dev/null)" ]; then
    log "[DRY-RUN] würde vorhandenes Ergebnisverzeichnis leeren und neu anlegen: $outdir"
  else
    log "[DRY-RUN] würde Ergebnisverzeichnis anlegen: $outdir"
  fi

  # Testdatei bei Abbruch (Ctrl-C, Crash) automatisch aufräumen, nicht nur am
  # normalen Ende der Funktion — sonst bleibt eine große (--size) Testdatei im
  # --target-Verzeichnis liegen. Nur im Datei-Modus relevant (kein --device).
  # WICHTIG: EXIT- und INT/TERM-Trap getrennt. Ein Trap auf INT/TERM ohne
  # explizites 'exit' beendet das Skript NICHT — bash läuft nach dem Trap-Body
  # einfach weiter. Ohne das 'exit' hier würde Ctrl-C nur die aktuelle
  # Testdatei löschen und die Schleife mit dem nächsten Teiltest fortsetzen
  # (der die Datei sofort neu anlegt), statt die ganze Testsuite abzubrechen.
  # TESTFILE ist bewusst global (siehe Kommentar bei der Deklaration oben) — schlägt
  # z.B. fio fehl (set -e/pipefail), muss der Trap auch dann noch aufräumen können.
  TESTFILE=""
  if [ "$DRY_RUN" -eq 0 ] && [ -z "$DEVICE" ]; then
    TESTFILE="${TARGET_DIR%/}/fio-testfile"
    trap 'rm -f "$TESTFILE"' EXIT
    trap 'rm -f "$TESTFILE"; exit 130' INT TERM
  fi

  # Optionaler SMART-Check vor dem Lauf, wenn Device + smartctl vorhanden
  if [ -n "$DEVICE" ] && command -v smartctl >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[DRY-RUN] smartctl -a $DEVICE > ${outdir}/smart-before.txt"
    else
      smartctl -a "$DEVICE" > "${outdir}/smart-before.txt" 2>&1 || true
    fi
  fi

  # 1) Sequenzieller Durchsatz — große Blöcke, hohe Tiefe
  run_fio_job "seq_read" "$outdir" \
    --rw=read --bs=1M --iodepth=32 --numjobs=1 --ioengine="$IOENGINE"

  run_fio_job "seq_write" "$outdir" \
    --rw=write --bs=1M --iodepth=32 --numjobs=1 --ioengine="$IOENGINE"

  # 2) Random IOPS — kleine Blöcke, hohe Parallelität
  run_fio_job "rand_read_iops" "$outdir" \
    --rw=randread --bs=4k --iodepth=32 --numjobs=4 --ioengine="$IOENGINE"

  run_fio_job "rand_write_iops" "$outdir" \
    --rw=randwrite --bs=4k --iodepth=32 --numjobs=4 --ioengine="$IOENGINE"

  # 3) Latenz — QD=1, ein Job, ioengine=psync statt $IOENGINE: bei Queue-Tiefe 1
  #    gibt es nichts zu asynchron zu verwalten, psync misst die reine Round-Trip-
  #    Zeit pro Anfrage ohne den (kleinen) Overhead der async-Engine selbst.
  run_fio_job "latency_read" "$outdir" \
    --rw=randread --bs=4k --iodepth=1 --numjobs=1 --ioengine=psync

  run_fio_job "latency_write" "$outdir" \
    --rw=randwrite --bs=4k --iodepth=1 --numjobs=1 --ioengine=psync

  # 4) Gemischte Last — nahe an realem Workload (z.B. DB-artig 70/30)
  run_fio_job "mixed_70r_30w" "$outdir" \
    --rw=randrw --rwmixread=70 --bs=4k --iodepth=16 --numjobs=2 --ioengine="$IOENGINE"

  if [ -n "$DEVICE" ] && command -v smartctl >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[DRY-RUN] smartctl -a $DEVICE > ${outdir}/smart-after.txt"
    else
      smartctl -a "$DEVICE" > "${outdir}/smart-after.txt" 2>&1 || true
    fi
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    # Testdatei explizit entfernen (nicht erst auf den EXIT-Trap warten) und
    # danach den Trap deaktivieren, damit er beim normalen Skriptende nicht
    # nochmal unnötig auf $TESTFILE prüft.
    if [ -n "$TESTFILE" ]; then
      rm -f "$TESTFILE"
      trap - EXIT INT TERM
    fi
    print_summary "$outdir"
  elif [ -n "$TARGET_DIR" ]; then
    log "[DRY-RUN] Testdatei würde danach gelöscht: ${TARGET_DIR%/}/fio-testfile"
  fi
}

# Subcommand 'compare': vergleicht die Bandbreite zweier 'run'-Ergebnis-Labels
# Test für Test, druckt eine Tabelle und schreibt compare_<a>_vs_<b>.csv.
cmd_compare() {
  local label1="${1:-}" label2="${2:-}"
  [ -n "$label1" ] && [ -n "$label2" ] || die "Verwendung: compare <label1> <label2>"
  validate_label "$label1"
  validate_label "$label2"

  local dir1="${RESULTS_ROOT}/${label1}"
  local dir2="${RESULTS_ROOT}/${label2}"
  [ -d "$dir1" ] || die "Kein Ergebnis für Label '$label1' gefunden ($dir1)"
  [ -d "$dir2" ] || die "Kein Ergebnis für Label '$label2' gefunden ($dir2)"

  command -v jq >/dev/null 2>&1 || die "jq wird für 'compare' benötigt"

  local csv_file="${RESULTS_ROOT}/compare_${label1}_vs_${label2}.csv"
  echo "test,direction,bw_before_MBps,bw_after_MBps,delta_pct,regression" > "$csv_file"

  echo ""
  echo "=== Vergleich: $label1  ->  $label2 ==="
  printf '%-16s %-6s %12s %12s %10s\n' "Test" "Rich." "vorher" "nachher" "Delta"

  for json1 in "$dir1"/*.json; do
    [ -e "$json1" ] || continue
    local name; name=$(basename "$json1" .json)
    local json2="${dir2}/${name}.json"
    [ -e "$json2" ] || { log "Kein passendes Ergebnis in $label2 für $name, übersprungen"; continue; }

    for rw in read write; do
      local bw1 bw2
      bw1=$(jq -r --arg rw "$rw" '.jobs[0][$rw].bw // empty' "$json1")
      bw2=$(jq -r --arg rw "$rw" '.jobs[0][$rw].bw // empty' "$json2")
      [ -n "$bw1" ] && [ -n "$bw2" ] || continue
      [ "$bw1" != "0" ] || continue

      local delta_pct
      delta_pct=$(awk -v a="$bw1" -v b="$bw2" 'BEGIN { printf "%.1f", ((b-a)/a)*100 }')

      local flag="" is_regression="nein"
      awk -v d="$delta_pct" 'BEGIN { exit !(d < -10) }' && { flag=" <-- REGRESSION"; is_regression="ja"; }

      local bw1_mb bw2_mb
      bw1_mb=$(awk -v v="$bw1" 'BEGIN{printf "%.1f", v/1024}')
      bw2_mb=$(awk -v v="$bw2" 'BEGIN{printf "%.1f", v/1024}')

      printf '%-16s %-6s %10.1f MB/s %10.1f MB/s %8s%%%s\n' \
        "$name" "$rw" "$bw1_mb" "$bw2_mb" "$delta_pct" "$flag"

      echo "${name},${rw},${bw1_mb},${bw2_mb},${delta_pct},${is_regression}" >> "$csv_file"
    done
  done
  echo ""
  log "CSV geschrieben: $csv_file"
  echo "Hinweis: 'Delta' < -10% ist als REGRESSION markiert (Bandbreite)."
  echo "Für Latenz-Vergleich direkt in den *.json unter clat_ns nachsehen (latency_* Tests)."
}

# Analysiert nach dem watch-Lauf das Latenz-Log und das Heartbeat-Log auf
# Anomalien und ordnet sie einer geschätzten Wanduhrzeit zu, damit man sie
# gegen den tatsächlichen Umschwenk-/Failover-Zeitpunkt abgleichen kann.
analyze_watch() {
  local outdir="$1" start_epoch="$2"
  local latlog
  latlog=$(ls "${outdir}"/*_lat.*.log 2>/dev/null | head -n1 || true)

  echo ""
  echo "=== Anomalie-Timeline: $(basename "$outdir") ==="
  echo "Start des Messlaufs: $(cat "${outdir}/start_time.txt" 2>/dev/null || echo unbekannt)"

  if [ -n "$latlog" ]; then
    echo ""
    echo "--- Latenz-Ausreißer (> ${SPIKE_THRESHOLD_MS} ms), aus $(basename "$latlog") ---"
    local thr_ns=$((SPIKE_THRESHOLD_MS * 1000000))
    local found=0
    while IFS=',' read -r t_ms lat_ns ddir _rest; do
      t_ms=$(echo "$t_ms" | tr -d ' ')
      lat_ns=$(echo "$lat_ns" | tr -d ' ')
      ddir=$(echo "$ddir" | tr -d ' ')
      [ -n "$t_ms" ] && [ -n "$lat_ns" ] || continue
      if [ "$lat_ns" -gt "$thr_ns" ] 2>/dev/null; then
        found=1
        local wall_epoch=$((start_epoch + t_ms / 1000))
        local wall_str
        wall_str=$(date -d "@${wall_epoch}" +%H:%M:%S 2>/dev/null || date -r "$wall_epoch" +%H:%M:%S 2>/dev/null || echo "?")
        local dir_name="read"; [ "$ddir" = "1" ] && dir_name="write"; [ "$ddir" = "2" ] && dir_name="trim"
        printf '  t+%8ss  (~%s)  %-5s  lat=%s ms\n' "$((t_ms/1000))" "$wall_str" "$dir_name" "$((lat_ns/1000000))"
      fi
    done < "$latlog"
    [ "$found" -eq 0 ] && echo "  keine Ausreißer über der Schwelle gefunden"
  else
    log "Kein Latenz-Log gefunden (fio evtl. abgebrochen?)"
  fi

  echo ""
  echo "--- Stalls im Heartbeat (> ${HEARTBEAT_TIMEOUT}s ohne Antwort) ---"
  if [ -s "${outdir}/heartbeat.log" ] && grep -q STALL "${outdir}/heartbeat.log"; then
    while read -r ts status _rest; do
      [ "$status" = "STALL" ] || continue
      local wall_str
      wall_str=$(date -d "@${ts}" +%H:%M:%S 2>/dev/null || date -r "$ts" +%H:%M:%S 2>/dev/null || echo "?")
      printf '  %s  HEARTBEAT STALL\n' "$wall_str"
    done < "${outdir}/heartbeat.log"
  else
    echo "  keine Stalls im Heartbeat gefunden"
  fi

  echo ""
  echo "Hinweis: Wanduhr-Zeiten mit dem tatsächlichen Umschwenk-/Failover-Zeitstempel"
  echo "(z.B. multipathd -ll, dmesg, Storage-Array-/Replikations-Log) abgleichen."
}

# Subcommand 'watch': startet einen durchgehenden fio-Job plus unabhängigen
# Heartbeat-Hintergrundprozess für die Dauer eines Umschwenks/Failovers und ruft
# danach analyze_watch() für die Anomalie-Timeline auf.
cmd_watch() {
  [ -n "$LABEL" ] || die "--label ist erforderlich"
  validate_label "$LABEL"
  [ -n "$TARGET_DIR" ] || die "--target <dir> ist erforderlich"
  [ -z "$DEVICE" ] || die "'watch' unterstützt kein --device — bewusst nur Testdatei, siehe --help"

  if [ "$DRY_RUN" -eq 0 ]; then
    [ -d "$TARGET_DIR" ] || die "Zielverzeichnis existiert nicht: $TARGET_DIR"
    [ -w "$TARGET_DIR" ] || die "Zielverzeichnis nicht beschreibbar: $TARGET_DIR (Berechtigungen/Mount prüfen, z.B. NFS root_squash/UID-Mapping)"
    check_free_space "$TARGET_DIR" "$SIZE"
  fi

  check_deps

  local outdir="${RESULTS_ROOT}/${LABEL}"

  # Wie bei 'run': existierendes Label nur mit --force überschreiben, sonst bricht
  # ein wiederholter watch-Lauf mit demselben Label eine frühere Anomalie-Timeline
  # nicht versehentlich weg.
  if [ -d "$outdir" ] && [ -n "$(ls -A "$outdir" 2>/dev/null)" ] && [ "$FORCE" -ne 1 ]; then
    die "Label '$LABEL' existiert bereits und enthält Ergebnisse ($outdir). Mit --force überschreiben (Ordner wird geleert) oder ein anderes --label wählen."
  fi

  TESTFILE="${TARGET_DIR%/}/fio-watch-testfile"
  local heartbeat_log="${outdir}/heartbeat.log"
  local cpu_load_log="${outdir}/cpu_load.log"
  local start_epoch
  start_epoch=$(date +%s)

  # --continue_on_error=all: bei einem echten Umschwenk/Failover können kurze
  #   I/O-Fehler auftreten (Pfad-Wechsel, kurzer Timeout) — ohne das würde fio
  #   beim ersten Fehler abbrechen und genau die interessanteste Phase der
  #   Messung fehlt. Fehler werden stattdessen protokolliert, der Lauf geht weiter.
  # --write_lat_log + --log_avg_msec=1000: schreibt sekundengenaue Latenzwerte
  #   statt nur eines Gesamtdurchschnitts über die ganze Laufzeit — ein kurzer
  #   Hänger mitten im 30-Minuten-Fenster würde im Durchschnitt sonst verschwinden.
  # --iodepth niedrig (WATCH_IODEPTH, Default 4): der Messlauf soll den Umschwenk
  #   selbst nicht durch eigene Last zusätzlich verschärfen.
  # Bewusst KEIN --output=<datei>: fio leitet damit ALLE Ausgaben (auch die
  #   periodischen Live-Status-Zeilen) in die Datei um, nichts mehr geht
  #   auf stdout — der Live-Status auf dem Terminal wäre dann komplett stumm,
  #   trotz "tee" weiter unten. Ohne --output läuft alles über stdout, tee
  #   zeigt es live UND schreibt es nach watch-status.log.
  # --eta=always + --eta-newline (NICHT --status-interval!): fio erkennt, dass
  #   stdout hier keine echte TTY ist (sondern in "tee" gepiped wird), und
  #   unterdrückt seine periodische Status-/ETA-Zeile standardmäßig komplett
  #   dafür. --eta=always erzwingt die Anzeige trotzdem, --eta-newline sorgt für
  #   eine echte Newline pro Intervall statt eines Carriage-Return-Overwrites,
  #   der nur auf einem echten Terminal Sinn ergibt. --status-interval bewusst
  #   NICHT gesetzt: das erzwingt bei fio einen kompletten Status-DUMP (inkl.
  #   eigenem "Run status group"-Block) bei jedem Tick statt der schlanken
  #   Ein-Zeile-Ausgabe, die --eta-newline allein schon liefert — unübersichtlich
  #   bei einem 30-Minuten-Lauf mit vielen Ticks.
  local fio_cmd=(fio
    --name=watch
    --filename="$TESTFILE"
    --size="$SIZE"
    --direct=1
    --time_based
    --runtime="$DURATION"
    --rw=randrw
    --rwmixread="$WATCH_RWMIXREAD"
    --bs="$WATCH_BS"
    --iodepth="$WATCH_IODEPTH"
    --numjobs=1
    --ioengine="$IOENGINE"
    --eta=always
    --eta-newline="$STATUS_INTERVAL"
    --continue_on_error=all
    --write_lat_log="${outdir}/${LABEL}"
    --log_avg_msec=1000
  )

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -d "$outdir" ] && [ -n "$(ls -A "$outdir" 2>/dev/null)" ]; then
      log "[DRY-RUN] würde vorhandenes Ergebnisverzeichnis leeren und neu anlegen: $outdir"
    else
      log "[DRY-RUN] würde Ergebnisverzeichnis anlegen: $outdir"
    fi
    log "[DRY-RUN] Heartbeat im Hintergrund: alle ${HEARTBEAT_INTERVAL}s ein O_DIRECT-Schreibtest,"
    log "          Timeout ${HEARTBEAT_TIMEOUT}s -> bei Überschreitung 'STALL' in ${outdir}/heartbeat.log"
    printf '  [DRY-RUN] %s\n' "${fio_cmd[*]}"
    log "[DRY-RUN] Nach Ende: Latenz-Log (>${SPIKE_THRESHOLD_MS}ms) und Heartbeat-Log auf Stalls durchsuchen"
    log "          und beides mit Wanduhrzeit des Umschwenks abgleichen."
    return 0
  fi

  # Ordner komplett leeren statt nur einzelne Dateien zu ersetzen — sonst würden
  # heartbeat.log/watch-status.log eines vorherigen Laufs mit demselben Label
  # weiterbestehen (siehe Append-Fix unten) und alte mit neuen Zeitstempeln mischen.
  rm -rf "$outdir"
  mkdir -p "$outdir"
  echo "$start_epoch" > "${outdir}/start_epoch.txt"
  date > "${outdir}/start_time.txt"
  # Für generate-report.py: SPIKE_THRESHOLD_MS/HEARTBEAT_TIMEOUT existieren sonst
  # nur als Shell-Variablen dieses Laufs und wären für einen späteren 'report'-
  # Aufruf (eigener Prozess) sonst nicht mehr bekannt.
  echo "$SPIKE_THRESHOLD_MS" > "${outdir}/spike_threshold_ms.txt"
  echo "$HEARTBEAT_TIMEOUT" > "${outdir}/heartbeat_timeout_s.txt"

  log "Start: Label='$LABEL', Dauer=${DURATION}s, Ziel=$TARGET_DIR"
  log "Wanduhr-Zeitpunkt des eigentlichen Umschwenks separat notieren (z.B. wann Failover ausgelöst wurde)."
  log "Live-Status alle ${STATUS_INTERVAL}s unten, Abbruch mit Ctrl-C möglich (Heartbeat wird dann sauber beendet)."

  # Unabhängiger Puls-Check: läuft als eigener Hintergrundprozess parallel zu fio
  # und meldet auch dann zuverlässig "kein Lebenszeichen", wenn fio selbst wegen
  # eines I/O-Hängers im Kernel blockiert und seine eigene Statusausgabe verzögert
  # oder ausbleibt — bewusst unabhängig von fio, nicht nur dessen Latenz-Log.
  # ">" statt ">>": heartbeat.log gehört exklusiv diesem Lauf (der Ordner wurde
  # oben ohnehin schon geleert) — mit ">>" würden sich bei Wiederverwendung eines
  # Labels alte und neue Heartbeat-Zeitstempel vermischen und die Anomalie-Timeline
  # verfälschen.
  # prev_status verfolgt Zustandswechsel, damit nur beim Wechsel OK<->STALL eine
  # Zeile auf dem Terminal erscheint (log() schreibt nach stderr, landet also nicht
  # in "$heartbeat_log" — nur dessen stdout wird umgeleitet) — nicht bei jedem
  # einzelnen Check, sonst würde das Terminal bei HEARTBEAT_INTERVAL=1s zugespamt.
  # Genau das war die Lücke im zweiten Testfall: hängt fio selbst im Kernel fest
  # (I/O-Hänger, z.B. eine für Minuten unerreichbare LIF), blieb bislang auch das
  # Terminal komplett stumm bis zum Ende — der Heartbeat lief zwar unabhängig
  # weiter, meldete sich aber nur in der Datei, nie live.
  #
  # CPU-Last (1-Min-Load aus /proc/loadavg) wird bei jedem Check zusätzlich in
  # cpu_load.log mitgeschrieben — bewusst NUR in die Datei, keine eigene
  # Terminal-Zeile. Ein erster Versuch, das live auszugeben, ist schiefgegangen:
  # zwei unabhängige Prozesse (fio und dieser Heartbeat) schreiben unsynchronisiert
  # auf dasselbe Terminal, und fios eigene Tick-Zeile nutzt Carriage-Return-
  # Overwrites (siehe --eta-newline oben) — eine dazwischenfunkende Zeile vom
  # Heartbeat konnte fios Zeile mitten im Aufbau zerreißen. Für Werte, die (anders
  # als ein STALL) nicht in Echtzeit gebraucht werden, ist eine Datei ohne dieses
  # Risiko die bessere Wahl.
  (
    prev_status="OK"
    while true; do
      local_ts=$(date +%s)
      if timeout "$HEARTBEAT_TIMEOUT" dd if=/dev/zero of="${TESTFILE}.hb" bs=4k count=1 oflag=direct conv=fsync >/dev/null 2>&1; then
        echo "${local_ts} OK"
        [ "$prev_status" = "STALL" ] && log "Heartbeat: wieder OK — Ziel antwortet wieder"
        prev_status="OK"
      else
        echo "${local_ts} STALL"
        [ "$prev_status" = "OK" ] && log "Heartbeat: STALL — kein Ping seit über ${HEARTBEAT_TIMEOUT}s"
        prev_status="STALL"
      fi
      cpu_load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null) || cpu_load="?"
      echo "${local_ts} ${cpu_load}" >> "$cpu_load_log"
      sleep "$HEARTBEAT_INTERVAL"
    done
  ) > "$heartbeat_log" &
  HB_PID=$!
  # Trap deckt neben dem Heartbeat-Prozess auch die Testdatei ab — sonst bleibt
  # bei Ctrl-C/Abbruch eine große (--size) Testdatei im --target liegen. TESTFILE/
  # HB_PID sind bewusst global (siehe Kommentar bei der Deklaration oben) — schlägt
  # z.B. fio fehl, muss der Trap auch dann noch aufräumen können.
  trap 'kill "$HB_PID" 2>/dev/null || true; rm -f "$TESTFILE" "${TESTFILE}.hb"' EXIT INT TERM

  set +e
  "${fio_cmd[@]}" | tee "${outdir}/watch-status.log"
  set -e

  kill "$HB_PID" 2>/dev/null || true
  trap - EXIT INT TERM

  rm -f "$TESTFILE" "${TESTFILE}.hb"

  analyze_watch "$outdir" "$start_epoch"
}

# ---- Argument-Parsing ----
[ $# -ge 1 ] || { usage; exit 1; }
SUBCMD="$1"; shift

case "$SUBCMD" in
  run)
    while [ $# -gt 0 ]; do
      case "$1" in
        --target) TARGET_DIR="${2:?Option --target benötigt einen Wert}"; shift 2 ;;
        --device) DEVICE="${2:?Option --device benötigt einen Wert}"; shift 2 ;;
        --label) LABEL="${2:?Option --label benötigt einen Wert}"; shift 2 ;;
        --size) SIZE="${2:?Option --size benötigt einen Wert}"; shift 2 ;;
        --runtime) RUNTIME="${2:?Option --runtime benötigt einen Wert}"; shift 2 ;;
        --ioengine) IOENGINE="${2:?Option --ioengine benötigt einen Wert}"; shift 2 ;;
        --confirm-destructive) CONFIRM_DESTRUCTIVE=1; shift ;;
        --force) FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unbekannte Option: $1" ;;
      esac
    done
    cmd_run
    ;;
  compare)
    cmd_compare "${1:-}" "${2:-}"
    ;;
  watch)
    while [ $# -gt 0 ]; do
      case "$1" in
        --target) TARGET_DIR="${2:?Option --target benötigt einen Wert}"; shift 2 ;;
        --label) LABEL="${2:?Option --label benötigt einen Wert}"; shift 2 ;;
        --duration) DURATION="${2:?Option --duration benötigt einen Wert}"; shift 2 ;;
        --status-interval) STATUS_INTERVAL="${2:?Option --status-interval benötigt einen Wert}"; shift 2 ;;
        --heartbeat-interval) HEARTBEAT_INTERVAL="${2:?Option --heartbeat-interval benötigt einen Wert}"; shift 2 ;;
        --heartbeat-timeout) HEARTBEAT_TIMEOUT="${2:?Option --heartbeat-timeout benötigt einen Wert}"; shift 2 ;;
        --spike-threshold) SPIKE_THRESHOLD_MS="${2:?Option --spike-threshold benötigt einen Wert}"; shift 2 ;;
        --size) SIZE="${2:?Option --size benötigt einen Wert}"; shift 2 ;;
        --ioengine) IOENGINE="${2:?Option --ioengine benötigt einen Wert}"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unbekannte Option: $1" ;;
      esac
    done
    cmd_watch
    ;;
  report)
    command -v python3 >/dev/null 2>&1 || die "python3 wird für 'report' benötigt"
    python3 "${SCRIPT_DIR}/generate-report.py" "$@"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    die "Unbekanntes Subcommand: $SUBCMD"
    ;;
esac
  