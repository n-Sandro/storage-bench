#!/usr/bin/env python3
"""Erzeugt einen HTML-Report aus storage-bench.sh-Ergebnissen (run + compare).

Arbeitsweise: liest die fio-JSON-Dateien direkt aus results/<label>/*.json (nicht
die CSVs — die JSONs haben mehr Nachkommastellen und den fio-Versionsstring), baut
daraus ein JSON-Datenobjekt und ersetzt damit Platzhalter in report-template.html
per einfachem String-Replace (bewusst kein Templating-Framework/Dependency).
Das ganze Rendern (Diagramme, Legende, Glossar, Tabellen) passiert danach im
Browser via JS, dieses Skript liefert nur die Daten.
"""
import sys
import os
import json
import glob
import datetime
import html
from collections import Counter

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RESULTS_ROOT = os.path.join(SCRIPT_DIR, "results")
TEMPLATE_PATH = os.path.join(SCRIPT_DIR, "report-template.html")

# Validierte kategoriale Palette (farbenblind-sicher geprüft, siehe dataviz-Skill).
# Reihenfolge ist Teil der Prüfung — nicht umsortieren, ohne die Validierung
# erneut laufen zu lassen. Label->Slot-Zuordnung erfolgt unten simpel nach
# Reihenfolge der Kommandozeilen-Argumente, daher max. 8 Labels pro Report.
PALETTE = [
    ("#2a78d6", "#3987e5"),  # blue
    ("#eb6834", "#d95926"),  # orange
    ("#1baf7a", "#199e70"),  # aqua
    ("#eda100", "#c98500"),  # yellow
    ("#e87ba4", "#d55181"),  # magenta
    ("#008300", "#008300"),  # green
    ("#4a3aa7", "#9085e9"),  # violet
    ("#e34948", "#e66767"),  # red
]

# Klartext-Namen für die Test-Keys aus storage-bench.sh. Neue Tests im Hauptskript
# brauchen hier (und in TEST_GLOSSARY unten) einen Eintrag, sonst taucht im Report
# nur der interne Key auf statt einer lesbaren Bezeichnung.
NAME_MAP = {
    "seq_read": "Sequenziell Lesen",
    "seq_write": "Sequenziell Schreiben",
    "rand_read_iops": "Random Lesen (QD32)",
    "rand_write_iops": "Random Schreiben (QD32)",
    "latency_read": "Latenz Lesen (QD1)",
    "latency_write": "Latenz Schreiben (QD1)",
}

METRIC_GLOSSARY = [
    ("BW (MB/s)", "Durchsatz — Megabyte pro Sekunde, die gelesen bzw. geschrieben wurden."),
    ("IOPS", "Input/Output Operations per Second — Anzahl einzelner I/O-Vorgänge pro Sekunde. "
             "Bei kleinen Blockgrößen (4K) oft aussagekräftiger als reine Bandbreite."),
    ("Ø Lat. (ms)", "Durchschnittliche Zeit von Anfrage bis Antwort (Completion Latency) pro I/O-Vorgang."),
    ("p99 Lat. (ms)", "99. Perzentil der Latenz — 99% aller Anfragen waren schneller als dieser Wert. "
                       "Zeigt Ausreißer, die ein reiner Durchschnitt verschleiert."),
    ("QD (Queue Depth)", "Anzahl gleichzeitig ausstehender I/O-Anfragen. QD=1 = seriell, eine nach der "
                          "anderen. QD=32 = 32 parallele Anfragen — realistischer für moderne SSDs/NVMe "
                          "und Multi-User-Workloads."),
    ("direct=1 (O_DIRECT)", "Alle Tests umgehen den Linux-Seiten-Cache und greifen direkt auf das Gerät "
                             "zu — sonst würden die Werte teils nur RAM-Geschwindigkeit statt echter "
                             "Storage-Performance zeigen."),
    ("ioengine (sync/async)", "Wie fio Anfragen an den Kernel stellt. Synchron (psync): blockierender "
                               "read()/write()-Aufruf, wartet auf die Antwort, bevor die nächste Anfrage "
                               "rausgeht — eine nach der anderen, auch über mehrere Prozesse (numjobs) "
                               "hinweg jeweils für sich. Asynchron (libaio): Anfrage wird abgeschickt, "
                               "ohne auf die Antwort zu warten — mehrere können so aus einem einzigen "
                               "Prozess gleichzeitig offen sein (iodepth), ohne dafür mehrere Prozesse zu "
                               "brauchen. Die Latenz-Tests nutzen bewusst psync statt libaio: auch eine "
                               "asynchrone Engine hat bei iodepth=1 noch eigenen Verwaltungs-Overhead "
                               "(Einreihen, später aus der Completion-Queue abholen) — psync misst ohne "
                               "diesen Umweg."),
]

