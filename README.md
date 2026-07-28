# storage-bench.sh

Kommandozeilen-Tool für Storage-Performance-Tests unter Linux, gebaut auf [fio](https://fio.readthedocs.io/). Vier Aufgaben, vier Subcommands:

| Subcommand | Wofür |
|---|---|
| `run` | Testsuite (7 Teiltests) gegen ein Verzeichnis oder Blockgerät, Ergebnis unter einem Label gespeichert |
| `compare` | Zwei gespeicherte `run`-Labels gegenüberstellen (z.B. vorher/nachher) |
| `watch` | Ein durchgehender Messlauf, gedacht für den Moment eines Storage-Umschwenks/Failovers |
| `report` | Alles oben als HTML-Report mit Diagrammen aufbereiten |

Alles läuft lokal, nichts wird irgendwohin gesendet. Ergebnisse landen unter `results/` neben dem Skript.

## Die vier Dateien

```
storage-bench.sh              Alles außer dem HTML-Report — bash, ruft fio auf
generate-report.py            Liest results/*.json, baut den HTML-Report
report-template.html          Template für run/compare-Reports (Diagramme, Vergleichstabelle)
report-template-watch.html    Eigenes Template für watch-Reports (Latenz-Zeitreihe)
```

`generate-report.py` liest die fio-JSON-Dateien, baut daraus ein JSON-Datenobjekt und setzt es per einfachem String-Replace in eine Kopie der passenden `.html`-Vorlage ein. Kein Templating-Framework, kein Build-Schritt. Das eigentliche Rendern (Diagramme, Tabellen) passiert danach im Browser per JavaScript — die erzeugte `report.html` ist eine einzelne, in sich geschlossene Datei ohne externe Abhängigkeiten (kein CDN, keine Web-Fonts), auch offline nutzbar.

## Voraussetzungen

- `fio` — macht die eigentlichen Tests
- `jq` — wertet die fio-JSON-Ergebnisse für `run`/`compare` aus
- `python3` — nur für `report`
- `smartctl` — optional, nur für den SMART-Check bei `--device`

Keins davon wird automatisch installiert.

---

## `run` — Testsuite gegen Verzeichnis oder Gerät

```bash
./storage-bench.sh run --target /mnt/test --label baseline
./storage-bench.sh run --device /dev/nvme1n1 --label baseline --confirm-destructive
```

Führt sieben fio-Teiltests nacheinander aus, jeder als eigener fio-Prozess mit eigener JSON-Ausgabedatei unter `results/<label>/`:

| Teiltest | rw | bs | iodepth | numjobs | ioengine | Wofür |
|---|---|---|---|---|---|---|
| `seq_read` | read | 1M | 32 | 1 | `--ioengine` | Sequenzieller Durchsatz lesend |
| `seq_write` | write | 1M | 32 | 1 | `--ioengine` | Sequenzieller Durchsatz schreibend |
| `rand_read_iops` | randread | 4k | 32 | 4 | `--ioengine` | Zufällige IOPS lesend, hohe Parallelität |
| `rand_write_iops` | randwrite | 4k | 32 | 4 | `--ioengine` | Zufällige IOPS schreibend, hohe Parallelität |
| `latency_read` | randread | 4k | 1 | 1 | psync (fest) | Reine Latenz einzelner Leseanfragen |
| `latency_write` | randwrite | 4k | 1 | 1 | psync (fest) | Reine Latenz einzelner Schreibanfragen |
| `mixed_70r_30w` | randrw, 70/30 | 4k | 16 | 2 | `--ioengine` | Gemischte Last, realistischer Anwendungsfall |

Die beiden `latency_*`-Tests erzwingen `psync` unabhängig von `--ioengine`: bei Queue-Tiefe 1 gibt es nichts asynchron zu verwalten, `psync` misst die reine Anfrage-Antwort-Zeit ohne den (kleinen) Verwaltungs-Overhead einer async-Engine.

`mixed_70r_30w` ist technisch **ein** fio-Job (`--rw=randrw --rwmixread=70`), der Lese- und Schreibanteil aber getrennt zurückmeldet — im Report/Terminal erscheinen daher zwei Zeilen ("Mischlast 70/30 — Lesen" / "— Schreiben") aus derselben JSON-Datei.

Jeder Teiltest läuft `--runtime` Sekunden (Default 30) plus 5 Sekunden festen `--ramp_time` (Einschwingzeit, nicht mitgemessen, nicht konfigurierbar). Alle Tests nutzen `--direct=1` (O_DIRECT) — ohne das würden kleine, schnelle Testdateien teils nur die Geschwindigkeit des Linux-Seitencaches zeigen statt echter Storage-Performance.

Die Testdatei (`<target>/fio-testfile`, Größe `--size`, Default 4G) wird beim ersten Teiltest angelegt und danach von allen weiteren wiederverwendet — nicht bei jedem Teiltest neu erzeugt. Am Ende (oder bei Abbruch/Fehler) wird sie automatisch gelöscht.

**Optionen:**

| Flag | Default | Bedeutung |
|---|---|---|
| `--target <dir>` | – | Testverzeichnis (nicht destruktiv) |
| `--device <dev>` | – | Rohes Blockgerät — **destruktiv**, überschreibt alle Daten darauf |
| `--confirm-destructive` | aus | Pflicht, um `--device` tatsächlich zu nutzen |
| `--label <name>` | – | Pflicht, Name für diesen Lauf |
| `--size <size>` | `4G` | Testdatei-/Testbereichsgröße |
| `--runtime <sek>` | `30` | Laufzeit je Teiltest |
| `--ioengine <engine>` | `libaio` | fio-I/O-Engine (außer bei den Latenz-Tests, siehe oben) |
| `--force` | aus | Vorhandenes Label überschreiben |
| `--dry-run` | aus | Nur zeigen, was ausgeführt würde |

`--target` und `--device` schließen sich aus. Bei `--device` läuft vorab (falls `smartctl` installiert ist) ein SMART-Snapshot vor und nach dem Lauf.

**Ausgabe:** pro Teiltest `<name>.json` (fio-Rohdaten) und `<name>.log` (leer, außer bei Fehlern/Warnungen), außerdem `summary.csv` (eine Zeile je Test×Richtung) und eine Terminal-Zusammenfassung — Details zu jeder einzelnen Datei in der [Log-Referenz](#log-referenz-was-steht-in-welcher-datei) weiter unten.

---

## `compare` — zwei run-Labels gegenüberstellen

```bash
./storage-bench.sh compare baseline after-upgrade
```

Vergleicht Bandbreite (nicht Latenz) zweier zuvor per `run` erzeugter Labels, Test für Test, und markiert einen Bandbreiten-Rückgang von mehr als 10% als `REGRESSION`. Schreibt `results/compare_<label1>_vs_<label2>.csv`. Für Latenz-Vergleiche direkt in die `*.json` der Labels schauen (`clat_ns`).

---

## `watch` — Messung während eines Umschwenks

```bash
./storage-bench.sh watch --target /mnt/test --label switchover-2026-07-24 --duration 1800
```

Anders als `run`: kein Satz einzelner Teiltests, sondern **ein** durchgehender fio-Job über die komplette `--duration` (Default 1800s = 30 Min), gedacht für den Moment eines echten Storage-Failovers. Kombiniert aus:

- **fio-Job**: `randrw`, `rwmixread=70`, `bs=4k`, `iodepth=4` (niedrig gehalten, damit der Messlauf den Umschwenk nicht selbst zusätzlich belastet), `--continue_on_error=all` (kurze I/O-Fehler während des Failovers brechen den Lauf nicht ab, werden nur protokolliert).
- **Latenz-Zeitreihe**: `--write_lat_log` mit `--log_avg_msec=1000` — sekundengenaue Werte statt nur eines Gesamtdurchschnitts, sonst verschwindet ein kurzer Hänger in der Mittelung.
- **Live-Status**: periodische Fortschrittszeile auf dem Terminal (`--eta=always --eta-newline`, nötig weil stdout hier durch `tee` läuft und fio periodische Ausgaben sonst standardmäßig unterdrückt, da keine echte TTY erkannt wird).
- **Unabhängiger Heartbeat**: parallel zu fio, alle `--heartbeat-interval` Sekunden (Default 1) ein einzelner `dd`-Schreibtest mit `timeout`. Läuft als eigener Hintergrundprozess und meldet auch dann noch, wenn fio selbst im Kernel auf einen I/O-Hänger wartet und seine eigene Statusausgabe deshalb ausbleibt. Überschreitet ein Check `--heartbeat-timeout` (Default 2s), wird `STALL` in `heartbeat.log` protokolliert **und** sofort eine Zeile auf dem Terminal ausgegeben (nur beim Zustandswechsel OK↔STALL, nicht bei jedem einzelnen Check).
- **Nach Laufende**: automatische Anomalie-Timeline — alle Latenzausreißer über `--spike-threshold` (Default 100ms) und alle Heartbeat-Stalls, mit geschätzter Wanduhrzeit zum Abgleich gegen den tatsächlichen Failover-Zeitpunkt (z.B. `multipathd -ll`, `dmesg`, Storage-Array-Log — die muss man separat notieren, `watch` kennt den Auslöser selbst nicht).

**Optionen:**

| Flag | Default | Bedeutung |
|---|---|---|
| `--target <dir>` | – | Pflicht (kein `--device` bei `watch`) |
| `--label <name>` | – | Pflicht |
| `--duration <sek>` | `1800` | Gesamtdauer |
| `--status-interval <sek>` | `5` | Live-Status-Intervall |
| `--heartbeat-interval <sek>` | `1` | Abstand zwischen Puls-Checks |
| `--heartbeat-timeout <sek>` | `2` | Ab wann ein Puls als hängend gilt |
| `--spike-threshold <ms>` | `100` | Latenzschwelle für die Anomalie-Timeline |
| `--size <size>` | `4G` | Testdateigröße |
| `--ioengine <engine>` | `libaio` | fio-I/O-Engine |
| `--force` | aus | Vorhandenes Label überschreiben |
| `--dry-run` | aus | Nur zeigen, was ausgeführt würde |

**Ausgabe** unter `results/<label>/`: `watch-status.log`, `heartbeat.log`, `cpu_load.log`, `<label>_lat.1.log` (+ `_clat`/`_slat`-Varianten), `start_epoch.txt`/`start_time.txt`, `spike_threshold_ms.txt`/`heartbeat_timeout_s.txt` — was genau in jeder einzelnen Datei steht, siehe die [Log-Referenz](#log-referenz-was-steht-in-welcher-datei) weiter unten. Kein `summary.csv` — `watch` ist nicht für den `compare`-Vergleich gedacht.

---

## `report` — HTML-Report

```bash
./storage-bench.sh report                              # alle gefundenen Labels
./storage-bench.sh report baseline after-upgrade        # gezielt
./storage-bench.sh report switchover-2026-07-24         # ein watch-Label
```

Baut aus einem oder mehreren `run`-Ergebnissen (plus zugehörigen `compare`-CSVs) eine Diagramm-/Tabellen-Ansicht, oder — wenn genau ein Label übergeben wird und das ein `watch`-Ergebnis ist (erkennbar an `heartbeat.log`) — automatisch den separaten Zeitreihen-Report. Beides landet standardmäßig unter `results/report.html` (`--out <pfad>` zum Ändern).

### run/compare-Report

- **Kopfzeile**: fio-Version, Erzeugungszeitpunkt, einbezogene Labels.
- **Kennzahlen-Kacheln**: größter/kleinster Durchsatz-Unterschied über alle Tests (automatisch aus den Daten berechnet, kein fester Text), Anzahl Verzeichnisse mit den echten `--target`/`--device`-Pfaden, Aufrufparameter (`--size`/`--runtime`/`--ioengine`).
- **Farb-Legende**: ein Swatch je Label, anklickbar zum Ein-/Ausblenden in Diagrammen und Vergleichstabelle (nützlich, um einen extremen Ausreißer kurzzeitig aus der Skala zu nehmen).
- **Zwei Diagramme** (Durchsatz, Latenz): horizontale Balken, logarithmische Skala, mit Tooltip und exaktem Wert je Balken.
- **Vergleichstabelle**, falls passende `compare_*.csv`-Dateien existieren: Delta-Balken, REGRESSION/OK-Markierung.
- **Testparameter** (aufklappbar): tatsächlich verwendete fio-Optionen je Testart, mit Abweichungsliste, falls ein Label mal andere Werte hatte.
- **Rohdaten-Tabelle** (aufklappbar): alle Werte tabellarisch.
- **Zwei Glossare** (aufklappbar): Kennzahlen-Erklärungen und Testarten-Erklärungen, jeweils nur für tatsächlich vorkommende Einträge.
- Folgt automatisch dem Farbschema des Browsers, per Schalter in der Kopfzeile auch manuell umschaltbar.

### watch-Report

Komplett eigenes, kleineres Template (`report-template-watch.html`), weil die Datenform grundsätzlich anders ist — eine Zeitreihe statt Kategorien:

- **Kennzahlen-Kacheln**: höchste gemessene Latenz, Anzahl Latenz-Spikes über der Schwelle, **I/O-Fehler** (aus fios `errors: total=N` in `watch-status.log` geparst — relevant, weil `--continue_on_error=all` echte Fehler während des Failovers nicht abbricht, sondern nur zählt), Anzahl und Gesamtdauer der Heartbeat-Stalls, höchste CPU-Last des Testrechners.
- **Latenzverlauf-Diagramm**: Lesen/Schreiben als Linien über die Zeit, logarithmische y-Achse (fester Boden 0.01ms, Deckel bei der nächsten Zehnerpotenz über Maximalwert/Spike-Schwelle — verhindert, dass ein einzelner extremer Ausreißer die normale Baseline unlesbar staucht). X-Achse zeigt **Wanduhrzeit** (nicht Sekunden seit Start), direkt gegen externe Logs wie `multipathd -ll`/`dmesg` abgleichbar. Heartbeat-Stalls als rot schattierte Zeitbereiche, Spike-Schwelle als gestrichelte Referenzlinie.
- **CPU-Last-Diagramm**: eigenes Panel unter dem Latenzverlauf, aus `cpu_load.log`, lineare y-Achse (anders als die Latenz-Skala), dieselbe Zeitachse — zum Abgleich, ob ein Latenz-Spike eher am Testrechner selbst lag statt am Storage. Blendet sich komplett aus, wenn `cpu_load.log` fehlt (ältere Ergebnisse vor Einführung dieses Felds).
- **Ereignis-Tabelle** (aufklappbar): jeder einzelne Latenz-Spike und Heartbeat-Stall mit Uhrzeit — dieselbe Anomalie-Timeline wie im Terminal (`analyze_watch()`), zusätzlich im Report statt nur als Zähler auf den Kacheln.

Ein watch- und ein run-Label lassen sich nicht in einem Aufruf mischen — die Datenformen passen nicht zusammen.

---

## Sicherheitsmodell

- Standardmäßig wird nur eine Testdatei in `--target` beschrieben, nie ein rohes Blockgerät.
- `--device` nur bei `run`, nur mit explizitem `--confirm-destructive`. `watch` unterstützt `--device` gar nicht.
- `--label` wird validiert (kein `/`, nicht `.`/`..`) — landet sonst unverändert im Ergebnispfad `results/<label>/`, der bei `--force` mit `rm -rf` geleert wird. Ohne die Prüfung könnte `--label ../../etc` diesen Pfad nach außerhalb von `results/` verlegen.
- Vor jedem Lauf: Zielverzeichnis muss existieren und beschreibbar sein (`-w`-Check — sonst scheitert erst fio selbst mitten im Lauf mit einer kryptischen Permission-Fehlermeldung, typisch bei NFS mit `root_squash`), plus ein Check, ob genug freier Platz für `--size` da ist (sonst bricht fio mit dem kryptischen `err=28 ... No space left on device` ab, ohne zu sagen wie viel gefehlt hat).
- Ein existierendes Label wird nie stillschweigend überschrieben, nur mit `--force`.
- `--dry-run` führt nichts aus, legt nichts an, zeigt nur die geplanten fio-Kommandos.
- Alle CLI-Optionen mit Wert (`--size`, `--label`, …) brechen mit klarer Meldung ab, wenn der Wert fehlt, statt mit einem rohen `unbound variable`.
- Der Report escaped alles, was aus `--label`/`--target` stammt, bevor es als HTML eingesetzt wird (`html.escape()` in Python, `esc()` im Template-JS) — sonst könnte ein böswilliger Labelname mit HTML/JS-Inhalt den Report manipulieren.

---

## Wie die Kennzahlen berechnet werden

Terminal-Ausgabe, `summary.csv` und `report.html` lesen alle aus derselben Quelle — den vier fio-Rohwerten in `<test>.json` unter `.jobs[0].read`/`.write` — und wenden dieselben Formeln an, nur mit unterschiedlicher Rundung:

| fio-Rohwert | Einheit | Umrechnung | Ergebnis |
|---|---|---|---|
| `.bw` | KiB/s | `/ 1024` | MB/s (eigentlich MiB/s, aus Lesbarkeit "MB/s" genannt) |
| `.iops` | IOPS | – | IOPS |
| `.clat_ns.mean` | ns | `/ 1000000` | Ø-Latenz in ms |
| `.clat_ns.percentile["99.000000"]` | ns | `/ 1000000` | p99-Latenz in ms |

- **Terminal**: ganzzahlig (BW, IOPS) bzw. 2 Nachkommastellen (Latenz).
- **`summary.csv`**: dieselben Formeln, aber ungerundet — bewusst andere Rundung, damit die CSV für eigene Weiterverarbeitung nicht durch Rundungsfehler verfälscht wird.
- **`report.html`**: zweistufig gerundet (`generate-report.py` beim Bau der Daten, das Template nochmal beim Anzeigen).

`compare`s Delta (nur Bandbreite): `((bw_nachher − bw_vorher) / bw_vorher) × 100`, mit voller Genauigkeit auf den rohen KiB/s-Werten berechnet, erst am Ende auf 1 Nachkommastelle gerundet. Unter −10% = REGRESSION.

---

## Ergebnisverzeichnis im Überblick

```
results/
├── <label>/                              (von run)
│   ├── seq_read.json / .log
│   ├── seq_write.json / .log
│   ├── rand_read_iops.json / .log
│   ├── rand_write_iops.json / .log
│   ├── latency_read.json / .log
│   ├── latency_write.json / .log
│   ├── mixed_70r_30w.json / .log
│   ├── summary.csv
│   └── smart-before.txt / smart-after.txt   (nur bei --device)
│
├── <label>/                              (von watch, statt obigem)
│   ├── watch-status.log
│   ├── heartbeat.log / cpu_load.log
│   ├── <label>_lat.1.log / _clat.1.log / _slat.1.log
│   ├── start_epoch.txt / start_time.txt
│   └── spike_threshold_ms.txt / heartbeat_timeout_s.txt
│
├── compare_<a>_vs_<b>.csv                (von compare)
└── report.html                           (von report)
```

`results/` ist nicht Teil des Git-Repos (`.gitignore`) — es sind lokale Messergebnisse, keine Projektdateien.

### Log-Referenz: was steht in welcher Datei

**Von `run`, pro Teiltest (`<test>` = `seq_read`, `seq_write`, ...):**

| Datei | Format | Inhalt |
|---|---|---|
| `<test>.json` | fio-JSON (`--output-format=json`) | Der vollständige fio-Report für diesen Teiltest — bw/iops/Latenz-Perzentile/job-options/... Die eigentliche Datenquelle für Terminal-Zusammenfassung, `summary.csv` und `report.html`. |
| `<test>.log` | Klartext | fios **stderr** — leer im Erfolgsfall, gefüllt mit Warnungen/Fehlermeldungen, falls beim Teiltest etwas schiefging (z.B. ungültige `--ioengine`, I/O-Fehler). `--output` auf dem fio-Aufruf leitet die eigentliche (reguläre) Ausgabe komplett in die `.json`-Datei um — stdout ist bei `--output-format=json` deshalb grundsätzlich leer, stderr bleibt davon unberührt und ist die einzig sinnvolle Quelle für diese Datei. |
| `summary.csv` | CSV | Eine Zeile je Test×Richtung (`label,test,direction,bw_MBps,iops,avg_lat_ms,p99_lat_ms`), erst **nach** allen Teiltests aus den `.json`-Dateien zusammengestellt. |
| `smart-before.txt` / `smart-after.txt` | Klartext | Nur bei `--device` + installiertem `smartctl`: roher `smartctl -a`-Output vor bzw. nach der gesamten Suite. |

**Von `watch`:**

| Datei | Format | Inhalt |
|---|---|---|
| `watch-status.log` | Klartext | Kompletter `tee`-Mitschnitt von fios stdout: periodische Live-Ticks (`--eta-newline`) plus die menschenlesbare Endstatistik am Schluss. Kein JSON — anders als `run` nutzt `watch` bewusst kein `--output-format=json`, weil sonst (wie beim `<test>.log`-Fix oben) stdout leer wäre und der Live-Status verschwände. Quelle für die I/O-Fehleranzahl im watch-Report (`errors: total=N` darin). |
| `heartbeat.log` | `<epoch> OK\|STALL` | Eine Zeile je Puls-Check (alle `--heartbeat-interval` Sekunden), unabhängig von fio geschrieben. Basis der "Stalls im Heartbeat"-Auswertung (Terminal und Report). |
| `cpu_load.log` | `<epoch> <load1>` | Eine Zeile je Puls-Check, 1-Minuten-Load-Average aus `/proc/loadavg`, vom selben Hintergrundprozess wie `heartbeat.log` mitgeschrieben. Bewusst nur in die Datei, keine Terminal-Ausgabe — ein Versuch, das live auszugeben, kollidierte mit fios eigener Tick-Zeile (zwei unsynchronisierte Prozesse auf demselben Terminal, teils mitten in einer Carriage-Return-Zeile). Wird vom watch-Report als eigenes Chart-Panel dargestellt (siehe unten); im Terminal selbst nicht ausgewertet. |
| `<label>_lat.1.log` | `zeit_ms, latenz_ns, richtung, blockgröße, offset` | Von `--write_lat_log`/`--log_avg_msec=1000`: eine gemittelte Zeile pro Sekunde und Richtung (0=read/1=write/2=trim). **Die** Datei für die Latenz-Zeitreihe — liest sowohl `analyze_watch()` im Terminal als auch der watch-Report daraus. |
| `<label>_clat.1.log` / `_slat.1.log` | wie oben | Von fio automatisch mit `--write_lat_log` mitgeschrieben (Completion- bzw. Submission-Latenz statt Gesamtlatenz), aber von `storage-bench.sh` nirgends ausgewertet. |
| `start_epoch.txt` | eine Zahl | Unix-Timestamp (`date +%s`) bei Laufstart — Referenzpunkt, um Sekunden-seit-Start in Wanduhrzeit umzurechnen (Terminal-Anomalie-Timeline, watch-Report-Chart). |
| `start_time.txt` | eine Zeile | Menschenlesbarer `date`-Output bei Laufstart, nur zur Anzeige. |
| `spike_threshold_ms.txt` | eine Zahl | Der bei diesem Lauf tatsächlich verwendete `--spike-threshold`-Wert — nur als Shell-Variable im laufenden Prozess bekannt und für einen späteren, separaten `report`-Aufruf sonst verloren. |
| `heartbeat_timeout_s.txt` | eine Zahl | Dasselbe für `--heartbeat-timeout` (beschriftet die "Stalls"-Schwelle in der Ereignis-Tabelle des watch-Reports). |

**Von `compare`:** `compare_<a>_vs_<b>.csv` — `test,direction,bw_before_MBps,bw_after_MBps,delta_pct,regression`, eine Zeile je Test×Richtung, die in beiden verglichenen Labels existiert.

**Von `report`:** nur `report.html` (oder der Pfad aus `--out`) — liest ausschließlich bereits vorhandene Dateien, schreibt selbst nichts unter `results/<label>/`.

---

## Bekannte Grenzen

- `--direct=1` (O_DIRECT) schlägt auf `tmpfs`/`/dev/shm` nicht zuverlässig fehl (kernelabhängig) — kann dort unbemerkt RAM- statt Storage-Geschwindigkeit liefern. Nie gegen tmpfs testen, vorher mit `mount`/`df -T` prüfen.
- In Docker/Kubernetes ist die beschreibbare Container-Layer (overlay2) je nach Kernel unzuverlässig für O_DIRECT — gegen einen Bind-Mount oder ein echtes Volume testen.
- Sehr alte fio-Versionen (2.x) könnten den p99-Latenz-Key anders benennen als erwartet (`"99.000000"`) — p99 zeigt dann still `0` statt zu crashen. `fio --version` vorher prüfen.
- Root-Rechte nur für `run --device` nötig, nicht für den normalen Datei-Modus.
- Es ist ein echter Lastgenerator — auf geteilter/produktiver Infrastruktur `--size`/`--runtime` reduzieren, um andere Workloads nicht zu stören.
- Maximal 8 Labels gleichzeitig im run/compare-Report (Länge der Farbpalette).
- watch- und run-Labels lassen sich nicht in einem `report`-Aufruf mischen.

---

## Report erweitern (für Anpassungen am Code)

- Platzhalter im run/compare-Template: `__REPORT_TITLE__`, `/*__SERIES_CSS_LIGHT__*/`, `/*__SERIES_CSS_DARK__*/`, `/*__REPORT_DATA__*/`. Im watch-Template: `__REPORT_TITLE__`, `/*__WATCH_DATA__*/`. Beides simples String-Replace, kein Templating-Framework.
- `window.__REPORT_DATA__` (bzw. `DATA` im watch-Template) ist der einzige Datenkanal vom Python-Skript ins Frontend — alles JS-seitige Rendern liest ausschließlich daraus.
- Neue Testarten in `storage-bench.sh` brauchen einen Eintrag in `NAME_MAP` und `TEST_GLOSSARY` in `generate-report.py`, sonst erscheinen sie im Report nur mit ihrem internen Key.
- `PALETTE` in `generate-report.py`: acht farbenblind-sicher geprüfte Farbpaare, Reihenfolge nicht ohne erneute Prüfung ändern.
- Alles, was aus `--label`/`--target` stammt, muss beim Rendern escaped werden (`html.escape()` in Python, `esc()` im Template-JS) — siehe Sicherheitsmodell oben.