TEST_GLOSSARY = {
    "seq_read": "Große 1M-Blöcke werden der Reihe nach gelesen, mit 32 gleichzeitig ausstehenden "
                "Anfragen über eine asynchrone Engine (libaio) — fio hält das Storage konstant "
                "beschäftigt, statt auf jede einzelne Antwort zu warten. Misst die maximale "
                "Durchsatzgrenze bei großen, zusammenhängenden Zugriffen — relevant z.B. für Backups "
                "oder große Dateiübertragungen, wo die Anfragegröße zählt, nicht die Anzahl der Zugriffe.",
    "seq_write": "Große 1M-Blöcke werden der Reihe nach geschrieben, mit 32 gleichzeitig ausstehenden "
                 "Anfragen über eine asynchrone Engine (libaio) — fio hält das Storage konstant "
                 "beschäftigt, statt auf jede einzelne Antwort zu warten. Misst die maximale "
                 "Durchsatzgrenze bei großen, zusammenhängenden Schreibzugriffen — relevant z.B. für "
                 "Backups oder große Dateiübertragungen, wo die Anfragegröße zählt, nicht die Anzahl "
                 "der Zugriffe.",
    "rand_read_iops": "Kleine 4K-Blöcke werden an zufälligen Positionen gelesen, mit hoher Parallelität: "
                       "32 Anfragen gleichzeitig über 4 parallele Prozesse (numjobs=4), macht 128 "
                       "gleichzeitig ausstehende Anfragen insgesamt. Misst, wie viele einzelne "
                       "Leseoperationen pro Sekunde möglich sind, wenn viele Anfragen gleichzeitig "
                       "unterwegs sein dürfen — relevant für Datenbanken oder viele gleichzeitige "
                       "Nutzer, nicht für die Größe der einzelnen Anfrage.",
    "rand_write_iops": "Kleine 4K-Blöcke werden an zufälligen Positionen geschrieben, mit hoher "
                        "Parallelität: 32 Anfragen gleichzeitig über 4 parallele Prozesse (numjobs=4), "
                        "macht 128 gleichzeitig ausstehende Anfragen insgesamt. Misst, wie viele "
                        "einzelne Schreiboperationen pro Sekunde möglich sind, wenn viele Anfragen "
                        "gleichzeitig unterwegs sein dürfen — relevant für Datenbanken oder viele "
                        "gleichzeitige Nutzer, nicht für die Größe der einzelnen Anfrage.",
    "latency_read": "Kleine 4K-Blöcke werden einzeln gelesen, mit iodepth=1 und synchroner Engine "
                     "(psync) statt einer asynchronen — nie mehr als eine Anfrage gleichzeitig "
                     "unterwegs, nichts wird gepuffert oder überlappt. Gemessen wird die reine "
                     "Tür-zu-Tür-Zeit einer einzelnen Anfrage in ms; die MB/s im Durchsatz-Diagramm "
                     "sind hier ein Nebenprodukt, kein aussagekräftiger Wert. Wichtig für Workloads, "
                     "die nicht parallelisieren können.",
    "latency_write": "Kleine 4K-Blöcke werden einzeln geschrieben, mit iodepth=1 und synchroner Engine "
                      "(psync) statt einer asynchronen — nie mehr als eine Anfrage gleichzeitig "
                      "unterwegs, nichts wird gepuffert oder überlappt. Gemessen wird die reine "
                      "Tür-zu-Tür-Zeit einer einzelnen Schreibanfrage in ms; die MB/s im "
                      "Durchsatz-Diagramm sind hier ein Nebenprodukt, kein aussagekräftiger Wert. "
                      "Wichtig für Workloads, die nicht parallelisieren können.",
    "mixed_70r_30w": "70% Lese-, 30% Schreibanfragen gleichzeitig, mit iodepth=16 über 2 parallele "
                      "Prozesse (32 gleichzeitig ausstehende Anfragen insgesamt) — simuliert einen "
                      "realistischeren Anwendungsfall als reine Lese- oder Schreibtests, z.B. eine "
                      "Datenbank, die gleichzeitig liest und schreibt.",
}


def die(msg):
    print(f"FEHLER: {msg}", file=sys.stderr)
    sys.exit(1)


def label_for(test_key, rw):
    """Klartext-Bezeichnung für Diagramm/Tabelle. mixed_70r_30w ist der einzige Test
    mit read UND write in derselben JSON-Datei, daher der Sonderfall — alle anderen
    Tests sind schon anhand ihres Keys eindeutig einer Richtung zugeordnet."""
    if test_key == "mixed_70r_30w":
        return "Mischlast 70/30 — " + ("Lesen" if rw == "read" else "Schreiben")
    return NAME_MAP.get(test_key, test_key)


# Job-Options-Felder aus dem fio-JSON, die im Report als "Testparameter" gezeigt
# werden — das sind exakt die Optionen, mit denen fio tatsächlich lief (keine
# Ableitung/Vermutung aus storage-bench.sh nötig, das JSON ist die Ground Truth).
PARAM_FIELDS = ["rw", "bs", "iodepth", "numjobs", "ioengine", "size", "direct", "runtime", "ramp_time"]


def load_label(label):
    """Liest alle *.json eines results/<label>/-Ordners ein und extrahiert
    bw/iops/Latenz je Test und Richtung. fio schreibt für nicht getestete Richtungen
    ein leeres {"io_bytes": 0, ...}-Objekt statt den Key wegzulassen — deshalb der
    io_bytes-Check, um z.B. bei seq_read die leere "write"-Hälfte zu überspringen.
    Rückgabe: (tests-dict {testname: {"read"/"write": {bw, iops, lat, p99}}},
    fio-Versionsstring, params-dict {testname: {rw, bs, iodepth, ...}} aus den
    "job options" des jeweiligen Jobs, target_path — der ursprüngliche --target/
    --device-Wert, aus dem "filename" des ersten gelesenen Jobs zurückgerechnet)."""
    outdir = os.path.join(RESULTS_ROOT, label)
    if not os.path.isdir(outdir):
        die(f"Kein Ergebnis für Label '{label}' gefunden ({outdir})")
    tests = {}
    params = {}
    fio_version = None
    target_path = None
    for jf in sorted(glob.glob(os.path.join(outdir, "*.json"))):
        name = os.path.splitext(os.path.basename(jf))[0]
        with open(jf) as f:
            try:
                data = json.load(f)
            except json.JSONDecodeError:
                # Kann z.B. nach einem per Ctrl-C abgebrochenen 'run' vorkommen,
                # wenn fio mitten im Schreiben der JSON-Ausgabe unterbrochen wurde
                # (die Datei existiert dann, ist aber kein valides JSON). Einzelne
                # kaputte Datei überspringen statt den ganzen Report mit einem
                # Python-Traceback abzubrechen — der Rest des Labels ist ja intakt.
                print(f"WARNUNG: {jf} ist kein gültiges JSON (übersprungen, "
                      f"vermutlich ein abgebrochener Lauf)", file=sys.stderr)
                continue
        if fio_version is None:
            fio_version = data.get("fio version")
        job = data["jobs"][0]
        entry = {}
        for rw in ("read", "write"):
            j = job.get(rw, {})
            if j.get("io_bytes", 0):
                clat = j.get("clat_ns", {})
                entry[rw] = {
                    "bw": j["bw"] / 1024,
                    "iops": j["iops"],
                    "lat": clat.get("mean", 0) / 1e6,
                    "p99": clat.get("percentile", {}).get("99.000000", 0) / 1e6,
                }
        if entry:
            tests[name] = entry
            job_opts = job.get("job options", {})
            params[name] = {field: job_opts.get(field, "–") for field in PARAM_FIELDS}
            if target_path is None:
                filename = job_opts.get("filename")
                if filename:
                    # Datei-Modus hängt in storage-bench.sh immer "/fio-testfile" an
                    # den --target-Wert an — das wieder abschneiden ergibt exakt den
                    # ursprünglichen --target. Bei --device ist filename bereits der
                    # Geräte-Pfad selbst (kein Suffix zum Abschneiden).
                    suffix = "/fio-testfile"
                    target_path = filename[:-len(suffix)] if filename.endswith(suffix) else filename
    return tests, fio_version, params, target_path or "?"


# ---- watch-Report: eigener, komplett getrennter Pfad -----------------------
# 'watch'-Ergebnisse sind eine Zeitreihe (Latenz über Zeit + Stall-Intervalle),
# strukturell etwas anderes als die Kategorien-Daten von run/compare oben —
# daher eigenes Template, eigenes JSON-Schema, eigene Baufunktion. Berührt
# nichts von dem, was oben für run/compare gebaut wird.

WATCH_TEMPLATE_PATH = os.path.join(SCRIPT_DIR, "report-template-watch.html")


def is_watch_label(label):
    """Ein watch-Lauf erzeugt heartbeat.log, ein run-Lauf nie — reicht als
    eindeutiges Unterscheidungsmerkmal (beide Subcommands leeren ihren
    Ergebnisordner vor dem Schreiben komplett, es kann also nie eine Mischung
    aus beidem im selben Label-Ordner geben)."""
    return os.path.exists(os.path.join(RESULTS_ROOT, label, "heartbeat.log"))


def parse_latency_series(path):
    """Liest <label>_lat.1.log (Format von fios --write_lat_log: 'zeit_ms,
    latenz_ns, richtung, blockgröße, offset' je Zeile, richtung 0=read/1=write/
    2=trim) und baut zwei nach Zeit sortierte [sekunde, latenz_ms]-Listen."""
    series = {"read": [], "write": []}
    if not os.path.exists(path):
        return series
    with open(path) as f:
        for line in f:
            parts = [p.strip() for p in line.strip().split(",")]
            if len(parts) < 3:
                continue
            try:
                t_ms, lat_ns = float(parts[0]), float(parts[1])
            except ValueError:
                continue
            key = {"0": "read", "1": "write"}.get(parts[2])
            if key:
                series[key].append([round(t_ms / 1000, 3), round(lat_ns / 1e6, 4)])
    return series


def parse_heartbeat_stalls(path):
    """Liest heartbeat.log ('<epoch> OK'/'<epoch> STALL' je Zeile) und fasst
    aufeinanderfolgende STALL-Zeilen zu Intervallen [start_epoch, end_epoch]
    zusammen — fürs Chart interessieren Zeiträume, nicht einzelne Pulse."""
    stalls = []
    cur_start = None
    last_epoch = None
    if not os.path.exists(path):
        return stalls
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) != 2:
                continue
            try:
                epoch = int(parts[0])
            except ValueError:
                continue
            if parts[1] == "STALL":
                if cur_start is None:
                    cur_start = epoch
                last_epoch = epoch
            elif cur_start is not None:
                stalls.append([cur_start, last_epoch])
                cur_start = None
    if cur_start is not None:
        stalls.append([cur_start, last_epoch])
    return stalls


def build_watch_report(label, out_path):
    """Baut den Zeitreihen-Report für ein einzelnes watch-Label. Analog zum
    run/compare-Pfad in main(): Daten einlesen -> JSON bauen -> Platzhalter im
    (eigenen) Template ersetzen -> Datei schreiben."""
    outdir = os.path.join(RESULTS_ROOT, label)

    def read_file(name, default=""):
        p = os.path.join(outdir, name)
        return open(p).read().strip() if os.path.exists(p) else default

    start_epoch_raw = read_file("start_epoch.txt")
    if not start_epoch_raw:
        die(f"'{label}' hat kein start_epoch.txt — unvollständiger watch-Lauf?")
    start_epoch = int(start_epoch_raw)
    spike_threshold_ms = int(read_file("spike_threshold_ms.txt", "100"))

    lat_files = glob.glob(os.path.join(outdir, f"{label}_lat.1.log"))
    latency = parse_latency_series(lat_files[0]) if lat_files else {"read": [], "write": []}
    stalls_epoch = parse_heartbeat_stalls(os.path.join(outdir, "heartbeat.log"))
    # Stalls relativ zum Laufstart wie die Latenz-Zeitreihe (Sekunden seit
    # start_epoch), damit beides im selben Koordinatensystem im Chart landet.
    stalls = [[s - start_epoch, e - start_epoch] for s, e in stalls_epoch]

    all_points = latency["read"] + latency["write"]
    max_lat_ms = max((p[1] for p in all_points), default=0)
    duration = max((p[0] for p in all_points), default=0)
    if stalls:
        duration = max(duration, stalls[-1][1])

    watch_data = {
        "label": label,
        "startTime": read_file("start_time.txt", "unbekannt"),
        "generated": datetime.datetime.now().strftime("%Y-%m-%d %H:%M"),
        "duration": duration,
        "spikeThresholdMs": spike_threshold_ms,
        "latency": latency,
        "stalls": stalls,
        "maxLatencyMs": round(max_lat_ms, 3),
        "spikeCount": sum(1 for p in all_points if p[1] > spike_threshold_ms),
    }

    if not os.path.exists(WATCH_TEMPLATE_PATH):
        die(f"Watch-Report-Template fehlt: {WATCH_TEMPLATE_PATH}")
    with open(WATCH_TEMPLATE_PATH) as f:
        template = f.read()

    json_str = json.dumps(watch_data, ensure_ascii=False).replace("</", "<\\/")
    # Gleiches XSS-Escaping wie im run/compare-Pfad unten: --label fließt roh
    # in den <title> ein, bevor überhaupt JS aus dem Report läuft.
    title = html.escape(f"Storage-Watch: {label}")
    html_out = template.replace("__REPORT_TITLE__", title)
    html_out = html_out.replace("/*__WATCH_DATA__*/", json_str)

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w") as f:
        f.write(html_out)

    print(f"Watch-Report geschrieben: {out_path}")
    print(f"Label: {label} — {watch_data['spikeCount']} Latenz-Spike(s), "
          f"{len(stalls)} Stall(s) erkannt")


def main():
    """Einstiegspunkt: Argumente parsen -> pro Label load_label() aufrufen ->
    Daten zu einem gemeinsamen JSON-Objekt zusammenführen (Tests, Rohdaten,
    Vergleiche, Auto-Kennzahlen, Glossar) -> Platzhalter im Template ersetzen ->
    fertige HTML-Datei schreiben. Reihenfolge unten spiegelt genau diese Schritte."""
    args = sys.argv[1:]
    out_path = os.path.join(RESULTS_ROOT, "report.html")
    if "--out" in args:
        i = args.index("--out")
        if i + 1 >= len(args):
            die("Option --out benötigt einen Wert")
        out_path = os.path.abspath(args[i + 1])
        del args[i:i + 2]

    labels = args
    if not labels and os.path.isdir(RESULTS_ROOT):
        labels = sorted(
            d for d in os.listdir(RESULTS_ROOT)
            if os.path.isdir(os.path.join(RESULTS_ROOT, d))
            and glob.glob(os.path.join(RESULTS_ROOT, d, "*.json"))
        )

    # Ein einzelnes watch-Label -> eigener Zeitreihen-Report statt run/compare
    # (siehe build_watch_report oben). Mehrere Labels gemischt mit einem
    # watch-Label werden bewusst nicht unterstützt (fällt unten in load_label()
    # einfach mit einem leeren Ergebnis für dieses Label durch) — kein
    # sinnvoller Anwendungsfall, Zeitreihe und Kategorien-Vergleich lassen sich
    # nicht in einem Report vereinen.
    if len(labels) == 1 and is_watch_label(labels[0]):
        build_watch_report(labels[0], out_path)
        return

    if not labels:
        die("Keine Labels gefunden. Erst 'storage-bench.sh run --label <name>' ausführen "
            "oder Label(s) als Argument angeben.")
    if len(labels) > len(PALETTE):
        die(f"Maximal {len(PALETTE)} Labels gleichzeitig unterstützt (Farbpalette), "
            f"{len(labels)} angegeben.")

    all_tests = {}
    all_params = {}
    all_target_paths = {}
    fio_version = None
    for label in labels:
        tests, fv, params, target_path = load_label(label)
        all_tests[label] = tests
        all_params[label] = params
        all_target_paths[label] = target_path
        fio_version = fio_version or fv

    test_order = []
    for label in labels:
        for t in all_tests[label]:
            if t not in test_order:
                test_order.append(t)

    tests_json = []
    raw = []
    for t in test_order:
        for rw in ("read", "write"):
            if not any(rw in all_tests[l].get(t, {}) for l in labels):
                continue
            values = {}
            for l in labels:
                v = all_tests[l].get(t, {}).get(rw)
                if v:
                    values[l] = {
                        "bw": round(v["bw"], 2),
                        "iops": round(v["iops"], 1),
                        "lat": round(v["lat"], 3),
                        "p99": round(v["p99"], 3),
                    }
                    raw.append([l, label_for(t, rw), rw, values[l]["bw"],
                                values[l]["iops"], values[l]["lat"], values[l]["p99"]])
            tests_json.append({"key": t, "dir": rw, "label": label_for(t, rw), "values": values})

    # Testparameter: einmal pro Testart die gemeinsamen (häufigsten) Werte über alle
    # Labels, plus separat eine kurze Abweichungsliste — keine volle Label×Test-
    # Matrix. Grund: die Parameter sind zwischen Labels praktisch immer identisch
    # (Standard-Testsuite), die volle Matrix wäre nur Wiederholung. Interessant ist
    # allein der seltene Fall, dass ein Label abweicht (z.B. anderes --ioengine oder
    # --size) — genau das würde einen Vorher/Nachher-Vergleich verfälschen.
    params_common = []
    params_deviations = []
    for t in test_order:
        label_params = {l: all_params[l][t] for l in labels if t in all_params[l]}
        if not label_params:
            continue
        test_label = "Mischlast 70/30" if t == "mixed_70r_30w" else NAME_MAP.get(t, t)
        common = {}
        for field in PARAM_FIELDS:
            values = [p[field] for p in label_params.values()]
            common[field] = Counter(values).most_common(1)[0][0]
        params_common.append({"test": test_label, "values": common})
        for l, p in label_params.items():
            for field in PARAM_FIELDS:
                if p[field] != common[field]:
                    params_deviations.append([l, test_label, field, p[field], common[field]])

    # Vorhandene compare_*.csv zwischen den angegebenen Labels einlesen. compare
    # schreibt die CSV nur in der Richtung, in der sie aufgerufen wurde
    # (compare A B -> compare_A_vs_B.csv, nicht auch B_vs_A) — deshalb hier beide
    # Reihenfolgen probieren, statt eine bestimmte Aufrufreihenfolge zu verlangen.
    compares = {}
    for i, a in enumerate(labels):
        for b in labels[i + 1:]:
            for (x, y) in ((a, b), (b, a)):
                csv_path = os.path.join(RESULTS_ROOT, f"compare_{x}_vs_{y}.csv")
                if os.path.exists(csv_path):
                    rows = []
                    with open(csv_path) as f:
                        next(f)
                        for line in f:
                            parts = line.strip().split(",")
                            if len(parts) != 6:
                                continue
                            test, direction, before, after, delta, reg = parts
                            rows.append([test, direction, float(before), float(after),
                                         float(delta), reg == "ja"])
                    if rows:
                        compares[f"{x} → {y}"] = rows

    locations = [{"key": l, "label": l, "color": f"var(--series-{i + 1})"}
                 for i, l in enumerate(labels)]

    # Auto-generierte Kennzahlen statt Hand-Text: die "größter/kleinster
    # Unterschied"-Kacheln werden aus den tatsächlichen Werten berechnet, damit sie
    # bei jeder beliebigen Label-Kombination stimmen (2 Labels oder 8, egal welche
    # Testarten vorhanden sind) — kein Report-Text, der bei anderen Daten falsch wird.
    spreads = []
    for t in tests_json:
        vals = [v["bw"] for v in t["values"].values() if v["bw"] > 0]
        if len(vals) >= 2:
            spreads.append((max(vals) / min(vals), t["label"], min(vals), max(vals)))
    spreads.sort(key=lambda s: s[0])

    stats = []
    if spreads:
        smallest, biggest = spreads[0], spreads[-1]
        stats.append({
            "value": f"{biggest[0]:.1f}×", "crit": biggest[0] > 2,
            "label": f"Größter Unterschied — {biggest[1]}",
            "detail": f"{biggest[2]:.0f} – {biggest[3]:.0f} MB/s",
        })
        stats.append({
            "value": f"{smallest[0]:.2f}×", "crit": False,
            "label": f"Kleinster Unterschied — {smallest[1]}",
            "detail": f"{smallest[2]:.0f} – {smallest[3]:.0f} MB/s",
        })
    stats.append({
        "value": str(len(labels)), "crit": False,
        "label": "Getestete Verzeichnisse",
        "detail": ", ".join(all_target_paths[l] for l in labels),
    })

    # Aufrufparameter-Kachel: mit welchem --size/--runtime/--ioengine tatsächlich
    # getestet wurde, auch wenn nur Default-Werte — sonst muss man dafür erst die
    # aufklappbare Testparameter-Tabelle öffnen. Eigene Datenstruktur statt eines
    # generischen stats-Eintrags: das sind mehrere kurze Schlüssel/Wert-Paare, kein
    # einzelner Kennzahlwert — als eine "4G / 30s"-Value gequetscht bricht das im
    # schmalen Kachel-Raster um. Mehrheits-Logik wie params_common oben; da nur die
    # Latenz-Tests bewusst immer psync erzwingen (2 von 7 Tests), gewinnt bei einem
    # einzelnen, konsistenten --ioengine-Aufruf automatisch der richtige Wert.
    invocation_fields = ["size", "runtime", "ioengine", "direct"]
    all_param_rows = [p for params in all_params.values() for p in params.values()]
    common_invocation = {}
    for field in invocation_fields:
        vals = [p[field] for p in all_param_rows]
        common_invocation[field] = Counter(vals).most_common(1)[0][0] if vals else "?"
    call_params = {
        "deviates": any(d[2] in ("size", "runtime") for d in params_deviations),
        "size": common_invocation["size"],
        "runtime": f"{common_invocation['runtime']}s",
        "ioengine": common_invocation["ioengine"],
        "direct": common_invocation["direct"],
    }

    csv_files = sorted(set(
        [os.path.relpath(p, RESULTS_ROOT) for p in glob.glob(os.path.join(RESULTS_ROOT, "*.csv"))]
        + [f"{l}/summary.csv" for l in labels
           if os.path.exists(os.path.join(RESULTS_ROOT, l, "summary.csv"))]
    ))
    # html.escape() auf die CSV-Dateinamen: die enthalten Label-Namen (z.B.
    # "<label>/summary.csv"), also potenziell nutzergesteuerten Text — landet hier
    # direkt als HTML-String (kein JSON-Datenkanal, der clientseitig escaped würde).
    footer_html = (
        f"<div>CSV-Dateien: {' · '.join(f'<code>{html.escape(c)}</code>' for c in csv_files)}</div>"
        f"<div>Erzeugt mit generate-report.py aus storage-bench.sh-Ergebnissen "
        f"({datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}).</div>"
    )

    # Nur Glossar-Einträge für Testarten, die im Report auch tatsächlich vorkommen
    # (test_order) — sonst würde z.B. eine Erklärung zu Latenz-Tests auftauchen,
    # obwohl der Report gar keine Latenz-Tests enthält (falls run mal abgebrochen
    # wurde oder nur eine Teilmenge der *.json vorliegt).
    glossary_tests = [{"term": NAME_MAP.get(t, t) if t != "mixed_70r_30w" else "Mischlast 70/30",
                        "desc": TEST_GLOSSARY[t]}
                       for t in test_order if t in TEST_GLOSSARY]

    report_data = {
        "glossary": {"metrics": METRIC_GLOSSARY, "tests": glossary_tests},
        "meta": {
            "fio_version": fio_version or "unbekannt",
            "generated": datetime.datetime.now().strftime("%Y-%m-%d %H:%M"),
            "labels": labels,
        },
        "locations": locations,
        "tests": tests_json,
        "raw": raw,
        "paramsCommon": params_common,
        "paramsDeviations": params_deviations,
        "paramFields": PARAM_FIELDS,
        "compares": compares,
        "stats": stats,
        "callParams": call_params,
        "footer": footer_html,
    }

    with open(TEMPLATE_PATH) as f:
        template = f.read()

    series_css_light = "\n    ".join(f"--series-{i + 1}: {PALETTE[i][0]};" for i in range(len(labels)))
    series_css_dark = "\n      ".join(f"--series-{i + 1}: {PALETTE[i][1]};" for i in range(len(labels)))

    # "</" escapen: report_data kann durch Testnamen/Labels im Prinzip einen
    # "</script>"-artigen String enthalten, der sonst das umgebende <script>-Tag im
    # Template vorzeitig beenden würde.
    json_str = json.dumps(report_data, ensure_ascii=False).replace("</", "<\\/")

    # html.escape() auf den Titel: labels fließt roh in ", ".join(labels) ein und
    # landet unmittelbar im statischen <title>-Tag (__REPORT_TITLE__-Ersetzung) —
    # ohne Escaping würde z.B. --label "<script>...</script>" dort direkt als
    # HTML geparst, noch bevor überhaupt JS aus dem Report läuft.
    title = html.escape("Storage-Benchmark: " + ", ".join(labels))
    html_out = template.replace("__REPORT_TITLE__", title)
    html_out = html_out.replace("/*__SERIES_CSS_LIGHT__*/", series_css_light)
    html_out = html_out.replace("/*__SERIES_CSS_DARK__*/", series_css_dark)
    html_out = html_out.replace("/*__REPORT_DATA__*/", json_str)

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w") as f:
        f.write(html_out)

    print(f"Report geschrieben: {out_path}")
    print(f"Labels: {', '.join(labels)}")
    if compares:
        print(f"Vergleiche eingebunden: {', '.join(compares.keys())}")
    else:
        print("Keine compare-CSVs gefunden — Report zeigt nur die run-Auswertung.")


if __name__ == "__main__":
    main()
